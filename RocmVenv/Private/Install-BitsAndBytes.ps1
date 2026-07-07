function Get-BnbSource {
    [CmdletBinding()]
    param(
        [string] $SourcePath = (Join-Path $PSScriptRoot '..\Data\bnb-source.json')
    )
    if (-not (Test-Path $SourcePath)) {
        throw "bnb source config not found at '$SourcePath'."
    }
    return Get-Content -Raw -Path $SourcePath | ConvertFrom-Json
}

function Get-VenvQuantInfo {
    <#
    .SYNOPSIS
        Probes the venv python for its ROCm (hip) version and CPython tag.
    .OUTPUTS
        { RocmMinor; CPythonTag; Hip }. RocmMinor is $null for a CPU-only torch.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $VenvPython)

    $py = @'
import sys
try:
    import torch
except Exception as e:
    print("HIP None")
    print("CP cp%d%d" % (sys.version_info[0], sys.version_info[1]))
    sys.exit(0)
print("HIP", getattr(torch.version, "hip", None))
print("CP", "cp%d%d" % (sys.version_info[0], sys.version_info[1]))
'@
    # Temp .py file, not `python -c`: PowerShell 5.1 mangles quoted multi-line -c.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rocm_bnb_info_' + [System.IO.Path]::GetRandomFileName() + '.py')
    Set-Content -Path $tmp -Value $py -Encoding UTF8
    try {
        $out = & $VenvPython $tmp 2>$null
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }

    $hip = $null; $cp = $null
    foreach ($line in $out) {
        if ($line -match '^HIP\s+(.+)$') { $hip = $Matches[1].Trim() }
        elseif ($line -match '^CP\s+(cp\d+)') { $cp = $Matches[1] }
    }

    $rocmMinor = $null
    if ($hip -and $hip -ne 'None' -and $hip -match '^(\d+)\.(\d+)') {
        $rocmMinor = "$($Matches[1]).$($Matches[2])"
    }

    return [pscustomobject]@{
        RocmMinor  = $rocmMinor
        CPythonTag = $cp
        Hip        = if ($hip -eq 'None') { $null } else { $hip }
    }
}

function Resolve-BnbWheelUrl {
    <#
    .SYNOPSIS
        Queries the community fork's GitHub releases and picks the best-matching
        bitsandbytes wheel for (ROCm minor, CPython tag, gfx target).
    .DESCRIPTION
        Ranking: ROCm major MUST match. Then exact minor > nearest-lower minor >
        generic (major only). A higher minor than installed is rejected (ABI risk).
        Variant coverage: '_all' (every gfx) preferred over '_rdna'; a CDNA target
        (gfx9xx) rejects '_rdna'. The CPython tag must match the asset exactly.
    .OUTPUTS
        { Url; Version; Tag; Variant } for the best wheel, or $null if none match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RocmMinor,
        [Parameter(Mandatory)] [string] $CPythonTag,
        [string] $Target,
        $Source = (Get-BnbSource)
    )

    if ($RocmMinor -notmatch '^(\d+)\.(\d+)$') {
        throw "Invalid ROCm minor '$RocmMinor' (expected e.g. 7.15)."
    }
    $wantMajor = [int]$Matches[1]
    $wantMinor = [int]$Matches[2]
    $requiresAll = $Target -and ($Target -match '^gfx9')

    $prefs = @($Source.buildPreference)
    $variantRank = {
        param($v)
        $i = [array]::IndexOf($prefs, $v)
        if ($i -lt 0) { return 0 }
        return ($prefs.Count - $i)
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'RocmVenv'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

    $releases = Invoke-RestMethod -Uri $Source.apiUrl -Headers $headers -Method Get

    $best = $null
    $bestScore = -1
    foreach ($rel in $releases) {
        $tag = "$($rel.tag_name)"

        # ROCm token from the release tag: rocm7.15 or rocm7.
        if ($tag -notmatch 'rocm(\d+)(?:\.(\d+))?') { continue }
        $relMajor = [int]$Matches[1]
        $relMinor = if ($Matches[2]) { [int]$Matches[2] } else { $null }
        if ($relMajor -ne $wantMajor) { continue }

        if ($null -eq $relMinor) {
            $rocmRank = 100                              # generic rocmN
        } elseif ($relMinor -eq $wantMinor) {
            $rocmRank = 300                              # exact minor
        } elseif ($relMinor -lt $wantMinor) {
            $rocmRank = 200 + $relMinor                  # nearest-lower wins
        } else {
            continue                                     # higher minor: ABI risk
        }

        # gfx-coverage variant from the release tag.
        $variant = if ($tag -match '[-_](all|rdna)\b') { $Matches[1] } else { $null }
        if ($requiresAll -and $variant -eq 'rdna') { continue }

        $vRank = & $variantRank $variant

        foreach ($asset in $rel.assets) {
            $name = "$($asset.name)"
            if ($name -notmatch '\.whl$') { continue }
            if ($name -notmatch [regex]::Escape($CPythonTag)) { continue }

            $score = ($rocmRank * 10) + $vRank
            if ($score -gt $bestScore) {
                $version = if ($name -match 'bitsandbytes-([^-]+)-cp') { $Matches[1] } else { $null }
                $bestScore = $score
                $best = [pscustomobject]@{
                    Url     = $asset.browser_download_url
                    Version = $version
                    Tag     = $tag
                    Variant = $variant
                }
            }
        }
    }

    return $best
}

