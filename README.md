# Vedran's Utilities

Native AppKit utilities for Apple Silicon Macs. Requires macOS 14 or later.

```bash
./Scripts/build-app.sh
open "build/Vedran's Utilities.app"
```

Run the tests with `swift test`.

To package a drag-to-install disk image at `build/VedransUtilities-<version>.dmg`:

```bash
./Scripts/build-dmg.sh
```

The app is ad-hoc signed, not notarized. On another Mac, macOS will block the first launch until it's allowed under System Settings > Privacy & Security.

## Memory

Measures bandwidth live, with a compact power readout alongside, by operation, block size, thread count and processor: performance cores, efficiency cores or GPU.

- **Read, Write, Copy, Triad, Random.** Kernels are hand-written NEON, so the compiler can't remove or reshape them.
- **GB/s is decimal.** Following STREAM, Copy counts read + write and Triad counts all three arrays. Random counts one 128-byte line per load, so treat it as a load rate in line-equivalents, not bus traffic: it can exceed the memory interface's rating.
- **Block size is per thread and per buffer.** Each thread has its own buffers, so Copy allocates 2× and Triad 3×. Blocks shrink automatically to keep the total under 60% of RAM.
- **Core choice is a request.** macOS can't pin threads, so P-cores and E-cores set the thread's quality of service. Thread count is capped at the core count of the chosen type, because extra threads would mix core types and blur the result.
- **GPU** runs the same operations as Metal compute kernels on private buffers, counted the same way. Triad uses 32-bit floats, as Metal has no doubles. The GPU schedules its own threads, so block size is the only axis.
- **Sweeps** sample each configuration until it is steady, for longer on large footprints, then take the median of the last five windows. Live runs of at least a second also join the charts.

## Power

No admin rights needed. macOS doesn't document these sources, so this is what testing on an M4 Max under macOS 27 showed. Rails may behave differently on other Macs.

| Reading | Source | Observed behaviour |
| --- | --- | --- |
| System total | SMC `PSTR` | Follows every load |
| Adapter input | SMC `PDTR` | Tracks system total on AC |
| SoC rail | SMC `PSVR` | Rises with CPU **and** GPU load |
| Memory rail | SMC `PMVC` | Flat on cache-only load, rises with DRAM traffic |
| Everything else | `PSTR − PSVR − PMVC` | Remainder: display, storage and so on |
| GPU | IOReport `GPU Energy` | Separate reading, already included in the SoC rail. Under a GPU load it read 36 W while the rail rose 73 W, so treat it as a lower bound |
| This app's CPU | `proc_pid_rusage` `ri_energy_nj` | Per-process CPU energy |
| Battery, adapter | IORegistry `AppleSmartBattery` | |

The IOReport `Energy Model` channels most tools use for CPU, DRAM and ANE power (`CPU Energy`, `DRAM`, ...) were frozen on this machine, so they aren't used. Only `GPU Energy` advanced.

## SSD

Reads each NVMe drive's SMART / Health Information log through IOKit's NVMe SMART interface, with no admin rights needed. It shows the drive's wear estimate as life remaining, every critical-warning bit as a health check, media errors, data read and written, power-on time, power cycles, unsafe shutdowns and temperature. It refreshes every 30 seconds.

The read test measures sequential read speed using large files already on the Mac, so it writes nothing. A search thread walks folders any app may read without a privacy prompt (`/Applications`, `/Library`, `/System`, `/opt`, `/usr`, `/Users/Shared`) and hands each file of at least 64 MiB to a reader as soon as it's found. The reader takes them one at a time in 32 MiB requests and stops after 40 GB. Two details keep the result about the drive rather than RAM:

- **Files already in memory are skipped**, checked with `mincore`, because macOS serves cached pages from RAM even with caching off. On this Mac, a cached file read at 24 GB/s against about 6 GB/s from the SSD.
- **Reads use `F_NOCACHE`**, so the test neither fills RAM nor warms the cache for the next run.
- **APFS-compressed files are skipped**, because the CPU decompresses them during the read. Rosetta's shared caches, for example, read at 1.3 GB/s while uncompressed files read at 6.2 GB/s.

Data units are 512,000 bytes as the NVMe spec defines them, shown in decimal TB. USB and SATA drives don't pass SMART through to macOS without a third-party driver, so they aren't listed.

## Launch options

For scripted screenshots and checks: `VU_TAB=power` or `VU_TAB=ssd` opens that tab, `VU_PROCESSOR=gpu` selects the GPU, and `VU_AUTORUN=live|blocks|threads|map` starts a memory run, and `VU_TAB=ssd VU_AUTORUN=read` starts the read test.
