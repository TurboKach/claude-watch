#!/usr/bin/env bash
# Fixture tests for tools/disk-scan.sh — the disk facts TSV (plan §3c).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# The scanner is pure input -> output given a synthetic tree, so everything here
# pins VALUES, not exit codes: group totals, each confidence, the paths that must
# be absent, and the exact failure strings (§9 E7, E11). The three cases that are
# not about a tree — the lock, the deadline and a failing rename — are driven
# with a fake pid, a stub `du` and a stub `mv` respectively.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCAN="$REPO/tools/disk-scan.sh"
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skp() { skip=$((skip + 1)); printf '  \033[90mskip\033[0m  %s\n' "$1"; }

TMP=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

TAB=$'\t'
CACHE=""
OUT="$TMP/stdout"; ERR="$TMP/stderr"

# ------------------------------------------------------------------ helpers --
# Paths reach awk through ENVIRON, never -v: -v runs backslash processing, and
# these paths deliberately contain metacharacters.
dirsize() { CW_P="$1" LC_ALL=C awk -F'\t' '$1=="dir" && $2==ENVIRON["CW_P"]{print $3}' "$CACHE"; }
dirconf() { CW_P="$1" LC_ALL=C awk -F'\t' '$1=="dir" && $2==ENVIRON["CW_P"]{print $5}' "$CACHE"; }
gtot()    { CW_G="$1" LC_ALL=C awk -F'\t' '$1=="group" && $2==ENVIRON["CW_G"]{print $3}' "$CACHE"; }
gcount()  { CW_G="$1" LC_ALL=C awk -F'\t' '$1=="group" && $2==ENVIRON["CW_G"]{print $4}' "$CACHE"; }
noteval() { CW_N="$1" LC_ALL=C awk -F'\t' '$1=="note" && $2==ENVIRON["CW_N"]{print $3}' "$CACHE"; }
scancol() { LC_ALL=C awk -F'\t' -v n="$1" '$1=="scan"{print $n}' "$CACHE"; }   # 2=partial 3=deadline 4=scanned 5=total
volcol()  { LC_ALL=C awk -F'\t' -v n="$1" '$1=="vol"{print $n}' "$CACHE"; }

eq() {  # <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi
}
between() {  # <desc> <got> <lo> <hi>
  case "$2" in ''|*[!0-9]*) bad "$1 (got '$2', wanted a number)"; return ;; esac
  if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then ok "$1"
  else bad "$1 (got $2, wanted $3..$4)"; fi
}
absent() {  # <desc> <path>
  if [ -z "$(dirsize "$2")" ]; then ok "$1"; else bad "$1 (a dir row exists)"; fi
}

# ------------------------------------------------------------- the tree ------
# $SRC doubles as the fake HOME, so the fixed shortlist (~/Downloads,
# ~/Library/Containers, ...) is synthetic too and the run never touches the real
# home directory or its TCC-protected corners.
SRC="$TMP/home"
OLD=$(date -v-30d +%Y%m%d%H%M.%S)
kb() { dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null; }

mkdir -p "$SRC/repo/node_modules" "$SRC/repo/src" "$SRC/repo/target"
printf '{}\n' > "$SRC/repo/package.json"
kb "$SRC/repo/node_modules/big" 200
kb "$SRC/repo/src/main.c" 8
kb "$SRC/repo/target/blob" 100
touch -t "$OLD" "$SRC/repo/node_modules/big"          # idle + marker -> confirmed

mkdir -p "$SRC/active/node_modules"
printf '{}\n' > "$SRC/active/package.json"
kb "$SRC/active/node_modules/big" 150                  # fresh + marker -> likely

mkdir -p "$SRC/we ird ; dir/node_modules"
kb "$SRC/we ird ; dir/node_modules/blob" 50            # space and a ; must survive

mkdir -p "$SRC/tab${TAB}dir/node_modules"
kb "$SRC/tab${TAB}dir/node_modules/blob" 60            # a TSV cannot carry this

mkdir -p "$SRC/deep/a/b/c/node_modules"
kb "$SRC/deep/a/b/c/node_modules/blob" 400             # depth 5: below the cap

mkdir -p "$SRC/Downloads"
kb "$SRC/Downloads/iso" 500

