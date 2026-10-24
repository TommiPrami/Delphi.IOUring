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
      Package     Source\Packages\Lazarus\DelphiIOUring.pas: the main unit of the
                  Lazarus package, compiled without Lazarus (optimized; no -Run)

    Linux: on Windows, Linux64 builds and runs inside WSL, with the FPC of the
    default WSL distribution (Ubuntu: sudo apt install fpc). On a Linux
    machine (PowerShell 7) Linux64 and LinuxArm64 build natively with the FPC
    there - the platform of the machine, no cross compiling. All projects:
    the tests with the Linux-only tests of Source\UnitTests\Linux, the
    benchmarks without their Windows-only contenders.

.PARAMETER Project
    Tests, Benchmarks, Structures, Blocks, Writes or Package. Default Tests.

.PARAMETER Platform
    Win32, Win64, Linux64 or LinuxArm64. Default: Win32 on Windows, the
    machine's own platform on Linux.

.PARAMETER FpcDir
    Windows only: the FPC folder of the Lazarus installation. Default
    C:\lazarus\fpc\3.2.2.

.PARAMETER LinuxFpcUnits
    Linux only: the FPC unit folder. Default: the folder of the distribution's
    fpc package, /usr/lib/<cpu>-linux-gnu/fpc/<version>/units/<cpu>-linux.

.PARAMETER Distribution
    Linux64 on Windows only: the WSL distribution to build and run in (a name
    from "wsl -l", for example Ubuntu-26.04). Default: WSL's default
    distribution. All distributions use the same output folder: run a program
    in the distribution that built it.

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

.EXAMPLE
    .\Build-FPC.ps1 -Project Blocks -Platform Linux64 -Run -RunArguments '--size-gib','2'

.EXAMPLE
    pwsh Source/Build-FPC.ps1 -Project Tests -Optimize -Run     # on a Linux machine (x64 or ARM64)
