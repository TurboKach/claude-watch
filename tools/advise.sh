#!/usr/bin/env bash
# claude-watch advise — "what should I fix, in priority order", within each domain.
#
# Sourced lazily by claude-watch's `advise)` / `disk)` dispatch, never at file
# scope: the once-a-day `hook` path pays nothing for a command it never runs.
# Read-only by construction — there is no side-effecting path in this file. The
# one thing that scans is tools/disk-scan.sh, reached only via `disk --refresh`.
#
# Everything here relies on the parent script for $DATA/$RAW/$STATE, read_day(),
# is_uint(), fmt_dur(), the colour variables and $JESC_AWK.

# ------------------------------------------------------------ thresholds ---
# One table, used for validation, for --show-thresholds, and to export the
# effective value so an analyzer never has to re-decide what the default is.
# Order is the print order.
CW_THRESHOLDS='CLAUDE_WATCH_DISK_CRIT_PCT 10 pct
CLAUDE_WATCH_DISK_CRIT_GIB 25 gib
CLAUDE_WATCH_DISK_WARN_PCT 20 pct
CLAUDE_WATCH_DISK_WARN_GIB 50 gib
CLAUDE_WATCH_DISK_GROUP_WARN_PCT 2 pct
CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS 24 hours
CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB 200 mb
CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB 1 gib'

CW_DISK_TTL=21600          # 6h (§1)
CW_LIVENESS_SECONDS=120    # the same constant status() uses (claude-watch:1308)

# Hard ceiling on how many day files one run will open. It exists so a caller
# who raises CLAUDE_WATCH_KEEP_DAYS past it cannot ask for a window the reader
# will quietly truncate: the clamp is applied to the ADVERTISED window, not just
# to the loop bound, so requested_seconds always describes what was actually
# read and `clamped` says it was reduced.
CW_MAX_WINDOW_DAYS=400

CW_CAVEAT='CPU and memory advice are not in this version. Even claude-watch report'"'"'s CPU figures are partial by construction: processes under CLAUDE_WATCH_FLOOR (5% of one core) and beyond the top CLAUDE_WATCH_TOPN (8) per sample are never recorded, so twenty processes at 4% — 0.8 cores — produce zero rows. GPU and Neural Engine power are not measured at all (README Limitations). A quiet CPU report does not mean a cool machine.'

# Resolves every knob, rejecting a value awk would silently coerce to 0, and
# exports the effective value so the analyzers read one number rather than each
# re-deriving the default.
cw_load_thresholds() {
  local name def unit cur src
  CW_THRESHOLD_TABLE=""
  while read -r name def unit; do
    [ -n "$name" ] || continue
    eval "cur=\${$name-}"
    if [ -n "$cur" ]; then
      if ! is_uint "$cur"; then
        printf 'claude-watch advise: %s="%s" is not a non-negative integer. Unset it or give a whole number. Try: %s=%s claude-watch advise\n' \
          "$name" "$cur" "$name" "$def" >&2
        return 2
      fi
      src="$name"
    else
      cur="$def"; src="default"
      eval "$name=\$def"
    fi
    export "${name?}"
    CW_THRESHOLD_TABLE="$CW_THRESHOLD_TABLE$name $cur $unit $src
"
  done <<EOF
$CW_THRESHOLDS
EOF
  return 0
}

# Source is recorded while the value is resolved, because by the time the table
# is printed every knob is exported and "is it in the environment" no longer
# distinguishes an override from a default.
cw_show_thresholds() {
  local name cur unit src
  printf '%sclaude-watch advise — effective thresholds%s\n' "$C_HEAD" "$C_RST"
  printf '  %s%-38s %6s %-6s %s%s\n' "$C_DIM" "knob" "value" "unit" "source" "$C_RST"
  while read -r name cur unit src; do
    [ -n "$name" ] || continue
    printf '  %s%-38s%s %6s %-6s %s%s%s\n' "$C_KEY" "$name" "$C_RST" "$cur" "$unit" "$C_DIM" "$src" "$C_RST"
  done <<EOF
$CW_THRESHOLD_TABLE
EOF
}

# ------------------------------------------------------------ day files ----
# Distinct dates that have raw data, oldest first. A day present as both .tsv
# and .tsv.gz is one date, not two.
cw_day_list() {
  ls -1 "$RAW" 2>/dev/null | LC_ALL=C awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.tsv(\.gz)?$/ {
      d = substr($0, 1, 10)
      if (!(d in seen)) { seen[d] = 1; print d }
    }' | sort
}

# ------------------------------------------------------------ the window ---
# One definition of "this is an epoch the reader may trust", shared textually by
# the window FILTER and the window VALIDATOR because they have to agree. The
# filter cannot simply test `$1 + 0 >= cutoff`: awk converts `notanepoch` to 0,
# which is below every cutoff, so a damaged row would be dropped before the
# validator ever saw it — counted as absent rather than as damaged, which is the
# silent-shortfall failure U0 spent three review rounds closing one layer down.
#
# The ten-digit bound is U0's and is what makes epoch comparison injective; see
# CW_WINDOW_AWK for why it is a length() test and not a brace interval.
CW_EPOCH_OK='($1 ~ /^(0|[1-9][0-9]*)$/ && length($1) <= 10)'

