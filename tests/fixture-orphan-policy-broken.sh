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

printf '\n  -- G1: an empty ORPHAN_EXCLUDE_RE is also a broken policy --\n'
# `x ~ ""` is true for every string, so an unset/empty EXCLUDE_RE does not
# make every process an orphan (that is MATCH/PROV's failure mode) — it makes
# NO process an orphan, because `args[p] ~ EXCL` matches everything and the
# scan excludes every candidate it finds. That reads exactly like "nothing to
# report", including for a tree that was reported as an orphan a moment ago,
# with no error anywhere. Only MATCH/PROV were checked before this fix.
STUBX="$TMP/stubx"; mkdir -p "$STUBX/tools"
cp "$REPO/tools/sample.sh" "$STUBX/tools/sample.sh"
cat > "$STUBX/tools/orphan-policy.sh" <<'POLICY'
# Sources cleanly, but ORPHAN_EXCLUDE_RE is missing this time.
ORPHAN_MATCH_RE='(node|tsx|npm|npx|yarn|pnpm|bun|deno)'
ORPHAN_PROVENANCE_RE='(/private)?/tmp/claude-[0-9]+/|/\.claude/worktrees/'
ORPHAN_MIN_DEFAULT=60
POLICY

HOME4="$TMP/home4"; mkdir -p "$HOME4"
CLAUDE_WATCH_FLOOR=0 CLAUDE_WATCH_MEMFLOOR=0 CLAUDE_WATCH_TOPN=8 \
  CLAUDE_WATCH_HOME="$HOME4" bash "$STUBX/tools/sample.sh" 2>"$HOME4/stderr.log"
rc4=$?
[ "$rc4" = 0 ] && ok "sample.sh exits 0 against an EXCL-missing policy" \
              || bad "sample.sh exits 0 against an EXCL-missing policy (got $rc4)"

DAY4=$(ls "$HOME4/raw" 2>/dev/null | head -n1)
if [ -z "$DAY4" ]; then
  bad "sample.sh wrote a day file against an EXCL-missing policy"
else
  n_disabled4=$(awk -F'\t' '$2 == "orphan_scan" && $3 == "disabled"' "$HOME4/raw/$DAY4" | wc -l | tr -d ' ')
  [ "$n_disabled4" -gt 0 ] \
    && ok "an EXCL-missing policy also records the orphan_scan disabled marker" \
    || bad "an EXCL-missing policy also records the orphan_scan disabled marker (none found — a previously-reported orphan would silently read as gone)"
fi
if grep -q 'ORPHAN_EXCLUDE_RE' "$HOME4/stderr.log"; then
  ok "the warning names ORPHAN_EXCLUDE_RE too"
else
  bad "the warning names ORPHAN_EXCLUDE_RE too"; sed 's/^/        /' "$HOME4/stderr.log"
fi

printf '\n  -- G2: the prune must not delete a same-run-but-later marker across midnight --\n'
# Simulate process A (which still thinks "today" is D) racing process B (which
# has already rolled over to D+1 and created its marker). A fake `date` pins
# what sample.sh sees as "today" so the race is deterministic instead of
# depending on the wall clock actually crossing midnight mid-test.
FAKEDATE="$TMP/fakedate"; mkdir -p "$FAKEDATE"
cat > "$FAKEDATE/date" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  +%F) echo "2026-01-01" ;;
  +%s) echo "1767225600" ;;
  *)   exec /bin/date "$@" ;;
esac
FAKE
chmod +x "$FAKEDATE/date"

HOME5="$TMP/home5"; mkdir -p "$HOME5/state"
# B already created D+1's marker before A (running with the pinned "today" of
# D = 2026-01-01) gets to the prune step.
: > "$HOME5/state/orphan-policy-broken.2026-01-02"
# A genuinely stale marker from well before D should still be pruned — the
# fix narrows what gets deleted, it must not stop deleting old ones.
: > "$HOME5/state/orphan-policy-broken.2025-12-31"

PATH="$FAKEDATE:$PATH" CLAUDE_WATCH_FLOOR=0 CLAUDE_WATCH_MEMFLOOR=0 CLAUDE_WATCH_TOPN=8 \
  CLAUDE_WATCH_HOME="$HOME5" bash "$STUB/tools/sample.sh" >/dev/null 2>"$HOME5/err"

if [ -e "$HOME5/state/orphan-policy-broken.2026-01-02" ]; then
  ok "a later (D+1) marker created by another process survives A's prune"
else
  bad "a later (D+1) marker created by another process survives A's prune (deleted — the next D+1 sample will warn again)"
fi
if [ -e "$HOME5/state/orphan-policy-broken.2025-12-31" ]; then
  bad "a genuinely stale marker is still pruned (found untouched)"
else
  ok "a genuinely stale marker is still pruned"
fi
if [ -e "$HOME5/state/orphan-policy-broken.2026-01-01" ]; then
  ok "today's own marker is created"
else
  bad "today's own marker is created"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
