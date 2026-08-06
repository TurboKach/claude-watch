#!/usr/bin/env bash
# Fixture tests for the sampler row schema v2 (advise-plan §6 U1).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# What is being pinned:
#   1. The ship blocker (G8): adding fields to `sys` and `proc` must not change
#      one byte of `report --json` on the same sample data. `report` reads
#      sys $4-$8, session $3-$7, proc $3,$4,$5 and orphan $3,$5,$6 and ignores
#      everything after — this test is what proves that stayed true. It is run
#      against a day file written HERE, containing all four row kinds, so the
#      proof never depends on what the machine happened to be doing; the live
#      sampler run is a second, separate check.
#   2. The v2 row shapes, with the schema version pinned at $9 of the sys row.
#   3. The two offsets that had to move with `-o time=`: the roots awk reads the
#      first argv token at $7, and the argv strip loop skips 6 leading columns.
#      Miss either and `roots` silently goes empty, i.e. no session rows at all.
#   4. esec() against real macOS TIME values. macOS prints [MMMM:]SS.hh with
#      UNBOUNDED minutes: 148:08.43 is 148 minutes, not 148 hours. A parser that
#      guesses hh:mm:ss on two fields is wrong by 60x, so the shape is asserted,
#      never assumed.
#   5. The vm_stat parse, against fixed vm_stat text — the counters cannot be
#      certified by a live machine, where a constant wrong value passes.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CW="$REPO/claude-watch"
SAMPLER="$REPO/tools/sample.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

printf '\033[1mfixture-sample-schema\033[0m\n'

if bash -n "$SAMPLER" 2>"$TMP/syntax.err"; then
  ok "tools/sample.sh parses"
else
  bad "tools/sample.sh parses"; sed 's/^/        /' "$TMP/syntax.err"
fi