mkdir -p "$SRC/Library/Containers/app/node_modules"
kb "$SRC/Library/Containers/app/node_modules/blob" 70  # must not be counted twice

RP=$( cd -P "$SRC" && pwd -P )                          # the scanner emits physical paths

# ------------------------------------------------------- run A: the tree -----
echo "tree"
DA="$TMP/dataA"
CACHE="$DA/state/disk.tsv"
HOME="$SRC" CLAUDE_WATCH_HOME="$DA" CLAUDE_WATCH_REPO_ROOTS="$SRC" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcA=$?
eq "run A exits 0" "$rcA" "0"
if [ ! -f "$CACHE" ]; then
  bad "run A wrote a cache"; sed 's/^/        /' "$ERR"; exit 1
fi
ok "run A wrote a cache"

# Every row is exactly five tab-separated fields — a path that broke that rule
# would shift the numeric columns at the reader.
if LC_ALL=C awk -F'\t' 'NF != 5 { print; n++ } END { exit(n > 0) }' "$CACHE" > "$TMP/badrows"; then
  ok "every row has five fields"
else
  bad "every row has five fields"; sed 's/^/        /' "$TMP/badrows"
fi

eq "epoch row present" "$(LC_ALL=C awk -F'\t' '$1=="epoch"{print ($3 > 1600000000) ? "y" : "n"}' "$CACHE")" "y"
eq "vol row is the volume holding \$HOME" "$(volcol 2)" "$(df -k "$SRC" | awk 'NR==2 {m=$0; for (i=1;i<=8;i++) sub(/^[^ ]+[ ]+/,"",m); print m}')"
eq "df_size_kb recorded" "$(volcol 5)" "$(df -k "$SRC" | awk 'NR==2{print $2}')"

# --- sizes and counts ---
# node_modules = repo 200 + active 150 + metachar 50; the tab path is skipped,
# the depth-5 one is out of reach, and the one under Library/Containers is
# deduped into the containers total.
between "node_modules group total is 400K" "$(gtot node_modules)" 400 424
eq      "node_modules counts 3 directories" "$(gcount node_modules)" "3"
between "rebuildable group total is 100K"   "$(gtot rebuildable)" 100 112
eq      "rebuildable counts 1 directory"    "$(gcount rebuildable)" "1"
between "downloads group total is 500K"     "$(gtot downloads)" 500 520
between "containers group total is 70K"     "$(gtot containers)" 70 96

# --- confidence, the column that gates every removal command ---
eq "marker + idle  -> confirmed"  "$(dirconf "$RP/repo/node_modules")"      "confirmed"
eq "marker, in use -> likely"     "$(dirconf "$RP/active/node_modules")"    "likely"
eq "name only      -> unverified" "$(dirconf "$RP/repo/target")"            "unverified"
eq "no marker      -> unverified" "$(dirconf "$RP/we ird ; dir/node_modules")" "unverified"

# --- what must not be there ---
absent "the src/ decoy is not a hit"          "$RP/repo/src"
absent "a node_modules below the depth cap is out of reach" "$RP/deep/a/b/c/node_modules"
absent "a hit under the shortlist is not double counted"    "$RP/Library/Containers/app/node_modules"
if LC_ALL=C grep -q "$TAB.*$TAB.*tab" "$CACHE"; then
  bad "the tab path never reaches the cache"
else
  ok "the tab path never reaches the cache"
fi

# --- the metacharacter path survives whole, and carries no command ---
between "the space/; path is measured" "$(dirsize "$RP/we ird ; dir/node_modules")" 50 64
if LC_ALL=C grep -qE '(^|[^a-z])rm( |$)' "$CACHE"; then
  bad "the scanner emits no removal command"
else
  ok "the scanner emits no removal command"
fi

