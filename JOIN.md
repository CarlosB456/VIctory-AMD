# Join VIctory-AMD – Collaborative AI Optimization & Verification

## COPY & PASTE THIS PROMPT INTO YOUR AI AGENT

#### English

```text
Fetch and follow the instructions at https://raw.githubusercontent.com/CarlosB456/VIctory-AMD/main/JOIN.md to contribute to VIctory-AMD. Fork CarlosB456/VIctory-AMD, read SECURITY-GATE.md and TASKS.json, pick one open task, verify it with unit tests, and open a clean Pull Request against main.
```

#### Español

```text
Lee y sigue las instrucciones de https://raw.githubusercontent.com/CarlosB456/VIctory-AMD/main/JOIN.md (o del repositorio https://github.com/CarlosB456/VIctory-AMD) para sumarte a optimizar VIctory-AMD. Haz fork del repo, revisa SECURITY-GATE.md y TASKS.json, elige una tarea abierta, impleméntala con unit tests reales y abre un Pull Request contra CarlosB456/VIctory-AMD.
```

---

`VIctory-AMD` (`https://github.com/CarlosB456/VIctory-AMD`) is a collaborative effort based on [`Belobug/VIctory-Belobug-AMD`](https://github.com/Belobug/VIctory-Belobug-AMD) where anyone can point **any** AI coding agent (Antigravity, Claude Code, Cursor, Codex, Gemini CLI, DeepSeek, Qwen, etc.) at real bottlenecks to reach **30 FPS playable, bug-free gameplay**.

> You do **not** need a local copy of any retail game — the maintainer's hardware gatekeeper (`scripts/eval-pr.ps1`) runs the real benchmark automatically on AMD Radeon RX 6600 (8 GB VRAM, 16 GB RAM).

Nothing is merged on trust. Every Pull Request passes through two strict gates:
1. **Static Security & Anti-Slop Audit (`SECURITY-GATE.md`)** before any untrusted code is compiled or executed.
2. **Real Hardware Verification (`scripts/eval-pr.ps1`)** — Rust unit tests + release build (`victory.exe`) + timed live benchmark comparing FPS, frame time, copy overhead, RAM/commit, and crash/device-removal counts against `main`.

---

## Rules for Contributors & AI Agents

Read `SECURITY-GATE.md` before writing code:

1. **Zero AI Slop:**
   - Do NOT disable, weaken, or `#[ignore]` existing tests.
   - Do NOT fake FPS by skipping real rendering passes or altering `scripts/eval-pr.ps1`.
   - Every change must include real unit tests (`cargo test`) and a concise technical summary.
2. **Zero Untrusted Side Effects (Strict Security):**
   - Do NOT modify `build.rs`, `.github/workflows/`, `scripts/`, or add third-party crates to `Cargo.toml` / `Cargo.lock` unless strictly required and explained.
   - Do NOT add network calls, telemetry, dynamic shell execution (`Command::new`, PowerShell, `cmd.exe`), registry/persistence writes, or filesystem access outside documented `victory` cache/VFS paths.
3. **One Task, One Clean PR:**
   - Pick a task from `TASKS.json` / `TASKS.md` (or use `open-discovery` for any verified improvement).
   - Never commit game files, `.exe`/`.dll`/`.rpf` binaries, logs, or API keys.

---

## Quick Start for Your AI Agent

```powershell
# 1. Fork & clone (and ALWAYS sync your fork with CarlosB456/VIctory-AMD BEFORE branching!)
gh repo fork CarlosB456/VIctory-AMD --clone
cd VIctory-AMD
gh repo sync --source CarlosB456/VIctory-AMD
git fetch origin main
git checkout main
git reset --hard origin/main

# 2. Pick a task ID from TASKS.json / TASKS.md (or open-discovery)
git checkout -b task/<task-id>

# 3. Implement your change + unit tests

# 4. Run tests and build locally
cargo test --release --workspace -- --test-threads=1
cargo build --release -p victory

# 5. Push and open a Pull Request against CarlosB456/VIctory-AMD (base: main)
git push -u origin task/<task-id>
gh pr create --repo CarlosB456/VIctory-AMD --base main --title "[<task-id>] Concise summary"
```
