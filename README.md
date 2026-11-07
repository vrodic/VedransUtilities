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

Measures bandwidth live, by operation, block size, thread count and processor: performance cores, efficiency cores or GPU.

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

## Launch options

For scripted screenshots and checks: `VU_TAB=power` opens the Power tab, `VU_PROCESSOR=gpu` selects the GPU, and `VU_AUTORUN=live|blocks|threads|map` starts a run.
