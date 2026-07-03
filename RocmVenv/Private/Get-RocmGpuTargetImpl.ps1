function Get-RocmGpuMap {
    [CmdletBinding()]
    param(
        [string] $MapPath = (Join-Path $PSScriptRoot '..\Data\gfx-map.json')
    )
    if (-not (Test-Path $MapPath)) {
        throw "gfx map not found at '$MapPath'."
    }
    return Get-Content -Raw -Path $MapPath | ConvertFrom-Json
}

function Get-RocmPciDeviceId {
    param([string] $PnpDeviceId)
    if ($PnpDeviceId -match 'DEV_([0-9A-Fa-f]{4})') {
        return ('0x' + $Matches[1].ToLower())
    }
    return $null
}

function Resolve-RocmTarget {
    param(
        [Parameter(Mandatory)] $Map,
        [string] $Name,
        [string] $DeviceId
    )
    if ($DeviceId -and $Map.byDeviceId.PSObject.Properties.Name -contains $DeviceId) {
        return [pscustomobject]@{ Target = $Map.byDeviceId.$DeviceId; Arch = 'PCI id match'; Source = 'device-id' }
    }
    foreach ($entry in $Map.byName) {
        if ($Name -and $Name.ToLower().Contains($entry.match.ToLower())) {
            return [pscustomobject]@{ Target = $entry.target; Arch = $entry.arch; Source = 'name' }
        }
    }
    return $null
}

function Get-RocmGpuTarget {
    <#
    .SYNOPSIS
        Detects installed AMD GPU(s) and resolves the matching ROCm gfx target.
    .DESCRIPTION
        Reads the Windows video controllers, filters AMD/ATI adapters, and maps
        each to a gfx target using Data/gfx-map.json (name first, then PCI id).
        Returns one object per detected AMD GPU with Name, DeviceId, Target,
        Arch and Source. Target is $null when the GPU is not in the map.
    .EXAMPLE
        Get-RocmGpuTarget
    #>
    [CmdletBinding()]
    param(
        [string] $MapPath = (Join-Path $PSScriptRoot '..\Data\gfx-map.json')
    )

    $map = Get-RocmGpuMap -MapPath $MapPath

    $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
        Where-Object {
            $_.AdapterCompatibility -match 'Advanced Micro Devices|ATI|AMD' -or
            $_.Name -match 'Radeon|AMD|ATI'
        }

    if (-not $controllers) {
        Write-Warning 'No AMD GPU detected via Win32_VideoController.'
        return @()
    }

    foreach ($c in $controllers) {
        $deviceId = Get-RocmPciDeviceId -PnpDeviceId $c.PNPDeviceID
        $resolved = Resolve-RocmTarget -Map $map -Name $c.Name -DeviceId $deviceId
        [pscustomobject]@{
            Name     = $c.Name
            DeviceId = $deviceId
            Target   = $resolved.Target
            Arch     = $resolved.Arch
            Source   = $resolved.Source
        }
    }
}
