#!/usr/bin/env bash
# Fixture tests for the linear window aggregation (advise-plan §6 U0).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# The aggregation used to sort the sample epochs and the gap list with two
# selection sorts, so 4x the rows cost 13x the time and week/month windows were
# unusable. The rewrite keeps a gap histogram and a running max instead. These
# fixtures pin the three things that rewrite could plausibly have broken:
#
#   A. a real day file, byte-identical to the output the sorting version gave
#      (tests/fixtures/day-golden.json, generated before the change)
#   B. the exact median rank — int(dn/2)+1 of an ASCENDING sort, an upper
#      median. The natural `c >= dn/2` picks a different bucket for every even
#      dn, and iv rescales interval/observed/active/cpu seconds wholesale.
#   C. that it is actually linear: 60k rows in under 5 seconds. The absence of
#      that assertion is what let the quadratic version ship.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CW="$REPO/claude-watch"
FIX="$REPO/tests/fixtures"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "fixture-aggregation: python3 required"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/raw" || exit 1
JSON="$TMP/out.json"
ERR="$TMP/out.err"

# Field layout is exactly what tools/sample.sh emits:
#   sys  ep sys - load mem_used_kb free_kb swap_mb ncpu
sysrow() { printf '%s\tsys\t-\t1.00\t1000000\t1000000\t0\t8\n' "$1"; }

# <date> <label> — run report --json, validate, leave it in $JSON and stderr in $ERR
load_report() {
  local d=$1 label=$2 rc
  CLAUDE_WATCH_HOME="$TMP" "$CW" report "$d" --json > "$JSON" 2>"$ERR"; rc=$?
  if [ "$rc" -ne 0 ]; then bad "$label: report --json exits 0 (got $rc)"; return 1; fi
  if ! python3 -m json.tool < "$JSON" >/dev/null 2>&1; then
    bad "$label: report --json is well-formed"; sed 's/^/        /' "$JSON"; return 1
  fi
  ok "$label: report --json is well-formed, exit 0"
  return 0
}

# <desc> <python expression over `d`> <expected number>
# Same helper as tests/fixture-report.sh: the expressions are literals written
# in this file, never input, and eval runs with builtins removed. There is no
# untrusted string anywhere on this path.
num() {
  local out
  out=$(python3 - "$JSON" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    v = eval(sys.argv[2], {"__builtins__": {"len": len, "max": max}}, {"d": d})
except Exception as e:
    print("raised %s: %s" % (type(e).__name__, e)); raise SystemExit
print("PASS" if abs(float(v) - float(sys.argv[3])) < 1e-9 else "got %r" % (v,))
PY
)
  [ "$out" = PASS ] && ok "$1 = $3" || bad "$1 (wanted $3, $out)"
}

# ================================================== A. real day file, golden ==
# A ~1400-row day recorded by the sampler, with its report --json output as it
# stood BEFORE the rewrite. This is the only assertion here that covers the
# whole document at once — interval_seconds, observed_seconds and still_alive
# included, which a peak/avg/total fixture does not.
A_DATE=2026-08-05
cp "$FIX/day-golden.tsv" "$TMP/raw/$A_DATE.tsv" || exit 1

echo "A. a real day file reproduces the pre-rewrite output byte for byte"
if load_report "$A_DATE" A; then
  if diff -u "$FIX/day-golden.json" "$JSON" > "$TMP/golden.diff" 2>&1; then
    ok "A --json is byte-identical to the pre-rewrite golden"
  else
    bad "A --json is byte-identical to the pre-rewrite golden"; sed 's/^/        /' "$TMP/golden.diff"
  fi
  if [ -s "$ERR" ]; then bad "A stderr is silent"; sed 's/^/        /' "$ERR"; else ok "A stderr is silent"; fi
fi

# ======================================= B. the median rank, where it matters ==
# Deltas 10, 10, 20, 20: dn = 4, so need = int(4/2)+1 = 3 and the third element
# of the ascending list is 20. The tempting `c >= dn/2` stops at the second and
# returns 10 — halving observed_seconds and every rate derived from it.
B_DATE=2026-01-20
B_T0=1768867200
{
  sysrow  "$B_T0"
  sysrow  $((B_T0 + 10))
  sysrow  $((B_T0 + 20))
  sysrow  $((B_T0 + 40))
  sysrow  $((B_T0 + 60))
} > "$TMP/raw/$B_DATE.tsv"

