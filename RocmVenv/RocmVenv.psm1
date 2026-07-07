# RocmVenv - reusable ROCm + PyTorch venv bootstrap for Windows.
# Load private implementation files.
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

function Initialize-RocmVenv {
    <#
    .SYNOPSIS
        One-click setup: detect GPU, create a venv, install ROCm + PyTorch, verify.
    .PARAMETER VenvPath
        Location of the virtual environment (default: .venv).
    .PARAMETER Target
        Override the gfx target(s), e.g. gfx1201. Skips auto-detection.
    .PARAMETER PythonExe
        Base Python interpreter to build the venv from (default: python).
    .PARAMETER Force
        Recreate the venv even if it already exists.
    .PARAMETER SkipTorch
        Install only the ROCm libraries, not PyTorch.
    .PARAMETER SkipBitsAndBytes
        Do not install the community bitsandbytes (4-bit/8-bit quant) wheel.
    .EXAMPLE
        Initialize-RocmVenv
    .EXAMPLE
        Initialize-RocmVenv -Target gfx1201 -VenvPath .venv -Force
    #>
    [CmdletBinding()]
    param(
        [string]   $VenvPath = '.venv',
        [string[]] $Target,
        [string]   $PythonExe = 'python',
        [switch]   $Force,
        [switch]   $SkipTorch,
        [switch]   $SkipBitsAndBytes
    )

    Write-Host '[1/6] Detecting GPU and gfx target ...'
    $targets = @()
    if ($Target) {
        $targets = $Target
        Write-Host "  Using target override: $($targets -join ', ')"
    } else {
        $gpus = Get-RocmGpuTarget
        foreach ($g in $gpus) {
            $tag = if ($g.Target) { $g.Target } else { 'UNKNOWN' }
            Write-Host "  $($g.Name)  ->  $tag"
        }
        $targets = @($gpus | Where-Object Target | Select-Object -ExpandProperty Target -Unique)
        if (-not $targets) {
            throw 'Could not map any GPU to a gfx target. Pass -Target <gfxXXXX> explicitly (see Data/gfx-map.json).'
        }
    }

    Write-Host '[2/6] Preparing virtual environment ...'
    $venvPython = New-RocmVenv -VenvPath $VenvPath -PythonExe $PythonExe -Force:$Force

    Write-Host '[3/6] Installing ROCm + PyTorch ...'
    Install-RocmPackages -VenvPython $venvPython -Targets $targets -SkipTorch:$SkipTorch

    Write-Host '[4/6] Installing bitsandbytes (quantization) ...'
    # No torch -> no hip version to match, so bnb is skipped alongside -SkipTorch.
    $bnb = $null
    if ($SkipTorch -or $SkipBitsAndBytes) {
        Write-Host '  Skipped.'
    } else {
        $primary = @($targets)[0]
        $bnb = Install-RocmBitsAndBytes -VenvPython $venvPython -Target $primary
    }

    Write-Host '[5/6] Verifying ...'
    $ok = if ($SkipTorch) { $true } else { Test-RocmInstall -VenvPython $venvPython }

    Write-Host '[6/6] Done.'
    return [pscustomobject]@{
        VenvPython   = $venvPython
        Targets      = $targets
        Verified     = $ok
        BitsAndBytes = $bnb
    }
}

function Invoke-RocmBenchmark {
    <#
    .SYNOPSIS
        Runs the short FP32/FP16 matmul benchmark inside the venv.
    .PARAMETER VenvPath
        Location of the venv containing the ROCm PyTorch install.
    #>
    [CmdletBinding()]
    param(
        [string] $VenvPath = '.venv',
        [string] $ScriptPath = (Join-Path $PSScriptRoot '..\benchmark\benchmark.py')
    )
    $venvPython = Join-Path $VenvPath 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        throw "venv python not found at '$venvPython'. Run Initialize-RocmVenv first."
    }
    if (-not (Test-Path $ScriptPath)) {
        throw "benchmark script not found at '$ScriptPath'."
    }
    & $venvPython $ScriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Benchmark failed (exit $LASTEXITCODE)."
    }
}

Export-ModuleMember -Function Get-RocmGpuTarget, Initialize-RocmVenv, Invoke-RocmBenchmark, Install-RocmBitsAndBytes
