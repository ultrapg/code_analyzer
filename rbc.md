# rbc — Rust Build Clean

A zero-dependency, single-command recursive runner to clean Rust projects. No installs, no config files, no bloat.

---

## What it does

`rbc` scans your current directory for Rust projects (identified by `Cargo.toml`) and automatically runs `cargo clean` in each of them to free up disk space.

By default, it is configured to:

* **Target only directories one level deep** (perfect for workspaces or a folder full of separate projects).
* **Verify Rust environments** (prevents errors by skipping folders that don't contain a `Cargo.toml`).
* **Run safely in subshells** (ensures your terminal stays exactly where you started).

---

## Quick Start

Copy the command into your shell (or save it as `rbc` in your `$PATH`):

```bash
find . -mindepth 1 -maxdepth 1 -type d -exec bash -c '[ -f "$0/Cargo.toml" ] && echo -e "\nCleaning $0..." && cd "$0" && cargo clean' {} \;

```

### Example Output

```text
Cleaning ./my-axum-backend...
    Removed 854 files, 1.2 GiB total

Cleaning ./cli-tool...
    Removed 112 files, 345.1 MiB total

Cleaning ./rust-wasm-project...
    Removed 430 files, 890.5 MiB total

```

---

## Make it a permanent command

### Option A: Alias (quick & dirty)

Add to your `~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`:

```bash
alias rbc='find . -mindepth 1 -maxdepth 1 -type d -exec bash -c '\''[ -f "$0/Cargo.toml" ] && echo -e "\nCleaning $0..." && cd "$0" && cargo clean'\'' {} \;'

```

### Option B: Script (recommended)

Save the snippet below as `/usr/local/bin/rbc` (or `~/.local/bin/rbc`):

```bash
#!/usr/bin/env bash
# rbc — Rust Build Clean

echo "Scanning for Rust projects..."

find . -mindepth 1 -maxdepth 1 -type d -exec bash -c '
    if [ -f "$0/Cargo.toml" ]; then
        echo -e "\n🧹 Cleaning $0..."
        cd "$0" && cargo clean
    fi
' {} \;

echo -e "\n✨ Done!"

```

Then make it executable:

```bash
chmod +x /usr/local/bin/rbc

```

Now run it from anywhere:

```bash
rbc

```

---

## How it works

| Stage | Tool | Purpose |
| --- | --- | --- |
| **Targeting** | `find` | Locates subdirectories exactly one level deep (`-mindepth 1 -maxdepth 1 -type d`). |
| **Isolation** | `bash -c` | Spawns a temporary subshell so directory changes (`cd`) don't affect your current terminal session. |
| **Validation** | `[ -f ... ]` | Checks if `Cargo.toml` exists before attempting to clean, avoiding noisy errors. |
| **Execution** | `cargo clean` | Clears the `target/` directory of compiled artifacts. |

---

## Customization

### Deep Clean (Recursive everywhere)

To search your entire file tree instead of just one level down, remove the depth limits:

```bash
find . -type d -exec bash -c '[ -f "$0/Cargo.toml" ] && echo "Cleaning $0..." && cd "$0" && cargo clean' {} \;

```

### Quiet Mode (No output)

If you just want the space back without the terminal noise, redirect the output to `/dev/null`:

```bash
find . -mindepth 1 -maxdepth 1 -type d -exec bash -c '[ -f "$0/Cargo.toml" ] && cd "$0" && cargo clean > /dev/null 2>&1' {} \;

```

### Dry Run (See what would be cleaned)

Swap `cargo clean` for a simple `echo` to verify which folders will be targeted without actually deleting anything:

```bash
find . -mindepth 1 -maxdepth 1 -type d -exec bash -c '[ -f "$0/Cargo.toml" ] && echo "Ready to clean: $0"' {} \;

```

---

## PowerShell Version

For Windows environments, use this equivalent PowerShell one-liner. It uses `--manifest-path` so it doesn't even need to change directories:

```powershell
Get-ChildItem -Directory | Where-Object { Test-Path (Join-Path $_.FullName "Cargo.toml") } | ForEach-Object { Write-Host "`nCleaning $($_.Name)..." -ForegroundColor Cyan; cargo clean --manifest-path (Join-Path $_.FullName "Cargo.toml") }

```
