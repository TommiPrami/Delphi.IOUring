<#
.SYNOPSIS
    Builds (and optionally runs) the Free Pascal test runner or benchmark.

.DESCRIPTION
    Calls the FPC compiler binary directly (ppc386.exe for Win32, ppcx64.exe
    for Win64), so it works without fpc.exe, fpc.cfg or lazbuild. Output goes
    to <project folder>\<Platform>\.

      Tests       Source\UnitTests\FPC\Delphi.IOUring.UnitTests.FPC.lpr  (debug info)
      Benchmarks  Source\Benchmarks\FPC\Delphi.IOUring.Benchmarks.FPC.lpr (optimized)
      Structures  Source\Benchmarks\FPC\Delphi.IOUring.Benchmarks.Structures.FPC.lpr (optimized)
      Blocks      Source\Benchmarks\FPC\Delphi.IOUring.Benchmarks.Blocks.FPC.lpr (optimized)
      Writes      Source\Benchmarks\FPC\Delphi.IOUring.Benchmarks.Writes.FPC.lpr (optimized)

    Linux64 builds and runs inside WSL, with the FPC of the default WSL
    distribution (Ubuntu: sudo apt install fpc). So far only the tests:

      Tests       Source\UnitTests\Linux\Delphi.IOUring.UnitTests.Linux.lpr (debug info)

.PARAMETER Project
    Tests, Benchmarks, Structures, Blocks or Writes. Default Tests.

.PARAMETER Platform
    Win32, Win64 or Linux64. Default Win32.

.PARAMETER FpcDir
    The FPC folder of the Lazarus installation. Default C:\lazarus\fpc\3.2.2.

