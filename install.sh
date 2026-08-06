#!/usr/bin/env bash
# Installer for claude-watch. Run from a clone:
#   ./install.sh
# Symlinks the CLI onto PATH, installs + loads the launchd sampler, and prints
# the one line to add to your shell rc (it never edits your rc for you).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DEST="$BIN_DIR/claude-watch"
LABEL="com.turbokach.claudewatch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(uname -s)" = "Darwin" ] || { echo "error: macOS only (uses ps, vm_stat, lsof, launchd)." >&2; exit 1; }

# --- CLIs on PATH ---
mkdir -p "$BIN_DIR"
ln -sf "$REPO/claude-watch" "$DEST"
ln -sf "$REPO/claude-top" "$BIN_DIR/claude-top"
chmod +x "$REPO/claude-watch" "$REPO/claude-top" "$REPO/tools/sample.sh"
echo "symlinked $DEST -> $REPO/claude-watch"
echo "symlinked $BIN_DIR/claude-top -> $REPO/claude-top"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add it to run \`claude-watch\` by name" ;;
esac

# --- agent skills ---
# Symlinked rather than copied so the skill stays in step with the flags it
# documents: pulling the repo updates the skill. Claude Code follows a symlinked
# skill directory and picks up edits live, without a restart.
SKILL_DIR="$HOME/.claude/skills"
mkdir -p "$SKILL_DIR"
for s in claude-watch claude-watch-reap; do
  # `ln -sfn` onto a REAL directory does not replace it — it drops the link
  # INSIDE it, and Claude Code then keeps loading the old copy while this script
  # cheerfully reports success. Refuse rather than half-install.
  if [ -d "$SKILL_DIR/$s" ] && [ ! -L "$SKILL_DIR/$s" ]; then
    echo "warning: $SKILL_DIR/$s is a real directory, not a symlink — skipping."
    echo "         Claude Code will keep loading that copy. Remove it and re-run:"
    echo "           rm -rf $SKILL_DIR/$s && ./install.sh"
    continue
  fi
  ln -sfn "$REPO/skills/$s" "$SKILL_DIR/$s"
  echo "symlinked $SKILL_DIR/$s -> $REPO/skills/$s"
done

# --- launchd sampler ---
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
    "$REPO/tools/$LABEL.plist" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "loaded launchd job $LABEL (samples every 10s)"

# --- new-day hook: print the line, don't edit their rc ---
# The date guard is inline rather than inside claude-watch on purpose: this runs
# on EVERY shell start, and shelling out to the script costs ~10ms (bash startup
# plus parsing) against ~1.3ms for a builtin test. Measured, not assumed.
RC="$HOME/.zshrc"
HOOK_LINE='[[ -r ~/.claude-watch/state/last-shown && "$(<~/.claude-watch/state/last-shown)" == "$(date +%F)" ]] || claude-watch hook'
echo
if grep -qF 'claude-watch hook' "$RC" 2>/dev/null; then
  echo "new-day hook already present in $RC"
else
  echo "To get the daily digest on your first shell of a new day, add to $RC:"
  echo
  echo "    $HOOK_LINE"
  echo
  echo "(~1.3ms on every other shell; it only execs claude-watch once a day)"
fi

echo
echo "Done. Verify with:  claude-watch doctor"
echo "First digest appears on your next new day; \`claude-watch\` shows today so far."
