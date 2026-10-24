<#
.SYNOPSIS
    CI: builds and runs the Free Pascal tests through Source/Build-FPC.ps1 and
    turns every failed test into an annotation of the run.

.DESCRIPTION
    Annotations are shown on the run's page and can be read through the
    GitHub API without signing in (the full log needs a sign-in). The exit
    code is the test program's.

    -AllowNotAvailable: when the test program reports "Not available: ..."
    first (the system has no usable ring), the step passes with a warning
    instead (Windows runners without IoRing version 4, Docs/Design.md 12.5).
#>
param(
    [string] $Platform = '',
    [switch] $Optimize,
    [string] $FpcDir = '',
    [switch] $AllowNotAvailable
)

$arguments = @{ Project = 'Tests'; Run = $true; Optimize = $Optimize }
if ($Platform) {
    $arguments.Platform = $Platform
}
if ($FpcDir) {
    $arguments.FpcDir = $FpcDir
}
$buildScript = Join-Path $PSScriptRoot '../../Source/Build-FPC.ps1'

$output = & $buildScript @arguments 2>&1
$code = $LASTEXITCODE

$name = if ($Platform) { $Platform } else { 'this machine' }
if ($Optimize) {
    $name += ', -O3'
}

# The test program prints the name of every test on a line of its own, and
# "  FAILED: ..." / "  ERROR: ..." right after it
$test = ''
foreach ($line in $output) {
    $text = "$line"
    Write-Host $text
    if ($text -match '^T\w+\.\w+$') {
        $test = $text
    } elseif ($text -match '^\s+(FAILED|ERROR): (.*)$') {
        $message = "$($Matches[1]): $($Matches[2])" -replace '%', '%25'
        # In a property value, ',' and ':' end the value: escape them
        $title = "$test ($name)" -replace '%', '%25' -replace ':', '%3A' -replace ',', '%2C'
        Write-Host "::error title=$title::$message"
    }
}

if ($code -ne 0) {
    $reason = $output | Where-Object { "$_" -like 'Not available:*' } | Select-Object -First 1
    if ($AllowNotAvailable -and $reason) {
        Write-Host "::warning::$name built, not tested - $reason"
        exit 0
    }
}
exit $code
