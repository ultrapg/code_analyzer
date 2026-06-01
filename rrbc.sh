#!/usr/bin/env bash
set -uo pipefail

# rrbc — Rust Repo Build Checker
# Fetches all public repos from a GitHub user, clones/pulls them,
# and builds only the Rust ones in release mode.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=()
FAIL=()
SKIP=()
CLONE_FAIL=()

# Check dependencies
for cmd in curl git cargo; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}rrbc error:${NC} '$cmd' is required but not installed."
        exit 1
    fi
done

# Parse argument
if [ $# -eq 0 ]; then
    echo -e "${CYAN}rrbc${NC} — Rust Repo Build Checker"
    echo ""
    echo -e "${BLUE}Usage:${NC} rrbc <github-username-or-url>"
    echo ""
    echo "Examples:"
    echo "  rrbc ultrapg"
    echo "  rrbc https://github.com/ultrapg"
    exit 1
fi

INPUT="$1"

# Extract username from URL or use directly
if [[ "$INPUT" =~ ^https?://github\.com/([^/]+)/?.*$ ]]; then
    USERNAME="${BASH_REMATCH[1]}"
else
    USERNAME="$INPUT"
fi

echo -e "${CYAN}rrbc${NC} ${BLUE}→ Fetching repositories for GitHub user:${NC} ${CYAN}$USERNAME${NC}"

# Create a working directory
WORK_DIR="${USERNAME}_repos"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Build curl args — use GITHUB_TOKEN if available to avoid rate limits
CURL_ARGS=(-sL -H "Accept: application/vnd.github.v3+json")
if [ -n "${GITHUB_TOKEN:-}" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    echo -e "${GREEN}rrbc → Using GITHUB_TOKEN for authentication${NC}"
fi

# Fetch all repos with pagination
PAGE=1
ALL_REPOS=()
while true; do
    API_URL="https://api.github.com/users/${USERNAME}/repos?per_page=100&page=${PAGE}"
    RESPONSE=$(curl "${CURL_ARGS[@]}" "$API_URL")

    # Debug: if empty response, show what we got
    if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "[]" ]; then
        break
    fi

    # Check for API errors
    if echo "$RESPONSE" | grep -q '"message"'; then
        MSG=$(echo "$RESPONSE" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"//; s/"$//')
        echo -e "${RED}rrbc error:${NC} GitHub API error — $MSG"
        echo -e "${YELLOW}Tip: Set GITHUB_TOKEN env var if you're hitting rate limits.${NC}"
        exit 1
    fi

    # Extract repo names — prefer python3, fallback to grep/sed
    REPOS_ON_PAGE=""
    if command -v python3 &>/dev/null; then
        REPOS_ON_PAGE=$(echo "$RESPONSE" | python3 -c "import sys,json; [print(r['full_name']) for r in json.load(sys.stdin)]" 2>/dev/null)
    fi

    if [ -z "$REPOS_ON_PAGE" ]; then
        # Fallback grep/sed parser
        REPOS_ON_PAGE=$(echo "$RESPONSE" | grep -o '"full_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"//; s/"$//')
    fi

    if [ -z "$REPOS_ON_PAGE" ]; then
        echo -e "${YELLOW}rrbc → Warning: Could not parse repos from API response.${NC}"
        echo -e "${YELLOW}Raw response (first 500 chars):${NC}"
        echo "$RESPONSE" | head -c 500
        echo ""
        break
    fi

    while IFS= read -r repo; do
        [ -n "$repo" ] && ALL_REPOS+=("$repo")
    done <<< "$REPOS_ON_PAGE"

    # Count repos on this page
    COUNT=$(echo "$REPOS_ON_PAGE" | grep -c '^' || true)
    if [ "$COUNT" -lt 100 ]; then
        break
    fi

    PAGE=$((PAGE + 1))
done

TOTAL=${#ALL_REPOS[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo -e "${YELLOW}rrbc:${NC} No public repositories found for user '$USERNAME'."
    exit 0
fi

echo -e "${CYAN}rrbc${NC} ${BLUE}→ Found${NC} ${CYAN}$TOTAL${NC} ${BLUE}repositories.${NC}\n"

# Process each repository
for repo in "${ALL_REPOS[@]}"; do
    REPO_NAME=$(basename "$repo")

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Repository:${NC} ${CYAN}$REPO_NAME${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Clone or pull
    if [ -d "$REPO_NAME/.git" ]; then
        echo -e "${YELLOW}rrbc → Pulling updates...${NC}"
        if (cd "$REPO_NAME" && git pull --ff-only); then
            echo -e "${GREEN}✓ Updated${NC}"
        else
            echo -e "${RED}✗ Pull failed, trying to continue...${NC}"
        fi
    else
        echo -e "${YELLOW}rrbc → Cloning...${NC}"
        if git clone --depth 1 "https://github.com/${repo}.git" "$REPO_NAME"; then
            echo -e "${GREEN}✓ Cloned${NC}"
        else
            echo -e "${RED}✗ Clone failed${NC}"
            CLONE_FAIL+=("$REPO_NAME")
            continue
        fi
    fi

    # Check if it's a Rust project
    if [ ! -f "$REPO_NAME/Cargo.toml" ]; then
        echo -e "${YELLOW}[SKIP]${NC} Not a Rust repository (no Cargo.toml)"
        SKIP+=("$REPO_NAME")
        continue
    fi

    echo -e "${YELLOW}rrbc → Building release...${NC}"
    if (cd "$REPO_NAME" && cargo build --release); then
        echo -e "${GREEN}[PASS]${NC} Build succeeded"
        PASS+=("$REPO_NAME")
    else
        echo -e "${RED}[FAIL]${NC} Build failed"
        FAIL+=("$REPO_NAME")
    fi
done

echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}     ${CYAN}rrbc${NC} ${BLUE}— Rust Repo Build Checker Summary${NC}     ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

if [ ${#PASS[@]} -gt 0 ]; then
    echo -e "\n${GREEN}✓ Passed (${#PASS[@]}):${NC}"
    for r in "${PASS[@]}"; do
        echo -e "  ${GREEN}•${NC} $r"
    done
fi

if [ ${#FAIL[@]} -gt 0 ]; then
    echo -e "\n${RED}✗ Failed (${#FAIL[@]}):${NC}"
    for r in "${FAIL[@]}"; do
        echo -e "  ${RED}•${NC} $r"
    done
fi

if [ ${#SKIP[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}○ Skipped (not Rust) (${#SKIP[@]}):${NC}"
    for r in "${SKIP[@]}"; do
        echo -e "  ${YELLOW}•${NC} $r"
    done
fi

if [ ${#CLONE_FAIL[@]} -gt 0 ]; then
    echo -e "\n${RED}✗ Clone failed (${#CLONE_FAIL[@]}):${NC}"
    for r in "${CLONE_FAIL[@]}"; do
        echo -e "  ${RED}•${NC} $r"
    done
fi

TOTAL_PROCESSED=$((${#PASS[@]} + ${#FAIL[@]} + ${#SKIP[@]} + ${#CLONE_FAIL[@]}))
echo -e "\n${BLUE}Total repositories:${NC} $TOTAL"
echo -e "${BLUE}Processed:${NC} $TOTAL_PROCESSED"
echo -e "${GREEN}Passed:${NC} ${#PASS[@]}  ${RED}Failed:${NC} ${#FAIL[@]}  ${YELLOW}Skipped:${NC} ${#SKIP[@]}  ${RED}Clone errors:${NC} ${#CLONE_FAIL[@]}"
