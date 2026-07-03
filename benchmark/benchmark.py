"""Short PyTorch performance test for a ROCm-enabled GPU.

Runs a warmup and then times matmuls in FP32 and FP16, reporting the
effective throughput in TFLOPS. Exits non-zero if no GPU is available.
"""

import sys
import time

try:
    import torch
except ImportError:
    print("FAIL: torch is not installed in this environment.")
    sys.exit(1)

if not torch.cuda.is_available():
    print("FAIL: torch.cuda.is_available() is False - no ROCm GPU visible.")
    sys.exit(2)

device = torch.device("cuda")
name = torch.cuda.get_device_name(0)
print(f"Device : {name}")
print(f"torch  : {torch.__version__}  (hip {getattr(torch.version, 'hip', None)})")
print("-" * 56)


def bench(dtype, n=8192, iters=50, warmup=10):
    a = torch.randn(n, n, device=device, dtype=dtype)
    b = torch.randn(n, n, device=device, dtype=dtype)
    for _ in range(warmup):
        a @ b
    torch.cuda.synchronize()

    start = time.perf_counter()
    for _ in range(iters):
        a @ b
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - start

    # 2 * n^3 FLOPs per matmul (multiply + add).
    flops = 2.0 * (n ** 3) * iters
    tflops = flops / elapsed / 1e12
    per_iter_ms = elapsed / iters * 1e3
    print(f"{str(dtype):<16} {n}x{n}  {per_iter_ms:8.2f} ms/iter  {tflops:8.1f} TFLOPS")
    return tflops


bench(torch.float32)
bench(torch.float16)
print("-" * 56)
print("Benchmark complete.")
