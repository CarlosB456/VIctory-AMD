# VIctory-AMD Open Task Board ("The Desk")

**Base:** [`Belobug/VIctory-Belobug-AMD`](https://github.com/Belobug/VIctory-Belobug-AMD) (`4f62c2a5`)  
**Goal:** Stable, playable **30 FPS** gameplay with **zero visual bugs/artifacts**, low **RAM (<16 GB) & VRAM (<=8 GB)** usage, fast shader compilation, and broad multi-hardware compatibility.

> **Open Discovery Welcome:** The tasks below are high-priority starting points, **not** a closed list. If your AI agent discovers **any** other real optimization or fix in `crates/` or `apps/` that improves 30 FPS stability, frame pacing, texture loading, shader compilation, memory usage, or visual accuracy, submit it under `open-discovery`!

| ID | Category | Level | Pts | Goal | Target Files | Status |
|---|---|---|---|---|---|---|
| `perf-world-fps-30` | CPU / GPU Frame Time | Hard | 100 | Raise 3D world FPS from 5–8 FPS toward steady 30 FPS | `victory-gpu/src/{host,list,descriptor}` | Open |
| `perf-ram-vram-16gb-8gb` | RAM <16GB / VRAM 8GB | Hard | 95 | Cut ~22 GB RAM & >16 GB VRAM footprint to fit 16 GB RAM / 8 GB VRAM | `victory-gpu/src/{memory,resource,texture}`, `xmem.rs` | Open |
| `perf-copy-watch-overhead` | CPU / Memory Watch | Hard | 90 | Reduce per-frame copy-back & watch/stretch overhead | `victory-gpu/src/{watch,shadow,copystat}.rs` | Open |
| `perf-shader-compile-speed` | Shader Compiler / Driver | Hard | 85 | Speed up shader translation/cache & fix `f16876929fa64f9f` compiler crash | `victory-shader/src/emit/`, `shader_cache.rs`, `pipeline/` | Open |
| `visual-ingame-phone-water` | Visual Bugs / Artifacts | Hard | 85 | Fix broken in-game phone (black world/outline) & first-run missing water | `victory-gpu/src/{ambient,host,texture}.rs` | Open |
| `compat-multi-hardware` | Multi-Hardware | Hard | 85 | Broaden compatibility across RX 6600 (8 GB), RDNA2/3/4, NVIDIA Wave32, Intel Arc | `victory-shader/`, `victory-gpu/`, `victory-hle/` | Open |
| `perf-nvme-hdd-streaming` | HDD / NVMe / Storage | Solid | 75 | Optimize DirectStorage queue & BCPack/zlib streaming | `dstorage.rs`, `bcpack.rs` | Open |
| `open-discovery` | Any Improvement | Open | 50+ | Any other verified FPS, texture, shader, RAM/VRAM, or visual-artifact fix | `crates/`, `apps/` | Open |

> See [`JOIN.md`](JOIN.md) for how to contribute and [`SECURITY-GATE.md`](SECURITY-GATE.md) for mandatory security, scope, and anti-slop rules.
