#!/usr/bin/env bash
# Fixture tests for the report aggregation (handoff §7a).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# The aggregation is the highest-value unreviewed surface in the repo: four bugs
# have been found in it by eye, and the smoke suite would not have caught one of
# them. It is also pure input -> output, so it can be pinned exactly. Every
# expected number below is checkable on paper from the day-file it is asserted
# against, and these fixtures are the regression harness for any future rewrite
# of the aggregation — so they pin VALUES, not exit codes.
#
# Every --json assertion goes through `python3 -m json.tool` first, so a document
# that is merely malformed fails loudly instead of quietly reading as absent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CW="$REPO/claude-watch"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "fixture-report: python3 required"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/raw" || exit 1
JSON="$TMP/out.json"
TEXT="$TMP/out.txt"

# ------------------------------------------------------------------ writers --
# Field layouts are exactly what tools/sample.sh emits:
#   sys      ep sys -    load    mem_used_kb free_kb swap_mb ncpu
#   session  ep session  cwd     cores       rss_kb  detail  label
#   proc     ep proc     name    cores       rss_kb  pid
#   orphan   ep orphan   name    cores       rss_kb  age_seconds
sysrow()  { printf '%s\tsys\t-\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
sessrow() { printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
procrow() { printf '%s\tproc\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
orphrow() { printf '%s\torphan\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

# --------------------------------------------------------------- assertions --
load_report() {  # <date> <label> — run report --json, validate, leave it in $JSON
  local d=$1 label=$2 rc
  CLAUDE_WATCH_HOME="$TMP" "$CW" report "$d" --json > "$JSON" 2>/dev/null; rc=$?
  CLAUDE_WATCH_HOME="$TMP" "$CW" report "$d"        > "$TEXT" 2>/dev/null
  if [ "$rc" -ne 0 ]; then bad "$label: report --json exits 0 (got $rc)"; return 1; fi
  if ! python3 -m json.tool < "$JSON" >/dev/null 2>&1; then
    bad "$label: report --json is well-formed"; sed 's/^/        /' "$JSON"; return 1
  fi
  ok "$label: report --json is well-formed"
  # awk prints nan/-nan/inf for 0/0 and x/0. Those parse as JSON *numbers* in
  # Python's permissive loader, so json.tool alone would wave them through.
  if grep -Eqi '(^|[^a-z])-?(nan|inf)([^a-z]|$)' "$JSON" "$TEXT"; then
    bad "$label: no nan/inf anywhere in the output"
  else
    ok "$label: no nan/inf anywhere in the output"
  fi
  return 0
}

# Assertions name the field with a small Python expression over `d`, the parsed
# document — `d["machine_cpu"][0]["cpu_seconds"]` reads better than any path
# mini-language would. The expressions are literals written in this file, never
# input, and eval runs with builtins removed; there is no untrusted string
# anywhere on this path.
#
# <desc> <python expression over `d`> <expected number>
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

# <desc> <python expression over `d`> <expected string>  (JSON booleans as true/false)
str() {
  local out
  out=$(python3 - "$JSON" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    v = eval(sys.argv[2], {"__builtins__": {"len": len, "max": max}}, {"d": d})
except Exception as e:
    print("raised %s: %s" % (type(e).__name__, e)); raise SystemExit
print("true" if v is True else "false" if v is False else v)
PY
)
  [ "$out" = "$3" ] && ok "$1 = $3" || bad "$1 (wanted \"$3\", got \"$out\")"
}

# =========================================================== A. known input ==
# 100 samples, 10s apart, one session and two machine-wide processes. Every
# figure below is arithmetic on those 100 rows and nothing else.
#
#   session   1.00 cores x50 then 3.00 x50  -> peak 3.00, avg 2.00, active 1000s
#   burner    1.50 cores in all 100         -> total 150 core-samples x 10s = 1500s
#   quiet     0.10 cores in the first 25    -> total 2.5 x 10s = 25s, seen 25%
A_DATE=2026-01-02
A_T0=1767312000
{
  i=0
  while [ "$i" -lt 100 ]; do
    ep=$((A_T0 + 10 * i))
    load=2.50;    [ "$i" -eq 42 ] && load=7.00
    used=8000000; [ "$i" -eq 7 ]  && used=9000000
    free=4000000; [ "$i" -eq 13 ] && free=1000000
    swap=0;       [ "$i" -eq 5 ]  && swap=300
    sysrow "$ep" "$load" "$used" "$free" "$swap" 8
    if [ "$i" -lt 50 ]; then scores=1.00; srss=500000; else scores=3.00; srss=800000; fi
    detail='-'; [ "$i" -eq 60 ] && detail='node@2.5'
    sessrow "$ep" '/tmp/proj' "$scores" "$srss" "$detail" 'fixture session'
    procrow "$ep" burner 1.50 100000 4242
    [ "$i" -lt 25 ] && procrow "$ep" quiet 0.10 900000 4243
    i=$((i + 1))
  done
} > "$TMP/raw/$A_DATE.tsv"

echo "A. 100 samples at 10s, arithmetic pinned exactly"
if load_report "$A_DATE" A; then
  num "A samples"            'd["samples"]'            100
  num "A cores"              'd["cores"]'              8
  num "A interval_seconds"   'd["interval_seconds"]'   10
  num "A observed_seconds"   'd["observed_seconds"]'   1000

  num "A session peak_cores"     'd["sessions"][0]["peak_cores"]'          3
  num "A session avg_cores"      'd["sessions"][0]["avg_cores"]'           2
  num "A session active_seconds" 'd["sessions"][0]["active_seconds"]'      1000
  num "A session rss_kb"         'd["sessions"][0]["rss_kb"]'              800000
  str "A session hottest_child"  'd["sessions"][0]["hottest_child"]'       node
  num "A hottest_child_cores"    'd["sessions"][0]["hottest_child_cores"]' 2.5

  # Ranked by cpu_seconds, not peak: that ordering is the point of the two lists.
  str "A machine_cpu[0] name"     'd["machine_cpu"][0]["name"]'        burner
  num "A burner cpu_seconds"      'd["machine_cpu"][0]["cpu_seconds"]' 1500
  num "A burner peak_cores"       'd["machine_cpu"][0]["peak_cores"]'  1.5
  num "A burner avg_cores"        'd["machine_cpu"][0]["avg_cores"]'   1.5
  num "A burner seen_pct"         'd["machine_cpu"][0]["seen_pct"]'    100
  str "A machine_cpu[1] name"     'd["machine_cpu"][1]["name"]'        quiet
  num "A quiet cpu_seconds"       'd["machine_cpu"][1]["cpu_seconds"]' 25
  num "A quiet avg_cores"         'd["machine_cpu"][1]["avg_cores"]'   0.1
  num "A quiet seen_pct (25 of 100 samples)" 'd["machine_cpu"][1]["seen_pct"]' 25

  # Memory is a separate ranking: quiet holds 900M at 0.1 cores and would never
  # surface in a CPU ordering.
  str "A machine_mem[0] name"  'd["machine_mem"][0]["name"]'      quiet
  num "A quiet rss_kb"         'd["machine_mem"][0]["rss_kb"]'    900000
  num "A quiet instances"      'd["machine_mem"][0]["instances"]' 1
  str "A machine_mem[1] name"  'd["machine_mem"][1]["name"]'      burner

  num "A peak_load"          'd["system"]["peak_load"]'         7
  num "A peak_mem_used_kb"   'd["system"]["peak_mem_used_kb"]'  9000000
  num "A min_free_kb"        'd["system"]["min_free_kb"]'       1000000
  num "A max_swap_mb"        'd["system"]["max_swap_mb"]'       300
fi

# ======================================================== B. same-name fold ==
# Three processes called "firefox" in every one of 10 samples. They must be
# folded into ONE observation per sample before aggregating; counting each row
# separately puts seen_pct at 300%. CPU sums across them (three at 0.50 really
# is 1.5 cores) but RSS must NOT (handoff §4.3, §9): report the largest single
# process and how many there were.
B_DATE=2026-01-03
B_T0=1767398400
{
  i=0
  while [ "$i" -lt 10 ]; do
    ep=$((B_T0 + 10 * i))
    sysrow "$ep" 1.00 1000000 1000000 0 8
    procrow "$ep" firefox 0.50 1000000 100
    procrow "$ep" firefox 0.50 2000000 101
    procrow "$ep" firefox 0.50 3000000 102
    i=$((i + 1))
  done
} > "$TMP/raw/$B_DATE.tsv"

echo "B. same-name processes fold before aggregating"
if load_report "$B_DATE" B; then
  num "B samples"                       'd["samples"]'                       10
  num "B one entry per name"            'len(d["machine_cpu"])'              1
  num "B seen_pct stays at 100, not 300" 'd["machine_cpu"][0]["seen_pct"]'   100
  num "B seen_pct never exceeds 100"    'max(p["seen_pct"] for p in d["machine_cpu"])' 100
  num "B cpu sums across instances"     'd["machine_cpu"][0]["cpu_seconds"]' 150
  num "B peak_cores is the folded 1.50" 'd["machine_cpu"][0]["peak_cores"]'  1.5
  num "B avg_cores is the folded 1.50"  'd["machine_cpu"][0]["avg_cores"]'   1.5
  num "B rss is the largest ONE, not the sum" 'd["machine_mem"][0]["rss_kb"]' 3000000
  num "B instances counted"             'd["machine_mem"][0]["instances"]'   3
fi

# ================================== C. derived interval and excluded gap ==
# 20 samples at 30s, a 3600s sleep, then 10 more at 30s. The interval is the
# MEDIAN delta with gaps > 600s dropped, so it must read 30 (not the 10s
# default, and not an average dragged up by the gap). observed_seconds is
# samples x interval, so the hour asleep is excluded: 30 x 30 = 900, against a
# wall-clock span of 4440s.
C_DATE=2026-01-04
C_T0=1767484800
{
  i=0
  while [ "$i" -lt 20 ]; do
    ep=$((C_T0 + 30 * i))
    sysrow "$ep" 1.00 1000000 1000000 0 8
    procrow "$ep" idler 0.20 100000 200
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 10 ]; do
    ep=$((C_T0 + 570 + 3600 + 30 * i))
    sysrow "$ep" 1.00 1000000 1000000 0 8
    procrow "$ep" idler 0.20 100000 200
    i=$((i + 1))
  done
} > "$TMP/raw/$C_DATE.tsv"

echo "C. sampling interval is derived; a sleep gap is excluded"
if load_report "$C_DATE" C; then
  num "C samples"                      'd["samples"]'                 30
  num "C interval is the median delta" 'd["interval_seconds"]'        30
  num "C observed excludes the 3600s gap" 'd["observed_seconds"]'     900
  num "C total uses the derived interval" 'd["machine_cpu"][0]["cpu_seconds"]' 180
fi

# ================================== D. lastep comes from sys rows (§4.16) ==
# 10 samples. "reaped-tool" stops after sample 5, "late-tool" after sample 7,
# and NOTHING orphaned is present in the final sample. Measuring "still alive"
# against the newest ORPHAN row instead of the last SAMPLE makes the test
# vacuous — late-tool owns the newest orphan row and would report itself alive.
D_DATE=2026-01-05
D_T0=1767571200
{
  i=0
  while [ "$i" -lt 10 ]; do
    ep=$((D_T0 + 10 * i))
    sysrow "$ep" 1.00 1000000 1000000 0 8
    if [ "$i" -lt 5 ]; then
      rss=50000; [ "$i" -eq 2 ] && rss=55000
      orphrow "$ep" reaped-tool 0.00 "$rss" $((3600 + 10 * i))
    fi
    [ "$i" -lt 7 ] && orphrow "$ep" late-tool 0.00 10000 100
    i=$((i + 1))
  done
} > "$TMP/raw/$D_DATE.tsv"

echo "D. still_alive is measured against the last sample, not the last orphan row"
BY_NAME='{o["name"]: o for o in d["orphans"]}'
if load_report "$D_DATE" D; then
  num "D two orphans recorded"     'len(d["orphans"])'                                2
  str "D orphan gone mid-day"      "$BY_NAME"'["reaped-tool"]["still_alive"]'         false
  str "D newest orphan row is NOT alive" "$BY_NAME"'["late-tool"]["still_alive"]'     false
  num "D orphan age is the max seen" "$BY_NAME"'["reaped-tool"]["age_seconds"]'       3640
  num "D orphan rss is the max seen" "$BY_NAME"'["reaped-tool"]["rss_kb"]'            55000
fi

# An orphan that IS present in the final sample must still read alive, or the
# fix above would have been "return false always".
E_DATE=2026-01-06
E_T0=1767657600
{
  i=0
  while [ "$i" -lt 5 ]; do
    ep=$((E_T0 + 10 * i))
    sysrow "$ep" 1.00 1000000 1000000 0 8
    orphrow "$ep" live-tool 0.00 20000 900
    i=$((i + 1))
  done
} > "$TMP/raw/$E_DATE.tsv"

echo "E. an orphan present in the final sample reads alive"
if load_report "$E_DATE" E; then
  str "E orphan in the last sample" "$BY_NAME"'["live-tool"]["still_alive"]' true
fi

# ================================================== F/G/H. degenerate input ==
# Three ways to hand the aggregation nothing to divide by. None may produce
# invalid JSON, a nan, or a non-zero exit.
: > "$TMP/raw/2026-01-07.tsv"                       # F: completely empty day-file

{                                                   # G: rows, but no sys row at all
  procrow 1767744000 stray 1.00 100000 300
  procrow 1767744010 stray 1.00 100000 300
} > "$TMP/raw/2026-01-08.tsv"

{                                                   # H: exactly one sample
  sysrow  1767830400 1.00 2000000 500000 0 8
  sessrow 1767830400 '/tmp/solo' 2.00 300000 '-' ''
  procrow 1767830400 solo 0.75 200000 400
  orphrow 1767830400 solo-orphan 0.00 1000 60
} > "$TMP/raw/2026-01-09.tsv"

echo "F. an empty day-file"
if load_report 2026-01-07 F; then
  num "F samples"      'd["samples"]'         0
  num "F no sessions"  'len(d["sessions"])'   0
  num "F no orphans"   'len(d["orphans"])'    0
fi

echo "G. rows with no sys row (seen_pct would divide by zero)"
if load_report 2026-01-08 G; then
  num "G samples"          'd["samples"]'          0
  num "G no machine_cpu"   'len(d["machine_cpu"])' 0
fi

echo "H. exactly one sample (no delta to take a median of)"
if load_report 2026-01-09 H; then
  num "H samples"                   'd["samples"]'                       1
  num "H interval falls back to 10" 'd["interval_seconds"]'              10
  num "H observed_seconds"          'd["observed_seconds"]'              10
  num "H session avg over 1 sample" 'd["sessions"][0]["avg_cores"]'      2
  num "H session active_seconds"    'd["sessions"][0]["active_seconds"]' 10
  num "H proc cpu_seconds"          'd["machine_cpu"][0]["cpu_seconds"]' 7.5
  num "H proc seen_pct"             'd["machine_cpu"][0]["seen_pct"]'    100
  str "H sole orphan is alive"      "$BY_NAME"'["solo-orphan"]["still_alive"]' true
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
