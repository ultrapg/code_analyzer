# tloc — Total Lines of Code

A zero-dependency, single-command line counter for your projects. No installs, no config files, no bloat.

---

## What it does

`tloc` recursively scans your project and reports:

| Metric | Description |
|--------|-------------|
| **Files** | Total files analyzed |
| **Lines** | Total newline characters (`\n`) |
| **Characters** | Total bytes across all matched files |

It automatically skips the noise:
- Hidden files & directories (`.*`)
- Rust build artifacts (`target/`)
- JavaScript dependencies (`node_modules/`)

---

## Quick Start

Copy the command into your shell (or save it as `tloc` in your `$PATH`):

```bash
find . -type f \
  -not -path '*/.*' \
  -not -path '*/target/*' \
  -not -path '*/node_modules/*' \
  -exec cat {} + 2>/dev/null \
  | wc -l -m \
  | awk -v files=$(find . -type f -not -path '*/.*' -not -path '*/target/*' -not -path '*/node_modules/*' | wc -l) \
    '{print "Files:      " files "\nLines:      " $1 "\nCharacters: " $2}'
```

### Example Output

```text
Files:      42
Lines:      3847
Characters: 128293
```

---

## Make it a permanent command

### Option A: Alias (quick & dirty)
Add to your `~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`:

```bash
alias tloc='find . -type f -not -path '''*/.*''' -not -path '''*/target/*''' -not -path '''*/node_modules/*''' -exec cat {} + 2>/dev/null | wc -l -m | awk -v files=$(find . -type f -not -path '''*/.*''' -not -path '''*/target/*''' -not -path '''*/node_modules/*''' | wc -l) '''{print "Files:      " files "\nLines:      " $1 "\nCharacters: " $2}''''
```

### Option B: Script (recommended)
Save the snippet below as `/usr/local/bin/tloc` (or `~/.local/bin/tloc`):

```bash
#!/usr/bin/env bash
# tloc — Total Lines of Code

find . -type f \
  -not -path '*/.*' \
  -not -path '*/target/*' \
  -not -path '*/node_modules/*' \
  -exec cat {} + 2>/dev/null \
  | wc -l -m \
  | awk -v files=$(find . -type f -not -path '*/.*' -not -path '*/target/*' -not -path '*/node_modules/*' | wc -l) \
    '{print "Files:      " files "\nLines:      " $1 "\nCharacters: " $2}'
```

Then make it executable:

```bash
chmod +x /usr/local/bin/tloc
```

Now run it from anywhere:

```bash
tloc
```

---

## How it works

| Stage | Tool | Purpose |
|-------|------|---------|
| **Find** | `find` | Locate all regular files, prune noise paths |
| **Concatenate** | `cat` | Stream contents into a single pipe |
| **Count** | `wc -l -m` | Count lines (`-l`) and characters (`-m`) |
| **Format** | `awk` | Pretty-print with the pre-counted file total |

The `2>/dev/null` suppresses permission errors. The command runs entirely within standard POSIX utilities—no external dependencies.

---

## Customization

### Exclude additional directories
Add more `-not -path` clauses:

```bash
-not -path '*/vendor/*' \
-not -path '*/dist/*' \
-not -path '*/build/*'
```

### Target specific file types
Replace the `find` file test with an extension filter:

```bash
find . -type f \( -name '*.rs' -o -name '*.py' -o -name '*.md' \) ...
```

### Count only source code (no docs/tests)
```bash
find . -type f -not -path '*/.*' -not -path '*/target/*' -not -path '*/node_modules/*' -not -path '*/tests/*' -not -name '*.md' ...
```
