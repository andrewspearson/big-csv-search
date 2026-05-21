#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SearchScript = Join-Path $script:RepoRoot "Search-Csv.ps1"

function Write-TestPass {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $script:Passed++
    Write-Host "[PASS] $Name"
}

function Write-TestFail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:Failed++
    Write-Host "[FAIL] $Name"
    Write-Host "       $Message"
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,

        [Parameter(Mandatory = $true)]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected: [$Expected]. Actual: [$Actual]."
    }
}

function Assert-Contains {
    param(
        [AllowNull()]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSubstring,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($null -eq $Actual -or -not $Actual.Contains($ExpectedSubstring)) {
        throw "$Message Expected substring: [$ExpectedSubstring]. Actual: [$Actual]."
    }
}

function Assert-NotContains {
    param(
        [AllowNull()]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$UnexpectedSubstring,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($null -ne $Actual -and $Actual.Contains($UnexpectedSubstring)) {
        throw "$Message Unexpected substring: [$UnexpectedSubstring]. Actual: [$Actual]."
    }
}

function Assert-FileLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedLines,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Message File does not exist: $Path"
    }

    $actualLines = [System.IO.File]::ReadAllLines($Path)
    Assert-Equal -Actual $actualLines.Count -Expected $ExpectedLines.Count -Message "$Message Line count mismatch."

    for ($i = 0; $i -lt $ExpectedLines.Count; $i++) {
        Assert-Equal -Actual $actualLines[$i] -Expected $ExpectedLines[$i] -Message "$Message Line $($i + 1) mismatch."
    }
}

function New-TestDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("big-csv-search-tests-" + [guid]::NewGuid().ToString("N"))
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Write-TestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
}

function Invoke-SearchCsv {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $processInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $pwsh
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    [void]$processInfo.ArgumentList.Add("-NoProfile")
    [void]$processInfo.ArgumentList.Add("-File")
    [void]$processInfo.ArgumentList.Add($script:SearchScript)

    foreach ($argument in $Arguments) {
        [void]$processInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    $tempDir = New-TestDirectory

    try {
        & $Body $tempDir
        Write-TestPass -Name $Name
    } catch {
        Write-TestFail -Name $Name -Message $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

if (-not (Test-Path -LiteralPath $script:SearchScript)) {
    throw "Search script not found: $script:SearchScript"
}

Invoke-Test -Name "missing required paths prints usage" -Body {
    param($tempDir)

    $result = Invoke-SearchCsv -Arguments @()

    Assert-Equal -Actual $result.ExitCode -Expected 1 -Message "Exit code should indicate failure."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "usage: .\Search-Csv.ps1" -Message "Usage should be printed to stderr."
    Assert-Equal -Actual $result.StdOut -Expected "" -Message "Stdout should stay empty."
}

Invoke-Test -Name "requires column or column name" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    Write-TestFile -Path $csv -Lines @("id,name", "1,Alice")
    Write-TestFile -Path $items -Lines @("Alice")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 1 -Message "Exit code should indicate failure."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "provide either -Column or -ColumnName" -Message "Column validation should be printed."
}

Invoke-Test -Name "column name requires header" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    Write-TestFile -Path $csv -Lines @("id,name", "1,Alice")
    Write-TestFile -Path $items -Lines @("Alice")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-ColumnName", "name", "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 1 -Message "Exit code should indicate failure."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "-ColumnName requires -HasHeader" -Message "Header validation should be printed."
}

Invoke-Test -Name "zero-based column search returns matching rows" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    $out = Join-Path $tempDir "out.csv"
    Write-TestFile -Path $csv -Lines @(
        "1,Alice,no match",
        "2,Bob,needle inside",
        "3,Carla,other"
    )
    Write-TestFile -Path $items -Lines @("needle")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-Column", "2", "-Out", $out, "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Search should succeed."
    Assert-FileLines -Path $out -ExpectedLines @("2,Bob,needle inside") -Message "Output rows should match."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "done: processed 3 rows, found 1 matches" -Message "Final summary should be on stderr."
    Assert-Equal -Actual $result.StdOut -Expected "" -Message "Stdout should stay empty."
}

Invoke-Test -Name "header column search is case-insensitive and skips short rows" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    $out = Join-Path $tempDir "out.csv"
    Write-TestFile -Path $csv -Lines @(
        "id,name,note",
        "1,Alice,no match",
        "2,""Bob, Jr."",""contains TARGET value""",
        "3,Eve,""said """"hello"""" to acme""",
        "4,Dan"
    )
    Write-TestFile -Path $items -Lines @("  target  ", "", "ACME", "target")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-HasHeader", "-ColumnName", "NOTE", "-Out", $out, "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Search should succeed."
    Assert-FileLines -Path $out -ExpectedLines @(
        "id,name,note",
        "2,""Bob, Jr."",contains TARGET value",
        "3,Eve,""said """"hello"""" to acme"""
    ) -Message "Header search output should match."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "done: processed 4 rows, found 2 matches" -Message "Final summary should count data rows."
}

Invoke-Test -Name "no matches with header writes only header" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    $out = Join-Path $tempDir "out.csv"
    Write-TestFile -Path $csv -Lines @("id,name,note", "1,Alice,no match", "2,Bob,also no")
    Write-TestFile -Path $items -Lines @("missing")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-HasHeader", "-ColumnName", "note", "-Out", $out, "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Search should succeed."
    Assert-FileLines -Path $out -ExpectedLines @("id,name,note") -Message "Only the header should be written."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "found 0 matches" -Message "Final summary should report zero matches."
}

Invoke-Test -Name "lower output lowercases every emitted field" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    $out = Join-Path $tempDir "out.csv"
    Write-TestFile -Path $csv -Lines @("ID,Name,Note", "1,ALICE,MatchMe", "2,Bob,skip")
    Write-TestFile -Path $items -Lines @("matchme")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-HasHeader", "-ColumnName", "note", "-Out", $out, "-LowerOutput", "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Search should succeed."
    Assert-FileLines -Path $out -ExpectedLines @("id,name,note", "1,alice,matchme") -Message "Output should be lowercased."
}

Invoke-Test -Name "progress zero suppresses periodic progress" -Body {
    param($tempDir)

    $csv = Join-Path $tempDir "input.csv"
    $items = Join-Path $tempDir "items.txt"
    $out = Join-Path $tempDir "out.csv"
    Write-TestFile -Path $csv -Lines @("1,Alice,match", "2,Bob,match")
    Write-TestFile -Path $items -Lines @("match")

    $result = Invoke-SearchCsv -Arguments @("-Csv", $csv, "-Items", $items, "-Column", "2", "-Out", $out, "-Progress", "0")

    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Search should succeed."
    Assert-NotContains -Actual $result.StdErr -UnexpectedSubstring "processed 1 rows" -Message "Periodic progress should be suppressed."
    Assert-Contains -Actual $result.StdErr -ExpectedSubstring "done: processed 2 rows, found 2 matches" -Message "Final summary should still be emitted."
}

Write-Host ""
Write-Host ("Tests complete: {0} passed, {1} failed" -f $script:Passed, $script:Failed)

if ($script:Failed -gt 0) {
    exit 1
}

exit 0
