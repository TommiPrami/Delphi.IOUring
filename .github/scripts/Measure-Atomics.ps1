<#
.SYNOPSIS
    The atomics on AArch64 (Docs/Design.md §12.9): the Structures benchmark built with each way of doing the atomics,
    run in turns.

.DESCRIPTION
    Builds Delphi.IOUring.Benchmarks.Structures three times:
      rtl    the way before Phase 27 (FPC's Interlocked routines, a full barrier on each side, no CPU hint)
      yield  the assembler routines, CpuPause = YIELD
      isb    the assembler routines, CpuPause = ISB (the default since Phase 27)
    and runs them in turns, -Rounds times. Each run's tables also become one annotation of the workflow run (readable
    without signing in), and all output goes to the job summary and to -OutputFolder.

.PARAMETER Rounds
    How many times each variant runs. Default 2.

.PARAMETER Threads
    Thread counts for the benchmark. Default 1,2,4 (the runner has 4 processors).

.PARAMETER Runs
    Runs per case inside the benchmark (the median is reported). Default 3.

.PARAMETER OutputFolder
    Where the outputs go. Default: the runner's temporary folder.
#>
param(
    [int] $Rounds = 2,
    [string] $Threads = '1,2,4',
    [int] $Runs = 3,
    [string] $OutputFolder = $env:RUNNER_TEMP
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$build = Join-Path $root 'Source/Build-FPC.ps1'
$variants = [ordered]@{
    rtl   = @('IORING_ATOMICS_AARCH64_RTL')
    yield = @('IORING_ATOMICS_AARCH64_YIELD')
    isb   = @()
}
New-Item -ItemType Directory -Force $OutputFolder | Out-Null

# Build each variant and keep its program
foreach ($name in $variants.Keys) {
    & $build -Project Structures -Define $variants[$name]
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error title=Atomics benchmark::The $name variant did not build"
        exit 1
    }
    $program = Get-ChildItem (Join-Path $root 'Source/Benchmarks/FPC') -Recurse -File -Filter 'Delphi.IOUring.Benchmarks.Structures.FPC' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Copy-Item $program.FullName (Join-Path $OutputFolder "structures-$name")
    & chmod +x (Join-Path $OutputFolder "structures-$name")
}

# Run them in turns
for ($round = 1; $round -le $Rounds; $round++) {
    foreach ($name in $variants.Keys) {
        $log = Join-Path $OutputFolder "structures-$name-$round.txt"
        Write-Host "=== $name, round $round"
        & (Join-Path $OutputFolder "structures-$name") --threads $Threads --runs $Runs 2>&1 | Tee-Object -FilePath $log
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::error title=Atomics benchmark::$name, round $round failed (exit code $LASTEXITCODE)"
            exit 1
        }

        # The tables: the structure's first line and the rows (scenario, threads, lock-free, lock, ratio ...)
        $lines = Get-Content $log | Where-Object { $_ -match '^(Free list:|Request queue:|tight\s|work 1 us\s)' }
        $message = ($lines -join "`n") -replace '%', '%25' -replace "`r", '' -replace "`n", '%0A'
        Write-Host "::notice title=Atomics $name, round $round::$message"

        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content $env:GITHUB_STEP_SUMMARY "### $name, round $round"
            Add-Content $env:GITHUB_STEP_SUMMARY '```'
            Get-Content $log | Add-Content $env:GITHUB_STEP_SUMMARY
            Add-Content $env:GITHUB_STEP_SUMMARY '```'
        }
    }
}
