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
#      everything after — this test is what proves that stayed true.
#   2. The v2 row shapes, with the schema version pinned at $9 of the sys row.
#   3. The two offsets that had to move with `-o time=`: the roots awk reads the
#      first argv token at $7, and the argv strip loop skips 6 leading columns.
#      Miss either and `roots` silently goes empty, i.e. no session rows at all.
#   4. esec() against real macOS TIME values. macOS prints [MMMM:]SS.hh with
#      UNBOUNDED minutes: 148:08.43 is 148 minutes, not 148 hours. A parser that
#      guesses hh:mm:ss on two fields is wrong by 60x, so the shape is asserted,
#      never assumed.
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

# --------------------------------------------------------------- the sampler --
printf '\n  -- sampler runs and emits schema 2 --\n'

if bash -n "$SAMPLER" 2>"$TMP/syntax.err"; then
  ok "tools/sample.sh parses"
else
  bad "tools/sample.sh parses"; sed 's/^/        /' "$TMP/syntax.err"
fi

V2="$TMP/v2"
mkdir -p "$V2/raw" || exit 1
CLAUDE_WATCH_HOME="$V2" bash "$SAMPLER" || bad "sample.sh run 1 exits 0"
sleep 1
CLAUDE_WATCH_HOME="$V2" bash "$SAMPLER" || bad "sample.sh run 2 exits 0"

DAY=$(ls "$V2/raw/" 2>/dev/null | head -n1)
DATE="${DAY%.tsv}"
if [ -z "$DAY" ]; then
  bad "sampler wrote a day file"; printf '\n  %d passed, %d failed\n' "$pass" "$((fail + 1))"; exit 1
fi
ok "sampler wrote a day file ($DAY)"
RAWV2="$V2/raw/$DAY"

# Field counts per row kind. sys and proc grew; session and orphan did not.
check_nf() {  # <kind> <expected NF>
  local kind=$1 want=$2 got
  got=$(awk -F'\t' -v k="$kind" '$2 == k { print NF }' "$RAWV2" | sort -u | tr '\n' ' ')
  got="${got% }"
  if [ -z "$got" ]; then
    printf '  \033[33mskip\033[0m  %s rows: none in this sample\n' "$kind"
  elif [ "$got" = "$want" ]; then
    ok "$kind rows all have NF=$want"
  else
    bad "$kind rows all have NF=$want (got: $got)"
  fi
}
check_nf sys 13
check_nf session 7
check_nf proc 7
check_nf orphan 6

schema=$(awk -F'\t' '$2 == "sys" { print $9 }' "$RAWV2" | sort -u | tr '\n' ' ')
[ "${schema% }" = "2" ] && ok 'sys $9 is the schema version 2' \
                        || bad "sys \$9 is the schema version 2 (got: $schema)"

# proc cumulative CPU seconds must be a bare number — §6c treats anything else
# as estimate-era for that row, so a formatting slip would silently downgrade
# every proc row in the file.
badct=$(awk -F'\t' '$2 == "proc" && $7 !~ /^[0-9]+(\.[0-9]+)?$/ { c++ } END { print c + 0 }' "$RAWV2")
[ "$badct" = "0" ] && ok 'every proc $7 matches ^[0-9]+(\.[0-9]+)?$' \
                   || bad "every proc \$7 is a plain number ($badct rows are not)"

# NF=7 on session rows above is also the G6 assertion: sessions deliberately
# carry no cumulative CPU, because a tree cumulative drops by the whole lifetime
# of a departing child and a delta there can go negative for a busy session.

# ------------------------------------------------ the ship blocker: G8 diff --
printf '\n  -- G8: report is byte-identical to the schema-1 projection --\n'

# The "before" file is this exact sample data with the v2 fields cut off: sys
# back to 8 fields, proc back to 6. Same rows, same order, schema-1 shape.
V1="$TMP/v1"
mkdir -p "$V1/raw" || exit 1
awk -F'\t' 'BEGIN { OFS = "\t" }
  $2 == "sys"  { print $1, $2, $3, $4, $5, $6, $7, $8; next }
  $2 == "proc" { print $1, $2, $3, $4, $5, $6; next }
  { print }' "$RAWV2" > "$V1/raw/$DAY"

if cmp -s "$RAWV2" "$V1/raw/$DAY"; then
  bad "the v1 projection actually differs from the v2 file (nothing was added?)"
else
  ok "the v1 projection differs from the v2 file"
fi

CLAUDE_WATCH_HOME="$V2" "$CW" report "$DATE" --json > "$TMP/v2.json" 2>"$TMP/v2.err"; rc2=$?
CLAUDE_WATCH_HOME="$V1" "$CW" report "$DATE" --json > "$TMP/v1.json" 2>"$TMP/v1.err"; rc1=$?
if [ "$rc2" = 0 ] && [ "$rc1" = 0 ]; then
  ok "report --json exits 0 on both files"
else
  bad "report --json exits 0 on both files (v2=$rc2 v1=$rc1)"
fi
if [ -s "$TMP/v2.json" ] && cmp -s "$TMP/v2.json" "$TMP/v1.json"; then
  ok "report --json is byte-identical before and after the schema change"
else
  bad "report --json is byte-identical before and after the schema change"
  diff "$TMP/v1.json" "$TMP/v2.json" | sed 's/^/        /' | head -20
fi