echo "B. even dn takes the UPPER median (gaps 10,10,20,20 -> 20, not 10)"
if load_report "$B_DATE" B; then
  num "B samples"            'd["samples"]'           5
  num "B interval_seconds"   'd["interval_seconds"]'  20
  num "B observed_seconds"   'd["observed_seconds"]'  100
fi

# Odd dn keeps the plain middle: deltas 10, 20, 30 -> need = 2 -> 20.
C_DATE=2026-01-21
C_T0=1768953600
{
  sysrow  "$C_T0"
  sysrow  $((C_T0 + 10))
  sysrow  $((C_T0 + 30))
  sysrow  $((C_T0 + 60))
} > "$TMP/raw/$C_DATE.tsv"

echo "C. odd dn takes the middle (gaps 10,20,30 -> 20)"
if load_report "$C_DATE" C; then
  num "C interval_seconds" 'd["interval_seconds"]' 20
fi

# ==================================================== D/E. no usable gaps ==
# Every gap >= 600s: a laptop woken a handful of times. dn = 0, so iv falls back
# to 10 rather than to an empty bucket.
D_DATE=2026-01-22
D_T0=1769040000
{
  sysrow  "$D_T0"
  sysrow  $((D_T0 + 3600))
  sysrow  $((D_T0 + 7200))
  sysrow  $((D_T0 + 10800))
} > "$TMP/raw/$D_DATE.tsv"

echo "D. every gap >= 600s falls back to a 10s interval"
if load_report "$D_DATE" D; then
  num "D samples"          'd["samples"]'          4
  num "D interval_seconds" 'd["interval_seconds"]' 10
  num "D observed_seconds" 'd["observed_seconds"]' 40
fi

E_DATE=2026-01-23
sysrow 1769126400 > "$TMP/raw/$E_DATE.tsv"

echo "E. a single sample has no gap at all and still reads 10s"
if load_report "$E_DATE" E; then
  num "E samples"          'd["samples"]'          1
  num "E interval_seconds" 'd["interval_seconds"]' 10
fi

# ============================================== F. out-of-order sample epochs ==
# The old code sorted, so a truncated or interleaved file produced a wrongly
# plausible answer. The new code says so on stderr, keeps the running max, and
# still exits 0 with clean JSON on stdout.
F_DATE=2026-01-24
F_T0=1769212800
{
  sysrow  "$F_T0"
  sysrow  $((F_T0 + 10))
  sysrow  $((F_T0 + 30))
  sysrow  $((F_T0 + 20))
  sysrow  $((F_T0 + 40))
} > "$TMP/raw/$F_DATE.tsv"

F_WANT='claude-watch: raw/2026-01-24.tsv has 1 out-of-order sample epochs — the raw file is interleaved or truncated, so the sample count, coverage and every rate derived from them may be inflated. Compare a neighbouring day before trusting this one'

echo "F. out-of-order epochs are reported on stderr, not silently re-ordered"
if load_report "$F_DATE" F; then
  if [ "$(cat "$ERR")" = "$F_WANT" ]; then
    ok "F stderr carries the exact out-of-order message"
  else
    bad "F stderr carries the exact out-of-order message"
    printf '        wanted: %s\n        got:    %s\n' "$F_WANT" "$(cat "$ERR")"
  fi
  if grep -q 'out-of-order' "$JSON"; then
    bad "F --json stdout stays clean"
  else
    ok "F --json stdout stays clean"
  fi
  # The result is the running-max one, computed from the file as written:
  # deltas 10, 20, -10 (dropped, not positive), 20 -> dn = 3, need = 2 -> 20.
  num "F samples"          'd["samples"]'          5
  num "F interval_seconds" 'd["interval_seconds"]' 20
  num "F observed_seconds" 'd["observed_seconds"]' 100
fi

# The human path reports it too, and still exits 0.
CLAUDE_WATCH_HOME="$TMP" "$CW" report "$F_DATE" > "$TMP/out.txt" 2>"$ERR"; rc=$?
[ "$rc" -eq 0 ] && ok "F human path exits 0" || bad "F human path exits 0 (got $rc)"
grep -q 'out-of-order sample epochs' "$ERR" \
  && ok "F human path reports the disorder on stderr" \
  || bad "F human path reports the disorder on stderr"

