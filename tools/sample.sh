#!/usr/bin/env bash
# One sampling pass. launchd runs this on a StartInterval, so nothing stays
# resident between samples — there is no daemon to leak, which matters for a
# tool whose whole job is noticing leaked processes.
#
# Writes append-only TSV facts. All aggregation happens at report time, so the
# report logic can change without re-collecting data.
set -u

DATA="${CLAUDE_WATCH_HOME:-$HOME/.claude-watch}"
RAW="$DATA/raw"
STATE="$DATA/state"
FLOOR="${CLAUDE_WATCH_FLOOR:-5}"            # %CPU of one core; below this, machine-wide rows are noise
MEMFLOOR="${CLAUDE_WATCH_MEMFLOOR:-409600}" # RSS in KB (400M); catches idle memory hogs the CPU floor misses
TOPN="${CLAUDE_WATCH_TOPN:-8}"              # cap on machine-wide rows per sample

# What counts as a leaked dev process lives in one file, shared with the
# `claude-watch orphans` killer so the two can never disagree.
POLICY="$(dirname "${BASH_SOURCE[0]:-$0}")/orphan-policy.sh"
# shellcheck source=orphan-policy.sh
. "$POLICY" || { echo "claude-watch: cannot read $POLICY" >&2; exit 1; }
ORPHAN_MIN="${CLAUDE_WATCH_ORPHAN_MIN:-$ORPHAN_MIN_DEFAULT}"  # unparented dev processes older than this are flagged

mkdir -p "$RAW" "$STATE/cwd" "$STATE/label" || exit 1

now=$(date +%s)
out="$RAW/$(date +%F).tsv"

# `time=` is cumulative CPU time. %cpu is a decaying average over up to a
# minute of previous real time, so it can only ever estimate what a process
# burned; the cumulative counter, differenced between samples, is exact.
snap=$(ps -Ao pid=,ppid=,pcpu=,rss=,etime=,time=,args= 2>/dev/null) || exit 0
[ -n "$snap" ] || exit 0

# $7 is the first token of the command line. Do NOT parse by leading characters:
# ps right-pads the pid column, so a fixed-offset parse silently drops sessions
# whose pid is narrower than the widest pid on the machine.
roots=$(printf '%s\n' "$snap" | awk '{ n = $7; sub(/.*\//, "", n); if (n == "claude") print $1 }')

# --- resolve cwd + tab label once per session, then cache by pid ---
# Neither changes for a live pid, and lsof is the expensive part of a sample.
for p in $roots; do
  [ -f "$STATE/cwd/$p" ] && continue
  cwd=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1)
  [ -n "$cwd" ] || cwd="?"
  printf '%s' "$cwd" > "$STATE/cwd/$p"

  # cwd -> project slug -> the one transcript written recently. Claude holds no
  # open handle on its transcript, so this is the only way to map pid->session.
  # Ambiguous cases resolve to no label rather than a wrong one.
  label=""
  slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
  proj="$HOME/.claude/projects/$slug"
  if [ -d "$proj" ]; then
    hits=$(find "$proj" -maxdepth 1 -name '*.jsonl' -mmin -5 2>/dev/null)
    if [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ]; then
      id=$(basename "$hits" .jsonl)
      label=$(head -n1 "$HOME/.claude/session-labels/$id.txt" 2>/dev/null \
              | LC_ALL=C tr -d '\000-\037\177' | tr '\t' ' ')
    fi
  fi
  printf '%s' "$label" > "$STATE/label/$p"
done