# cw_read_window <seconds> — raw TSV on stdout, oldest row first, epoch >= now-N.
#
# Order is load-bearing: the aggregation closes a sample on an epoch change, so
# concatenating days newest-first corrupts the fold. read_day() prefers the plain
# .tsv, which is what makes a day held as both .tsv and .tsv.gz read exactly once
# — a week window crosses the gzip threshold every time.
#
# A non-zero gzcat exit is recorded (E8), never swallowed: a corrupt archive
# otherwise yields a silently short window with an honest-looking coverage number.
cw_read_window() {
  local secs=$1 d i n
  local cutoff=$(( CW_NOW - secs ))
  n=$(( secs / 86400 + 2 ))
  # Unreachable: the caller has already clamped the window to
  # CW_MAX_WINDOW_DAYS. It stays as an assertion, because the day a caller
  # forgets, a truncated read is the failure mode with no symptom.
  [ "$n" -gt $((CW_MAX_WINDOW_DAYS + 2)) ] && n=$((CW_MAX_WINDOW_DAYS + 2))
  : > "$CW_TMP/failed-days"
  : > "$CW_TMP/covered-days"
  : > "$CW_TMP/window-days"
  {
    i=$((n - 1))
    while [ "$i" -ge 0 ]; do
      d=$(date -v-"${i}"d +%F)
      i=$((i - 1))
      printf '%s\n' "$d" >> "$CW_TMP/window-days"
      if [ -f "$RAW/$d.tsv" ] || [ -f "$RAW/$d.tsv.gz" ]; then
        # Buffered, then emitted only on success. gzip detects corruption from
        # the CRC and length trailer at the END of the stream, so a truncated
        # archive decompresses a perfectly valid-looking PREFIX and only then
        # exits non-zero. Streaming read_day straight into the pipe would let
        # those untrusted rows count toward samples, interval and coverage while
        # E8 simultaneously reported the day as unreadable — the two halves of
        # the output contradicting each other. One buffer file, reused per day.
        if read_day "$d" > "$CW_TMP/day.buf" 2>/dev/null; then
          cat "$CW_TMP/day.buf"
          printf '%s\n' "$d" >> "$CW_TMP/covered-days"
        else
          printf '%s\n' "$d" >> "$CW_TMP/failed-days"
        fi
      fi
    done
  } | CW_CUTOFF="$cutoff" LC_ALL=C awk -F'\t' '
    '"$CW_EPOCH_OK"' { if (($1 + 0) >= (ENVIRON["CW_CUTOFF"] + 0)) print; next }
    { print }   # damaged epoch: pass it through so the validator can count it
  '
}

# The window is read exactly ONCE per run. This pass derives the metadata and
# emits it as M rows; v2's cpu/memory analyzer folds into the same pass rather
# than paying for a second read.
#
# The interval derivation is U0's algorithm, VERBATIM, down to the epoch guard
# and the have_prev sentinel. It is copied rather than described because advise
# and report must derive the same iv from the same bytes: iv multiplies into
# observed_seconds and therefore into every rate and every threshold decision,
# so two implementations that drift by one bucket silently disagree about how
# busy the machine was, in two commands the user reads side by side.
#
# The parts that are not obvious, in U0 wording:
#   - the rank is int(dn/2)+1 reached by c >= need, an UPPER median. The natural
#     c >= dn/2 picks the wrong bucket for every even dn.
#   - the bucket walk is numeric 1..599; for (g in hist) is undefined-order.
#   - iv falls back to 10 when dn == 0 (one sample, or every gap over 600s).
#   - the ten-digit epoch bound is what makes epoch comparison injective: awk
#     holds numbers as doubles, so past 2^53 distinct integers stop being
#     distinct and two samples collapse into one. It is a length() test, not a
#     brace interval, because macOS awk 20200816 matches braces as literal text.
#   - have_prev, not prev_ep != "", marks the first row: "" is a value a damaged
#     file can contain, so it cannot also be a sentinel.
CW_WINDOW_AWK='
  $2 == "sys" {
    if (! '"$CW_EPOCH_OK"') { badep++; next }
    ep = $1
    if (!have_prev || ep != prev_ep) {
      if (have_prev) {
        if (ep < prev_ep) disorder++
        gap = ep - prev_ep
        if (gap > 0 && gap < 600) { hist[gap]++; dn++ }
      }
      sysn++; prev_ep = ep; have_prev = 1
      if (ep > lastep) lastep = ep
      if (!have_first || ep < firstep) { firstep = ep; have_first = 1 }
    }
    ncpu = $8 + 0
    if (NF >= 13 && $9 + 0 == 2) {
      memsize = $12 + 0; swapcap = $13 + 0
      if (!have_s2 || ep < schema2_since) { schema2_since = ep; have_s2 = 1 }
    }
    next
  }
  END {
    need = int(dn / 2) + 1
    iv = 10
    c = 0
    for (g = 1; g < 600; g++) { c += hist[g]; if (c >= need) { iv = g; break } }
    covered = sysn * iv
    printf "M\tiv\t%d\n", iv
    printf "M\tsamples\t%d\n", sysn
    printf "M\tobserved_seconds\t%d\n", covered
    printf "M\tread_seconds\t%d\n", (sysn > 0 && lastep > firstep) ? lastep - firstep : 0
    printf "M\tncpu\t%s\n", (sysn > 0 ? ncpu : "")
    printf "M\tmemsize_kb\t%s\n", (memsize > 0 ? memsize "" : "")
    printf "M\tswap_cap_mb\t%s\n", (swapcap > 0 ? swapcap "" : "")
    printf "M\tlast_epoch\t%s\n", (sysn > 0 ? lastep "" : "")
    printf "M\tfirst_epoch\t%s\n", (sysn > 0 ? firstep "" : "")
    printf "M\tschema2_since\t%s\n", (have_s2 ? schema2_since "" : "")
    printf "M\tdisorder\t%d\n", disorder
    printf "M\tbadep\t%d\n", badep
  }
'

# ------------------------------------------------------------ disk cache ---
# Read only. advise NEVER scans (G7); `disk --refresh` is the only scanner.
cw_read_disk_cache() {
  CW_DISK_CACHE_STATE=missing
  CW_DISK_EPOCH=""; CW_DISK_AGE=""; CW_DISK_PARTIAL=""; CW_DISK_DEADLINE=""
  CW_DISK_ROOTS_SCANNED=""; CW_DISK_ROOTS_TOTAL=""; CW_VOLUME_TOTAL_KB=""
  CW_DISK_STALE=0
  local cache="${CLAUDE_WATCH_DISK_CACHE:-$STATE/disk.tsv}"
  CW_DISK_CACHE="$cache"
  [ -f "$cache" ] || return 0
  local line
  line=$(LC_ALL=C awk -F'\t' '
    $1 == "epoch" { ep = $3 + 0 }
    $1 == "scan"  { pa = $2 + 0; dl = $3 + 0; rs = $4 + 0; rt = $5 + 0; sawscan = 1 }
    $1 == "vol"   { used = $3 + 0; avail = $4 + 0; sawvol = 1 }
    END {
      if (ep <= 0 || !sawvol) { print "malformed"; exit }
      printf "ok\t%d\t%d\t%d\t%d\t%d\t%d\n", ep, pa, dl, rs, rt, used + avail
    }' "$cache" 2>/dev/null)
  case "$line" in
    ok*) ;;
    *) CW_DISK_CACHE_STATE=malformed; return 0 ;;
  esac
  IFS=$'\t' read -r _ CW_DISK_EPOCH CW_DISK_PARTIAL CW_DISK_DEADLINE \
    CW_DISK_ROOTS_SCANNED CW_DISK_ROOTS_TOTAL CW_VOLUME_TOTAL_KB <<EOF
