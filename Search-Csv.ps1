#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Csv = "",

    [Parameter()]
    [string]$Items = "",

    [Parameter()]
    [int]$Column = -1,

    [Parameter()]
    [string]$ColumnName = "",

    [Parameter()]
    [string]$Out = "matches.csv",

    [Parameter()]
    [switch]$HasHeader,

    [Parameter()]
    [switch]$LowerOutput,

    [Parameter()]
    [long]$Progress = 1000000
)

Set-StrictMode -Version 2.0

function Write-Stderr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [Console]::Error.WriteLine($Message)
}

function Normalize-Value {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return $Value.Trim().ToLowerInvariant()
}

function New-AhoNode {
    return @{
        Next = @{}
        Fail = 0
        Output = $false
    }
}

function Add-AhoPattern {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$Nodes,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $current = 0

    for ($i = 0; $i -lt $Pattern.Length; $i++) {
        $char = [string]$Pattern[$i]
        $nextMap = $Nodes[$current]["Next"]

        if (-not $nextMap.ContainsKey($char)) {
            $next = $Nodes.Count
            [void]$Nodes.Add((New-AhoNode))
            $nextMap[$char] = $next
        } else {
            $next = $nextMap[$char]
        }

        $current = $next
    }

    $Nodes[$current]["Output"] = $true
}

function Complete-AhoFailures {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$Nodes
    )

    $queue = New-Object -TypeName System.Collections.ArrayList
    foreach ($child in $Nodes[0]["Next"].Values) {
        [void]$queue.Add($child)
    }

    for ($head = 0; $head -lt $queue.Count; $head++) {
        $current = $queue[$head]
        $currentNext = $Nodes[$current]["Next"]

        foreach ($char in @($currentNext.Keys)) {
            $child = $currentNext[$char]
            [void]$queue.Add($child)

            $failure = $Nodes[$current]["Fail"]
            while ($failure -ne 0) {
                $failureNext = $Nodes[$failure]["Next"]
                if ($failureNext.ContainsKey($char)) {
                    $Nodes[$child]["Fail"] = $failureNext[$char]
                    break
                }
                $failure = $Nodes[$failure]["Fail"]
            }

            if ($failure -eq 0) {
                $rootNext = $Nodes[0]["Next"]
                if ($rootNext.ContainsKey($char) -and $rootNext[$char] -ne $child) {
                    $Nodes[$child]["Fail"] = $rootNext[$char]
                }
            }

            if ($Nodes[$Nodes[$child]["Fail"]]["Output"]) {
                $Nodes[$child]["Output"] = $true
            }
        }
    }
}

function New-AhoCorasick {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    $nodes = New-Object -TypeName System.Collections.ArrayList
    [void]$nodes.Add((New-AhoNode))

    foreach ($pattern in $Patterns) {
        Add-AhoPattern -Nodes $nodes -Pattern $pattern
    }

    Complete-AhoFailures -Nodes $nodes

    return @{
        Nodes = $nodes
    }
}

function Test-AhoContains {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Matcher,

        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    $nodes = $Matcher["Nodes"]
    $current = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $char = [string]$Text[$i]

        while ($current -ne 0) {
            if ($nodes[$current]["Next"].ContainsKey($char)) {
                break
            }
            $current = $nodes[$current]["Fail"]
        }

        if ($nodes[$current]["Next"].ContainsKey($char)) {
            $current = $nodes[$current]["Next"][$char]
        }

        if ($nodes[$current]["Output"]) {
            return $true
        }
    }

    return $false
}

function Load-Items {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $reader = $null
    $seen = @{}
    $itemsList = New-Object -TypeName System.Collections.ArrayList

    try {
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($Path, [System.Text.Encoding]::UTF8, $true, 1048576)

        while (-not $reader.EndOfStream) {
            $item = Normalize-Value -Value $reader.ReadLine()
            if ($item.Length -eq 0) {
                continue
            }
            if ($seen.ContainsKey($item)) {
                continue
            }

            $seen[$item] = $true
            [void]$itemsList.Add($item)
        }
    } catch {
        throw "read items file: $($_.Exception.Message)"
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    return [string[]]$itemsList.ToArray([string])
}

function Initialize-TextFieldParser {
    $typeName = "Microsoft.VisualBasic.FileIO.TextFieldParser, Microsoft.VisualBasic"
    $parserType = [Type]::GetType($typeName, $false)

    if ($null -eq $parserType) {
        try {
            [void][System.Reflection.Assembly]::Load("Microsoft.VisualBasic")
        } catch {
            $loadedAssembly = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.VisualBasic")
            if ($null -eq $loadedAssembly) {
                throw "The built-in Microsoft.VisualBasic assembly is not available."
            }
        }
    }

    $parserType = [Type]::GetType($typeName, $false)
    if ($null -eq $parserType) {
        throw "The built-in Microsoft.VisualBasic TextFieldParser type is not available."
    }
}

function New-CsvParser {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamReader]$Reader
    )

    Initialize-TextFieldParser

    $parser = New-Object -TypeName "Microsoft.VisualBasic.FileIO.TextFieldParser" -ArgumentList $Reader
    $parser.TextFieldType = "Delimited"
    $parser.SetDelimiters(",")
    $parser.HasFieldsEnclosedInQuotes = $true
    $parser.TrimWhiteSpace = $false

    return $parser
}

function Find-Column {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Header,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $wanted = Normalize-Value -Value $Name

    for ($i = 0; $i -lt $Header.Length; $i++) {
        if ((Normalize-Value -Value $Header[$i]) -eq $wanted) {
            return $i
        }
    }

    return -1
}

