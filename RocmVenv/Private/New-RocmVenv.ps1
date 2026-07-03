# ROCm/PyTorch wheels target CPython 3.10-3.13 (no 3.14 wheels yet).
$script:RocmPyMin = 10
$script:RocmPyMax = 13

function Get-RocmPyInterpreter {
    # Probes one interpreter invocation and returns its version + real exe path,
    # or $null if it is unusable / out of the supported range.
    # NOTE: the -c snippets deliberately avoid double quotes - PowerShell 5.1
    # mangles inner quotes when passing the argument to python.exe.
    param(
        [Parameter(Mandatory)] [string]   $Exe,
        [string[]] $Prefix = @()
    )
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $null }

    $probe = $Prefix + @('-c', 'import sys; print(sys.version_info.major, sys.version_info.minor)')
    $out = & $Exe @probe 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $nums = ("$out" -split '\s+') | Where-Object { $_ }
    if ($nums.Count -lt 2) { return $null }
    $major = [int]$nums[0]; $minor = [int]$nums[1]
    if ($major -ne 3 -or $minor -lt $script:RocmPyMin -or $minor -gt $script:RocmPyMax) {
        return $null
    }

    $exeProbe = $Prefix + @('-c', 'import sys; print(sys.executable)')
    $path = & $Exe @exeProbe 2>$null | Select-Object -First 1
    if (-not $path) { return $null }
    return [pscustomobject]@{ Exe = $path.Trim(); Version = "$major.$minor" }
}

function Find-RocmPython {
    param([string] $PythonExe = 'python')

    $candidates = @()
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in '3.13', '3.12', '3.11', '3.10') {
            $candidates += , @{ Exe = 'py'; Prefix = @("-$v") }
        }
    }
    $candidates += , @{ Exe = $PythonExe; Prefix = @() }
    $candidates += , @{ Exe = 'python3';   Prefix = @() }

    foreach ($c in $candidates) {
        $found = Get-RocmPyInterpreter -Exe $c.Exe -Prefix $c.Prefix
        if ($found) { return $found }
    }
    return $null
}

function Install-RocmPython {
    param([string] $Version = '3.12')

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "No compatible Python (3.10-3.13) found and winget is unavailable. Install Python $Version from https://www.python.org/downloads/ and retry."
    }
    Write-Host "  Installing Python $Version via winget ..."
    & winget install --id "Python.Python.$Version" --source winget `
        --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget install of Python $Version failed (exit $LASTEXITCODE)."
    }
    # Refresh PATH in the current session so the freshly installed Python is found.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Get-RocmPython {
    <#
    .SYNOPSIS
        Locates a Python interpreter in the supported range (3.10-3.13),
        installing one via winget if none is present.
    #>
    [CmdletBinding()]
    param(
        [string] $PythonExe = 'python',
        [switch] $NoInstall
    )

    $found = Find-RocmPython -PythonExe $PythonExe
    if ($found) { return $found }

    if ($NoInstall) {
        throw 'No compatible Python (3.10-3.13) found on PATH. Install Python 3.10-3.13 and retry.'
    }

    Write-Host '  No compatible Python (3.10-3.13) found - attempting automatic install ...'
    Install-RocmPython
    $found = Find-RocmPython -PythonExe $PythonExe
    if ($found) { return $found }

    throw 'No compatible Python (3.10-3.13) available even after an install attempt. Install it manually from https://www.python.org/downloads/ and retry.'
}

function New-RocmVenv {
    <#
    .SYNOPSIS
        Creates (or reuses) a virtual environment and upgrades pip.
    .OUTPUTS
        Path to the venv's python.exe.
    #>
    [CmdletBinding()]
    param(
        [string] $VenvPath = '.venv',
        [string] $PythonExe = 'python',
        [switch] $Force
    )

    $python = Get-RocmPython -PythonExe $PythonExe
    Write-Host "  Using Python $($python.Version) at $($python.Exe)"

    $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

    if ((Test-Path $venvPython) -and -not $Force) {
        Write-Host "  Reusing existing venv at '$VenvPath'."
    } else {
        if ((Test-Path $VenvPath) -and $Force) {
            Write-Host "  Removing existing venv at '$VenvPath' (-Force)."
            Remove-Item -Recurse -Force $VenvPath
        }
        Write-Host "  Creating venv at '$VenvPath' ..."
        & $python.Exe -m venv $VenvPath
        if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit $LASTEXITCODE)." }
    }

    Write-Host '  Upgrading pip ...'
    & $venvPython -m pip install --upgrade pip --quiet
    if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed (exit $LASTEXITCODE)." }

    return (Resolve-Path $venvPython).Path
}
