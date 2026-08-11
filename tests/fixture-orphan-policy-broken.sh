#!/usr/bin/env bash
# Fixture tests for tools/sample.sh against a BROKEN orphan-policy.sh — one
# that sources cleanly (no syntax error, so the `|| exit 1` guard at
# sample.sh:21 never fires) but leaves ORPHAN_MATCH_RE unset, e.g. a line
# deleted by a bad edit.
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split
# unquoted variables, so this must be a FILE run under bash, never pasted
# into a shell.
#
# Two failure classes pinned here:
#   F1 — sample.sh runs under `set -u`. The awk -v list used to expand
#        $ORPHAN_MATCH_RE/$ORPHAN_EXCLUDE_RE/$ORPHAN_PROVENANCE_RE
#        unconditionally, so an unset regex aborted the WHOLE sample before
#        awk emitted a single row — sys/session/proc rows lost too, for a
#        bug confined to orphan matching.
#   F2 — the once-per-day warning throttle read-then-wrote a marker file
#        non-atomically, so two racing samples (or a read/write split by
#        an unwritable state dir) could both decide "not warned today" and
#        both log — the exact flood the throttle exists to prevent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# tools/sample.sh finds its policy relative to its OWN directory
# (`$(dirname "${BASH_SOURCE[0]}")/orphan-policy.sh`), not via an env var, so
# testing a broken policy means running a COPY of the script beside a broken
# policy file — the same technique fixture-window.sh §9 uses for
# claude-watch's advise-*.sh stubs.
STUB="$TMP/stub"; mkdir -p "$STUB/tools"
cp "$REPO/tools/sample.sh" "$STUB/tools/sample.sh"
cat > "$STUB/tools/orphan-policy.sh" <<'POLICY'
# Sources cleanly, but ORPHAN_MATCH_RE is missing — a plausible edit mistake,
# not a syntax error.
ORPHAN_EXCLUDE_RE='(Applications|/usr/libexec|/System/)'
ORPHAN_PROVENANCE_RE='(/private)?/tmp/claude-[0-9]+/|/\.claude/worktrees/'
ORPHAN_MIN_DEFAULT=60
POLICY

printf '\n  -- F1: a broken policy skips only the orphan section --\n'

HOME1="$TMP/home1"; mkdir -p "$HOME1"
CLAUDE_WATCH_FLOOR=0 CLAUDE_WATCH_MEMFLOOR=0 CLAUDE_WATCH_TOPN=8 \
  CLAUDE_WATCH_HOME="$HOME1" bash "$STUB/tools/sample.sh" 2>"$HOME1/stderr.log"
rc=$?
[ "$rc" = 0 ] && ok "sample.sh exits 0 against a broken policy (was: set -u abort)" \
             || bad "sample.sh exits 0 against a broken policy (got $rc)"

DAY1=$(ls "$HOME1/raw" 2>/dev/null | head -n1)
if [ -z "$DAY1" ]; then
  bad "sample.sh wrote a day file against a broken policy"
else
  ok "sample.sh wrote a day file against a broken policy"
  n_sys=$(awk -F'\t' '$2 == "sys"' "$HOME1/raw/$DAY1" | wc -l | tr -d ' ')
  [ "$n_sys" -gt 0 ] && ok "sys row(s) still written ($n_sys)" \
                     || bad "sys row(s) still written (none — the abort regressed)"
  n_sess=$(awk -F'\t' '$2 == "session"' "$HOME1/raw/$DAY1" | wc -l | tr -d ' ')
  n_proc=$(awk -F'\t' '$2 == "proc"' "$HOME1/raw/$DAY1" | wc -l | tr -d ' ')
  # session/proc rows depend on what is running on this machine, so their
  # presence is not pinned — only that the sampler reached far enough to try,
  # which the sys row above already proves. Reported for visibility.
  printf '  \033[90minfo\033[0m  %s session row(s), %s proc row(s) also written\n' "$n_sess" "$n_proc"
  n_orphan=$(awk -F'\t' '$2 == "orphan"' "$HOME1/raw/$DAY1" | wc -l | tr -d ' ')
  [ "$n_orphan" = 0 ] && ok "no orphan rows are written while the policy is broken" \
                      || bad "no orphan rows are written while the policy is broken (got $n_orphan)"
  n_disabled=$(awk -F'\t' '$2 == "orphan_scan" && $3 == "disabled"' "$HOME1/raw/$DAY1" | wc -l | tr -d ' ')
  [ "$n_disabled" -gt 0 ] && ok "an explicit orphan_scan disabled marker is recorded" \
                          || bad "an explicit orphan_scan disabled marker is recorded (none found)"
fi
if grep -q 'ORPHAN_MATCH_RE' "$HOME1/stderr.log"; then
  ok "the warning names the broken variable"
else
  bad "the warning names the broken variable"; sed 's/^/        /' "$HOME1/stderr.log"
fi

printf '\n  -- F2: the warning does not repeat within the same day --\n'
: > "$HOME1/stderr.log"
CLAUDE_WATCH_HOME="$HOME1" bash "$STUB/tools/sample.sh" 2>>"$HOME1/stderr.log"
n_warn=$(grep -c 'orphan detection is disabled' "$HOME1/stderr.log")
[ "$n_warn" = 0 ] && ok "a second run the same day does not warn again" \
                  || bad "a second run the same day does not warn again (got $n_warn)"

printf '\n  -- F2: two concurrent samples racing the throttle warn at most once --\n'
HOME2="$TMP/home2"; mkdir -p "$HOME2"
CLAUDE_WATCH_HOME="$HOME2" bash "$STUB/tools/sample.sh" 2>"$HOME2/err.a" &
p1=$!
CLAUDE_WATCH_HOME="$HOME2" bash "$STUB/tools/sample.sh" 2>"$HOME2/err.b" &
p2=$!
wait "$p1" "$p2"
races=$(cat "$HOME2/err.a" "$HOME2/err.b" | grep -c 'orphan detection is disabled')
[ "$races" -le 1 ] && ok "two racing samples warn at most once (got $races)" \
                    || bad "two racing samples warn at most once (got $races — the flood the throttle exists to prevent)"

printf '\n  -- F2: an unwritable state dir suppresses the warning instead of flooding it --\n'
HOME3="$TMP/home3"
mkdir -p "$HOME3/raw" "$HOME3/state/cwd" "$HOME3/state/label"
chmod 555 "$HOME3/state"
CLAUDE_WATCH_HOME="$HOME3" bash "$STUB/tools/sample.sh" >/dev/null 2>"$HOME3/err"
rc3=$?
chmod 755 "$HOME3/state"
[ "$rc3" = 0 ] && ok "sample.sh still exits 0 when the state dir is unwritable" \
              || bad "sample.sh still exits 0 when the state dir is unwritable (got $rc3)"
if [ -s "$HOME3/err" ]; then
  bad "an unwritable state dir does not print a warning it could not throttle"
  sed 's/^/        /' "$HOME3/err"
else
  ok "an unwritable state dir does not print a warning it could not throttle"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