function Install-BnbRuntimeDep {
    # bitsandbytes is installed with --no-deps (so pip never swaps out the ROCm
    # torch). That also skips its light pure-Python runtime deps (e.g. packaging),
    # so install them here from the wheel metadata - everything except torch.
    param([Parameter(Mandatory)] [string] $VenvPython)

    $py = @'
import sys
import importlib.metadata as m
try:
    reqs = m.metadata("bitsandbytes").get_all("Requires-Dist") or []
except Exception:
    reqs = []
for r in reqs:
    if ";" in r:            # skip optional extras / env-marker deps
        continue
    if r.strip().lower().startswith("torch"):
        continue            # never touch the ROCm torch already installed
    print(r.strip())
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rocm_bnb_deps_' + [System.IO.Path]::GetRandomFileName() + '.py')
    Set-Content -Path $tmp -Value $py -Encoding UTF8
    try {
        $deps = @(& $VenvPython $tmp 2>$null | Where-Object { $_ })
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
    if (-not $deps) { return }

    Write-Host "  Installing bitsandbytes runtime deps: $($deps -join ', ')"
    & $VenvPython -m pip install @deps
    if ($LASTEXITCODE -ne 0) { throw "installing bitsandbytes runtime deps failed (exit $LASTEXITCODE)." }
}

function Test-BnbInstall {
    # 4-bit Linear matmul smoke test on the GPU; returns { Ok; Version }.
    param([Parameter(Mandatory)] [string] $VenvPython)

    $py = @'
import sys
try:
    import torch, bitsandbytes as bnb
    from bitsandbytes.nn import Linear4bit
except Exception as e:
    print("BNB None")
    print("OK False", e)
    sys.exit(3)
print("BNB", getattr(bnb, "__version__", "unknown"))
try:
    lin = Linear4bit(64, 64, bias=False, compute_dtype=torch.float16).to("cuda")
    x = torch.randn(8, 64, device="cuda", dtype=torch.float16)
    y = lin(x)
    ok = bool(torch.isfinite(y).all().item())
except Exception as e:
    print("OK False", e)
    sys.exit(3)
print("OK", ok)
sys.exit(0 if ok else 3)
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rocm_bnb_test_' + [System.IO.Path]::GetRandomFileName() + '.py')
    Set-Content -Path $tmp -Value $py -Encoding UTF8
    try {
        $out = & $VenvPython $tmp
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
    $version = $null
    foreach ($line in $out) {
        if ($line -match '^BNB\s+(.+)$' -and $Matches[1] -ne 'None') { $version = $Matches[1].Trim() }
    }
    return [pscustomobject]@{ Ok = ($code -eq 0); Version = $version }
}

function Install-RocmBitsAndBytes {
    <#
    .SYNOPSIS
        Installs a matching community bitsandbytes (ROCm/Windows) wheel into a venv.
    .DESCRIPTION
        Detects the venv's ROCm minor + CPython tag, resolves the best wheel from
        the community fork's GitHub releases, installs it (--no-deps) and runs a
        4-bit Linear GPU smoke test. Never throws: any failure warns and returns a
        status object so the caller (bootstrap) can continue - torch stays usable.
    .PARAMETER VenvPython
        Path to the venv python.exe.
    .PARAMETER Target
        gfx target (e.g. gfx1201) used to reject an incompatible variant.
    .OUTPUTS
        { Installed; Version; WheelUrl; Reason }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VenvPython,
        [string] $Target,
        $Source = (Get-BnbSource)
    )

    $status = [pscustomobject]@{ Installed = $false; Version = $null; WheelUrl = $null; Reason = $null }

    try {
        $info = Get-VenvQuantInfo -VenvPython $VenvPython
        if (-not $info.RocmMinor) {
            $status.Reason = 'torch has no ROCm build (torch.version.hip is null); skipping bitsandbytes.'
            Write-Warning "  $($status.Reason)"
            return $status
        }
        Write-Host "  Detected: ROCm $($info.RocmMinor), $($info.CPythonTag), target $Target"

        $wheel = Resolve-BnbWheelUrl -RocmMinor $info.RocmMinor -CPythonTag $info.CPythonTag -Target $Target -Source $Source
        if (-not $wheel) {
            $status.Reason = "no matching bitsandbytes wheel for ROCm $($info.RocmMinor) / $($info.CPythonTag) / $Target."
            Write-Warning "  $($status.Reason)"
            return $status
        }
        Write-Host "  Selected wheel: $($wheel.Version)  [$($wheel.Tag), variant=$($wheel.Variant)]"
        $status.WheelUrl = $wheel.Url

        # Download to a temp .whl (community releases are not on a pip index).
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tmpWhl = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileName($wheel.Url))
        Write-Host '  Downloading wheel ...'
        Invoke-WebRequest -Uri $wheel.Url -OutFile $tmpWhl -Headers @{ 'User-Agent' = 'RocmVenv' } -UseBasicParsing

        try {
            Write-Host '  Installing bitsandbytes (--no-deps) ...'
            & $VenvPython -m pip install --no-deps $tmpWhl
            if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)." }
            Install-BnbRuntimeDep -VenvPython $VenvPython
        } finally {
            Remove-Item -Path $tmpWhl -ErrorAction SilentlyContinue
        }

        Write-Host '  Verifying bitsandbytes (4-bit Linear on GPU) ...'
        $test = Test-BnbInstall -VenvPython $VenvPython
        if ($test.Ok) {
            $status.Installed = $true
            $status.Version = if ($test.Version) { $test.Version } else { $wheel.Version }
            Write-Host "  bitsandbytes $($status.Version) installed and verified." -ForegroundColor Green
        } else {
            $status.Reason = 'bitsandbytes installed but the 4-bit smoke test failed.'
            Write-Warning "  $($status.Reason)"
        }
    } catch {
        $status.Reason = "bitsandbytes install skipped: $($_.Exception.Message)"
        Write-Warning "  $($status.Reason)"
    }

    return $status
}