# ============ F2. a non-adjacent duplicate epoch is never silently miscounted ==
# The one behaviour adjacency dedupe does not share with the old global set:
# epochs 100, 110, 100, 110 are two distinct samples, but the second pair is not
# adjacent to the first, so sysn reads 4 and observed_seconds is inflated with
# it. That is acceptable ONLY because it cannot be silent — coming back to an
# epoch you already left takes a strict decrease, which is precisely what
# disorder counts. This case pins that the warning fires on exactly the shape
# that inflates the count; the exhaustive check below pins that there is no
# other shape.
F2_DATE=2026-01-26
F2_T0=1769299200
{
  sysrow $((F2_T0 + 100))
  sysrow $((F2_T0 + 110))
  sysrow $((F2_T0 + 100))
  sysrow $((F2_T0 + 110))
} > "$TMP/raw/$F2_DATE.tsv"

echo "F2. a non-adjacent duplicate epoch inflates the count — and always says so"
if load_report "$F2_DATE" F2; then
  num "F2 samples counts the repeat" 'd["samples"]' 4
  grep -q 'out-of-order sample epochs' "$ERR" \
    && ok "F2 the inflating input trips the warning" \
    || bad "F2 the inflating input trips the warning (silent miscount)"
  grep -q 'may be inflated' "$ERR" \
    && ok "F2 the warning names the inflation, not just the interval" \
    || bad "F2 the warning names the inflation, not just the interval"
fi

# ======================= F3. detection completeness, against the real reader ==
# The property the linear design rests on: the sample count may differ from what
# the old global textual dedupe produced, but it may never differ SILENTLY.
#
# This must be checked against the actual aggregation. An earlier version of
# this test modelled the adjacency rule in Python and swept 21,844 integer
# sequences; it passed while two real inputs drifted in silence, because the
# model shared none of awk's behaviour on the values that matter:
#
#   * awk compares numeric-looking fields NUMERICALLY, so "0100" and "100" are
#     one epoch to `!=` but were two keys to the old textual sysseen[];
#   * "" is a field value a damaged file can hold, and it was also the "no
#     previous row" sentinel;
#   * awk holds numbers as doubles, so past 2^53 two distinct decimal epochs
#     compare EQUAL — the collision that makes epoch comparison non-injective
#     and, with it, the length-three argument below unsound. The reader now
#     bounds epochs at ten digits precisely so that cannot happen.
#
# So the sweep below runs the real `report` binary. The value space is every
# sequence of one to three sys rows over
#   {0, 00, 100, 0100, "", xyz, 9007199254740992, 9007199254740993}
# — 584 files, about 9 seconds. Small, but every member earns its place: a
# canonical zero and a canonical non-zero, both of their zero-padded spellings
# (numeric equality vs textual inequality), the empty field (the old sentinel),
# a non-numeric token, and BOTH sides of the exact-integer boundary — one alone
# is not enough, since a collision needs two decimals that share one double,
# and a sweep carrying only ...93 misses the case entirely (measured: 0 silent
# drifts found against a build with the collision, 12 once ...92 joins it).
# Repetition then supplies equal adjacents, decreasing pairs and the
# non-adjacent duplicate. Length three is the shortest that can hold "leave a
# value and come back", the only shape that inflates the count; longer
# sequences compose the same transitions without introducing a new kind,
# because the rule is a function of (previous epoch, this epoch) ONCE
# comparison is injective — which is exactly what the ten-digit bound buys.
#
# For each file: `old` is the pre-rewrite count computed the pre-rewrite way —
# distinct TEXTUAL epochs over EVERY sys row, which is exactly what sysseen[]
# held, including the spellings this reader now rejects. The assertion is that
# samples != old always comes with a non-empty stderr, plus that a
# non-canonical row is always named.
F3_DATE=2026-02-05
F3_LOG="$TMP/f3.log"
: > "$F3_LOG"

# EMPTY is a stand-in for the empty field: it keeps the generated list free of
# empty tokens, which bash's word splitting would drop.
python3 - > "$TMP/f3-seqs" <<'PY'
from itertools import product
vals = ["0", "00", "100", "0100", "EMPTY", "xyz",
        "9007199254740992", "9007199254740993"]
for n in (1, 2, 3):
    for s in product(vals, repeat=n):
        print(" ".join(s))
PY