function Format-Record {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Record,

        [Parameter(Mandatory = $true)]
        [bool]$UseLowerOutput
    )

    if (-not $UseLowerOutput) {
        return $Record
    }

    $formatted = New-Object -TypeName "System.String[]" -ArgumentList $Record.Length
    for ($i = 0; $i -lt $Record.Length; $i++) {
        if ($null -eq $Record[$i]) {
            $formatted[$i] = ""
        } else {
            $formatted[$i] = $Record[$i].ToLowerInvariant()
        }
    }

    return $formatted
}

function ConvertTo-CsvLine {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Record
    )

    $builder = New-Object -TypeName System.Text.StringBuilder

    for ($i = 0; $i -lt $Record.Length; $i++) {
        if ($i -gt 0) {
            [void]$builder.Append(",")
        }

        $field = $Record[$i]
        if ($null -eq $field) {
            $field = ""
        }

        $mustQuote = (
            $field.Contains(",") -or
            $field.Contains('"') -or
            $field.Contains("`r") -or
            $field.Contains("`n") -or
            ($field.Length -gt 0 -and [char]::IsWhiteSpace($field[0]))
        )

        if ($mustQuote) {
            [void]$builder.Append('"')
            [void]$builder.Append($field.Replace('"', '""'))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append($field)
        }
    }

    return $builder.ToString()
}

function Write-CsvRecord {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamWriter]$Writer,

        [Parameter(Mandatory = $true)]
        [string[]]$Record
    )

    $Writer.WriteLine((ConvertTo-CsvLine -Record $Record))
}

function Search-CsvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [int]$ColumnIndex,

        [Parameter()]
        [string]$HeaderColumnName,

        [Parameter(Mandatory = $true)]
        [bool]$TreatFirstRowAsHeader,

        [Parameter(Mandatory = $true)]
        [bool]$UseLowerOutput,

        [Parameter(Mandatory = $true)]
        [long]$ProgressEvery,

        [Parameter(Mandatory = $true)]
        [hashtable]$Matcher
    )

    $inputReader = $null
    $outputWriter = $null
    $parser = $null

    try {
        $inputReader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($CsvPath, [System.Text.Encoding]::UTF8, $true, 4194304)
        $outputWriter = New-Object -TypeName System.IO.StreamWriter -ArgumentList @($OutputPath, $false, [System.Text.Encoding]::UTF8, 4194304)
        $parser = New-CsvParser -Reader $inputReader

        $column = $ColumnIndex

        if ($TreatFirstRowAsHeader) {
            if ($parser.EndOfData) {
                return
            }

            try {
                $header = [string[]]$parser.ReadFields()
            } catch {
                throw "read header: $($_.Exception.Message)"
            }

            if (-not [string]::IsNullOrEmpty($HeaderColumnName)) {
                $column = Find-Column -Header $header -Name $HeaderColumnName
                if ($column -lt 0) {
                    throw "column `"$HeaderColumnName`" not found in header"
                }
            }

            if ($column -ge $header.Length) {
                throw "column index $column is outside header width $($header.Length)"
            }

            Write-CsvRecord -Writer $outputWriter -Record (Format-Record -Record $header -UseLowerOutput $UseLowerOutput)
        }

        $start = Get-Date
        [long]$rows = 0
        [long]$matches = 0

        while (-not $parser.EndOfData) {
            try {
                $record = [string[]]$parser.ReadFields()
            } catch {
                throw "read CSV row $($rows + 1): $($_.Exception.Message)"
            }

            $rows++
            if ($column -ge $record.Length) {
                continue
            }

            $value = Normalize-Value -Value $record[$column]
            if (Test-AhoContains -Matcher $Matcher -Text $value) {
                $matches++
                Write-CsvRecord -Writer $outputWriter -Record (Format-Record -Record $record -UseLowerOutput $UseLowerOutput)
            }

            if ($ProgressEvery -gt 0 -and ($rows % $ProgressEvery) -eq 0) {
                $elapsed = [DateTime]::Now - $start
                Write-Stderr -Message ("processed {0} rows, found {1} matches, elapsed {2}" -f $rows, $matches, $elapsed.ToString("c"))
            }
        }

        $outputWriter.Flush()
        $elapsedFinal = [DateTime]::Now - $start
        Write-Stderr -Message ("done: processed {0} rows, found {1} matches, elapsed {2}" -f $rows, $matches, $elapsedFinal.ToString("c"))
    } finally {
        if ($null -ne $parser) {
            $parser.Dispose()
        }
        if ($null -ne $outputWriter) {
            $outputWriter.Dispose()
        }
        if ($null -ne $inputReader) {
            $inputReader.Dispose()
        }
    }
}

try {
    if ([string]::IsNullOrEmpty($Csv) -or [string]::IsNullOrEmpty($Items)) {
        throw "usage: .\Search-Csv.ps1 -Csv huge.csv -Items items.txt -Column 2 -Out matches.csv"
    }
    if ($Column -lt 0 -and [string]::IsNullOrEmpty($ColumnName)) {
        throw "provide either -Column or -ColumnName"
    }
    if (-not [string]::IsNullOrEmpty($ColumnName) -and -not $HasHeader) {
        throw "-ColumnName requires -HasHeader"
    }

    $loadedItems = @(Load-Items -Path $Items)
    if ($loadedItems.Length -eq 0) {
        throw "items file did not contain any search terms"
    }

    $matcher = New-AhoCorasick -Patterns $loadedItems

    Search-CsvFile `
        -CsvPath $Csv `
        -OutputPath $Out `
        -ColumnIndex $Column `
        -HeaderColumnName $ColumnName `
        -TreatFirstRowAsHeader ([bool]$HasHeader) `
        -UseLowerOutput ([bool]$LowerOutput) `
        -ProgressEvery $Progress `
        -Matcher $matcher
} catch {
    Write-Stderr -Message $_.Exception.Message
    exit 1
}