$line
EOF
  CW_DISK_CACHE_STATE=ok
  CW_DISK_AGE=$(( CW_NOW - CW_DISK_EPOCH ))
  [ "$CW_DISK_AGE" -lt 0 ] && CW_DISK_AGE=0
  [ "$CW_DISK_AGE" -gt "$CW_DISK_TTL" ] && CW_DISK_STALE=1
  return 0
}

cw_disk_scan_json() {
  if [ "$CW_DISK_CACHE_STATE" != "ok" ]; then
    printf '{"epoch":null,"age_seconds":null,"ttl_seconds":%d,"stale":null,"scanned":false,"partial":null,"deadline_hit":null,"roots_scanned":null,"roots_total":null}' \
      "$CW_DISK_TTL"
    return 0
  fi
  printf '{"epoch":%d,"age_seconds":%d,"ttl_seconds":%d,"stale":%s,"scanned":true,"partial":%s,"deadline_hit":%s,"roots_scanned":%d,"roots_total":%d}' \
    "$CW_DISK_EPOCH" "$CW_DISK_AGE" "$CW_DISK_TTL" \
    "$([ "$CW_DISK_STALE" = 1 ] && printf 'true' || printf 'false')" \
    "$([ "$CW_DISK_PARTIAL" != 0 ] && printf 'true' || printf 'false')" \
    "$([ "$CW_DISK_DEADLINE" != 0 ] && printf 'true' || printf 'false')" \
    "$CW_DISK_ROOTS_SCANNED" "$CW_DISK_ROOTS_TOTAL"
}

# ------------------------------------------------------------ analyzers ----
# Stubs so the command runs and is testable before U4/U5 land. A real analyzer,
# once sourced, wins: this only fills a gap.
cw_stub_domain() {
  printf 'S\t%s\tunknown\tunavailable\tcache_missing\tnot implemented\tthis domain is not implemented yet, so nothing here has been measured\n' "$1"
}

cw_load_analyzers() {
  # shellcheck source=/dev/null
  [ -f "$REPO_DIR/tools/advise-disk.sh" ]  && . "$REPO_DIR/tools/advise-disk.sh"  2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$REPO_DIR/tools/advise-leaks.sh" ] && . "$REPO_DIR/tools/advise-leaks.sh" 2>/dev/null
  if ! declare -F advise_disk >/dev/null 2>&1; then
    advise_disk() { cw_stub_domain disk; }
  fi
  if ! declare -F advise_leaks >/dev/null 2>&1; then
    advise_leaks() { cw_stub_domain leaks; }
  fi
  return 0
}