# <space-separated tokens> — writes the day file, returns samples in $F3_SAMPLES,
# the pre-rewrite textual count in $F3_OLD, and stderr in $ERR.
f3_run() {
  local tok v json rest
  : > "$TMP/raw/$F3_DATE.tsv"
  F3_OLD=0
  local seen=" "
  for tok in $1; do
    v=$tok; [ "$v" = EMPTY ] && v=''
    printf '%s\tsys\t-\t1.00\t1000000\t1000000\t0\t8\n' "$v" >> "$TMP/raw/$F3_DATE.tsv"
    # sysseen[] keyed on the raw field text and accepted EVERY sys row, damaged
    # spellings included, so `old` filters nothing. Filtering here would compare
    # the reader against a flattering baseline rather than the one it replaced.
    case "$seen" in *"|$v|"*) ;; *) seen="$seen|$v| "; F3_OLD=$((F3_OLD + 1)) ;; esac
  done
  json=$(CLAUDE_WATCH_HOME="$TMP" "$CW" report "$F3_DATE" --json 2>"$ERR"); F3_RC=$?
  rest=${json#*\"samples\":}
  F3_SAMPLES=${rest%%,*}
}

echo "F3. no sample-count drift is silent, checked against the real aggregation"
f3_bad=0; f3_unnamed=0; f3_rc=0; f3_n=0; f3_drift=0
while IFS= read -r seq; do
  f3_run "$seq"
  f3_n=$((f3_n + 1))
  [ "$F3_RC" -eq 0 ] || f3_rc=$((f3_rc + 1))
  if [ "$F3_SAMPLES" != "$F3_OLD" ]; then
    f3_drift=$((f3_drift + 1))
    if [ ! -s "$ERR" ]; then
      f3_bad=$((f3_bad + 1))
      printf 'SILENT DRIFT: [%s] samples=%s old=%s\n' "$seq" "$F3_SAMPLES" "$F3_OLD" >> "$F3_LOG"
    fi
  fi
  case " $seq " in
    *" 00 "*|*" 0100 "*|*" EMPTY "*|*" xyz "*|*" 900719925474099[23] "*)
      grep -q 'not a plain integer' "$ERR" || {
        f3_unnamed=$((f3_unnamed + 1))
        printf 'UNNAMED BAD EPOCH: [%s]\n' "$seq" >> "$F3_LOG"; } ;;
  esac
done < "$TMP/f3-seqs"

[ "$f3_n" -eq 584 ] && ok "F3 swept $f3_n real report runs" \
                    || bad "F3 swept $f3_n real report runs (wanted 584)"
[ "$f3_rc" -eq 0 ] && ok "F3 every run exits 0" \
                   || bad "F3 every run exits 0 ($f3_rc did not)"
if [ "$f3_bad" -eq 0 ]; then
  ok "F3 zero silent drifts ($f3_drift of $f3_n drifted, all reported)"
else
  bad "F3 zero silent drifts (found $f3_bad)"; sed 's/^/        /' "$F3_LOG" | head -10
fi
[ "$f3_unnamed" -eq 0 ] && ok "F3 every non-canonical epoch is named on stderr" \
                        || bad "F3 every non-canonical epoch is named ($f3_unnamed silent)"

# The two shapes that broke the modelled version of this test, by name, so a
# future reader meets them directly rather than inside a sweep total.
echo "F4. the two spellings that a Python model of awk cannot see"
f3_run "100 0100 100"
# awk reads 0100 == 100 numerically; the old textual dedupe saw two epochs. The
# row is rejected, so the count is 1 against the old 2 — and it is announced.
[ "$F3_SAMPLES" = 1 ] && ok "F4 zero-padded epoch does not fold into its neighbour" \
                      || bad "F4 zero-padded epoch (samples=$F3_SAMPLES, wanted 1)"
grep -q 'not a plain integer' "$ERR" \
  && ok "F4 the padded epoch is reported, not silently dropped" \
  || bad "F4 the padded epoch is reported, not silently dropped"

f3_run "EMPTY 100 200"
# "" used to re-arm the "no previous row" sentinel and swallow a sample.
[ "$F3_SAMPLES" = 2 ] && ok "F4 an empty epoch cannot pose as the first row" \
                      || bad "F4 empty epoch (samples=$F3_SAMPLES, wanted 2)"
grep -q 'not a plain integer' "$ERR" \
  && ok "F4 the empty epoch is reported, not silently dropped" \
  || bad "F4 the empty epoch is reported, not silently dropped"

# A file whose every sys row is damaged still says so, even though it exits down
# the "no system samples" path before any of the aggregation runs.
f3_run "xyz 0100"
[ "$F3_SAMPLES" = 0 ] && ok "F4 an all-damaged file reports zero samples" \
                      || bad "F4 all-damaged file (samples=$F3_SAMPLES, wanted 0)"
grep -q 'not a plain integer' "$ERR" \
  && ok "F4 an all-damaged file is not mistaken for an idle sampler" \
  || bad "F4 an all-damaged file is not mistaken for an idle sampler"

