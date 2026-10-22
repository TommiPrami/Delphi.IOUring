<#
.SYNOPSIS
    Builds (and optionally runs) the Free Pascal test runner or benchmark.

.DESCRIPTION
    Calls the FPC compiler binary directly (ppc386.exe for Win32, ppcx64.exe
    for Win64), so it works without fpc.exe, fpc.cfg or lazbuild. Output goes
    to <project folder>\<Platform>\.

      Tests       Source\UnitTests\FPC\Delphi.IOUring.UnitTests.FPC.lpr  (debug info)
      Benchmarks  Source\Benchmarks\FPC\Delphi.IOUring.Benchmarks.FPC.lpr (optimized)

.PARAMETER Project
    Tests or Benchmarks. Default Tests.

.PARAMETER Platform
    Win32 or Win64. Default Win32.

.PARAMETER FpcDir
    The FPC folder of the Lazarus installation. Default C:\lazarus\fpc\3.2.2.

.PARAMETER Optimize
    Tests only: compile with -O3 too. The atomics tests mean most with
    optimization on. (Benchmarks are always optimized.)

.PARAMETER Run
    Run the program after a successful build. The exit code is the program's.

.PARAMETER RunArguments
    Arguments for the program when -Run is given (e.g. '--sizes', '1').

.EXAMPLE
    .\Build-FPC.ps1 -Project Tests -Platform Win32 -Run

.EXAMPLE
    .\Build-FPC.ps1 -Project Tests -Platform Win64 -Optimize -Run

.EXAMPLE
    .\Build-FPC.ps1 -Project Benchmarks -Run -RunArguments '--sizes','1,10','--runs','3'
#>
[CmdletBinding()]
param(
    [ValidateSet('Tests', 'Benchmarks')]
    [string] $Project = 'Tests',
    [ValidateSet('Win32', 'Win64')]
    [string] $Platform = 'Win32',
    [string] $FpcDir = 'C:\lazarus\fpc\3.2.2',
    [switch] $Optimize,
    [switch] $Run,
    [string[]] $RunArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Platform -eq 'Win32') {
    $compilerName = 'ppc386.exe'
    $target = 'i386-win32'
} else {
    $compilerName = 'ppcx64.exe'
    $target = 'x86_64-win64'
}

# The compiler can be a native or a cross compiler; take the first one found
$compiler = Get-ChildItem -Path (Join-Path $FpcDir 'bin') -Recurse -Filter $compilerName -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $compiler) {
    throw "$compilerName not found under $FpcDir\bin. Install or repair Lazarus/FPC for $Platform."
}

$rtlUnits = Join-Path $FpcDir "units\$target"
if (-not (Test-Path $rtlUnits)) {
    throw "FPC units for $target not found: $rtlUnits"
}

$sourceDir = $PSScriptRoot
$libraryUnits = Join-Path $sourceDir 'Units'

if ($Project -eq 'Tests') {
    $projectDir = Join-Path $sourceDir 'UnitTests\FPC'
    $programFile = 'Delphi.IOUring.UnitTests.FPC.lpr'
    $extraUnits = @(Join-Path $sourceDir 'UnitTests')       # TestFileHelpers, TestPlatformHelpers
    $codeOptions = @('-g', '-gl')                            # debug info with line numbers
    if ($Optimize) {
        $codeOptions += '-O3'
    }
} else {
    $projectDir = Join-Path $sourceDir 'Benchmarks\FPC'
    $programFile = 'Delphi.IOUring.Benchmarks.FPC.lpr'
    $extraUnits = @(Join-Path $sourceDir 'Benchmarks')      # Bench.Common, Bench.Readers
    $codeOptions = @('-O3', '-CX', '-XX', '-Xs')             # optimized, smart linking, stripped
}

$outputDir = Join-Path $projectDir $Platform
$unitOutputDir = Join-Path $outputDir 'units'
New-Item -ItemType Directory -Force -Path $unitOutputDir | Out-Null

$arguments = @('-n', '-B', '-vewn') + $codeOptions + @(
    "-Fu$rtlUnits\*",
    "-Fu$libraryUnits",
    "-Fi$libraryUnits",
    "-FU$unitOutputDir",
    "-FE$outputDir"
)
foreach ($unitDir in $extraUnits) {
    $arguments += "-Fu$unitDir"
}
$arguments += (Join-Path $projectDir $programFile)

Write-Host "Compiling $programFile with $($compiler.FullName) for $Platform"
& $compiler.FullName @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if ($Run) {
    & (Join-Path $outputDir ([IO.Path]::ChangeExtension($programFile, '.exe'))) @RunArguments
    exit $LASTEXITCODE
}