# ------------------------------------------------------------- emitter -----
# One awk program renders both the JSON and the human output from the same S/F
# rows, so the two can never disagree about order or severity. dom_json() is
# called by both `advise` and `disk`, which is what makes §3f's `domain` object
# byte-for-byte what advise puts in domains[] minus `priority`.
CW_EMIT_AWK='
# A real JSON number serializer, not a numeric-looking-text test.
#
# JSON RFC 8259 numbers are NARROWER than what awk and most eyes read as
# numeric: `.5`, `01` and `1.` are all rejected by a strict parser, and there is
# no nan and no inf at all. Two ways the old one-line guard shipped an invalid
# document that looked fine:
#   - it passed `.5` / `01` / `1.` straight through as JSON numbers
#   - it passed `1e999999`, which is finite TEXT and infinite VALUE; Python
#     turns that into float("inf") without raising, so json.tool validates a
#     document that already lost the contract
# So: accept canonical JSON text as-is (no round trip, no precision lost);
# canonicalise anything else awk agrees is a number through %.17g; then prove
# the RESULT is finite before it is allowed out. Anything left is 0.
function jnum(x,   s, v) {
  if (x ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) s = x
  else if (x ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) s = sprintf("%.17g", x + 0)
  else return "0"
  v = s + 0
  # Written as a positive range test so nan, which fails every comparison,
  # lands here too rather than sailing through a negated one.
  if (!(v >= -1.7976931348623157e308 && v <= 1.7976931348623157e308)) return "0"
  if (s !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) return "0"
  return s
}
function clamp01(s) {
  # The text guard runs FIRST. awk parses "nan" and "inf" into real IEEE values
  # that then sail through a range test (nan fails every comparison, so a naive
  # guard returns it unchanged) and print as bare nan/inf, which no JSON parser
  # accepts. Anything that does not look like a number is the missing-denominator
  # case, and the missing-denominator case is 0 (§3a).
  if (s !~ /^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/) return 0
  s = s + 0
  if (!(s >= 0)) return 0
  if (!(s <= 1)) return 1
  return s
}
function jstr(s) { return "\"" jesc(s) "\"" }
function jornull(s) { if (s == "") return "null"; return jstr(s) }
function jarr(csv,   i, n, a, out) {
  n = split(csv, a, ",")
  out = "["
  for (i = 1; i <= n; i++) {
    if (a[i] == "") continue
    if (out != "[") out = out ","
    out = out jstr(a[i])
  }
  return out "]"
}
function partial_of(csv,   n, a, r) {
  n = split(csv, a, ",")
  if (n < 1 || a[1] == "") return ""
  r = a[1]
  if (r == "scan_deadline") return "deadline"
  if (r == "scan_permission_denied") return "permissions"
  return r
}
function disp(s) { gsub(/[\001-\037\177]/, " ", s); return s }
function dord(d) { return (d in dorder) ? dorder[d] : 99 }
function worse(d, a, b) {
  if (rank[fsev[d, a]] != rank[fsev[d, b]]) return (rank[fsev[d, a]] > rank[fsev[d, b]])
  if (fshare[d, a] != fshare[d, b]) return (fshare[d, a] > fshare[d, b])
  return (fid[d, a] < fid[d, b])
}
function sortf(d,   i, j, n, t) {
  n = fn[d]
  for (i = 1; i <= n; i++) idx[i] = i
  for (i = 2; i <= n; i++)
    for (j = i; j > 1 && worse(d, idx[j], idx[j - 1]); j--) { t = idx[j - 1]; idx[j - 1] = idx[j]; idx[j] = t }
}
function fjson(d, k,   out) {
  out = "{\"id\":" jstr(fid[d, k])
  out = out ",\"severity\":" jstr(fsev[d, k]) ",\"severity_rank\":" rank[fsev[d, k]] + 0
  out = out ",\"share_of_domain\":" sprintf("%.6g", fshare[d, k])
  out = out ",\"value\":" jnum(fval[d, k]) ",\"unit\":" jstr(funit[d, k])
  out = out ",\"threshold\":" jnum(fthr[d, k]) ",\"threshold_name\":" jstr(ftname[d, k])
  out = out ",\"reclaimable_kb\":" jnum(frec[d, k]) ",\"confidence\":" jstr(fconf[d, k])
  out = out ",\"headline\":" jstr(fhead[d, k])
  out = out ",\"detail\":" jstr(fdet[d, k])
  out = out ",\"action\":" jornull(fact[d, k])
  return out "}"
}
function dom_json(d, prio,   i, out) {
  sortf(d)
  out = "{\"domain\":" jstr(d)
  if (prio > 0) out = out ",\"priority\":" prio
  out = out ",\"severity\":" jstr(dsev[d]) ",\"severity_rank\":" rank[dsev[d]] + 0
  out = out ",\"measurement_state\":" jstr(dstate[d])
  out = out ",\"measurement_reasons\":" jarr(dreason[d])
  out = out ",\"partial_reason\":" jornull(partial_of(dreason[d]))
  out = out ",\"summary\":" jstr(dsum[d])
  out = out ",\"remedy\":" jornull(drem[d])
  out = out ",\"findings\":["
  for (i = 1; i <= fn[d]; i++) out = out (i > 1 ? "," : "") fjson(d, idx[i])
  return out "]}"
}
function gib(kb) { return sprintf("%.1f GiB", kb / 1048576) }
function valfmt(v, u) {
  if (u == "kb")      return gib(v + 0)
  if (u == "pct")     return sprintf("%.1f%%", v + 0)
  if (u == "cores")   return sprintf("%.2f cores", v + 0)
  if (u == "seconds") return sprintf("%ds", v + 0)
  return v " " u
}
function sevtag(s) { return col[s] word[s] C_RST }
function pfind(d, k, full,   act) {
  if (!full) {
    printf "    %s %s%s%s  %s\n", sevtag(fsev[d, k]), C_DIM, fid[d, k], C_RST, disp(fhead[d, k])
    return
  }
  printf "    %s %s%s%s\n", sevtag(fsev[d, k]), C_KEY, fid[d, k], C_RST
  printf "      %s\n", disp(fhead[d, k])
  if (fdet[d, k] != "") printf "      %s%s%s\n", C_DIM, disp(fdet[d, k]), C_RST
  if (ftname[d, k] != "")
    printf "      %s%s at %s — %s · is %s, %s of this domain%s\n", C_DIM,
           (fsev[d, k] == "critical" ? "critical" : fsev[d, k]),
           valfmt(fthr[d, k], funit[d, k]), ftname[d, k],
           valfmt(fval[d, k], funit[d, k]), sprintf("%.1f%%", fshare[d, k] * 100), C_RST
  act = fact[d, k]
  # Quote-or-refuse, second layer (§3b): a command carrying a control byte is
  # never printed, however well quoted, because it is unreadable in a terminal
  # and unsafe to hand someone to paste.
  if (act ~ /[\001-\037\177]/) act = ""
  if (act != "") printf "      %s→%s %s\n", C_HOT, C_RST, act
}
function psection(d,   i, shown, rest) {
  sortf(d)
  if (dsev[d] == "ok" && fn[d] == 0) {
    printf "  %s %s%s%s — %s\n", sevtag("ok"), C_KEY, d, C_RST, disp(dsum[d])
    return
  }
  printf "\n  %s%s%s  %s %s\n", C_SEC, toupper(d), C_RST, sevtag(dsev[d]), disp(dsum[d])
  if (d == "disk" && DISK_BANNER != "") printf "    %s%s%s\n", C_DIM, DISK_BANNER, C_RST
  if (drem[d] != "") printf "    %s%s%s\n", C_DIM, disp(drem[d]), C_RST
  shown = 0
  for (i = 1; i <= fn[d] && i <= 10; i++) { pfind(d, idx[i], (i <= 3)); shown = i }
  rest = fn[d] - shown
  if (rest > 0) printf "    %s+ %d more (--json for all)%s\n", C_DIM, rest, C_RST
}
BEGIN {
  FS = "\t"
  rank["critical"] = 4; rank["warn"] = 3; rank["info"] = 2; rank["unknown"] = 1; rank["ok"] = 0
  word["critical"] = "CRITICAL"; word["warn"] = "WARN"; word["info"] = "INFO"
  word["ok"] = "OK"; word["unknown"] = "UNKNOWN unmeasured"
  mrank["complete"] = 0; mrank["partial"] = 1; mrank["unavailable"] = 2
  mname[0] = "complete"; mname[1] = "partial"; mname[2] = "unavailable"
  dorder["disk"] = 1; dorder["leaks"] = 2

  MODE   = ENVIRON["A_MODE"]
  C_HEAD = ENVIRON["A_C_HEAD"]; C_DIM = ENVIRON["A_C_DIM"]; C_KEY = ENVIRON["A_C_KEY"]
  C_HOT  = ENVIRON["A_C_HOT"];  C_RED = ENVIRON["A_C_RED"]; C_OK  = ENVIRON["A_C_OK"]
  C_SEC  = ENVIRON["A_C_SEC"];  C_RST = ENVIRON["A_C_RST"]
  col["critical"] = C_RED; col["warn"] = C_HOT; col["info"] = C_KEY
  col["ok"] = C_OK; col["unknown"] = C_DIM
  DISK_BANNER = ENVIRON["A_DISK_BANNER"]
}
$1 == "S" {
  d = $2
  if (!(d in seen)) { seen[d] = 1; dl[++dn] = d }
  dsev[d] = $3; dstate[d] = $4; dreason[d] = $5; dsum[d] = $6; drem[d] = $7
  next
}
$1 == "F" {
  d = $2
  if (!(d in seen)) { seen[d] = 1; dl[++dn] = d }
  i = ++fn[d]
  fid[d, i] = $3; fsev[d, i] = $4; fshare[d, i] = clamp01($5)
  fval[d, i] = $6; funit[d, i] = $7; fthr[d, i] = $8; ftname[d, i] = $9
  frec[d, i] = $10; fconf[d, i] = $11
  fhead[d, i] = $12; fdet[d, i] = $13; fact[d, i] = $14
  next
}
END {
  # Domain order: severity_rank desc, then the fixed disk -> leaks convention.
  # One rule for the headline, the sections and domains[] alike (§4).
  for (i = 2; i <= dn; i++)
    for (j = i; j > 1; j--) {
      a = dl[j]; b = dl[j - 1]
      if (rank[dsev[a]] > rank[dsev[b]] ||
          (rank[dsev[a]] == rank[dsev[b]] && dord(a) < dord(b))) {
        dl[j] = b; dl[j - 1] = a
      } else break
    }

  pstate = "ok"; prank = 0; pdomain = ""; pmstate = 0
  reasons = ENVIRON["A_WINDOW_REASONS"]
  for (i = 1; i <= dn; i++) {
    d = dl[i]
    if (i == 1) { pstate = dsev[d]; prank = rank[dsev[d]] + 0; pdomain = d }
    if (mrank[dstate[d]] + 0 > pmstate) pmstate = mrank[dstate[d]] + 0
    if (dreason[d] != "") reasons = (reasons == "" ? dreason[d] : reasons "," dreason[d])
  }
  if (reasons != "" && pmstate == 0) pmstate = 1
  # Deduplicate the union without relying on array iteration order.
  nsp = split(reasons, rs, ",")
  ureasons = ""
  for (i = 1; i <= nsp; i++) {
    if (rs[i] == "" || (rs[i] in rseen)) continue
    rseen[rs[i]] = 1
    ureasons = (ureasons == "" ? rs[i] : ureasons "," rs[i])
  }

  # primary.headline carries the actionable fact, never a bare domain name.
  htext = ""
  if (pdomain != "") {
    sortf(pdomain)
    htext = (fn[pdomain] > 0) ? fhead[pdomain, idx[1]] : dsum[pdomain]
  }
  headline = (pdomain == "") ? "no domains reported" \
             : sprintf("%s %s — %s", toupper(pstate), pdomain, htext)

  # One appended line per run: epoch, window, per-domain severity, top finding.
  logline = ENVIRON["A_NOW"] "\t" ENVIRON["A_WINDOW_LABEL"]
  for (i = 1; i <= dn; i++) {
    d = dl[i]; sortf(d)
    logline = logline "\t" d "=" dsev[d] ":" ((fn[d] > 0) ? fid[d, idx[1]] : "-")
  }
  if (ENVIRON["A_LOGTMP"] != "") print logline > ENVIRON["A_LOGTMP"]

  if (MODE == "disk-json") {
    printf "{\"command\":\"disk\",\"schema_version\":1,\"generated_at\":%d", ENVIRON["A_NOW"] + 0
    printf ",\"disk_scan\":%s", ENVIRON["A_DISK_SCAN"]
    printf ",\"domain\":%s}\n", dom_json("disk", -1)
    exit
  }
  if (MODE == "advise-json") {
    printf "{\"command\":\"advise\",\"schema_version\":1,\"generated_at\":%d", ENVIRON["A_NOW"] + 0
    printf ",\"primary\":{\"state\":%s,\"severity_rank\":%d,\"domain\":%s,\"headline\":%s,\"measurement_state\":%s,\"measurement_reasons\":%s}",
           jstr(pstate), prank, jornull(pdomain), jstr(headline), jstr(mname[pmstate]), jarr(ureasons)
    printf ",\"window\":{\"label\":%s,\"requested_seconds\":%d,\"read_seconds\":%d,\"observed_seconds\":%d,\"clamped\":%s,\"requested_days\":%d,\"available_days\":%d,\"covered_days\":%d,\"missing_or_failed_days\":%s}",
           jstr(ENVIRON["A_WINDOW_LABEL"]), ENVIRON["A_REQ_SECONDS"] + 0,
           ENVIRON["A_READ_SECONDS"] + 0, ENVIRON["A_OBSERVED_SECONDS"] + 0,
           (ENVIRON["A_CLAMPED"] == "1" ? "true" : "false"),
           ENVIRON["A_REQ_DAYS"] + 0, ENVIRON["A_AVAIL_DAYS"] + 0,
           ENVIRON["A_COVERED_DAYS"] + 0, jarr(ENVIRON["A_MISSING_DAYS"])
    printf ",\"samples\":%d", ENVIRON["A_SAMPLES"] + 0
    printf ",\"interval_seconds\":%d", ENVIRON["A_INTERVAL"] + 0
    printf ",\"cores\":%s", (ENVIRON["A_NCPU"] == "" ? "null" : sprintf("%d", ENVIRON["A_NCPU"] + 0))
    printf ",\"freshness\":{\"last_sample_epoch\":%s,\"age_seconds\":%s,\"sampler_ok\":%s}",
           (ENVIRON["A_LAST_EPOCH"] == "" ? "null" : sprintf("%d", ENVIRON["A_LAST_EPOCH"] + 0)),
           (ENVIRON["A_LAST_AGE"] == "" ? "null" : sprintf("%d", ENVIRON["A_LAST_AGE"] + 0)),
           (ENVIRON["A_SAMPLER_OK"] == "1" ? "true" : "false")
    printf ",\"cpu_basis\":{\"proc\":%s,\"session\":\"estimate\"}",
           (ENVIRON["A_SCHEMA2_SINCE"] == "" ? "\"estimate\"" : "\"cputime\"")
    printf ",\"cpu_basis_since\":%s",
           (ENVIRON["A_SCHEMA2_SINCE"] == "" ? "null" : sprintf("%d", ENVIRON["A_SCHEMA2_SINCE"] + 0))
    printf ",\"deferred_domains\":[\"cpu\",\"memory\"]"
    printf ",\"caveats\":[%s]", jstr(ENVIRON["A_CAVEAT"])
    printf ",\"domains\":["
    for (i = 1; i <= dn; i++) printf "%s%s", (i > 1 ? "," : ""), dom_json(dl[i], i)
    printf "]"
    printf ",\"disk_scan\":%s}\n", ENVIRON["A_DISK_SCAN"]
    exit
  }

  # ------------------------------------------------------------- human ----
  if (MODE == "disk-text") {
    printf "%sclaude-watch disk%s\n", C_HEAD, C_RST
    psection("disk")
    exit
  }
  printf "%sclaude-watch advise%s  %s%s%s\n", C_HEAD, C_RST, col[pstate], headline, C_RST
  if (ENVIRON["A_BANNER_E3"] != "") printf "  %s%s%s\n", C_RED, ENVIRON["A_BANNER_E3"], C_RST
  if (ENVIRON["A_BANNER_E6"] != "") printf "  %s%s%s\n", C_DIM, ENVIRON["A_BANNER_E6"], C_RST
  if (ENVIRON["A_BANNER_CLAMP"] != "") printf "  %s%s%s\n", C_DIM, ENVIRON["A_BANNER_CLAMP"], C_RST
  printf "  %s%s · %d samples · %s observed · interval %ss%s\n",
         C_DIM, ENVIRON["A_WINDOW_LABEL"], ENVIRON["A_SAMPLES"] + 0,
         ENVIRON["A_OBSERVED_HUMAN"], ENVIRON["A_INTERVAL"] + 0, C_RST
  for (i = 1; i <= dn; i++) psection(dl[i])
  printf "\n  %s%s%s\n", C_DIM, ENVIRON["A_CAVEAT"], C_RST
  printf "  %snot measured here: cpu, memory%s\n", C_DIM, C_RST
}
'