# The precision boundary. 9007199254740992 and ...93 are distinct decimals and
# distinct textual sysseen[] keys, but the SAME double: with no digit bound they
# compare equal, collapse into one sample, and never flush, with nothing on
# stderr. That collision is what would make epoch comparison non-injective and
# the length-three sweep above unsound, so it is pinned by the real binary here
# rather than left to a careful reading of the regex.
echo "F5. the exact-integer boundary, where two epochs become one double"
f3_run "9007199254740992 9007199254740993"
[ "$F3_SAMPLES" = 0 ] && ok "F5 past 2^53 both rows are rejected, not merged" \
                      || bad "F5 past 2^53 (samples=$F3_SAMPLES, wanted 0)"
[ "$F3_OLD" = 2 ] && ok "F5 the old textual dedupe counted them as 2" \
                  || bad "F5 old textual count (got $F3_OLD, wanted 2)"
grep -q 'not a plain integer' "$ERR" \
  && ok "F5 the collision is reported instead of silently merging" \
  || bad "F5 the collision is reported instead of silently merging"

# The bound itself: ten digits (through 9999999999, 2286-11-20) is canonical,
# eleven is not. A real epoch must stay on the accepted side of that line.
f3_run "1769299200 1769299210"
[ "$F3_SAMPLES" = 2 ] && ok "F5 a real ten-digit epoch pair is canonical" \
                      || bad "F5 real epochs (samples=$F3_SAMPLES, wanted 2)"
[ -s "$ERR" ] && bad "F5 real epochs produce no stderr" \
              || ok "F5 real epochs produce no stderr"
f3_run "9999999999 99999999999"
[ "$F3_SAMPLES" = 1 ] && ok "F5 ten digits in, eleven out" \
                      || bad "F5 digit bound (samples=$F3_SAMPLES, wanted 1)"
grep -q 'not a plain integer' "$ERR" \
  && ok "F5 the over-long epoch is named" \
  || bad "F5 the over-long epoch is named"
rm -f "$TMP/raw/$F3_DATE.tsv"

# ==================================== G. 60k rows in well under the deadline ==
# 20,000 samples — 55.6 hours at a 10s interval, so a bit over two days, not a
# week (a week is 60,480 samples). 60,000 rows in total, which is the size that
# matters: the two selection sorts were over rows, and took 82s on this input
# against 0.2s for the histogram walk. A full week is 3x this and still linear;
# what is pinned here is that the quadratic term is gone, not a week's runtime.
# Generated here, never committed.
G_DATE=2026-01-25
G_T0=1769299200
LC_ALL=C awk -v t0="$G_T0" 'BEGIN {
  OFS = "\t"
  for (i = 0; i < 20000; i++) {
    ep = t0 + 10 * i
    print ep, "sys", "-", "1.00", "1000000", "1000000", "0", "8"
    print ep, "proc", "burner", "1.50", "100000", "4242"
    print ep, "session", "/tmp/proj", "1.00", "500000", "-", "fixture"
  }
}' > "$TMP/raw/$G_DATE.tsv"

echo "G. 60k rows (20,000 samples at 10s = 55.6h) aggregate in under 5 seconds"
G_START=$(python3 -c 'import time; print(repr(time.time()))')
CLAUDE_WATCH_HOME="$TMP" "$CW" report "$G_DATE" --json > "$JSON" 2>"$ERR"; rc=$?
# repr() round-trips exactly, so the comparison below is against the elapsed
# time itself. Rounding to centiseconds first would let 5.004s pass as 5.00.
G_ELAPSED=$(python3 -c "import sys, time; print(repr(time.time() - float(sys.argv[1])))" "$G_START")
if [ "$rc" -ne 0 ]; then
  bad "G report --json exits 0 (got $rc)"
else
  ok "G report --json exits 0"
  num "G samples"          'd["samples"]'          20000
  num "G interval_seconds" 'd["interval_seconds"]' 10
  num "G observed_seconds" 'd["observed_seconds"]' 200000
fi
G_SHOWN=$(python3 -c "import sys; print('%.2f' % float(sys.argv[1]))" "$G_ELAPSED")
if python3 -c "import sys; raise SystemExit(0 if float(sys.argv[1]) < 5 else 1)" "$G_ELAPSED"; then
  ok "G aggregated 60k rows in ${G_SHOWN}s (< 5s)"
else
  bad "G aggregated 60k rows in ${G_SHOWN}s (wanted < 5s)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
