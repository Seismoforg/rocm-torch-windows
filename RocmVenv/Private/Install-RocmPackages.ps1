$script:RocmIndexUrl = 'https://rocm.nightlies.amd.com/whl-multi-arch/'

function Install-RocmPackages {
    <#
    .SYNOPSIS
        Installs ROCm nightly libraries and PyTorch (with ROCm) into a venv.
    .DESCRIPTION
        Uses TheRock's multi-arch wheel index and the [device-<target>] extras.
        Installs rocm[libraries,...] first, then torch/torchvision/torchaudio.
    .PARAMETER VenvPython
        Path to the venv python.exe (from New-RocmVenv).
    .PARAMETER Targets
        One or more gfx targets, e.g. gfx1201. Use 'all' for every supported GPU.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VenvPython,
        [Parameter(Mandatory)] [string[]] $Targets,
        [string] $IndexUrl = $script:RocmIndexUrl,
        [switch] $SkipTorch
    )

    $deviceExtras = ($Targets | ForEach-Object {
        if ($_ -eq 'all') { 'device-all' } else { "device-$_" }
    }) -join ','

    Write-Host "  Index : $IndexUrl"
    Write-Host "  Device: $deviceExtras"

    Write-Host '  Installing ROCm libraries ...'
    & $VenvPython -m pip install --index-url $IndexUrl "rocm[libraries,$deviceExtras]"
    if ($LASTEXITCODE -ne 0) { throw "ROCm install failed (exit $LASTEXITCODE)." }

    if ($SkipTorch) { return }

    Write-Host '  Installing PyTorch (torch, torchvision, torchaudio) ...'
    & $VenvPython -m pip install --index-url $IndexUrl `
        "torch[$deviceExtras]" "torchvision[$deviceExtras]" torchaudio
    if ($LASTEXITCODE -ne 0) { throw "PyTorch install failed (exit $LASTEXITCODE)." }
}

function Test-RocmInstall {
    <#
    .SYNOPSIS
        Verifies the install: torch import, GPU visibility, versions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $VenvPython)

    $py = @'
import sys
try:
    import torch
except Exception as e:
    print("FAIL: could not import torch:", e); sys.exit(1)
print("torch     :", torch.__version__)
print("hip       :", getattr(torch.version, "hip", None))
ok = torch.cuda.is_available()
print("gpu ready :", ok)
if ok:
    print("device    :", torch.cuda.get_device_name(0))
sys.exit(0 if ok else 2)
'@
    Write-Host '  Verifying installation ...'
    # Run from a temp .py file: passing a multi-line snippet with quotes via
    # `python -c` gets mangled by PowerShell 5.1's native argument handling.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rocm_verify_' + [System.IO.Path]::GetRandomFileName() + '.py')
    Set-Content -Path $tmp -Value $py -Encoding UTF8
    try {
        & $VenvPython $tmp
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
    if ($code -eq 0) {
        Write-Host '  Verification passed: GPU is visible to PyTorch.' -ForegroundColor Green
    } elseif ($code -eq 2) {
        Write-Warning 'torch installed but torch.cuda.is_available() is False. Check the gfx target / driver.'
    } else {
        throw 'Verification failed: torch could not be imported.'
    }
    return $code -eq 0
}