# ------------------------------------------------------------- commands ----
# Parses one --window value into CW_WIN_LABEL / CW_WIN_SECONDS / CW_WIN_DAYS.
cw_parse_window() {
  local w="$1" n u
  case "$w" in
    week)  CW_WIN_LABEL=week;  CW_WIN_SECONDS=$((7 * 86400));  CW_WIN_DAYS=7;  return 0 ;;
    month) CW_WIN_LABEL=month; CW_WIN_SECONDS=$((30 * 86400)); CW_WIN_DAYS=30; return 0 ;;
  esac
  n="${w%?}"; u="${w#"$n"}"
  is_uint "$n" || return 1
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  case "$u" in
    h) CW_WIN_SECONDS=$((n * 3600)) ;;
    d) CW_WIN_SECONDS=$((n * 86400)) ;;
    w) CW_WIN_SECONDS=$((n * 604800)) ;;
    *) return 1 ;;
  esac
  [ "$CW_WIN_SECONDS" -gt 0 ] 2>/dev/null || return 1   # integer overflow on an absurd N
  CW_WIN_LABEL="$w"
  CW_WIN_DAYS=$(( (CW_WIN_SECONDS + 86399) / 86400 ))
  return 0
}

cw_advise() {
  local json=0 window=24h show=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --show-thresholds) show=1 ;;
      --window)
        shift
        if [ $# -eq 0 ]; then
          printf 'claude-watch advise: --window needs a value. Accepted: 24h, week, month, or Nh/Nw/Nd. Try: claude-watch advise --window 24h\n' >&2
          return 2
        fi
        window="$1"
        ;;
      --refresh)
        printf 'claude-watch advise: advise never scans, so --refresh does nothing here. To rescan the disk: claude-watch disk --refresh\n' >&2
        return 2
        ;;
      *)
        printf 'claude-watch advise: unknown option "%s". Accepted: --window, --json, --show-thresholds. advise is read-only: it never kills, removes or scans. Try: claude-watch advise --window 24h\n' "$1" >&2
        return 2
        ;;
    esac
    shift
  done

  if ! cw_parse_window "$window"; then
    printf 'claude-watch advise: --window "%s" is not a duration. Accepted: 24h, week, month, or Nh/Nw/Nd (e.g. 6h, 2w, 14d). Try: claude-watch advise --window 24h\n' "$window" >&2
    return 2
  fi
  cw_load_thresholds || return 2
  if [ "$show" = 1 ]; then cw_show_thresholds; return 0; fi

  if [ -e "$DATA" ] && [ ! -r "$DATA" ]; then
    printf 'claude-watch advise: cannot read the data directory %s — check its permissions. Try: claude-watch doctor\n' "$DATA" >&2
    return 1
  fi

  CW_NOW=$(date +%s)
  CW_TMP=$(mktemp -d) || return 1
  trap 'rm -rf "$CW_TMP"' EXIT

  # Two clamps, both applied to the ADVERTISED window. The label keeps the
  # original ask; requested_seconds and requested_days become the window
  # actually read, so nothing downstream has to reconcile two numbers that
  # disagree, and `clamped` plus the banner name which limit bound.
  CW_CLAMPED=0; CW_CLAMP_REASON=""
  local keep_secs=$((KEEP_RAW_DAYS * 86400))
  local max_secs=$((CW_MAX_WINDOW_DAYS * 86400))
  if [ "$CW_WIN_SECONDS" -gt "$keep_secs" ]; then
    CW_CLAMPED=1
    CW_CLAMP_REASON="CLAUDE_WATCH_KEEP_DAYS (${KEEP_RAW_DAYS}d) — raw data is not retained beyond that"
    CW_WIN_SECONDS=$keep_secs; CW_WIN_DAYS=$KEEP_RAW_DAYS
  fi
  if [ "$CW_WIN_SECONDS" -gt "$max_secs" ]; then
    CW_CLAMPED=1
    CW_CLAMP_REASON="the ${CW_MAX_WINDOW_DAYS}-day reader ceiling — one run will not open more day files than that"
    CW_WIN_SECONDS=$max_secs; CW_WIN_DAYS=$CW_MAX_WINDOW_DAYS
  fi

  cw_window_pass
  cw_read_disk_cache
  cw_freshness
  cw_export_scalars

  local rows="$CW_TMP/rows"
  cw_load_analyzers
  { advise_disk; advise_leaks; } > "$rows"

  cw_render "$([ "$json" = 1 ] && printf 'advise-json' || printf 'advise-text')" "$rows" "$json"
  cw_append_log
  return 0
}

