<#
.SYNOPSIS
    The clock of the engine's wait spin on Linux (Docs/Design.md §12.10, Phase 28): the Blocks benchmark built with
    each clock, run in turns, warm cache only.

.DESCRIPTION
    Builds Pascal.IOUring.Benchmarks.Blocks twice:
      syscall  FPC's clock_gettime, a system call (the default)
      libc     the C library's clock_gettime, through the vDSO (IORING_CLOCK_LIBC)
    and runs them in turns, -Rounds times, on a 1 GiB file whose blocks are in the cache. Each run's tables also become
    one annotation of the workflow run (readable without signing in), and all output goes to the job summary and to
    -OutputFolder.

.PARAMETER Rounds
    How many times each variant runs. Default 3.

.PARAMETER Runs
    Runs per case inside the benchmark (the median is reported). Default 5.

.PARAMETER OutputFolder
    Where the outputs go. Default: the runner's temporary folder.
#>
param(
    [int] $Rounds = 3,
    [int] $Runs = 5,
    [string] $OutputFolder = $env:RUNNER_TEMP
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$build = Join-Path $root 'Source/Build-FPC.ps1'
$variants = [ordered]@{
    syscall = @()
    libc    = @('IORING_CLOCK_LIBC')
}
New-Item -ItemType Directory -Force $OutputFolder | Out-Null

# Build each variant and keep its program
foreach ($name in $variants.Keys) {
    if ($variants[$name].Count -gt 0) {
        & $build -Project Blocks -Define $variants[$name]
    }
    else {
        & $build -Project Blocks
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error title=Clock benchmark::The $name variant did not build"
        exit 1
    }
    $program = Get-ChildItem (Join-Path $root 'Source/Benchmarks/FPC') -Recurse -File -Filter 'Pascal.IOUring.Benchmarks.Blocks.FPC' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Copy-Item $program.FullName (Join-Path $OutputFolder "blocks-$name")
    & chmod +x (Join-Path $OutputFolder "blocks-$name")
}

# Run them in turns; the test file stays for the next run
for ($round = 1; $round -le $Rounds; $round++) {
    foreach ($name in $variants.Keys) {
        $log = Join-Path $OutputFolder "blocks-$name-$round.txt"
        Write-Host "=== $name, round $round"
        & (Join-Path $OutputFolder "blocks-$name") --cache warm --size-gib 1 --runs $Runs --keep 2>&1 | Tee-Object -FilePath $log
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::error title=Clock benchmark::$name, round $round failed (exit code $LASTEXITCODE)"
            exit 1
        }

        # The tables: the list names and the block reader's rows
        $lines = Get-Content $log | Where-Object { $_ -match '^(random|sorted)|^\s+(Block reader|pread)' }
        $message = ($lines -join "`n") -replace '%', '%25' -replace "`r", '' -replace "`n", '%0A'
        Write-Host "::notice title=Clock $name, round $round::$message"

        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content $env:GITHUB_STEP_SUMMARY "### $name, round $round"
            Add-Content $env:GITHUB_STEP_SUMMARY '```'
            Get-Content $log | Add-Content $env:GITHUB_STEP_SUMMARY
            Add-Content $env:GITHUB_STEP_SUMMARY '```'
        }
    }
}
