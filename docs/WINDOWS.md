# BitCrack on Windows 11 — build, test, benchmark

Fork notes for building and validating BitCrack on a Windows 11 workstation
with an NVIDIA RTX 3060 Laptop GPU (Ampere GA106, compute capability 8.6).
Upstream: <https://github.com/brichard19/BitCrack> (MIT, last upstream commit
`6bf8059`, 2021). Nothing here is intended for upstream submission.

## Scope and responsible use

The test and benchmark scripts only search for addresses that are either
published test vectors (generator point `k = 1`, solved puzzle #20) or derived
from a private key the script generates locally. Do not point BitCrack at
addresses you do not control, other than public puzzle addresses whose rules
explicitly invite participation.

## Verified environment (2026-11-18)

| Component | Version |
|---|---|
| OS | Windows 11 Pro for Workstations 10.0.26300 |
| GPU | NVIDIA GeForce RTX 3060 Laptop GPU, 6 GB, 30 SMs, CC 8.6 |
| Driver | 616.92 (CUDA UMD 13.4), WDDM |
| CUDA Toolkit | 13.4.1 (`nvcc` V13.4.59) via `winget install Nvidia.CUDA --version 13.4` |
| Compiler | Visual Studio Build Tools 2022 17.14, MSVC 14.44 (v143), Windows SDK 10.0.26100 |
| Python | 3.14 (only for `tests/synthetic/btcaddr.py`, standard library only) |

Pick a CUDA Toolkit whose version is **not newer than the driver's CUDA UMD
version** (`nvidia-smi`, top-right). Toolkit 13.5 binaries would need a newer
driver than 616.92.

## Build

```powershell
winget install --id Nvidia.CUDA --version 13.4 --exact   # once, needs admin (UAC)
.\scripts\build-windows.ps1                               # Release|x64
```

Outputs land in `x64\Release\`: `cuBitCrack.exe`, `clBitCrack.exe`,
`cudaInfo.exe`, `CLUnitTests.exe`, `AddrGen.exe`, `embedcl.exe`.

Other GPUs: `.\scripts\build-windows.ps1 -CudaArch compute_75,sm_75` (Turing),
`compute_89,sm_89` (Ada). With MSBuild directly:
`msbuild BitCrack.sln /p:Configuration=Release /p:Platform=x64 /p:BitCrackCudaArch=compute_86%2Csm_86`
(the comma must be escaped as `%2C`).

## Test

```powershell
.\x64\Release\cudaInfo.exe          # device, CC 8.6, 3840 cores
.\x64\Release\CLUnitTests.exe       # OpenCL add/mul/inverse mod p; exit 0 = PASS
.\tests\synthetic\run-synthetic.ps1 # end-to-end GPU checks, ~3 min, exit 0 = all pass
.\tests\run-script-regressions.ps1  # focused PowerShell checks using real GPU vectors and benchmark fixtures
.\tests\run-script-regressions.ps1 -PortableOnly # eight checks on Windows without a GPU build
```

`run-synthetic.ps1` stages (all verified on the hardware above):

| Stage | What it proves |
|---|---|
| btcaddr self-test | Independent pure-Python key→address derivation matches published vectors |
| vectors | cuBitCrack recovers `k=1` (compressed + uncompressed) and solved puzzle #20 (`0xd2c55`); each hit is re-derived by Python |
| cl-vectors | Same `k=1` check through clBitCrack (OpenCL) |
| puzzle | A random key in a 2^35-wide range is recovered; run stops with "No targets remaining" |
| bounds | Keys at START and END are found; START-1 is not |
| exhaust | A target outside the range is not reported; run ends "Reached end of keyspace" with no result file |
| checkpoint | Run 1 killed after the first checkpoint; run 2 with `--continue` logs the saved `next` key as its start and finds a key placed after it |

The default suite runs 13 checks and requires the CUDA and OpenCL binaries.
Use `-NoOpenCL` to skip OpenCL explicitly. The script regression suite uses the
Windows .NET Framework C# compiler to build its stand-in benchmark processes.
The Windows fixtures workflow runs the portable checks on GitHub-hosted
Windows in PowerShell 7 and Windows PowerShell 5.1. The full local regression
suite adds two checks using the CUDA and OpenCL binaries.

## Benchmark

```powershell
.\scripts\benchmark.ps1 -IncludeOpenCL      # ~4 min; writes %TEMP%\bitcrack-bench\benchmark.md
```

Each row records the child exit code and whether the benchmark stopped it at
the time limit. A successful row requires a positive throughput sample. An
unexpected nonzero exit or missing throughput produces a `FAIL` row and makes
the script exit 1 after writing the report. The path printed after the table
contains numbered stdout, stderr, and telemetry logs for the invocation.

Telemetry uses the NVIDIA UUID when the selected BitCrack device name has a
unique NVIDIA match. When the name is ambiguous or has no match, the row
reports throughput with telemetry unavailable.

Measured 2026-11-18, 40 s per configuration, laptop on AC power, compressed
keys, one target. VRAM is whole-GPU usage reported by nvidia-smi, including
~1.4 GB used by the desktop.

| Binary | Config | MKey/s | GPU % | VRAM MiB | Temp °C max | Power W avg | SM MHz avg |
|---|---|---:|---:|---:|---:|---:|---:|
| cuBitCrack | (auto) | 166.7 | 90 | 1641 | 57 | 90.6 | 1975 |
| cuBitCrack | `-b 60 -t 256 -p 256` | 611.6 | 97 | 2044 | 66 | 138.3 | 1855 |
| cuBitCrack | `-b 120 -t 256 -p 512` | 671.1 | 99 | 3587 | 67 | 137.8 | 1818 |
| cuBitCrack | **`-b 60 -t 256 -p 1024`** | **705.2** | 99 | 3559 | 68 | 139.9 | 1827 |
| cuBitCrack | `-b 120 -t 256 -p 1024` | 722.4 | 97 | 5481 | 68 | 135.7 | 1822 |
| clBitCrack | (auto) | 180.3 | 97 | 1675 | 64 | 101.3 | 1957 |

Recommended: `-b 60 -t 256 -p 1024`. The default (auto) configuration leaves
about 4x on the table. `-b 120 -t 256 -p 1024` is ~2 % faster but uses ~5.5 of
6 GB and leaves little headroom for the desktop.

### Realistic search times at 705 MKey/s

Full = whole range; expected = half the range (key uniformly distributed).

| Range width | Keys | Full | Expected |
|---|---:|---:|---:|
| 2^32 | 4.3e9 | 6.1 s | 3.0 s |
| 2^36 | 6.9e10 | 1.6 min | 49 s |
| 2^40 | 1.1e12 | 26 min | 13 min |
| 2^44 | 1.8e13 | 6.9 h | 3.5 h |
| 2^48 | 2.8e14 | 4.6 days | 2.3 days |
| 2^52 | 4.5e15 | 74 days | 37 days |
| 2^56 | 7.2e16 | 3.2 years | 1.6 years |
| 2^60 | 1.2e18 | 52 years | 26 years |
| 2^64 | 1.8e19 | 829 years | 415 years |
| 2^66 | 7.4e19 | 3,316 years | 1,658 years |
| 2^70 | 1.2e21 | 53,052 years | 26,526 years |

A single laptop GPU is practical up to roughly 2^48–2^52. Unsolved puzzle
ranges are far beyond that: they need large GPU fleets, or, where the public
key is already exposed, Pollard kangaroo / BSGS tools rather than BitCrack's
address brute force.

## Changes made in this fork (`develop`)

| Change | Why |
|---|---|
| All `.vcxproj`: `PlatformToolset` v141/v142 → **v143** | VS 2022 Build Tools ship only v143 |
| CUDA projects: build customization `CUDA 10.1` → **`CUDA 13.4`** | Matches installed toolkit |
| CUDA projects: `CodeGeneration` = `$(BitCrackCudaArch)`, default `compute_86,sm_86` | Old default was compute_30, which CUDA 12+ cannot target |
| `BitCrack.props`: hard-coded `CUDA\v10.1` paths → `$(CUDA_PATH)` | Toolkit-version independent |
| `clUtil/clutil.h`: define `CL_TARGET_OPENCL_VERSION 120` + `CL_USE_DEPRECATED_OPENCL_1_2_APIS` | CUDA 13 OpenCL headers deprecate `clCreateCommandQueue`; `/sdl` made C4996 an error |
| `KeyFinder/main.cpp`: `typedef struct {…} RunConfig;` → `struct RunConfig {…};` | MSVC 14.44 `/permissive-` error C5208 (clKeyFinder) |
| `CLKeySearchDevice/keysearch.cl`: `digestOut` parameters declared as `unsigned int digestOut[5]` | Driver 616 OpenCL compiler rejected passing a generic pointer to the private array parameter; clBitCrack kernels failed to build |
| `CLUnitTests/secp256k1test.cl`: use `addModP256k` / `invModP256k` | Upstream renamed the clMath API; the test kernel no longer compiled |
| `CLUnitTests/main.cpp`: count kernel build/launch exceptions as failures; exit 1 on FAIL | Upstream printed **PASS** and exited 0 even when the kernel failed to compile |
| `cudaUtil/cudaUtil.cpp`: cores/SM for CC 8.x and 9.x | cudaInfo reported 8 cores/SM (240 total) for Ampere |
| Added `scripts/build-windows.ps1`, `scripts/benchmark.ps1`, `tests/synthetic/*`, this document | Reproducible build, test, benchmark |

Not changed: Linux `Makefile` (still `COMPUTE_CAP=30`, which modern CUDA rejects;
not tested here), Win32 configurations (unused, still point at CUDA v9.2).

## Known limitations (observed)

- **END overshoot.** Search granularity is blocks × threads × points
  (15.7 M keys at the recommended config). END is inclusive, but keys up to one
  batch past END are also checked and reported (observed: END + 5,000,000 found
  in a 1 M-key range). START is respected. With `--share`, adjacent shares can
  overlap by up to one batch.
- **Checkpoint interval is fixed at 60 s** and a checkpoint is written only on
  that timer — not on Ctrl-C, on find, or at the end of the range. Up to 60 s
  of work is repeated after a crash.
- **`-t 512` fails** with "too many resources requested for launch": the
  kernel uses 220 registers/thread (`cuobjdump --dump-resource-usage`), so a
  block of 512 threads exceeds the 65,536-register limit. Use `-t 256` or lower.
- The `(auto)` launch configuration is ~4x slower than the tuned one on this GPU.
- Binaries contain only `sm_86` SASS (no PTX), so they will not run on other
  architectures without rebuilding with `-CudaArch`.
- Laptop thermals: sustained ~140 W at 66–68 °C on AC power; on battery or in
  a quiet/eco power mode the rate drops.

## Follow-up reliability work

1. Define the inclusive interval contract with synthetic CUDA and OpenCL
   coverage for END+1, partial final batches, and adjacent shares.
2. Exercise checkpoint interruption during writes, invalid checkpoint files,
   and resume from the last completed batch. Verify that resumed runs neither
   omit nor double-count completed work.
3. Add the GPU suites on a dedicated runner. Record which real GPU tests
   executed alongside the portable Windows CI checks.
4. Compare repeated benchmark runs with the commit, driver, GPU UUID, launch
   settings, duration, and power mode recorded alongside the raw samples.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `The CUDA Toolkit directory '' does not exist` | Shell started before the CUDA install, so `CUDA_PATH_V13_4` is missing. `build-windows.ps1` sets it; otherwise open a new terminal |
| `Cannot open include file: 'cuda.h'` / `'CL/cl.h'` | `CUDA_PATH` not set in this shell; open a new terminal or run `build-windows.ps1` |
| `MSB1006: Property is not valid` | Unescaped comma in `/p:BitCrackCudaArch=…`; use `%2C` |
| `error C4996: 'clCreateCommandQueue'` | Missing the `clutil.h` change above |
| `too many resources requested for launch` | Threads per block too high; use `-t 256` |
| `no kernel image is available for execution` | Binary built for another architecture; rebuild with matching `-CudaArch` |
| clBitCrack `changes address space of pointer` | Missing the `keysearch.cl` change above |
| Low MKey/s | Use `-b 60 -t 256 -p 1024`; check AC power and the Windows power mode |
