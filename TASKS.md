# VIctory-AMD — Task Board

> **Repo:** [CarlosB456/VIctory-AMD](https://github.com/CarlosB456/VIctory-AMD)  
> **Base:** [Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD)  
> **Goal:** Stable, playable Xbox Series S/X HLE emulation for GTA VI on the widest possible consumer hardware.

---

## Philosophy — Read This First

**Tasks are always open.** No task is ever "done and closed." Each task is a direction of improvement. Different contributors will find different angles — a fix that halves VRAM on an RX 6600 may leave room for another contributor to halve it again on a 4 GB GPU. PRs that improve the same task from a new angle are always welcome.

### Non-Contradiction Rule
Every PR must pass the **full crates/ unit test suite** AND a live timed run. PRs that:
- Break a previously passing test
- Increase frame time on RX 6600
- Increase RAM/VRAM consumption
- Introduce driver crashes on any supported GPU

...are rejected regardless of stated intent.

### Hardware Neutrality Rule
No optimization may hardcode a GPU vendor (AMD, NVIDIA, Intel), a specific architecture generation, or a specific wave size. Use runtime detection (DXGI, D3D12 feature level queries) or conservative safe defaults. Always keep Wave32 (NVIDIA/AMD RDNA) and Wave64 (AMD legacy) compatibility.

---

## Supported Hardware Matrix

| Vendor | Arch | Models | Min VRAM | Wave Size |
|--------|------|--------|----------|-----------|
| AMD | RDNA2 | RX 6500 XT – RX 6950 XT | 4 GB | 32 |
| AMD | RDNA3 | RX 7600 – RX 7900 XTX | 8 GB | 32 |
| AMD | RDNA4 | RX 9070 – RX 9070 XT | 16 GB | 32 |
| NVIDIA | Ampere | RTX 3060 – RTX 3090 Ti | 8 GB | 32 |
| NVIDIA | Ada | RTX 4060 – RTX 4090 | 8 GB | 32 |
| Intel | Xe-HPG | Arc A380, A750, A770 | 6 GB | 8 |

**RAM target:** 8–16 GB (must run stable at 16 GB; 8 GB must not crash)  
**VRAM target:** 6–8 GB minimum (must not OOM at 8 GB on RX 6600)  
**OS:** Windows 10 22H2+, Windows 11 23H2+  
**Storage:** HDD 7200 rpm, NVMe Gen3, NVMe Gen4  
**Console profile:** `series-s`

---

## Known Baselines (Do Not Regress)

| Area | Baseline | Commit |
|------|----------|--------|
| Pipeline load FPS | 121–124 fps / 8 ms/frame | `66678857` |
| D3D12 Agility SDK | SDKVersion=614 exported from victory.exe | `ff8e29e0` |
| Texpool class step | `/8` (finer), whole-slot slab heaps | `b74ca2b6` |
| World 3D FPS | 5–8 fps — **open improvement target** | — |
| RAM at 25 s | ~8.8–9.6 GB priv_mb — **open reduction target** | — |

---

## Tasks

> All tasks are `evergreen: true` — open to multiple independent PRs improving the same area from different angles.

---

### `perf-world-fps` — Raise 3D World Frame Rate Toward 30 FPS
**Category:** CPU / GPU Frame Time | **Points:** 100 | **Level:** Hard

The game renders 8,800+ draws per frame in the 3D world, currently running at 5–8 fps. Any PR that measurably reduces per-frame CPU or GPU time — without crashing or regressing tests — is welcome. Submit focused, non-overlapping PRs rather than one monolithic change.

**Where to look:**
- `crates/victory-gpu/src/host.rs` — `execute_inner`, `prewarm`, `finish_submission`
- `crates/victory-gpu/src/list.rs` — draw list sorting, culling, deduplication
- `crates/victory-gpu/src/descriptor/host.rs` — per-frame bindless descriptor patching
- `crates/victory-gpu/src/frame.rs` — frame pacing, present, uncapped logic
- `crates/victory-gpu/src/queue.rs` — submit batching, fence wait
- `crates/victory-gpu/src/shadow.rs` — copy-back overhead
- `crates/victory-gpu/src/watch.rs` — watch overhead per frame

**Acceptance:** Measurable ms/frame reduction on RX 6600. All victory-gpu unit tests pass. Zero crashes. Zero new driver warnings. Wave32 semantics preserved.

**Anti-patterns:** Do not hardcode wave size. Do not remove safety fences. Do not merge draw calls with different root signatures without correctness validation.

---

### `perf-ram-vram` — Reduce RAM and VRAM Usage for 16 GB / 8 GB Hardware
**Category:** RAM / VRAM Footprint | **Points:** 95 | **Level:** Hard

Observed: ~8.8–9.6 GB priv_mb at 25 s, climbing. VRAM must fit in 8 GB on RX 6600. Multiple non-overlapping improvements welcome: texture eviction, compressed heap reuse, resident set trimming, streaming LOD. Each PR must not conflict with the texpool baseline (`b74ca2b6`).

**Where to look:**
- `crates/victory-gpu/src/texpool.rs` — texture slot pool (baseline: b74ca2b6)
- `crates/victory-gpu/src/resource.rs` — GPU resource lifetime and eviction
- `crates/victory-gpu/src/memory.rs` — heap allocation and committed memory tracking
- `crates/victory-gpu/src/texture.rs` — texture upload, mip streaming
- `crates/victory-hle/src/modules/xmem.rs` — XMemAlloc large-page host allocator
- `crates/victory-hle/src/modules/files.rs` — RPF streaming buffer sizing

**Acceptance:** Measurable reduction in priv_mb or VRAM committed. 6/6 texpool unit tests still pass. Zero OOM crashes. Zero visual regressions.

**Anti-patterns:** Do not evict aggressively without measuring eviction rate. Do not regress texpool class step back to `/4`. Do not modify xmem without verifying BCPack still works.

---

### `perf-shader-compile` — Speed Up Shader Compilation; Fix Crashing Compute Shader
**Category:** Shader Compiler / Driver | **Points:** 85 | **Level:** Hard

First-launch pipeline rebuild causes minutes of black screen. Compute shader `f16876929fa64f9f` crashes the AMD driver compiler. Shader cache invalidation is too aggressive. Improvements to parallelism, caching, and DXIL translation quality are all welcome.

**Where to look:**
- `crates/victory-shader/src/emit/` — DXIL emitter, dead-code elimination
- `crates/victory-shader/src/opt/` — optimization passes
- `crates/victory-gpu/src/shader_cache.rs` — disk cache keying and invalidation
- `crates/victory-gpu/src/pipeline/` — pipeline object creation, worker scheduling
- `crates/victory-gpu/src/pipeline/make.rs` — BACKLOG_BUDGET, worker count

**Acceptance:** Faster measured pipeline build time. All victory-shader unit tests pass. No driver crashes on AMD/NVIDIA/Intel. Does not regress pipeline worker budget fix (`66678857`).

**Anti-patterns:** Do not increase worker count above n/4 without profiling. Do not add vendor-specific DXIL paths without a runtime branch guarded by DXGI vendor ID.

---

### `compat-multi-gpu` — Multi-GPU Compatibility: AMD, NVIDIA, Intel Arc
**Category:** Multi-GPU Compatibility | **Points:** 90 | **Level:** Hard

Developed primarily on AMD hardware. NVIDIA uses Wave32 with stricter DXIL validation. Intel Arc requires Resizable BAR and has different heap behavior. Any fix that improves compatibility without breaking AMD is valuable.

**Where to look:**
- `crates/victory-shader/` — wave size assumptions, SM6.6 intrinsic usage
- `crates/victory-gpu/src/device.rs` — DXGI adapter queries, feature level detection
- `crates/victory-gpu/src/memory.rs` — heap type selection (UPLOAD vs DEFAULT vs CUSTOM)
- `crates/victory-gpu/src/pipeline/` — root signature flags, SM version cap
- `crates/victory-hle/src/modules/kernel.rs` — host DLL policy (`amd_fidelityfx_upscaler_xbox.dll` refused)

**Acceptance:** No regression on RX 6600. Documented test evidence on at least one additional GPU family. Zero vendor strings hardcoded in Rust source.

**Anti-patterns:** Do not use vendor strings — use DXGI vendor IDs (AMD=0x1002, NVIDIA=0x10DE, Intel=0x8086). Do not assume Wave64. Do not require Resizable BAR unconditionally.

---

### `compat-low-end-hardware` — Support 4–6 GB VRAM, 8 GB RAM, HDD, 4-Core CPU
**Category:** Low-End Hardware | **Points:** 90 | **Level:** Hard

Target floor: RX 6500 XT (4 GB VRAM), 8 GB RAM, HDD, 4-core/8-thread CPU. Requires aggressive LOD, texture streaming, pipeline cache reuse, and worker thread caps. Must not degrade quality or FPS on higher-end hardware.

**Where to look:**
- `crates/victory-gpu/src/texpool.rs` — slot eviction policy under VRAM pressure
- `crates/victory-gpu/src/resource.rs` — resident set management
- `crates/victory-hle/src/modules/dstorage.rs` — staging buffer (32 MB), worker count (16)
- `crates/victory-gpu/src/pipeline/make.rs` — worker thread cap under low core count
- `crates/victory-formats/src/bcpack.rs` — decompression throughput on HDD

**Acceptance:** No OOM crash at 4 GB VRAM or 8 GB RAM. No regression on RX 6600 / 16 GB baseline. HDD streaming must not corrupt textures or produce pop-in gaps > 500 ms.

**Anti-patterns:** Do not reduce staging buffer below 16 MB. Do not evict pipeline cache entries. Do not add quality reduction without a runtime VRAM-pressure gate.

---

### `visual-artifacts` — Fix Visual Bugs: Phone, Water, Lighting, Shadows, Corruption
**Category:** Visual Bugs / Rendering Correctness | **Points:** 85 | **Level:** Hard

Known issues: (1) opening the in-game phone leaves world unlit (black) with empty outline only; (2) water missing on first run after shader cache rebuild until restart; (3) any other rendering artifact discovered. PRs fixing different artifacts are independent.

**Where to look:**
- `crates/victory-gpu/src/ambient.rs` — ambient/global lighting state
- `crates/victory-gpu/src/host.rs` — render target transitions, UAV barriers
- `crates/victory-gpu/src/texture.rs` — texture residency and promotion
- `crates/victory-gpu/src/list.rs` — render pass ordering
- `crates/victory-shader/src/emit/` — incorrect DXIL translation
- `crates/victory-hle/src/modules/dstorage.rs` — first-run file ordering

**Acceptance:** Artifact not reproducible in a live session. No new artifacts introduced. All unit tests pass.

**Anti-patterns:** Do not mask lighting bugs by boosting ambient — fix the state machine. Do not clear textures to magenta as a placeholder.

---

### `perf-storage-streaming` — Optimize DirectStorage and RPF Streaming for HDD and NVMe
**Category:** HDD / NVMe / DirectStorage | **Points:** 75 | **Level:** Solid

World streaming and BCPack/zlib decompression hitch during fast traversal. Improvements to queue depth, decompression parallelism, read-ahead, and staging buffer management are welcome. PRs may target HDD or NVMe separately.

**Where to look:**
- `crates/victory-hle/src/modules/dstorage.rs` — queue depth, staging buffer (32 MB / 16 workers)
- `crates/victory-formats/src/bcpack.rs` — BCPack block decompression, SIMD opportunities
- `crates/victory-formats/src/rpf.rs` — RPF archive reader, seek patterns

**Acceptance:** Faster decompression throughput (MB/s) or reduced hitch duration. Zero data corruption (hash-verify output). All victory-formats unit tests pass.

**Anti-patterns:** Do not increase staging buffer above 128 MB without measuring RAM impact. Do not use unsafe SIMD without feature-gating on the `cpufeatures` crate.

---

### `stability-crashes` — Fix Crashes, Panics, Deadlocks, Device Removal
**Category:** Stability / Crash Prevention | **Points:** 90 | **Level:** Hard

Any crash, Rust panic, D3D12 device removal, or deadlock found during gameplay is a valid target. Crashes may be intermittent — provide a reproduction step or log excerpt. PRs that add defensive checks, fix race conditions, or handle edge cases are always welcome.

**Where to look:**
- `crates/victory-gpu/src/` — fence waits, barrier transitions, descriptor heap overflow
- `crates/victory-hle/src/modules/` — HLE function panics on unexpected arguments
- `crates/victory-loader/src/` — image mapping, TLS redirect edge cases
- `apps/victory/src/main.rs` — top-level panic handler

**Acceptance:** Crash not reproducible. If intermittent, add a regression test or log assertion. All existing tests pass.

**Anti-patterns:** Do not use `unwrap()` in hot paths — propagate errors. Do not silence a panic with `catch_unwind` without logging.

---

### `perf-frame-pacing` — Eliminate Frame Time Spikes and Micro-Stutters
**Category:** Frame Pacing / Latency | **Points:** 75 | **Level:** Solid

Even at target FPS, irregular frame delivery causes perceived stutter. Improvements to present timing, fence pipelining, pipeline stall elimination, and GPU-CPU synchronization are welcome.

**Where to look:**
- `crates/victory-gpu/src/frame.rs` — present mode, `uncapped()`, vsync logic
- `crates/victory-gpu/src/queue.rs` — fence wait granularity
- `crates/victory-gpu/src/host.rs` — CPU-GPU sync points, prewarm
- `crates/victory-gpu/src/pipeline/make.rs` — just-in-time stalls when pipeline not ready

**Acceptance:** Measured reduction in frame time variance (99th percentile ms/frame). No regression to median FPS. All tests pass.

**Anti-patterns:** Do not remove GPU-CPU synchronization fences. Do not set present interval to 0 unconditionally.

---

### `open-discovery` — Find and Fix Anything Else
**Category:** Open Discovery | **Points:** 50 | **Level:** Open

If you find a performance win, bug, or compatibility issue not covered above — shader bugs, allocator inefficiencies, HLE correctness issues, input handling, audio glitches — open a PR. All areas of `crates/` and `apps/` are in scope.

**Acceptance:** Strictly scoped to VIctory-AMD functionality. Passes SECURITY-GATE.md. Includes at least one unit test or measured benchmark. Zero regressions.

**Anti-patterns:** Do not submit refactors with no measurable improvement. Do not submit changes to `scripts/`, `.github/`, or build infrastructure without prior discussion.

---

## How to Submit a PR

1. Fork [CarlosB456/VIctory-AMD](https://github.com/CarlosB456/VIctory-AMD)
2. Read [SECURITY-GATE.md](SECURITY-GATE.md) — your PR will be automatically scanned
3. Keep changes focused: one task direction per PR, minimum files touched
4. Include test results: paste the output of `cargo test --release -p victory-gpu`
5. Include a measured before/after: frame time, RAM, VRAM, or compile time
6. Open the PR — the AI evaluator will assess it within 5 minutes
