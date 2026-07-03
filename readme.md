# rocm-venv-setup

One-click, reusable **ROCm nightly + PyTorch** virtual-environment bootstrap for
Windows. Detects your AMD GPU, picks the matching `gfx` target, installs the
ROCm libraries and PyTorch from [TheRock](https://github.com/ROCm/TheRock)'s
multi-arch wheel index, verifies GPU visibility, and runs a short benchmark.

## Requirements

- Windows with an AMD GPU that has ROCm-on-Windows support
- Python **3.10–3.13** on `PATH` (PyTorch wheels target Torch 2.10–2.12)
- Internet access to `https://rocm.nightlies.amd.com/whl-multi-arch/`

## Quick start

```powershell
.\Install-RocmVenv.ps1
```

This walks through five steps: detect GPU → create `.venv` → install ROCm +
PyTorch → verify → benchmark. Common overrides:

```powershell
# Force a specific target (skip auto-detection) and rebuild the venv
.\Install-RocmVenv.ps1 -Target gfx1201 -VenvPath .venv -Force

# Install ROCm only (no PyTorch), skip the benchmark
.\Install-RocmVenv.ps1 -SkipTorch -SkipBenchmark
```

If your GPU can't be auto-mapped, the script lists the known targets and asks
you to pick one.

## Reusing this in a new project

**Variant A — copy (simplest):** copy the `RocmVenv/` folder, `Install-RocmVenv.ps1`
and `benchmark/` into the new project, then run `.\Install-RocmVenv.ps1`.

**Variant B — import the module:** keep this repo somewhere central and drive it
from your own script:

```powershell
Import-Module C:\path\to\rocm-venv-setup\RocmVenv

Initialize-RocmVenv -Target gfx1201 -VenvPath .venv
Invoke-RocmBenchmark -VenvPath .venv
```

## Public API

| Function              | Purpose                                                        |
| --------------------- | -------------------------------------------------------------- |
| `Get-RocmGpuTarget`   | Detect AMD GPU(s) and resolve the matching `gfx` target.       |
| `Initialize-RocmVenv` | Full setup: detect → venv → install ROCm + PyTorch → verify.   |
| `Invoke-RocmBenchmark`| Run the short FP32/FP16 matmul benchmark inside the venv.      |

## GPU → gfx mapping

Mappings live in [`RocmVenv/Data/gfx-map.json`](RocmVenv/Data/gfx-map.json) and
are extended without touching code:

- `byName` — substring match against the Windows video-controller name
  (first match wins; keep specific entries first).
- `byDeviceId` — optional map keyed by PCI device id (`0x....`); empty by default.
- `targets` — the list offered for manual selection.

Shipped examples: RX 9070/9060 → `gfx1201`/`gfx1200`, RX 7900 → `gfx1100`,
RX 7800/7700 → `gfx1101`, RX 7600 → `gfx1102`, RX 6000-series → `gfx103x`.

## How the install works

Based on TheRock's multi-arch index and `[device-<target>]` extras:

```powershell
pip install --index-url https://rocm.nightlies.amd.com/whl-multi-arch/ "rocm[libraries,device-gfx1201]"
pip install --index-url https://rocm.nightlies.amd.com/whl-multi-arch/ "torch[device-gfx1201]" "torchvision[device-gfx1201]" torchaudio
```

## Notes

- Uses **nightly** wheels — they can occasionally break; re-run with `-Force` to
  rebuild the venv from scratch.
- JAX on Windows is not yet available from TheRock; only PyTorch is installed.