# Reads the window once and folds the M rows into shell scalars.
cw_window_pass() {
  local meta="$CW_TMP/meta" k v
  cw_read_window "$CW_WIN_SECONDS" | LC_ALL=C awk -F'\t' "$CW_WINDOW_AWK" > "$meta"
  CW_INTERVAL_SECONDS=10; CW_SAMPLES=0; CW_OBSERVED_SECONDS=0; CW_READ_SECONDS=0
  CW_NCPU=""; CW_MEMSIZE_KB=""; CW_SWAP_CAP_MB=""
  CW_WIN_LAST_EPOCH=""; CW_WIN_FIRST_EPOCH=""; CW_SCHEMA2_SINCE=""
  CW_DISORDER=0; CW_BADEP=0
  while IFS=$'\t' read -r _ k v; do
    case "$k" in
      iv)               CW_INTERVAL_SECONDS="$v" ;;
      samples)          CW_SAMPLES="$v" ;;
      observed_seconds) CW_OBSERVED_SECONDS="$v" ;;
      read_seconds)     CW_READ_SECONDS="$v" ;;
      ncpu)             CW_NCPU="$v" ;;
      memsize_kb)       CW_MEMSIZE_KB="$v" ;;
      swap_cap_mb)      CW_SWAP_CAP_MB="$v" ;;
      last_epoch)       CW_WIN_LAST_EPOCH="$v" ;;
      first_epoch)      CW_WIN_FIRST_EPOCH="$v" ;;
      schema2_since)    CW_SCHEMA2_SINCE="$v" ;;
      disorder)         CW_DISORDER="$v" ;;
      badep)            CW_BADEP="$v" ;;
    esac
  done < "$meta"

  # Both of these are U0's errors, raised for the window rather than for one day
  # file. They go to stderr so --json stdout stays clean, and exit stays 0: the
  # numbers below are short, not absent, and saying which is the point.
  if [ "${CW_DISORDER:-0}" -gt 0 ]; then
    printf 'claude-watch advise: the window has %d out-of-order sample epochs — interval and coverage may be wrong; a raw file may be truncated or interleaved\n' \
      "$CW_DISORDER" >&2
  fi
  if [ "${CW_BADEP:-0}" -gt 0 ]; then
    printf 'claude-watch advise: the window has %d sys rows whose epoch is not a plain integer of at most ten digits — the sampler writes date +%%s, so a damaged epoch means a damaged file. Those rows are excluded, so samples and observed time below are short by up to that many\n' \
      "$CW_BADEP" >&2
  fi

  # E8 — a corrupt archive is a short window, and saying so is the whole point.
  CW_FAILED_DAYS=""
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    CW_FAILED_DAYS="${CW_FAILED_DAYS:+$CW_FAILED_DAYS,}$d"
    printf 'could not read raw/%s.tsv.gz — the archive is corrupt, so this window is short by one day. Remove that file to stop the warning; the day'"'"'s data is not recoverable\n' "$d" >&2
  done < "$CW_TMP/failed-days"

  # Day accounting. Days before the sampler ever ran are E6 territory, not gaps,
  # so only holes inside the recorded era count as missing.
  cw_day_list > "$CW_TMP/all-days"
  CW_AVAIL_DAYS=$(LC_ALL=C awk 'END{print NR+0}' < "$CW_TMP/all-days")
  CW_OLDEST_DAY=$(LC_ALL=C awk 'NR==1{print; exit}' < "$CW_TMP/all-days")
  CW_COVERED_DAYS=$(LC_ALL=C awk 'END{print NR+0}' < "$CW_TMP/covered-days")
  # A day older than the oldest file that exists is not a gap — the sampler had
  # not started yet, which is E6 and the window fields, not a fault. window-days
  # is generated oldest-first, so the result needs no sort. Days whose read
  # failed are absent from covered-days and therefore land here too.
  CW_MISSING_DAYS=$(CW_OLDEST="${CW_OLDEST_DAY:-}" LC_ALL=C awk '
    FNR == NR { got[$0] = 1; next }
    {
      if (ENVIRON["CW_OLDEST"] == "" || $0 < ENVIRON["CW_OLDEST"] || ($0 in got)) next
      out = out (out == "" ? "" : ",") $0
    }
    END { print out }' "$CW_TMP/covered-days" "$CW_TMP/window-days" 2>/dev/null)
}