# Drop cache entries for sessions that have exited, so state does not grow.
for f in "$STATE"/cwd/* "$STATE"/label/*; do
  [ -e "$f" ] || continue
  pid=$(basename "$f")
  kill -0 "$pid" 2>/dev/null || rm -f "$f"
done

# --- system totals ---
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
ncpu=$(sysctl -n hw.ncpu 2>/dev/null)
sys=$(vm_stat 2>/dev/null | awk -v ps="$(sysctl -n hw.pagesize)" \
        -v total="$(sysctl -n hw.memsize)" -v swap="$(sysctl -n vm.swapusage)" '
  /Anonymous pages/              { anon = $3 }
  /Pages wired down/             { wired = $4 }
  /Pages occupied by compressor/ { comp = $5 }
  /Pages purgeable/              { purge = $3 }
  /Pages free/                   { free = $3 }
  /Pages speculative/            { spec = $3 }
  # Since-boot cumulative counters, recorded raw and differenced by the reader.
  # These two lines have NF=2, so they are matched by name — reading them out of
  # a column of the page table above would silently record 0.
  /^Pageins/                     { pgin = $2 }
  /^Pageouts/                    { pgout = $2 }
  END {
    gsub(/\./, "", anon); gsub(/\./, "", wired); gsub(/\./, "", comp)
    gsub(/\./, "", purge); gsub(/\./, "", free); gsub(/\./, "", spec)
    gsub(/\./, "", pgin); gsub(/\./, "", pgout)
    split(swap, s, /[ =M]+/)
    for (i = 1; i <= 20; i++) if (s[i] == "used")  { swu = s[i+1]; break }
    for (i = 1; i <= 20; i++) if (s[i] == "total") { swt = s[i+1]; break }
    # Machine capacities are recorded per sample rather than looked up when the
    # data is read: a window can predate a RAM or swap-config change here.
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d", \
      (anon - purge + wired + comp) * ps / 1024, (free + spec) * ps / 1024, swu + 0, \
      pgin + 0, pgout + 0, total / 1024, swt + 0
  }')

metafile=$(mktemp) || exit 1
snapfile=$(mktemp) || { rm -f "$metafile"; exit 1; }
trap 'rm -f "$metafile" "$snapfile"' EXIT
printf '%s\n' "$snap" > "$snapfile"
for p in $roots; do
  printf '%s\t%s\t%s\n' "$p" "$(cat "$STATE/cwd/$p" 2>/dev/null)" "$(cat "$STATE/label/$p" 2>/dev/null)" >> "$metafile"
done

LC_ALL=C awk -v NOW="$now" -v FLOOR="$FLOOR" -v TOPN="$TOPN" -v OM="$ORPHAN_MIN" \
             -v MATCH="$ORPHAN_MATCH_RE" -v EXCL="$ORPHAN_EXCLUDE_RE" \
             -v MEMFLOOR="$MEMFLOOR" -v META="$metafile" -v SNAP="$snapfile" -v SYS="$sys" -v LOAD="$load" -v NCPU="$ncpu" '
  function esec(e,   a, b, d, n, h, m) {
    d = 0
    if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
    n = split(e, b, ":")
    if (n == 3) { h = b[1]; m = b[2] } else { h = 0; m = b[1]; b[3] = b[2] }
    return d * 86400 + h * 3600 + m * 60 + b[3]
  }
  function name(a,   n, parts, i, nw) {
    if (a ~ /\.app\/Contents\/MacOS\//) { n = a; sub(/.*\/Contents\/MacOS\//, "", n); sub(/ -.*/, "", n) }
    else { n = a; sub(/ .*/, "", n); sub(/.*\//, "", n) }
    if (n ~ /^\(.*\)$/) { sub(/^\(/, "", n); sub(/\)$/, "", n) }   # ps parenthesises an unreadable argv
    if (n ~ /^chrome-headless/) n = "chrome-headless-shell"
    if (a ~ /(-mcp|mcp-server|modelcontextprotocol)/) {
      nw = split(a, parts, /[ \/]+/)
      for (i = nw; i >= 1; i--) if (parts[i] ~ /mcp/) return "mcp " parts[i]
    }
    if (a ~ / --test( |$)/) n = n " --test"
    return n
  }
  function subcpu(p,   i, s) { s = cpu[p]; for (i = 1; i <= nk[p]; i++) s += subcpu(kid[p, i]); return s }
  function subrss(p,   i, s) { s = rss[p]; for (i = 1; i <= nk[p]; i++) s += subrss(kid[p, i]); return s }
  function mark(p, r,   i) { owner[p] = r; for (i = 1; i <= nk[p]; i++) mark(kid[p, i], r) }
  function clean(s) { gsub(/\t/, " ", s); return s }

  BEGIN {
    OFS = "\t"
    while ((getline line < META) > 0) {
      split(line, m, "\t"); isroot[m[1]] = 1; cwd[m[1]] = m[2]; tab[m[1]] = m[3]
    }
    close(META)

    while ((getline line < SNAP) > 0) {
      if (line == "") continue
      split(line, f, " ")
      p = f[1]; a = line
      for (i = 1; i <= 6; i++) sub(/^ *[^ ]+ +/, "", a)
      par[p] = f[2]; cpu[p] = f[3]; rss[p] = f[4]; secs[p] = esec(f[5])
      ctime[p] = esec(f[6])
      args[p] = a; seen[p] = 1
      if (p != 1) { nk[f[2]]++; kid[f[2], nk[f[2]]] = p }
    }
    close(SNAP)

    for (p in isroot) mark(p, p)

    # System row: always emitted, so the report knows the machine was awake.
    # $9 is the schema version and never moves: a sys row with NF == 8 is
    # schema 1, the era when every CPU number was a %cpu estimate.
    split(SYS, sv, "\t")
    print NOW, "sys", "-", LOAD, sv[1], sv[2], sv[3], NCPU, 2, sv[4], sv[5], sv[6], sv[7]

    # Session rows: always emitted even at 0%, so the report can compute how
    # long each session was alive, not just when it was busy.
    #
    # Deliberately no cumulative CPU here: a session row is a whole-tree
    # roll-up, and a tree cumulative drops by the whole lifetime of a departing
    # child the moment it exits, so a delta between two samples can go sharply
    # negative for a session that was in fact busy. %cpu sees that work.
    for (p in isroot) {
      hot = ""; hotc = -1
      for (q in owner) {
        if (owner[q] != p || q == p) continue
        if (cpu[q] > hotc) { hotc = cpu[q]; hot = name(args[q]) }
      }
      detail = (hotc > 0) ? sprintf("%s@%.1f", hot, hotc / 100) : "-"
      print NOW, "session", clean(cwd[p]), sprintf("%.2f", subcpu(p) / 100), subrss(p), \
            clean(detail) "\t" clean(tab[p])
    }

    # Machine-wide, outside every Claude tree. Ranked by CPU *and* separately by
    # memory: a CPU-only floor never records Firefox sitting at 1.0G and 0.0%,
    # which is precisely the kind of steady burn worth seeing in a daily report.
    n = 0; mn = 0
    for (p in seen) {
      if (owner[p] != "" || p == 0) continue
      if (cpu[p] >= FLOOR) hp[++n] = p
      if (rss[p] >= MEMFLOOR) mp[++mn] = p
    }
    for (i = 1; i < n; i++) for (k = i + 1; k <= n; k++)
      if (cpu[hp[k]] > cpu[hp[i]]) { t = hp[i]; hp[i] = hp[k]; hp[k] = t }
    for (i = 1; i < mn; i++) for (k = i + 1; k <= mn; k++)
      if (rss[mp[k]] > rss[mp[i]]) { t = mp[i]; mp[i] = mp[k]; mp[k] = t }
    for (i = 1; i <= n && i <= TOPN; i++) {
      p = hp[i]; emitted[p] = 1
      print NOW, "proc", clean(name(args[p])), sprintf("%.2f", cpu[p] / 100), rss[p], p, \
            sprintf("%.2f", ctime[p])
    }
    for (i = 1; i <= mn && i <= TOPN; i++) {
      p = mp[i]
      if (emitted[p]) continue
      print NOW, "proc", clean(name(args[p])), sprintf("%.2f", cpu[p] / 100), rss[p], p, \
            sprintf("%.2f", ctime[p])
    }

    # Orphans: dev tooling reparented to launchd. Whatever started it is gone,
    # but it still holds memory, ports and file handles.
    for (p in seen) {
      if (par[p] != 1 || owner[p] != "" || secs[p] < OM * 60) continue
      if (args[p] !~ MATCH) continue
      if (args[p] ~ EXCL) continue
      print NOW, "orphan", clean(name(args[p])), sprintf("%.2f", subcpu(p) / 100), subrss(p), secs[p]
    }
  }' >> "$out"
