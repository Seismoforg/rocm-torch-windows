# rocm-venv-setup

One-click, reusable **ROCm nightly + PyTorch** virtual-environment bootstrap for
Windows. Detects your AMD GPU, picks the matching `gfx` target, installs the
ROCm libraries and PyTorch from [TheRock](https://github.com/ROCm/TheRock)'s
multi-arch wheel index, adds a matching **bitsandbytes** (4-bit/8-bit
quantization) build, verifies GPU visibility, and runs a short benchmark.

## Requirements

- Windows with an AMD GPU that has ROCm-on-Windows support
- Python **3.10–3.13** on `PATH` (PyTorch wheels target Torch 2.10–2.12)
- Internet access to `https://rocm.nightlies.amd.com/whl-multi-arch/`
- Internet access to the GitHub Releases API (for the bitsandbytes wheel;
  optional — the step warns and continues if unavailable)

## Quick start

```powershell
.\Install-RocmVenv.ps1
```

This walks through six steps: detect GPU → create `.venv` → install ROCm +
PyTorch → install bitsandbytes → verify → benchmark. Common overrides:

```powershell
# Force a specific target (skip auto-detection) and rebuild the venv
.\Install-RocmVenv.ps1 -Target gfx1201 -VenvPath .venv -Force

# Install ROCm only (no PyTorch), skip the benchmark
.\Install-RocmVenv.ps1 -SkipTorch -SkipBenchmark

# Skip the bitsandbytes step (torch only)
.\Install-RocmVenv.ps1 -SkipBitsAndBytes
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
| `Get-RocmGpuTarget`      | Detect AMD GPU(s) and resolve the matching `gfx` target.    |
| `Initialize-RocmVenv`    | Full setup: detect → venv → ROCm + PyTorch → bnb → verify.  |
| `Invoke-RocmBenchmark`   | Run the short FP32/FP16 matmul benchmark inside the venv.   |
| `Install-RocmBitsAndBytes`| Install a matching community bitsandbytes wheel into a venv.|

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

## bitsandbytes (4-bit / 8-bit quantization)

Upstream `bitsandbytes` has no official Windows+ROCm wheel, so the installer
pulls a matching build from the community fork
[`0xDELUXA/bitsandbytes_win_rocm`](https://github.com/0xDELUXA/bitsandbytes_win_rocm).
The wheel is selected **dynamically** from the fork's GitHub Releases by:

- **ROCm minor** (from `torch.version.hip`): exact minor → nearest-lower minor →
  generic `rocm7`; a higher minor than installed is rejected (ABI risk).
- **CPython tag** (`cp312`, …): must match the wheel exactly.
- **gfx coverage**: the `_all` variant (every gfx) is preferred over `_rdna`;
  CDNA targets (`gfx9xx`) require `_all`.

The source and ranking rules live in
[`RocmVenv/Data/bnb-source.json`](RocmVenv/Data/bnb-source.json) — change the repo
or preferences there without touching code. Set `GITHUB_TOKEN` to raise the
API rate limit. After install, a 4-bit `Linear` GPU matmul smoke-tests the build.

Caveats: these are community `dev0` wheels pinned to a specific ROCm+gfx+Python
combination. If no match is found (or the API is offline / rate-limited), the
step **warns and continues** — PyTorch stays fully usable and only `bitsandbytes`
is absent. Opt out entirely with `-SkipBitsAndBytes`.

## Notes

- Uses **nightly** wheels — they can occasionally break; re-run with `-Force` to
  rebuild the venv from scratch.
- JAX on Windows is not yet available from TheRock; only PyTorch is installed.