# --- partial accounting ---
eq "partial=1 (a path was skipped)"    "$(scancol 2)" "1"
eq "deadline_hit=0"                    "$(scancol 3)" "0"
eq "roots_scanned=1"                   "$(scancol 4)" "1"
eq "roots_total=1"                     "$(scancol 5)" "1"
eq "note path_unrepresentable 1"       "$(noteval path_unrepresentable)" "1"
eq "no deadline note"                  "$(noteval deadline)" ""
eq "the lock is released"              "$([ -e "$DA/state/disk-scan.lock" ] && echo present || echo gone)" "gone"
eq "no work directory is left behind"  "$(ls -d "$DA"/state/disk-scan.work.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# ------------------------------------------- run B: a clean tree, no notes ---
echo "clean scan"
DB="$TMP/dataB"; HB="$TMP/homeB"; mkdir -p "$HB"
CACHE="$DB/state/disk.tsv"
HOME="$HB" CLAUDE_WATCH_HOME="$DB" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "partial=0 when nothing was skipped" "$(scancol 2)" "0"
eq "no note rows"                       "$(LC_ALL=C grep -c '^note' "$CACHE" || true)" "0"
eq "repo/node_modules still confirmed"  "$(dirconf "$RP/repo/node_modules")" "confirmed"

# ------------------------------------------- a root on another volume --------
echo "root on another volume"
OTHER=/System/Volumes/Preboot
if [ -d "$OTHER" ] && [ "$(stat -f %d "$OTHER")" != "$(stat -f %d "$HB")" ]; then
  DC="$TMP/dataC"; CACHE="$DC/state/disk.tsv"
  HOME="$HB" CLAUDE_WATCH_HOME="$DC" CLAUDE_WATCH_REPO_ROOTS="$OTHER:$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"
  eq "the off-volume root is skipped" "$(noteval root_off_home_volume)" "1"
  eq "roots_scanned=1 of 2"           "$(scancol 4)" "1"
  eq "roots_total=2"                  "$(scancol 5)" "2"
  eq "partial=1"                      "$(scancol 2)" "1"
else
  skp "root on another volume (no second volume to point at)"
fi

# --------------------------------------------------------------- the lock ----
echo "lock"
DL="$TMP/dataL"; mkdir -p "$DL/state"
LOCK="$DL/state/disk-scan.lock"
CACHE="$DL/state/disk.tsv"

# 1. a live owner: the loser prints E11 and never scans.
mkdir "$LOCK"; printf '%s\n' "$$" > "$LOCK/pid"
HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcL=$?
eq "a held lock exits 0" "$rcL" "0"
if grep -qF 'another disk scan is already running — nothing cached yet; re-run in a minute.' "$ERR"; then
  ok "E11 (no cache) verbatim on stderr"
else
  bad "E11 (no cache) verbatim on stderr"; sed 's/^/        /' "$ERR"
fi
eq "the loser wrote no cache" "$([ -f "$CACHE" ] && echo wrote || echo none)" "none"
eq "the loser did not take the lock" "$(cat "$LOCK/pid")" "$$"

# 1b. same, with a cache present: the message names its age.
printf 'epoch\t-\t1\t-\t-\n' > "$CACHE"
HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
if grep -qE '^another disk scan is already running — using the cached facts from [0-9]+[mhd] ago\. Re-run in a minute for fresh numbers\.$' "$ERR"; then
  ok "E11 (cached) verbatim on stderr"
else
  bad "E11 (cached) verbatim on stderr"; sed 's/^/        /' "$ERR"
fi
eq "the loser left the cache alone" "$(wc -l < "$CACHE" | tr -d ' ')" "1"

# 2. a young lock whose owner is dead is NOT broken: only age AND a dead pid.
DEAD=$( bash -c 'echo $$' )    # a pid that has already exited
if kill -0 "$DEAD" 2>/dev/null; then
  skp "stale lock (pid $DEAD was recycled)"
else
  printf '%s\n' "$DEAD" > "$LOCK/pid"
  HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"
  eq "a young lock is kept even with a dead owner" "$(cat "$LOCK/pid")" "$DEAD"

  # 3. old AND dead: broken, and the scan runs.
  touch -t "$OLD" "$LOCK"
  HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"; rcS=$?
  eq "a stale lock with a dead owner is broken" "$rcS" "0"
  eq "and the scan actually ran" "$(dirconf "$RP/repo/node_modules")" "confirmed"
  eq "and the lock is released" "$([ -e "$LOCK" ] && echo present || echo gone)" "gone"
fi