#>
[CmdletBinding()]
param(
    [ValidateSet('Tests', 'Benchmarks', 'Structures', 'Blocks', 'Writes', 'Package')]
    [string] $Project = 'Tests',
    [ValidateSet('Win32', 'Win64', 'Linux64', 'LinuxArm64')]
    [string] $Platform = '',
    [string] $FpcDir = 'C:\lazarus\fpc\3.2.2',
    [string] $LinuxFpcUnits = '',
    [string] $Distribution = '',
    [switch] $Optimize,
    [switch] $Run,
    [string[]] $RunArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $IsLinux exists in PowerShell 6 and newer only
$onLinuxHost = (Test-Path variable:IsLinux) -and $IsLinux

$sourceDir = $PSScriptRoot

# A path under Source\, with the separator of this machine (on Linux,
# PowerShell does not turn \ into /)
function Join-Source([string] $Relative) {
    return Join-Path $sourceDir ($Relative -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
}

$libraryUnits = Join-Source 'Units'

if ($onLinuxHost) {
    $machine = (& uname -m).Trim()
    switch ($machine) {
        'x86_64'  { $hostPlatform = 'Linux64'; $cpu = 'x86_64' }
        'aarch64' { $hostPlatform = 'LinuxArm64'; $cpu = 'aarch64' }
        default   { throw "This machine ($machine) is not supported: Linux64 (x86_64) or LinuxArm64 (aarch64) only." }
    }
    if (-not $Platform) {
        $Platform = $hostPlatform
    }
    if ($Platform -ne $hostPlatform) {
        throw "On this Linux machine only -Platform $hostPlatform can be built (no cross compiling)."
    }
} elseif (-not $Platform) {
    $Platform = 'Win32'
}

$isLinuxTarget = $Platform -in @('Linux64', 'LinuxArm64')
# Linux64 on Windows: build and run inside WSL
$viaWsl = $isLinuxTarget -and -not $onLinuxHost

if ($Platform -eq 'LinuxArm64' -and -not $onLinuxHost) {
    throw 'LinuxArm64 builds only on an ARM64 Linux machine (WSL runs x64).'
}

# Runs a Linux command: in WSL, or here on a Linux machine
function Invoke-Linux([string] $Command, [string[]] $Arguments) {
    if ($viaWsl) {
        & wsl.exe @wslOptions -e $Command @Arguments
    } else {
        & $Command @Arguments
    }
}

if ($isLinuxTarget) {
    if ($viaWsl) {
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            throw 'wsl.exe not found. Linux64 builds in WSL: install WSL, a Linux distribution and FPC in it.'
        }
        # wsl.exe options before -e: the distribution, if one was given
        $wslOptions = @()
        if ($Distribution) {
            $wslOptions = @('-d', $Distribution)
        }
        $cpu = 'x86_64'
    } elseif (-not (Get-Command fpc -ErrorAction SilentlyContinue)) {
        throw 'fpc not found. Install Free Pascal (Ubuntu: sudo apt install fpc).'
    }

    if (-not $LinuxFpcUnits) {
        # Where the distribution's fpc package puts the RTL units
        $fpcVersion = Invoke-Linux 'fpc' @('-iV')
        if ($LASTEXITCODE -ne 0 -or -not $fpcVersion) {
            throw 'fpc -iV failed. Install Free Pascal (Ubuntu: sudo apt install fpc).'
        }
        $LinuxFpcUnits = "/usr/lib/$cpu-linux-gnu/fpc/$("$fpcVersion".Trim())/units/$cpu-linux"
    }
    Invoke-Linux 'test' @('-d', $LinuxFpcUnits)
    if ($LASTEXITCODE -ne 0) {
        throw "FPC units not found: $LinuxFpcUnits. Install FPC (Ubuntu: sudo apt install fpc) or give -LinuxFpcUnits."
    }
    $rtlSearchPath = "$LinuxFpcUnits/*"

    if ($viaWsl) {
        $wslSourceDir = (& wsl.exe @wslOptions -e wslpath -a ($sourceDir -replace '\\', '/'))
        if ($LASTEXITCODE -ne 0 -or -not $wslSourceDir) {
            throw "wslpath could not convert $sourceDir"
        }
        $wslSourceDir = $wslSourceDir.Trim()
    }

    # The programs use cthreads, which links the C library: the linker needs the
    # folder of gcc's crtbegin.o (fpc.cfg names it, but -n leaves fpc.cfg out).
    # Without gcc the linker warns that crtbegin.o is missing, but links.
    $crtFile = $null
    try {
        $crtFile = Invoke-Linux 'gcc' @('-print-file-name=crtbegin.o') 2>$null
    } catch {
        $crtFile = $null
    }
    $linuxLibraryPath = $null
    if (($LASTEXITCODE -eq 0) -and $crtFile -and "$crtFile".Trim().StartsWith('/')) {
        $crtFile = "$crtFile".Trim()
        $linuxLibraryPath = $crtFile.Substring(0, $crtFile.LastIndexOf('/'))
    }
} else {
    if ($onLinuxHost) {
        throw "$Platform cannot be built on Linux."
    }
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
    if (-not $compiler -and $Platform -eq 'Win64') {
        # The installer of FPC alone (win32 and win64) has the x86_64 compiler as a cross compiler
        $compiler = Get-ChildItem -Path (Join-Path $FpcDir 'bin') -Recurse -Filter 'ppcrossx64.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $compiler) {
        throw "$compilerName not found under $FpcDir\bin. Install or repair Lazarus/FPC for $Platform."
    }

    $rtlUnits = Join-Path $FpcDir "units\$target"
    if (-not (Test-Path $rtlUnits)) {
        throw "FPC units for $target not found: $rtlUnits"
    }
    $rtlSearchPath = "$rtlUnits\*"
}

# A path for the compiler: in WSL, C:\... is /mnt/c/... (all paths given to
# the compiler are under $sourceDir)
function ConvertTo-CompilerPath([string] $Path) {
    if (-not $viaWsl) {
        return $Path
    }
    return $wslSourceDir + ($Path.Substring($sourceDir.Length) -replace '\\', '/')
}

if ($Project -eq 'Tests') {
    $projectDir = Join-Source 'UnitTests\FPC'
    $programFile = 'Delphi.IOUring.UnitTests.FPC.lpr'
    $extraUnits = @(Join-Source 'UnitTests\Common')         # Tests.Support, the shared tests and helpers
    if ($isLinuxTarget) {
        $extraUnits += Join-Source 'UnitTests\Linux'          # the Linux-only tests
    }
    $codeOptions = @('-g', '-gl')                            # debug info with line numbers
    if ($Optimize) {
        $codeOptions += '-O3'
    } else {
        $codeOptions += '-dIORING_NO_INLINE'                 # debug build: no inlining (Delphi.IOUring.inc)
    }
} elseif ($Project -eq 'Package') {
    # A unit, not a program: it pulls in every unit of the package and the
    # backend of this platform, as Lazarus compiles it
    if ($Run) {
        throw '-Run: the package is a unit, there is nothing to run.'
    }
    $projectDir = Join-Source 'Packages\Lazarus'
    $programFile = 'DelphiIOUring.pas'
    $extraUnits = @()
    $codeOptions = @('-O3')
} else {
    $projectDir = Join-Source 'Benchmarks\FPC'
    switch ($Project) {
        'Benchmarks' { $programFile = 'Delphi.IOUring.Benchmarks.FPC.lpr' }
        'Structures' { $programFile = 'Delphi.IOUring.Benchmarks.Structures.FPC.lpr' }
        'Blocks'     { $programFile = 'Delphi.IOUring.Benchmarks.Blocks.FPC.lpr' }
        'Writes'     { $programFile = 'Delphi.IOUring.Benchmarks.Writes.FPC.lpr' }
    }
    $extraUnits = @(Join-Source 'Benchmarks')                # Bench.Common, Bench.Readers, Bench.Structures, Bench.Blocks, Bench.Writes
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
if ($isLinuxTarget -and $linuxLibraryPath) {
    $arguments += "-Fl$linuxLibraryPath"
}
$arguments += (ConvertTo-CompilerPath (Join-Path $projectDir $programFile))

if ($viaWsl) {
    $distributionName = if ($Distribution) { $Distribution } else { 'the default distribution' }
    Write-Host "Compiling $programFile with the FPC of WSL ($distributionName) for $Platform"
    & wsl.exe @wslOptions -e fpc @arguments
} elseif ($isLinuxTarget) {
    Write-Host "Compiling $programFile with the FPC of this machine for $Platform"
    & fpc @arguments
} else {
    Write-Host "Compiling $programFile with $($compiler.FullName) for $Platform"
    & $compiler.FullName @arguments
}
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if ($Run) {
    $programName = [IO.Path]::GetFileNameWithoutExtension($programFile)
    if ($viaWsl) {
        & wsl.exe @wslOptions -e (ConvertTo-CompilerPath (Join-Path $outputDir $programName)) @RunArguments
    } elseif ($isLinuxTarget) {
        & (Join-Path $outputDir $programName) @RunArguments
    } else {
        & (Join-Path $outputDir "$programName.exe") @RunArguments
    }
    exit $LASTEXITCODE
}