# Field layouts, v2 (v1 differences marked):
#   sys      ep sys -   load  used_kb cores_free swap_mb ncpu | 2 pgin pgout memkb swapcap
#   session  ep session cwd   cores   rss_kb     detail  label
#   proc     ep proc    name  cores   rss_kb     pid          | cputime_seconds
#   orphan   ep orphan  name  cores   rss_kb     age_seconds
sysrow()  { printf '%s\tsys\t-\t%s\t%s\t%s\t%s\t%s\t2\t%s\t%s\t16777216\t1024\n' "$@"; }
sessrow() { printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
procrow() { printf '%s\tproc\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
orphrow() { printf '%s\torphan\t%s\t%s\t%s\t%s\n' "$@"; }

# The schema-1 projection: strip exactly the v2 suffixes and nothing else. A row
# that is already short (a panic mid-append, §9) is passed through untouched, so
# the projection cannot invent fields the estimate era would never have had.
project_v1() {
  awk -F'\t' 'BEGIN { OFS = "\t" }
    $2 == "sys"  && NF == 13 { print $1, $2, $3, $4, $5, $6, $7, $8; next }
    $2 == "proc" && NF == 7  { print $1, $2, $3, $4, $5, $6; next }
    { print }' "$1"
}

# Runs report both ways over <v2 file> and asserts the two agree byte for byte.
golden_diff() {  # <label> <v2 day file> <date>
  local label=$1 src=$2 date=$3 a="$TMP/gd-a" b="$TMP/gd-b" rc1 rc2
  rm -rf "$a" "$b"; mkdir -p "$a/raw" "$b/raw" || return 1
  cp "$src" "$a/raw/$date.tsv"
  project_v1 "$src" > "$b/raw/$date.tsv"

  if cmp -s "$a/raw/$date.tsv" "$b/raw/$date.tsv"; then
    bad "$label: the v1 projection differs from the v2 file (nothing was added?)"
  else
    ok "$label: the v1 projection differs from the v2 file"
  fi

  CLAUDE_WATCH_HOME="$a" "$CW" report "$date" --json > "$TMP/a.json" 2>/dev/null; rc1=$?
  CLAUDE_WATCH_HOME="$b" "$CW" report "$date" --json > "$TMP/b.json" 2>/dev/null; rc2=$?
  if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ -s "$TMP/a.json" ]; then
    ok "$label: report --json exits 0 and is non-empty on both files"
  else
    bad "$label: report --json exits 0 and is non-empty on both files (v2=$rc1 v1=$rc2)"
  fi
  if cmp -s "$TMP/a.json" "$TMP/b.json"; then
    ok "$label: report --json is byte-identical before and after the schema change"
  else
    bad "$label: report --json is byte-identical before and after the schema change"
    diff "$TMP/b.json" "$TMP/a.json" | sed 's/^/        /' | head -20
  fi

  CLAUDE_WATCH_HOME="$a" "$CW" report "$date" > "$TMP/a.txt" 2>/dev/null
  CLAUDE_WATCH_HOME="$b" "$CW" report "$date" > "$TMP/b.txt" 2>/dev/null
  if [ -s "$TMP/a.txt" ] && cmp -s "$TMP/a.txt" "$TMP/b.txt"; then
    ok "$label: the text report is byte-identical too"
  else
    bad "$label: the text report is byte-identical too"
    diff "$TMP/b.txt" "$TMP/a.txt" | sed 's/^/        /' | head -20
  fi

  if grep -Eqi '(^|[^a-z])-?(nan|inf)([^a-z]|$)' "$TMP/a.json" "$TMP/a.txt"; then
    bad "$label: no nan/inf anywhere in the v2 output"
  else
    ok "$label: no nan/inf anywhere in the v2 output"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool < "$TMP/a.json" >/dev/null 2>&1 \
      && ok "$label: report --json is well-formed" \
      || bad "$label: report --json is well-formed"
  fi
}

# <file> <kind> <expected NF> — a kind that is absent is a FAILURE, not a skip:
# a fixture that silently covers less than it claims is the whole problem.
require_nf() {
  local f=$1 kind=$2 want=$3 got
  got=$(awk -F'\t' -v k="$kind" '$2 == k { print NF }' "$f" | sort -u | tr '\n' ' ')
  got="${got% }"
  if [ -z "$got" ]; then bad "$kind rows exist and have NF=$want (none found)"
  elif [ "$got" = "$want" ]; then ok "$kind rows all have NF=$want"
  else bad "$kind rows all have NF=$want (got: $got)"; fi
}

# ------------------------------- G8, on a day file this test controls fully --
printf '\n  -- G8 ship blocker, on a deterministic day file --\n'

DET="$TMP/det.tsv"
E1=1768435200; E2=1768435260   # 2026-01-14 in UTC terms; the date is a label only
DETDATE=2026-01-14
{
  sysrow  "$E1" 2.50 8000000 4000000 512 10 205992372 1779453
  sessrow "$E1" /Users/x/proj 1.25 2000000 'node@0.5' 'my label'
  procrow "$E1" firefox 0.75 900000 501 1234.56
  procrow "$E1" node 0.10 100000 502 10.00
  orphrow "$E1" node 0.05 50000 7200
  sysrow  "$E2" 3.00 9000000 3000000 600 10 205993000 1779460
  sessrow "$E2" /Users/x/proj 0.50 2100000 '-' 'my label'
  procrow "$E2" firefox 0.80 910000 501 1240.00
  # A panic mid-append leaves a short line (§9). It must not change the report,
  # and the projection must leave it exactly as it found it.
  printf '%s\tproc\tnode\t0.10\n' "$E2"
  orphrow "$E2" node 0.05 50000 7260
} > "$DET"

for k in sys session proc orphan; do
  n=$(awk -F'\t' -v k="$k" '$2 == k { c++ } END { print c + 0 }' "$DET")
  [ "$n" -gt 0 ] && ok "the deterministic file carries $n $k row(s)" \
                 || bad "the deterministic file carries $k rows"
done
n=$(awk -F'\t' '$2 == "sys" && (NF != 13 || $9 != 2) { c++ } END { print c + 0 }' "$DET")
[ "$n" = 0 ] && ok "its sys rows carry the v2 suffix \$9..\$13 with \$9 == 2" \
             || bad "its sys rows carry the v2 suffix \$9..\$13 with \$9 == 2"
n=$(awk -F'\t' '$2 == "proc" && NF == 7 { c++ } END { print c + 0 }' "$DET")
[ "$n" -gt 0 ] && ok "its proc rows carry the v2 suffix \$7 ($n of them)" \
               || bad "its proc rows carry the v2 suffix \$7"

golden_diff "deterministic" "$DET" "$DETDATE"

# ...and the diff above is only worth anything if all four kinds actually
# reached the report. Assert each one is visible in the JSON it compared.
# (golden_diff leaves the v2 output in $TMP/a.json.)
for probe in '"cwd":"/Users/x/proj"' '"machine_cpu":[{"name":"firefox"' '"orphans":[{"name":"node"' '"samples":2'; do
  grep -qF "$probe" "$TMP/a.json" \
    && ok "deterministic: the compared report actually contains $probe" \
    || bad "deterministic: the compared report actually contains $probe"
done

# --------------------------------------------------------------- the sampler --
printf '\n  -- the live sampler emits schema 2 --\n'

V2="$TMP/v2"
mkdir -p "$V2/raw" || exit 1
# Floors at 0 so proc rows are guaranteed: the shape assertions below must not
# be able to pass by there being nothing to assert on.
export CLAUDE_WATCH_FLOOR=0 CLAUDE_WATCH_MEMFLOOR=0
CLAUDE_WATCH_HOME="$V2" bash "$SAMPLER" || bad "sample.sh run 1 exits 0"
sleep 1
CLAUDE_WATCH_HOME="$V2" bash "$SAMPLER" || bad "sample.sh run 2 exits 0"

DAY=$(ls "$V2/raw/" 2>/dev/null | head -n1)
DATE="${DAY%.tsv}"
if [ -z "$DAY" ]; then
  bad "sampler wrote a day file"; printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
ok "sampler wrote a day file ($DAY)"
RAWV2="$V2/raw/$DAY"

require_nf "$RAWV2" sys 13
require_nf "$RAWV2" proc 7
# session and orphan depend on what is running; assert the shape when present.
for k in session:7 orphan:6; do
  kind="${k%%:*}"; want="${k##*:}"
  if awk -F'\t' -v k="$kind" '$2 == k { found = 1 } END { exit !found }' "$RAWV2"; then
    require_nf "$RAWV2" "$kind" "$want"
  else
    printf '  \033[33mskip\033[0m  no %s rows in the live sample (pinned on the deterministic file)\n' "$kind"
  fi
done

schema=$(awk -F'\t' '$2 == "sys" { print $9 }' "$RAWV2" | sort -u | tr '\n' ' ')
[ "${schema% }" = "2" ] && ok 'sys $9 is the schema version 2' \
                        || bad "sys \$9 is the schema version 2 (got: $schema)"

# proc cumulative CPU seconds must be a bare number — §6c treats anything else
# as estimate-era for that row, so a formatting slip would silently downgrade
# every proc row in the file.
badct=$(awk -F'\t' '$2 == "proc" && $7 !~ /^[0-9]+(\.[0-9]+)?$/ { c++ } END { print c + 0 }' "$RAWV2")
[ "$badct" = "0" ] && ok 'every proc $7 matches ^[0-9]+(\.[0-9]+)?$' \
                   || bad "every proc \$7 is a plain number ($badct rows are not)"

# NF=7 on session rows is also the G6 assertion: sessions deliberately carry no
# cumulative CPU, because a tree cumulative drops by the whole lifetime of a
# departing child and a delta there can go negative for a session that was busy.

printf '\n  -- G8 again, on live sample data --\n'
golden_diff "live" "$RAWV2" "$DATE"

# ---------------------------------------------- machine capacities recorded --
printf '\n  -- capacities come from this machine, recorded per sample --\n'

want_mem=$(( $(sysctl -n hw.memsize) / 1024 ))
got_mem=$(awk -F'\t' '$2 == "sys" { print $12 }' "$RAWV2" | sort -u | tr '\n' ' ')
[ "${got_mem% }" = "$want_mem" ] && ok "sys \$12 is hw.memsize in KB ($want_mem)" \
                                 || bad "sys \$12 is hw.memsize in KB (want $want_mem, got: $got_mem)"

want_swap=$(sysctl -n vm.swapusage | awk '{ for (i = 1; i <= NF; i++) if ($i == "total") { v = $(i+2); sub(/M$/, "", v); printf "%d", v } }')
got_swap=$(awk -F'\t' '$2 == "sys" { print $13 }' "$RAWV2" | sort -u | tr '\n' ' ')
[ "${got_swap% }" = "$want_swap" ] && ok "sys \$13 is the vm.swapusage total in MB ($want_swap)" \
                                   || bad "sys \$13 is the vm.swapusage total in MB (want $want_swap, got: $got_swap)"

# ------------------------------------------------- the vm_stat parse, pinned --
printf '\n  -- the vm_stat parse, against fixed vm_stat text --\n'

# The parser is extracted from the sampler, so this cannot drift from what runs.
cat > "$TMP/extract-vm.awk" <<'EXTRACT'
/^sys=/ && /vm_stat/ { start = 1 }
start && !inprog { if ($0 ~ /'$/) inprog = 1; next }
inprog && /^  }/ { print "  }"; exit }
inprog { print }
EXTRACT
awk -f "$TMP/extract-vm.awk" "$SAMPLER" > "$TMP/vm.awk"

# Real vm_stat layout: the page table is columnar, but Pageins/Pageouts are
# NF=2 lines. Reading them out of a page-table column would record 0 forever.
cat > "$TMP/vm_stat.txt" <<'VMSTAT'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                                  100.
Pages active:                                200.
Pages inactive:                              300.
Pages speculative:                            50.
Pages throttled:                               0.
Pages wired down:                            400.
Pages purgeable:                              25.
"Translation faults":                     123456.
Pages copy-on-write:                        1000.
Pages zero filled:                          2000.
Pages reactivated:                           300.
Pages purged:                                 10.
File-backed pages:                           500.
Anonymous pages:                             600.
Pages stored in compressor:                  700.
Pages occupied by compressor:                800.
Decompressions:                              900.
Compressions:                               1000.
Pageins:                                205992372.
Pageouts:                                 1779453.
Swapins:                                       5.
Swapouts:                                      7.
VMSTAT

# used_kb = (600 - 25 + 400 + 800) pages * 4096 / 1024 = 7100
# free_kb = (100 + 50) pages * 4096 / 1024 = 600
got=$(LC_ALL=C awk -f "$TMP/vm.awk" -v ps=4096 -v total=17179869184 \
        -v swap="total = 1024.00M  used = 12.34M  free = 1011.66M  (encrypted)" \
        < "$TMP/vm_stat.txt")
want=$(printf '7100\t600\t12\t205992372\t1779453\t16777216\t1024')
if [ "$got" = "$want" ]; then
  ok "vm_stat parses to used/free/swap_used/pgin/pgout/memsize_kb/swap_cap_mb"
else
  bad "vm_stat parses to used/free/swap_used/pgin/pgout/memsize_kb/swap_cap_mb"
  printf '        want: %s\n        got:  %s\n' "$(printf '%s' "$want" | tr '\t' '|')" "$(printf '%s' "$got" | tr '\t' '|')"
fi

# Zero pageouts are legitimate on a machine that has never swapped, and must
# parse as 0 rather than as an empty field.
got=$(printf 'Pageins:  0.\nPageouts: 0.\n' | LC_ALL=C awk -f "$TMP/vm.awk" -v ps=4096 \
        -v total=17179869184 -v swap="total = 0.00M  used = 0.00M  free = 0.00M" | cut -f4,5)
[ "$got" = "$(printf '0\t0')" ] && ok "a machine that has never paged records 0, not an empty field" \
                                || bad "a machine that has never paged records 0 (got: '$got')"

# Liveness only — the parse above is what certifies the numbers. This says the
# recorded counter is the live one and not a constant.
PG="$TMP/pg"; mkdir -p "$PG/raw" || exit 1
CLAUDE_WATCH_HOME="$PG" bash "$SAMPLER"
first_in=$(awk -F'\t' '$2 == "sys" { print $10; exit }' "$PG/raw/"*.tsv)
moved=0
for _ in 1 2 3 4 5 6 7 8; do
  find /usr/bin -type f -print0 2>/dev/null | xargs -0 -n 40 cat > /dev/null 2>&1
  CLAUDE_WATCH_HOME="$PG" bash "$SAMPLER"
  last_in=$(awk -F'\t' '$2 == "sys" { v = $10 } END { print v }' "$PG/raw/"*.tsv)
  [ "$last_in" -gt "$first_in" ] && { moved=1; break; }
  sleep 1
done
[ "$moved" = 1 ] && ok "the recorded pagein counter is live ($first_in -> $last_in)" \
                 || bad "the recorded pagein counter is live (stuck at $first_in)"
nonint=$(awk -F'\t' '$2 == "sys" && ($10 !~ /^[0-9]+$/ || $11 !~ /^[0-9]+$/) { c++ } END { print c + 0 }' "$RAWV2")
[ "$nonint" = 0 ] && ok "pageins and pageouts are plain integers in every sys row" \
                  || bad "pageins and pageouts are plain integers in every sys row ($nonint are not)"

# ------------------------------------------------------------------- esec() --
printf '\n  -- esec() on real macOS TIME values --\n'

awk '/^  function esec/, /^  }$/' "$SAMPLER" > "$TMP/esec.awk"
cat >> "$TMP/esec.awk" <<'AWK'
BEGIN { n = split(T, a, ","); for (i = 1; i <= n; i++) printf "%.2f\n", esec(a[i]) }
AWK
got=$(LC_ALL=C awk -f "$TMP/esec.awk" -v T="0:00.00,1:23.45,148:08.43,1234:56.78" </dev/null)
want=$'0.00\n83.45\n8888.43\n74096.78'
if [ "$got" = "$want" ]; then
  ok "esec parses [MMMM:]SS.hh with unbounded minutes (148:08.43 -> 8888.43s)"
else
  bad "esec parses [MMMM:]SS.hh with unbounded minutes"
  printf '        want: %s\n        got:  %s\n' "$(printf '%s' "$want" | tr '\n' ' ')" "$(printf '%s' "$got" | tr '\n' ' ')"
fi
# etime keeps its own shapes, and esec is shared: pin them too.
got=$(LC_ALL=C awk -f "$TMP/esec.awk" -v T="13-20:47:14,01:02:03" </dev/null)
want=$'1198034.00\n3723.00'
[ "$got" = "$want" ] && ok "esec still parses the etime shapes (D-HH:MM:SS, HH:MM:SS)" \
                     || bad "esec still parses the etime shapes (got: $(printf '%s' "$got" | tr '\n' ' '))"

# ------------------------------------------------------- the column offsets --
printf '\n  -- the two offsets that move with -o time= --\n'

# A ps snapshot in the v2 column order: pid ppid pcpu rss etime time args.
# The argvs are deliberately awkward: one with spaces, one that ps parenthesised
# because the argv was unreadable (handoff §4.4), and one containing a TAB — the
# field separator of the file being written, which clean() has to neutralise.
printf ' 4242     1   0.0  12345 01:00:00 148:08.43 /Users/x/.local/bin/claude\n' > "$TMP/snap"
printf ' 4243  4242   1.5  99999    30:00   0:01.23 /bin/bash -c echo hello world\n' >> "$TMP/snap"
printf ' 4244  4242   0.0    100    10:00   1:23.45 (bash)\n' >> "$TMP/snap"
printf ' 4245  4242   0.0    200    05:00   0:02.00 /usr/local/bin/weird\targ\n' >> "$TMP/snap"

# The roots awk, taken verbatim out of the sampler.
roots_prog=$(sed -n "s/^roots=.*awk '\(.*\)')\$/\1/p" "$SAMPLER")
if [ -z "$roots_prog" ]; then
  bad "the roots awk could be extracted from sample.sh"
else
  got=$(LC_ALL=C awk "$roots_prog" < "$TMP/snap" | tr '\n' ' ')
  [ "${got% }" = "4242" ] && ok "claude roots are still detected after the column shift" \
                          || bad "claude roots are still detected after the column shift (got: '$got')"
fi

# The main pass, also taken verbatim out of the sampler.
cat > "$TMP/extract.awk" <<'EXTRACT'
/^LC_ALL=C awk / { start = 1 }
start && !inprog { if ($0 ~ /'$/) inprog = 1; next }
inprog && /^  }' >>/ { print "  }"; exit }
inprog { print }
EXTRACT
awk -f "$TMP/extract.awk" "$SAMPLER" > "$TMP/main.awk"
# shellcheck source=../tools/orphan-policy.sh
. "$REPO/tools/orphan-policy.sh"

run_main() {  # <meta file> <SYS value>
  LC_ALL=C awk -f "$TMP/main.awk" -v NOW=1700000000 -v FLOOR=0 -v TOPN=8 \
    -v OM="$ORPHAN_MIN_DEFAULT" -v MATCH="$ORPHAN_MATCH_RE" -v EXCL="$ORPHAN_EXCLUDE_RE" \
    -v MEMFLOOR=0 -v META="$1" -v SNAP="$TMP/snap" -v SYS="$2" -v LOAD=1.50 -v NCPU=8 \
    </dev/null
}
FAKESYS=$(printf '1\t2\t3\t4\t5\t6\t7')

: > "$TMP/meta.empty"
run_main "$TMP/meta.empty" "$FAKESYS" > "$TMP/out.noroot"
got=$(awk -F'\t' '$2 == "proc" { print $3 "/" $6 "/" $7 }' "$TMP/out.noroot" | sort | tr '\n' ' ')
want="bash/4243/1.23 bash/4244/83.45 claude/4242/8888.43 weird arg/4245/2.00 "
if [ "$got" = "$want" ]; then
  ok "argv with spaces, a parenthesised argv and a tab all parse, with their CPU time"
else
  bad "argv with spaces, a parenthesised argv and a tab all parse, with their CPU time"
  printf '        want: %s\n        got:  %s\n' "$want" "$got"
fi
nf=$(awk -F'\t' '$2 == "proc" { print NF }' "$TMP/out.noroot" | sort -u | tr '\n' ' ')
[ "${nf% }" = "7" ] && ok "a tab inside argv cannot add a column to the row" \
                    || bad "a tab inside argv cannot add a column to the row (NF: $nf)"

sysline=$(awk -F'\t' '$2 == "sys"' "$TMP/out.noroot")
want_sys=$(printf '1700000000\tsys\t-\t1.50\t1\t2\t3\t8\t2\t4\t5\t6\t7')
[ "$sysline" = "$want_sys" ] && ok "the sys row lays out exactly as schema 2 specifies" \
                             || bad "the sys row layout (got: $sysline)"

# If vm_stat or sysctl produced nothing, the sys row must still be 13 fields
# with the version at $9 — "fewer fields" must never read as "older era" (§6c).
run_main "$TMP/meta.empty" "" > "$TMP/out.nosys"
sysline=$(awk -F'\t' '$2 == "sys"' "$TMP/out.nosys")
want_sys=$(printf '1700000000\tsys\t-\t1.50\t\t\t\t8\t2\t\t\t\t')
if [ "$sysline" = "$want_sys" ]; then
  ok "an empty system read still emits 13 fields with \$9 == 2, not a short row"
else
  bad "an empty system read still emits 13 fields with \$9 == 2, not a short row"
  printf '        got NF=%s: %s\n' "$(printf '%s' "$sysline" | awk -F'\t' '{print NF}')" "$sysline"
fi

printf '4242\t/Users/x/proj\ttab label\n' > "$TMP/meta.root"
run_main "$TMP/meta.root" "$FAKESYS" > "$TMP/out.root"
sessline=$(awk -F'\t' '$2 == "session"' "$TMP/out.root")
want_sess=$(printf '1700000000\tsession\t/Users/x/proj\t0.01\t112644\tbash@0.0\ttab label')
[ "$sessline" = "$want_sess" ] && ok "the session row still rolls the whole tree up (rss 112644)" \
                               || bad "the session row still rolls the whole tree up (got: $sessline)"
nores=$(awk -F'\t' '$2 == "proc"' "$TMP/out.root" | wc -l | tr -d ' ')
[ "$nores" = "0" ] && ok "processes inside a claude tree stay out of the machine-wide rows" \
                   || bad "processes inside a claude tree stay out of the machine-wide rows ($nores emitted)"

# ------------------------------------------------------ live roots, if any --
printf '\n  -- live check --\n'
if pgrep -x claude >/dev/null 2>&1; then
  live=$(awk -F'\t' '$2 == "session"' "$RAWV2" | wc -l | tr -d ' ')
  [ "$live" -gt 0 ] && ok "claude is running and the live sample recorded $live session row(s)" \
                    || bad "claude is running but the live sample recorded no session rows"
else
  printf '  \033[33mskip\033[0m  no claude process running; live root detection not exercised\n'
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
