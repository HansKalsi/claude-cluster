#!/usr/bin/env bash

# claude-cluster installer
# Symlinks ./claude-cluster into $CLAUDE_CLUSTER_INSTALL_DIR (default: ~/bin)
# and reports on missing runtime dependencies.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$REPO_DIR/claude-cluster"
INSTALL_DIR="${CLAUDE_CLUSTER_INSTALL_DIR:-$HOME/bin}"
TARGET="$INSTALL_DIR/claude-cluster"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ ! -f "$SCRIPT_PATH" ]]; then
    log_error "claude-cluster script not found at $SCRIPT_PATH"
    exit 1
fi

chmod +x "$SCRIPT_PATH"
mkdir -p "$INSTALL_DIR"

if [[ -L "$TARGET" ]]; then
    log_warn "Replacing existing symlink: $TARGET"
    rm -f "$TARGET"
elif [[ -e "$TARGET" ]]; then
    log_error "$TARGET already exists and is not a symlink. Refusing to overwrite."
    log_error "Remove it manually if you want to reinstall: rm $TARGET"
    exit 1
fi

ln -s "$SCRIPT_PATH" "$TARGET"
log_success "Linked $TARGET -> $SCRIPT_PATH"

if ! echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
    log_warn "$INSTALL_DIR is not in your PATH"
    echo "    Add this line to ~/.zshrc (or your shell's rc file):"
    echo "        export PATH=\"$INSTALL_DIR:\$PATH\""
fi

log_info "Checking runtime dependencies..."

if command -v jq &> /dev/null; then
    log_success "jq found"
else
    log_warn "jq missing — install with: brew install jq"
fi

if command -v claude &> /dev/null; then
    log_success "claude CLI found"
else
    log_warn "claude CLI missing — see https://docs.claude.com/en/docs/claude-code"
fi

log_success "Installation complete. Run: claude-cluster help"