CLAUDE_WATCH_HOME="$V2" "$CW" report "$DATE" > "$TMP/v2.txt" 2>/dev/null
CLAUDE_WATCH_HOME="$V1" "$CW" report "$DATE" > "$TMP/v1.txt" 2>/dev/null
if [ -s "$TMP/v2.txt" ] && cmp -s "$TMP/v2.txt" "$TMP/v1.txt"; then
  ok "the text report is byte-identical too"
else
  bad "the text report is byte-identical too"
  diff "$TMP/v1.txt" "$TMP/v2.txt" | sed 's/^/        /' | head -20
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool < "$TMP/v2.json" >/dev/null 2>&1 \
    && ok "report --json is well-formed on a v2 file" \
    || bad "report --json is well-formed on a v2 file"
fi

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

# ------------------------------------------------------- pageout counters ----
printf '\n  -- pagein/pageout counters are live since-boot values --\n'

nz=$(awk -F'\t' '$2 == "sys" && ($10 + 0 == 0 || $11 + 0 == 0) { c++ } END { print c + 0 }' "$RAWV2")
[ "$nz" = "0" ] && ok "pageins and pageouts are non-zero in every sys row" \
                || bad "pageins and pageouts are non-zero in every sys row ($nz rows are 0)"

# Monotonic, and pageins must actually advance — that is what distinguishes a
# live counter from a constant parsed out of the wrong column. Some churn is
# generated between samples, and the check retries rather than racing a quiet
# second on an idle machine.
PG="$TMP/pg"; mkdir -p "$PG/raw" || exit 1
CLAUDE_WATCH_HOME="$PG" bash "$SAMPLER"
first_in=$(awk -F'\t' '$2 == "sys" { print $10; exit }' "$PG/raw/"*.tsv)
first_out=$(awk -F'\t' '$2 == "sys" { print $11; exit }' "$PG/raw/"*.tsv)
moved=0
for _ in 1 2 3 4 5 6 7 8; do
  find /usr/bin -type f -print0 2>/dev/null | xargs -0 -n 40 cat > /dev/null 2>&1
  CLAUDE_WATCH_HOME="$PG" bash "$SAMPLER"
  last_in=$(awk -F'\t' '$2 == "sys" { v = $10 } END { print v }' "$PG/raw/"*.tsv)
  [ "$last_in" -gt "$first_in" ] && { moved=1; break; }
  sleep 1
done
last_out=$(awk -F'\t' '$2 == "sys" { v = $11 } END { print v }' "$PG/raw/"*.tsv)
[ "$moved" = 1 ] && ok "pageins increase across samples ($first_in -> $last_in)" \
                 || bad "pageins increase across samples (stuck at $first_in)"
[ "$last_out" -ge "$first_out" ] && ok "pageouts never go backwards ($first_out -> $last_out)" \
                                 || bad "pageouts never go backwards ($first_out -> $last_out)"

# ------------------------------------------------------------------- esec() --
printf '\n  -- esec() on real macOS TIME values --\n'

# The function under test is extracted from the sampler, so this cannot drift.
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
# Note the deliberate awkward argv: one with spaces, one that ps parenthesised
# because the argv was unreadable (handoff §4.4).
cat > "$TMP/snap" <<'SNAP'
 4242     1   0.0  12345 01:00:00 148:08.43 /Users/x/.local/bin/claude
 4243  4242   1.5  99999    30:00   0:01.23 /bin/bash -c echo hello world
 4244  4242   0.0    100    10:00   1:23.45 (bash)
SNAP

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
FAKESYS=$(printf '1\t2\t3\t4\t5\t6\t7')

run_main() {  # <meta file>
  LC_ALL=C awk -f "$TMP/main.awk" -v NOW=1700000000 -v FLOOR=0 -v TOPN=8 \
    -v OM="$ORPHAN_MIN_DEFAULT" -v MATCH="$ORPHAN_MATCH_RE" -v EXCL="$ORPHAN_EXCLUDE_RE" \
    -v MEMFLOOR=0 -v META="$1" -v SNAP="$TMP/snap" -v SYS="$FAKESYS" -v LOAD=1.50 -v NCPU=8 \
    </dev/null
}

: > "$TMP/meta.empty"
run_main "$TMP/meta.empty" > "$TMP/out.noroot"
got=$(awk -F'\t' '$2 == "proc" { print $3 "/" $6 "/" $7 }' "$TMP/out.noroot" | sort | tr '\n' ' ')
want="bash/4243/1.23 bash/4244/83.45 claude/4242/8888.43 "
if [ "$got" = "$want" ]; then
  ok "argv with spaces and a parenthesised argv both parse, with their CPU time"
else
  bad "argv with spaces and a parenthesised argv both parse, with their CPU time"
  printf '        want: %s\n        got:  %s\n' "$want" "$got"
fi

sysline=$(awk -F'\t' '$2 == "sys"' "$TMP/out.noroot")
want_sys=$(printf '1700000000\tsys\t-\t1.50\t1\t2\t3\t8\t2\t4\t5\t6\t7')
[ "$sysline" = "$want_sys" ] && ok "the sys row lays out exactly as schema 2 specifies" \
                             || bad "the sys row layout (got: $sysline)"

printf '4242\t/Users/x/proj\ttab label\n' > "$TMP/meta.root"
run_main "$TMP/meta.root" > "$TMP/out.root"
sessline=$(awk -F'\t' '$2 == "session"' "$TMP/out.root")
want_sess=$(printf '1700000000\tsession\t/Users/x/proj\t0.01\t112444\tbash@0.0\ttab label')
[ "$sessline" = "$want_sess" ] && ok "the session row still rolls the whole tree up (rss 112444)" \
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
