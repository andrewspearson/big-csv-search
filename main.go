package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

type node struct {
	next   map[byte]int
	fail   int
	output bool
}

type ahoCorasick struct {
	nodes []node
}

func main() {
	csvPath := flag.String("csv", "", "large CSV file to search")
	itemsPath := flag.String("items", "", "file containing one search term per line")
	column := flag.Int("column", -1, "zero-based CSV column index to search")
	columnName := flag.String("column-name", "", "CSV column name to search; requires -has-header")
	outputPath := flag.String("out", "matches.csv", "output CSV file")
	hasHeader := flag.Bool("has-header", false, "treat the first CSV row as a header")
	lowerOutput := flag.Bool("lower-output", false, "write matching output rows in lower case")
	progressEvery := flag.Int64("progress", 1_000_000, "print progress every N rows; use 0 to disable")
	flag.Parse()

	if *csvPath == "" || *itemsPath == "" {
		exitWithError("usage: searchcsv -csv huge.csv -items items.txt -column 2 -out matches.csv")
	}
	if *column < 0 && *columnName == "" {
		exitWithError("provide either -column or -column-name")
	}
	if *columnName != "" && !*hasHeader {
		exitWithError("-column-name requires -has-header")
	}

	items, err := loadItems(*itemsPath)
	if err != nil {
		exitWithError(err.Error())
	}
	if len(items) == 0 {
		exitWithError("items file did not contain any search terms")
	}

	matcher := newAhoCorasick(items)

	err = searchCSV(searchOptions{
		csvPath:       *csvPath,
		outputPath:    *outputPath,
		column:        *column,
		columnName:    *columnName,
		hasHeader:     *hasHeader,
		lowerOutput:   *lowerOutput,
		progressEvery: *progressEvery,
		matcher:       matcher,
	})
	if err != nil {
		exitWithError(err.Error())
	}
}

type searchOptions struct {
	csvPath       string
	outputPath    string
	column        int
	columnName    string
	hasHeader     bool
	lowerOutput   bool
	progressEvery int64
	matcher       *ahoCorasick
}

func loadItems(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open items file: %w", err)
	}
	defer file.Close()

	seen := make(map[string]struct{})
	items := make([]string, 0)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1024), 1024*1024)

	for scanner.Scan() {
		item := normalize(scanner.Text())
		if item == "" {
			continue
		}
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		items = append(items, item)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read items file: %w", err)
	}

	return items, nil
}

func searchCSV(options searchOptions) error {
	input, err := os.Open(options.csvPath)
	if err != nil {
		return fmt.Errorf("open CSV: %w", err)
	}
	defer input.Close()

	output, err := os.Create(options.outputPath)
	if err != nil {
		return fmt.Errorf("create output CSV: %w", err)
	}
	defer output.Close()

	reader := csv.NewReader(bufio.NewReaderSize(input, 4*1024*1024))
	reader.ReuseRecord = true
	reader.FieldsPerRecord = -1

	bufferedOutput := bufio.NewWriterSize(output, 4*1024*1024)
	writer := csv.NewWriter(bufferedOutput)
	defer writer.Flush()

	column := options.column

	if options.hasHeader {
		header, err := reader.Read()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read header: %w", err)
		}

		if options.columnName != "" {
			column = findColumn(header, options.columnName)
			if column < 0 {
				return fmt.Errorf("column %q not found in header", options.columnName)
			}
		}

		if column >= len(header) {
			return fmt.Errorf("column index %d is outside header width %d", column, len(header))
		}

		if err := writer.Write(formatRecord(header, options.lowerOutput)); err != nil {
			return fmt.Errorf("write header: %w", err)
		}
	}

	start := time.Now()
	var rows int64
	var matches int64

	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read CSV row %d: %w", rows+1, err)
		}

		rows++
		if column >= len(record) {
			continue
		}

		value := normalize(record[column])
		if options.matcher.contains(value) {
			matches++
			if err := writer.Write(formatRecord(record, options.lowerOutput)); err != nil {
				return fmt.Errorf("write match on row %d: %w", rows, err)
			}
		}

		if options.progressEvery > 0 && rows%options.progressEvery == 0 {
			elapsed := time.Since(start).Round(time.Second)
			fmt.Fprintf(os.Stderr, "processed %d rows, found %d matches, elapsed %s\n", rows, matches, elapsed)
		}
	}

	if err := writer.Error(); err != nil {
		return fmt.Errorf("flush output CSV: %w", err)
	}
	if err := bufferedOutput.Flush(); err != nil {
		return fmt.Errorf("flush output buffer: %w", err)
	}

	elapsed := time.Since(start).Round(time.Second)
	fmt.Fprintf(os.Stderr, "done: processed %d rows, found %d matches, elapsed %s\n", rows, matches, elapsed)
	return nil
}

func findColumn(header []string, columnName string) int {
	wanted := normalize(columnName)
	for i, name := range header {
		if normalize(name) == wanted {
			return i
		}
	}
	return -1
}

func formatRecord(record []string, lowerOutput bool) []string {
	if !lowerOutput {
		return record
	}

	formatted := make([]string, len(record))
	for i, value := range record {
		formatted[i] = strings.ToLower(value)
	}
	return formatted
}

func normalize(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func newAhoCorasick(patterns []string) *ahoCorasick {
	matcher := &ahoCorasick{
		nodes: []node{newNode()},
	}

	for _, pattern := range patterns {
		matcher.add(pattern)
	}
	matcher.buildFailures()

	return matcher
}

func newNode() node {
	return node{
		next: make(map[byte]int),
	}
}

func (matcher *ahoCorasick) add(pattern string) {
	current := 0
	for i := 0; i < len(pattern); i++ {
		char := pattern[i]
		next, ok := matcher.nodes[current].next[char]
		if !ok {
			next = len(matcher.nodes)
			matcher.nodes = append(matcher.nodes, newNode())
			matcher.nodes[current].next[char] = next
		}
		current = next
	}
	matcher.nodes[current].output = true
}

func (matcher *ahoCorasick) buildFailures() {
	queue := make([]int, 0)
	for _, child := range matcher.nodes[0].next {
		queue = append(queue, child)
	}

	for head := 0; head < len(queue); head++ {
		current := queue[head]

		for char, child := range matcher.nodes[current].next {
			queue = append(queue, child)

			failure := matcher.nodes[current].fail
			for failure != 0 {
				if next, ok := matcher.nodes[failure].next[char]; ok {
					matcher.nodes[child].fail = next
					break
				}
				failure = matcher.nodes[failure].fail
			}

			if failure == 0 {
				if next, ok := matcher.nodes[0].next[char]; ok && next != child {
					matcher.nodes[child].fail = next
				}
			}

			if matcher.nodes[matcher.nodes[child].fail].output {
				matcher.nodes[child].output = true
			}
		}
	}
}

func (matcher *ahoCorasick) contains(text string) bool {
	current := 0

	for i := 0; i < len(text); i++ {
		char := text[i]

		for current != 0 {
			if _, ok := matcher.nodes[current].next[char]; ok {
				break
			}
			current = matcher.nodes[current].fail
		}

		if next, ok := matcher.nodes[current].next[char]; ok {
			current = next
		}

		if matcher.nodes[current].output {
			return true
		}
	}

	return false
}

func exitWithError(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
