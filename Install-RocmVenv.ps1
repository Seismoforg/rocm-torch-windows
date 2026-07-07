<#
.SYNOPSIS
    One-click ROCm nightly + PyTorch setup into a virtual environment.
.DESCRIPTION
    Detects the installed AMD GPU, picks the matching gfx target, creates a
    virtual environment, installs the ROCm nightly libraries and PyTorch from
    TheRock's multi-arch wheel index, verifies GPU visibility, and runs a short
    performance benchmark.

    Run from the project root:
        .\Install-RocmVenv.ps1
    Override the target or venv path:
        .\Install-RocmVenv.ps1 -Target gfx1201 -VenvPath .venv -Force
.PARAMETER VenvPath
    Virtual environment location (default: .venv).
.PARAMETER Target
    Force a gfx target (e.g. gfx1201) and skip auto-detection.
.PARAMETER PythonExe
    Base Python interpreter (default: python).
.PARAMETER Force
    Recreate the venv even if it exists.
.PARAMETER SkipTorch
    Install only ROCm libraries, not PyTorch.
.PARAMETER SkipBitsAndBytes
    Skip installing the community bitsandbytes (4-bit/8-bit quant) wheel.
.PARAMETER SkipBenchmark
    Skip the performance benchmark at the end.
#>
[CmdletBinding()]
param(
    [string]   $VenvPath = '.venv',
    [string[]] $Target,
    [string]   $PythonExe = 'python',
    [switch]   $Force,
    [switch]   $SkipTorch,
    [switch]   $SkipBitsAndBytes,
    [switch]   $SkipBenchmark
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'RocmVenv'
Import-Module $modulePath -Force

Write-Host ''
Write-Host '=== ROCm venv one-click installer ===' -ForegroundColor Cyan
Write-Host ''

# Interactive fallback: if auto-detection cannot map the GPU, let the user pick.
if (-not $Target) {
    $detected = @(Get-RocmGpuTarget | Where-Object Target)
    if (-not $detected) {
        $map = Get-Content -Raw (Join-Path $modulePath 'Data\gfx-map.json') | ConvertFrom-Json
        Write-Warning 'Could not auto-detect a gfx target for your GPU.'
        Write-Host 'Available targets:'
        for ($i = 0; $i -lt $map.targets.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f $i, $map.targets[$i])
        }
        $choice = Read-Host 'Select a target by number (or Ctrl+C to abort)'
        $Target = @($map.targets[[int]$choice])
    }
}

$result = Initialize-RocmVenv -VenvPath $VenvPath -Target $Target `
    -PythonExe $PythonExe -Force:$Force -SkipTorch:$SkipTorch -SkipBitsAndBytes:$SkipBitsAndBytes

Write-Host ''
if (-not $SkipTorch -and -not $SkipBenchmark) {
    Write-Host '=== Performance benchmark ===' -ForegroundColor Cyan
    Invoke-RocmBenchmark -VenvPath $VenvPath
}

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host "  venv    : $VenvPath"
Write-Host "  targets : $($result.Targets -join ', ')"
if ($result.BitsAndBytes) {
    $bnbMsg = if ($result.BitsAndBytes.Installed) { "bitsandbytes $($result.BitsAndBytes.Version)" } else { "not installed ($($result.BitsAndBytes.Reason))" }
    Write-Host "  quant   : $bnbMsg"
}
Write-Host "  activate: $VenvPath\Scripts\Activate.ps1"