# Mirrors status()'s liveness definition rather than inventing a second one.
cw_freshness() {
  local latest ep
  CW_LAST_EPOCH=""; CW_LAST_AGE=""; CW_SAMPLER_OK=0
  latest=$(ls -t "$RAW"/*.tsv 2>/dev/null | head -n1)
  if [ -n "$latest" ]; then
    ep=$(tail -n1 "$latest" 2>/dev/null | cut -f1)
    is_uint "$ep" && CW_LAST_EPOCH="$ep"
  fi
  [ -z "$CW_LAST_EPOCH" ] && [ -n "$CW_WIN_LAST_EPOCH" ] && CW_LAST_EPOCH="$CW_WIN_LAST_EPOCH"
  [ -n "$CW_LAST_EPOCH" ] || return 0
  CW_LAST_AGE=$(( CW_NOW - CW_LAST_EPOCH ))
  [ "$CW_LAST_AGE" -lt 0 ] && CW_LAST_AGE=0
  [ "$CW_LAST_AGE" -lt "$CW_LIVENESS_SECONDS" ] && CW_SAMPLER_OK=1
  return 0
}

# Derived once, exported once. Two derivations of observed_seconds in one JSON
# document can disagree, so no analyzer is allowed to compute these.
cw_export_scalars() {
  export CW_INTERVAL_SECONDS CW_SAMPLES CW_OBSERVED_SECONDS CW_READ_SECONDS
  export CW_NCPU CW_MEMSIZE_KB CW_SWAP_CAP_MB CW_VOLUME_TOTAL_KB
  export CW_DISK_CACHE CW_DISK_CACHE_STATE CW_DISK_AGE CW_DISK_STALE
  # Test hook: the window fixture asserts the exports against the top-level JSON.
  if [ -n "${CW_SCALARS_OUT:-}" ]; then
    {
      printf 'CW_INTERVAL_SECONDS=%s\n' "$CW_INTERVAL_SECONDS"
      printf 'CW_SAMPLES=%s\n'          "$CW_SAMPLES"
      printf 'CW_OBSERVED_SECONDS=%s\n' "$CW_OBSERVED_SECONDS"
      printf 'CW_READ_SECONDS=%s\n'     "$CW_READ_SECONDS"
      printf 'CW_NCPU=%s\n'             "$CW_NCPU"
      printf 'CW_MEMSIZE_KB=%s\n'       "$CW_MEMSIZE_KB"
      printf 'CW_SWAP_CAP_MB=%s\n'      "$CW_SWAP_CAP_MB"
      printf 'CW_VOLUME_TOTAL_KB=%s\n'  "$CW_VOLUME_TOTAL_KB"
    } > "$CW_SCALARS_OUT"
  fi
}

cw_append_log() {
  [ -s "$CW_TMP/logline" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  cat "$CW_TMP/logline" >> "$STATE/advise.log" 2>/dev/null || true
  return 0
}

# The §9 banners. Every one is stdout-suppressed on the --json path, where the
# machine-readable equivalent travels as remedy / partial_reason /
# measurement_reasons.
cw_render() {
  local mode="$1" rows="$2" json="$3"
  local b_e3="" b_e6="" b_clamp="" b_disk=""
  if [ "$json" != 1 ]; then
    if [ "$CW_SAMPLER_OK" != 1 ] && [ -n "$CW_LAST_AGE" ]; then
      b_e3="sampler stopped — last sample $(fmt_dur "$CW_LAST_AGE") ago. CPU and memory data are not being recorded; disk and leaks below are current. Fix: claude-watch doctor"
    fi
    if [ "${CW_AVAIL_DAYS:-0}" -gt 0 ] && [ "$CW_WIN_DAYS" -gt "$CW_AVAIL_DAYS" ]; then
      b_e6="window: $CW_WIN_LABEL (${CW_WIN_DAYS}d requested, ${CW_AVAIL_DAYS}d available — the sampler has only been recording since $CW_OLDEST_DAY). Nothing to fix; the window widens as data accumulates"
    fi
    [ "${CW_CLAMPED:-0}" = 1 ] && b_clamp="window clamped to ${CW_CLAMP_REASON}"
    if [ "$CW_DISK_CACHE_STATE" = ok ] && [ "$CW_DISK_STALE" = 1 ]; then
      b_disk="disk facts are $(fmt_dur "$CW_DISK_AGE") old (refreshed every 6h) — nothing has rescanned since. For current numbers: claude-watch disk --refresh (~10s, 120s cap)"
    fi
  fi

  local wreasons=""
  [ "${CW_SAMPLES:-0}" -eq 0 ] && wreasons="no_samples"
  [ "$CW_SAMPLER_OK" != 1 ] && wreasons="${wreasons:+$wreasons,}sampler_stale"
  # A damaged epoch is a partial read of the window, so it travels as the same
  # machine-readable reason a failed decompression does. The enum in §3e is
  # closed, and silently dropping rows with no reason at all is the failure this
  # whole tool exists to prevent.
  if [ -n "$CW_FAILED_DAYS" ] || [ "${CW_BADEP:-0}" -gt 0 ]; then
    wreasons="${wreasons:+$wreasons,}window_read_failed"
  fi

  A_MODE="$mode" \
  A_NOW="$CW_NOW" \
  A_CAVEAT="$CW_CAVEAT" \
  A_WINDOW_LABEL="$CW_WIN_LABEL" \
  A_REQ_SECONDS="$CW_WIN_SECONDS" \
  A_REQ_DAYS="$CW_WIN_DAYS" \
  A_CLAMPED="${CW_CLAMPED:-0}" \
  A_AVAIL_DAYS="${CW_AVAIL_DAYS:-0}" \
  A_COVERED_DAYS="${CW_COVERED_DAYS:-0}" \
  A_MISSING_DAYS="${CW_MISSING_DAYS:-}" \
  A_READ_SECONDS="$CW_READ_SECONDS" \
  A_OBSERVED_SECONDS="$CW_OBSERVED_SECONDS" \
  A_OBSERVED_HUMAN="$(fmt_dur "$CW_OBSERVED_SECONDS")" \
  A_SAMPLES="$CW_SAMPLES" \
  A_INTERVAL="$CW_INTERVAL_SECONDS" \
  A_NCPU="$CW_NCPU" \
  A_LAST_EPOCH="$CW_LAST_EPOCH" \
  A_LAST_AGE="$CW_LAST_AGE" \
  A_SAMPLER_OK="$CW_SAMPLER_OK" \
  A_SCHEMA2_SINCE="$CW_SCHEMA2_SINCE" \
  A_WINDOW_REASONS="$wreasons" \
  A_DISK_SCAN="$(cw_disk_scan_json)" \
  A_DISK_BANNER="$b_disk" \
  A_BANNER_E3="$b_e3" \
  A_BANNER_E6="$b_e6" \
  A_BANNER_CLAMP="$b_clamp" \
  A_LOGTMP="$CW_TMP/logline" \
  A_C_HEAD="$C_HEAD" A_C_DIM="$C_DIM" A_C_KEY="$C_KEY" A_C_HOT="$C_HOT" \
  A_C_RED="$C_RED" A_C_OK="$C_OK" A_C_SEC="$C_SEC" A_C_RST="$C_RST" \
  LC_ALL=C awk "$JESC_AWK$CW_EMIT_AWK" "$rows"
}

# `disk` reads the cache. `disk --refresh` is the ONLY thing here that scans.
cw_disk() {
  local json=0 refresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)    json=1 ;;
      --refresh) refresh=1 ;;
      *) printf 'claude-watch disk: unknown option "%s". Accepted: --refresh, --json. Try: claude-watch disk --refresh\n' "$1" >&2
         return 2 ;;
    esac
    shift
  done
  cw_load_thresholds || return 2

  if [ "$refresh" = 1 ]; then
    if [ ! -f "$REPO_DIR/tools/disk-scan.sh" ]; then
      printf 'claude-watch disk: the scanner tools/disk-scan.sh is not installed, so there is nothing to refresh. Re-run install.sh, or update your checkout: git -C %s pull\n' "$REPO_DIR" >&2
      return 1
    fi
    bash "$REPO_DIR/tools/disk-scan.sh" || return $?
  fi

  CW_NOW=$(date +%s)
  CW_TMP=$(mktemp -d) || return 1
  trap 'rm -rf "$CW_TMP"' EXIT

  CW_WIN_LABEL="-"; CW_WIN_SECONDS=0; CW_WIN_DAYS=0; CW_CLAMPED=0; CW_CLAMP_REASON=""
  CW_INTERVAL_SECONDS=10; CW_SAMPLES=0; CW_OBSERVED_SECONDS=0; CW_READ_SECONDS=0
  CW_NCPU=""; CW_MEMSIZE_KB=""; CW_SWAP_CAP_MB=""; CW_SCHEMA2_SINCE=""
  CW_WIN_LAST_EPOCH=""; CW_FAILED_DAYS=""
  cw_read_disk_cache
  cw_freshness
  cw_export_scalars

  CW_AVAIL_DAYS=0; CW_COVERED_DAYS=0; CW_MISSING_DAYS=""; CW_OLDEST_DAY=""
  local rows="$CW_TMP/rows"
  cw_load_analyzers
  advise_disk > "$rows"

  cw_render "$([ "$json" = 1 ] && printf 'disk-json' || printf 'disk-text')" "$rows" "$json"
  return 0
}