.PARAMETER LinuxFpcUnits
    Linux64 only: the FPC unit folder inside WSL. Default
    /usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux (Ubuntu's fpc package).

.PARAMETER Optimize
    Tests only: compile with -O3 and with inlining. Without it the tests are a
    debug build: no inlining (IORING_NO_INLINE), so the debugger can step into
    every routine. The atomics tests mean most with optimization on.
    (Benchmarks are always optimized.)

.PARAMETER Run
    Run the program after a successful build. The exit code is the program's.

.PARAMETER RunArguments
    Arguments for the program when -Run is given (e.g. '--sizes', '1').

.EXAMPLE
    .\Build-FPC.ps1 -Project Tests -Platform Win32 -Run

.EXAMPLE
    .\Build-FPC.ps1 -Project Tests -Platform Win64 -Optimize -Run

.EXAMPLE
    .\Build-FPC.ps1 -Project Tests -Platform Linux64 -Run

.EXAMPLE
    .\Build-FPC.ps1 -Project Benchmarks -Run -RunArguments '--sizes','1,10','--runs','3'
#>
[CmdletBinding()]
param(
    [ValidateSet('Tests', 'Benchmarks', 'Structures', 'Blocks', 'Writes')]
    [string] $Project = 'Tests',
    [ValidateSet('Win32', 'Win64', 'Linux64')]
    [string] $Platform = 'Win32',
    [string] $FpcDir = 'C:\lazarus\fpc\3.2.2',
    [string] $LinuxFpcUnits = '/usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux',
    [switch] $Optimize,
    [switch] $Run,
    [string[]] $RunArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir = $PSScriptRoot
$libraryUnits = Join-Path $sourceDir 'Units'
$isLinux64 = $Platform -eq 'Linux64'

if ($isLinux64) {
    if ($Project -ne 'Tests') {
        throw "Linux64: only -Project Tests can be built so far."
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe not found. Linux64 builds in WSL: install WSL, a Linux distribution and FPC in it.'
    }
    & wsl.exe -e test -d $LinuxFpcUnits
    if ($LASTEXITCODE -ne 0) {
        throw "FPC units not found in WSL: $LinuxFpcUnits. Install FPC in WSL (Ubuntu: sudo apt install fpc) or give -LinuxFpcUnits."
    }
    $wslSourceDir = (& wsl.exe -e wslpath -a ($sourceDir -replace '\\', '/'))
    if ($LASTEXITCODE -ne 0 -or -not $wslSourceDir) {
        throw "wslpath could not convert $sourceDir"
    }
    $wslSourceDir = $wslSourceDir.Trim()
    $rtlSearchPath = "$LinuxFpcUnits/*"
} else {
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
    $rtlSearchPath = "$rtlUnits\*"
}

# A path for the compiler: Linux64 compiles in WSL, where C:\... is /mnt/c/...
# (all paths given to the compiler are under $sourceDir)
function ConvertTo-CompilerPath([string] $Path) {
    if (-not $isLinux64) {
        return $Path
    }
    return $wslSourceDir + ($Path.Substring($sourceDir.Length) -replace '\\', '/')
}

if ($Project -eq 'Tests') {
    if ($isLinux64) {
        $projectDir = Join-Path $sourceDir 'UnitTests\Linux'
        $programFile = 'Delphi.IOUring.UnitTests.Linux.lpr'
    } else {
        $projectDir = Join-Path $sourceDir 'UnitTests\FPC'
        $programFile = 'Delphi.IOUring.UnitTests.FPC.lpr'
    }
    $extraUnits = @(Join-Path $sourceDir 'UnitTests')       # TestFileHelpers, TestPlatformHelpers
    $codeOptions = @('-g', '-gl')                            # debug info with line numbers
    if ($Optimize) {
        $codeOptions += '-O3'
    } else {
        $codeOptions += '-dIORING_NO_INLINE'                 # debug build: no inlining (Delphi.IOUring.inc)
    }
} else {
    $projectDir = Join-Path $sourceDir 'Benchmarks\FPC'
    switch ($Project) {
        'Benchmarks' { $programFile = 'Delphi.IOUring.Benchmarks.FPC.lpr' }
        'Structures' { $programFile = 'Delphi.IOUring.Benchmarks.Structures.FPC.lpr' }
        'Blocks'     { $programFile = 'Delphi.IOUring.Benchmarks.Blocks.FPC.lpr' }
        'Writes'     { $programFile = 'Delphi.IOUring.Benchmarks.Writes.FPC.lpr' }
    }
    $extraUnits = @(Join-Path $sourceDir 'Benchmarks')      # Bench.Common, Bench.Readers, Bench.Structures, Bench.Blocks, Bench.Writes
    $codeOptions = @('-O3', '-CX', '-XX', '-Xs')             # optimized, smart linking, stripped
}

$outputDir = Join-Path $projectDir $Platform
$unitOutputDir = Join-Path $outputDir 'units'
New-Item -ItemType Directory -Force -Path $unitOutputDir | Out-Null

$arguments = @('-n', '-B', '-vewn') + $codeOptions + @(
    "-Fu$rtlSearchPath",
    "-Fu$(ConvertTo-CompilerPath $libraryUnits)",
    "-Fi$(ConvertTo-CompilerPath $libraryUnits)",
    "-FU$(ConvertTo-CompilerPath $unitOutputDir)",
    "-FE$(ConvertTo-CompilerPath $outputDir)"
)
foreach ($unitDir in $extraUnits) {
    $arguments += "-Fu$(ConvertTo-CompilerPath $unitDir)"
}
$arguments += (ConvertTo-CompilerPath (Join-Path $projectDir $programFile))

if ($isLinux64) {
    Write-Host "Compiling $programFile with the FPC of WSL for $Platform"
    & wsl.exe -e fpc @arguments
} else {
    Write-Host "Compiling $programFile with $($compiler.FullName) for $Platform"
    & $compiler.FullName @arguments
}
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if ($Run) {
    if ($isLinux64) {
        & wsl.exe -e (ConvertTo-CompilerPath (Join-Path $outputDir ([IO.Path]::GetFileNameWithoutExtension($programFile)))) @RunArguments
    } else {
        & (Join-Path $outputDir ([IO.Path]::ChangeExtension($programFile, '.exe'))) @RunArguments
    }
    exit $LASTEXITCODE
}