# ----------------------------------------------------------- the deadline ----
# `timeout` is unavailable, so the deadline is the parent signalling the walk's
# own process group. A stub `du` that sleeps proves both halves: the parent
# returns on time AND the blocked worker is actually killed.
echo "deadline"
BIN="$TMP/bin"; mkdir -p "$BIN"
{
  printf '#!/bin/sh\n'
  printf 'touch %s/du-started\n' "$TMP"
  printf 'sleep 4\n'
  printf 'touch %s/du-survived\n' "$TMP"
  printf 'exec /usr/bin/du "$@"\n'
} > "$BIN/du"
chmod +x "$BIN/du"
DD="$TMP/dataD"; CACHE="$DD/state/disk.tsv"
t0=$(date +%s)
PATH="$BIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DD" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  CLAUDE_WATCH_DISK_DEADLINE=2 bash "$SCAN" > "$OUT" 2> "$ERR"; rcD=$?
t1=$(date +%s)
eq "the deadline run exits 0" "$rcD" "0"
between "it returns near the deadline" "$(( t1 - t0 ))" 2 8
eq "the cache is still written" "$([ -f "$CACHE" ] && echo yes || echo no)" "yes"
eq "deadline_hit=1" "$(scancol 3)" "1"
eq "partial=1"      "$(scancol 2)" "1"
eq "note deadline"  "$(noteval deadline)" "1"
eq "the volume facts survive the deadline" "$([ -n "$(volcol 3)" ] && echo yes || echo no)" "yes"
eq "the walk really did block in du" \
   "$([ -e "$TMP/du-started" ] && echo yes || echo no)" "yes"
sleep 5
eq "the blocked worker was killed, not orphaned" \
   "$([ -e "$TMP/du-survived" ] && echo survived || echo killed)" "killed"
eq "the lock is released after a deadline" \
   "$([ -e "$DD/state/disk-scan.lock" ] && echo present || echo gone)" "gone"

# -------------------------------------------------------- the atomic write ---
# The temp file must be created next to the cache: a temp on another volume
# makes the final mv a copy, not a rename.
echo "atomic write"
MVBIN="$TMP/mvbin"; mkdir -p "$MVBIN"
{
  printf '#!/bin/sh\n'
  printf 'printf "%%s\\n" "$1" >> %s/mv.log\n' "$TMP"
  printf 'if [ -n "${CW_TEST_MV_FAIL:-}" ]; then exit 1; fi\n'
  printf 'exec /bin/mv "$@"\n'
} > "$MVBIN/mv"
chmod +x "$MVBIN/mv"
DM="$TMP/dataM"; CACHE="$DM/state/disk.tsv"
PATH="$MVBIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DM" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "the temp file is created in \$STATE" "$(dirname "$(tail -n1 "$TMP/mv.log")")" "$DM/state"
eq "the cache landed" "$([ -f "$CACHE" ] && echo yes || echo no)" "yes"

# A failing rename is reported with E7 and exit 1, never swallowed into a
# silently retained stale cache.
before=$(cksum < "$CACHE")
PATH="$MVBIN:$PATH" CW_TEST_MV_FAIL=1 HOME="$HB" CLAUDE_WATCH_HOME="$DM" \
  CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" bash "$SCAN" > "$OUT" 2> "$ERR"; rcM=$?
eq "a failing rename exits 1" "$rcM" "1"
if grep -qF "claude-watch disk: could not write $CACHE — the volume is 95% full or the path is read-only. The previous cache is unchanged and is now stale. Free space, then re-run: claude-watch disk --refresh" "$ERR"; then
  ok "E7 verbatim on stderr"
else
  bad "E7 verbatim on stderr"; sed 's/^/        /' "$ERR"
fi
eq "the previous cache is unchanged" "$(cksum < "$CACHE")" "$before"
eq "no temp file is left behind" \
   "$(ls -A "$DM"/state/.disk.tsv.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# A read-only state directory cannot be written at all — same message, exit 1.
echo "read-only state"
DR="$TMP/dataR"; mkdir -p "$DR/state"; CACHE="$DR/state/disk.tsv"
chmod 555 "$DR/state"
HOME="$HB" CLAUDE_WATCH_HOME="$DR" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcR=$?
chmod 755 "$DR/state"
eq "a read-only \$STATE exits 1" "$rcR" "1"
if grep -qF "claude-watch disk: could not write $CACHE" "$ERR"; then
  ok "E7 names the cache it could not write"
else
  bad "E7 names the cache it could not write"; sed 's/^/        /' "$ERR"
fi

# ------------------------------------------------------------------ summary --
printf '\n  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
