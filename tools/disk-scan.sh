#!/usr/bin/env bash
# The disk scanner: measures what is reclaimable and writes the disk facts TSV
# that `claude-watch advise` reads. Standalone on purpose — CLAUDE_WATCH_REPO_ROOTS
# and CLAUDE_WATCH_DISK_CACHE are honoured so a fixture can point it at a
# synthetic tree, and so the analyzer can be tested against a hand-written cache
# with no real disk involved.
#
# Discovery is one bounded, single-volume `find` per configured repo root, plus a
# kind table of directories whose kind is known from the path (Downloads,
# Library/Caches, Library/Containers, the .claude/.codex transcript dirs,
# Library/Developer), measured by ONE bounded $HOME sweep (`du -kxd 4`, one
# volume) rather than a separate `du` per entry. The sweep runs LAST, after the
# repo roots, so they keep first claim on the deadline budget, and it is skipped
# entirely once the deadline has passed. Everything the sweep sees that is not
# under a kind-table path is an unattributed residual (see step 4b's `cover`
# row) — never folded into a group. A denial inside the sweep affects only the
# kind-table group whose path it names, never the whole scan (:41-49); only a
# denial that names no recoverable path, or a sweep that fails with no stderr at
# all, affects every group the sweep feeds.
#
# Output contract (five tab-separated columns, see the plan §3c):
#   epoch  -           <unix>          -                -
#   scan   <partial>   <deadline_hit>  <roots_scanned>  <roots_total>
#   note   <reason>    <count>         -                -
#   vol    <mount>     <used_kb>       <avail_kb>       <df_size_kb>
#   cover  home        <home_total_kb> <attributed_kb>  <complete>
#   group  <label>     <size_kb>       <dir_count>      <affected>
#   dir    <path>      <size_kb>       <group_label>    <confidence>
#
# The `cover` row is what keeps a coverage gap from being silent: `home_total_kb`
# is the sweep's own $HOME row and `attributed_kb` the sum of the group totals
# below it, so "how much of $HOME does any group account for" is a number this
# tool has to state. Both are MEASUREMENTS, never a difference: the reader
# subtracts, which is why an over-count cannot be clamped here into a figure the
# cache would present as a fact. A number this run did not measure is written
# `-`, like the vol row's df_size_kb — a sweep that never ran writes
# `cover  home  -  -  0`. `complete=0` (the sweep was skipped, killed, exited
# non-zero, printed no $HOME row, or hit a denial outside every kind-table entry)
# always travels with a `note coverage_incomplete <n>`, n >= 1, and partial=1.
#
# `scan partial` and `group affected` answer two different questions and must not
# be collapsed. `partial=1` means the scan AS A WHOLE was less than total, and it
# drives the summary banner. `affected=1` means THAT GROUP's own measurement was
# short — a denial under one of its paths, an unrepresentable path dropped from
# it, an off-volume root that could have fed it, or the deadline — and it is what
# gates severity capping. On a Mac without Full Disk Access every scan is partial
# because ~/Library/Caches denies reads; that says nothing about whether ~/Dev
# was measured completely, and it must not mute the finding that answers the
# user's actual question.
#
# The one volume denominator is used_kb + avail_kb. df's Size column is the APFS
# container, which includes space this volume cannot claim; it is recorded as
# df_size_kb and never divided by.
set -u
export LC_ALL=C

DATA="${CLAUDE_WATCH_HOME:-$HOME/.claude-watch}"
STATE="$DATA/state"
CACHE="${CLAUDE_WATCH_DISK_CACHE:-$STATE/disk.tsv}"
ROOTS="${CLAUDE_WATCH_REPO_ROOTS:-$HOME/Dev}"
# CLAUDE_WATCH_DISK_DEADLINE is a TEST HOOK, not a user knob: the fixtures cannot
# spend 120s proving the deadline fires. It is deliberately undocumented — do not
# put it in the README or the usage text.
DEADLINE="${CLAUDE_WATCH_DISK_DEADLINE:-120}"
GRACE=3                                          # TERM -> KILL delay for the walk
MAXDEPTH=4
IDLE_DAYS=14
# The boundary convention, shared with the analyzer: an entry whose mtime lands
# EXACTLY on the 14-day cutoff counts as ACTIVE, not idle. `find -newer` is
# strict, so the reference stamp is placed a second BEFORE the cutoff to make
# that so. The two sides must agree: if the scanner calls exact-cutoff idle and
# the analyzer calls it active, the cache says `confirmed` and the analyzer
# silently downgrades it at print time, which reads as a bug in both.
IDLE_SLACK=1
# TEST HOOK, not a user knob (epoch seconds): the cutoff is 14 days before the
# run, so a fixture cannot otherwise place a file exactly on a moving boundary.
# Deliberately undocumented — do not put it in the README or the usage text.
IDLE_CUTOFF="${CLAUDE_WATCH_DISK_IDLE_CUTOFF:-}"
TOPN=20                                          # dir rows kept per group
LOCK="$STATE/disk-scan.lock"
LOCK_STALE=150                                   # seconds before a lock may be broken

TAB=$'\t'
NL=$'\n'

# ------------------------------------------------------------------ messages --
# §9 E7. A failed write must never be swallowed into a silently retained stale
# cache: the reader would go on presenting last week's numbers as today's.
die_write() {
  printf 'claude-watch disk: could not write %s — the volume is 95%% full or the path is read-only. The previous cache is unchanged and is now stale. Free space, then re-run: claude-watch disk --refresh\n' "$CACHE" >&2
  exit 1
}

human_age() {  # <seconds> -> 45m / 3h / 2d
  local s=$1
  if   [ "$s" -lt 3600 ];   then printf '%dm' "$(( s / 60 ))"
  elif [ "$s" -lt 172800 ]; then printf '%dh' "$(( s / 3600 ))"
  else                           printf '%dd' "$(( s / 86400 ))"
  fi
}

# §9 E11. The loser of the lock NEVER scans — two concurrent scans would fight
# over the same disk and neither would finish inside the deadline.
lose_lock() {
  local mt now
  if [ -f "$CACHE" ]; then
    mt=$(stat -f %m "$CACHE" 2>/dev/null || printf '0')
    now=$(date +%s)
    printf 'another disk scan is already running — using the cached facts from %s ago. Re-run in a minute for fresh numbers.\n' \
      "$(human_age $(( now - mt )))" >&2
  else
    printf 'another disk scan is already running — nothing cached yet; re-run in a minute.\n' >&2
  fi
  exit 0
}

# ---------------------------------------------------------------------- lock --
# mkdir is the arbiter because it is atomic on APFS. `[ -f ] && touch` is TOCTOU:
# both runs lose the race and both proceed.
lock_held=0
MY_OWNER=""

# A pid is not an identity: pids are recycled, and a recycled one answers kill -0
# forever, so an age-plus-liveness breaker would never fire and every later run
# would silently serve a stale cache with no symptom. The process start time
# pins WHICH process that pid is.
#
# Residual, stated rather than hidden: lstart has one-second resolution, so a pid
# recycled onto a process started in the SAME second as the dead owner still
# collides. That needs a pid to wrap all the way around inside one second; the
# consequence is a lock held one cycle too long, not a second scanner.
#
# `claude-watch doctor` reads the file this writes and must derive the identity
# byte-identically — both run under LC_ALL=C, because `ps lstart` is
# locale-formatted and a differently-spelled month would read as a dead owner.
proc_ident() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

# $LOCK/pid carries BOTH facts, written as ONE file so it can never be observed
# half-written: line 1 the pid, line 2 the identity that pins it. Two separate
# writes had a window in which a stalled owner looked metadata-less, and a
# contender past the age limit would then break a LIVE owner's lock.
take_lock() {
  local ident tmpf="$LOCK/.owner.$$"
  ident=$(proc_ident "$$")
  MY_OWNER=$(printf '%s\n%s\n' "$$" "$ident")
  lock_held=1
  # Composed in the lock directory, then renamed into place: same directory, so
  # the rename is atomic, and a reader sees either no file or the whole thing.
  printf '%s\n%s\n' "$$" "$ident" > "$tmpf" 2>/dev/null &&
    mv "$tmpf" "$LOCK/pid" 2>/dev/null
}

acquire_lock() {
  mkdir -p "$STATE" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then
    # take_lock can fail to write or rename $LOCK/pid (a full or read-only
    # volume, the same fault die_write exists for) even though mkdir just
    # succeeded. Reporting success here would leave an ownerless lock: nothing
    # in it says who holds it, so a live scan and a crashed one look identical
    # to every later run. Same failure class as `[ -d "$LOCK" ] || die_write`
    # below — treat it the same way, and remove the lock we just took so a
    # write failure does not also wedge every later run behind it.
    if take_lock; then
      return 0
    fi
    lock_held=0
    rm -rf "$LOCK" 2>/dev/null
    die_write
  fi
  # Could not create it AND it does not exist: $STATE is not writable, which is
  # a cache-write failure, not a contended lock.
  [ -d "$LOCK" ] || die_write

  # The stale breaker needs BOTH tests. Age alone lets two runs break the same
  # lock and both proceed; a liveness test alone leaves a kill -9'd owner's lock
  # in place forever, after which every run silently serves a stale cache.
  local lpid lid lmt age stash
  lpid=$(sed -n 1p "$LOCK/pid" 2>/dev/null)
  lid=$(sed -n 2p "$LOCK/pid" 2>/dev/null)
  lmt=$(stat -f %m "$LOCK" 2>/dev/null || printf '0')
  age=$(( $(date +%s) - lmt ))
  [ "$age" -gt "$LOCK_STALE" ] || return 1

  # Breaking a live owner's lock is the worse error of the two: it puts two
  # scanners on the same disk. So anything short of positive evidence of death
  # keeps the lock. A live pid whose recorded identity is missing or unreadable
  # is treated as LIVE — only a live pid that demonstrably belongs to a
  # DIFFERENT process than the one that took the lock counts as recycled.
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    [ -n "$lid" ] || return 1                          # incomplete metadata: live
    [ "$(proc_ident "$lpid")" = "$lid" ] && return 1   # same process: live
  fi

  # Break by rename, not by rm: only one of two racing breakers can rename the
  # same directory away, so the winner is decided before either re-creates it.
  stash="$LOCK.stale.$$"
  mv "$LOCK" "$stash" 2>/dev/null || return 1
  rm -rf "$stash" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || return 1
  if take_lock; then
    return 0
  fi
  lock_held=0
  rm -rf "$LOCK" 2>/dev/null
  die_write
}

# Release only what we still own. A lock we took, lost to a breaker, and then
# blindly `rm -rf`'d would be the REPLACEMENT's lock — after which the breaker
# and the next run both scan. Deleting nothing is always the safe answer here:
# an over-held lock expires, a wrongly deleted one puts two scanners on the disk.
release_lock() {
  [ "$lock_held" = 1 ] || return 0
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$MY_OWNER" ] || return 0
  rm -rf "$LOCK" 2>/dev/null
  return 0
}

worker=""
tmp=""
WORK=""
# Ctrl-C mid-scan must leave no temp file, no work directory and no lock —
# otherwise the next run finds an orphaned lock and refuses for 150s.
tmp_cleanup() {
  [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null && kill -KILL -"$worker" 2>/dev/null
  [ -n "$tmp" ]    && rm -f "$tmp"
  [ -n "$WORK" ]   && rm -rf "$WORK"
  release_lock
  return 0
}
trap 'tmp_cleanup' EXIT
trap 'tmp_cleanup; exit 130' INT TERM

acquire_lock || lose_lock

# ------------------------------------------------------------------ workspace --
# Everything lives beside the cache, on the cache's own volume: a temp file on
# another volume turns the final mv from a rename into a copy, which is neither
# atomic nor guaranteed to fit on a full disk.
CACHE_DIR=$(dirname "$CACHE")
mkdir -p "$CACHE_DIR" 2>/dev/null
WORK="$STATE/disk-scan.work.$$"
mkdir -p "$WORK" 2>/dev/null || die_write
RAWOUT="$WORK/raw"
ERRLOG="$WORK/err"
CLAIM="$WORK/claimed"
REF="$WORK/ref"
: > "$RAWOUT" 2>/dev/null || die_write
: > "$ERRLOG"
: > "$CLAIM"
printf '%s' "$ROOTS" | tr ':' '\n' | grep -v '^$' > "$WORK/roots"
roots_total=$(wc -l < "$WORK/roots" | tr -d ' ')

START=$(date +%s)
HOMEDEV=$(stat -f %d "$HOME" 2>/dev/null || printf '')

# One reference file, so the idle test is a single find per hit instead of a
# stat over every child. It is stamped IDLE_SLACK seconds before the cutoff, so
# an entry sitting exactly on the cutoff is newer than it and reads as active.
[ -n "$IDLE_CUTOFF" ] || IDLE_CUTOFF=$(date -v-${IDLE_DAYS}d +%s)
touch -t "$(date -r $(( IDLE_CUTOFF - IDLE_SLACK )) +%Y%m%d%H%M.%S)" "$REF" 2>/dev/null

past_deadline() { [ $(( $(date +%s) - START )) -ge "$DEADLINE" ]; }

physdir() { ( cd -P -- "$1" 2>/dev/null && pwd -P ); }

group_of() {  # <basename> -> group label
  case "$1" in
    node_modules) printf 'node_modules' ;;
    *)            printf 'rebuildable' ;;
  esac
}

# Two independent tests, per §3c. A directory matched on NAME ALONE gets no
# removal command, ever — a hand-made `venv` of notes and a source directory
# called `target` both exist in the wild.
confidence_of() {  # <path> <basename> <group>
  local p=$1 base=$2 grp=$3 parent marker=0 idle=0 g newer nrc
  parent=${p%/*}
  case "$base" in
    node_modules|.next) [ -f "$parent/package.json" ] && marker=1 ;;
    target)             { [ -f "$parent/Cargo.toml" ] || [ -f "$parent/pom.xml" ]; } && marker=1 ;;
    .venv|venv)         [ -f "$p/pyvenv.cfg" ] && marker=1 ;;
    DerivedData)        for g in "$parent"/*.xcodeproj "$parent"/*.xcworkspace; do
                          [ -e "$g" ] && { marker=1; break; }
                        done ;;
  esac
  # The probe is RECURSIVE, not depth-1. `node_modules/pkg/lib/active.js` written
  # this morning inside a `pkg` directory whose own mtime is months old is a
  # directory in active use, and a depth-1 probe calls it idle — which is exactly
  # the promotion the confidence gate exists to prevent.
  #
  # Cost, measured over the 37 real hits under ~/Dev rather than guessed:
  # depth-1 0.11s, recursive 6.94s, worst single hit 0.80s. `-quit` makes the
  # active case cheap (it stops at the first fresh file); only genuinely idle
  # trees are walked in full, and the 120s deadline covers the pathological one.
  #
  # The probe must also SUCCEED to count. A find that failed on permissions
  # prints nothing too, and reading that silence as "nothing newer than 14 days"
  # is how a directory nobody could inspect earns a removal command. No reference
  # file, or a failed probe, means no idle evidence — and idle plus a marker is
  # the only thing that authorises a printed `rm -rf`.
  newer=$(find "$p" -xdev -mindepth 1 -newer "$REF" -print -quit 2>>"$ERRLOG"); nrc=$?
  if [ -f "$REF" ] && [ "$nrc" = 0 ] && [ -z "$newer" ]; then idle=1; fi
  [ "$nrc" = 0 ] || affect "$grp"
  if   [ "$marker" = 1 ] && [ "$idle" = 1 ]; then printf 'confirmed'
  elif [ "$marker" = 1 ];                    then printf 'likely'
  else                                            printf 'unverified'
  fi
}

# --------------------------------------------------------------------- walk --
# Runs in a background subshell, so every result travels back through $RAWOUT as
# it lands and a killed walk still yields what it had measured:
#   H <group> <size_kb> <confidence> <path>   a measured directory
#   T <group> <size_kb>                       a kind-table entry's own sweep
#                                              total — worker-only, NEVER written
#                                              to the cache; assembly prefers it
#                                              over that group's summed H rows
#   A <group>                                 THAT group's measurement is short
#   C <home_kb|-> <complete> <count> <inhome> the sweep's own $HOME total and
#                                              whether anything left the coverage
#                                              figure short — the `cover` row's
#                                              measurements; absent when the
#                                              sweep never ran
#   S                                         a repo root finished
#   V                                         a root skipped: other volume
#   U                                         a path a TSV cannot carry
#   D                                         the walk stopped on its own clock
#
# `A` is deliberately per group and separate from the global `partial`: a TCC
# denial under ~/Library/Containers says nothing about whether ~/Dev was measured
# completely, and muting the one finding that answers the user's question because
# an unrelated group was unreadable is exactly the failure to avoid.
affect() { printf 'A\t%s\n' "$1" >> "$RAWOUT"; }

measure() {  # <file of newline-delimited paths> — one batched du for the lot
  local f=$1 size path base grp conf drc berr="$WORK/berr" dout="$WORK/dout"
  [ -s "$f" ] || return 0
  : > "$berr"
  # Discovery is NUL-delimited so a path with a space or a `;` survives; the
  # paths in $f have already been filtered to those a TSV can carry.
  # du runs to a FILE, not into a pipe, so its exit status is readable: in a
  # pipeline the status belongs to the reader and a non-zero du disappears.
  tr '\n' '\0' < "$f" | xargs -0 du -skx > "$dout" 2>"$berr"
  drc=$?
  while IFS="$TAB" read -r size path; do
    [ -n "${path:-}" ] || continue
    base=${path##*/}
    grp=$(group_of "$base")
    conf=$(confidence_of "$path" "$base" "$grp")
    printf 'H\t%s\t%s\t%s\t%s\n' "$grp" "$size" "$conf" "$path" >> "$RAWOUT"
  done < "$dout"
  # A non-zero du that printed nothing to stderr is still a short measurement.
  if [ "$drc" != 0 ] && [ ! -s "$berr" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      affect "$(group_of "${path##*/}")"
    done < "$f"
  fi
  [ -s "$berr" ] || return 0
  cat "$berr" >> "$ERRLOG"
  # A batched du mixes groups, so attribute each error to the hit that contains
  # the path it names — a denial under one node_modules must not mark every
  # `target` in the same repo root as unmeasured.
  CW_KEPT="$f" CW_ERR="$berr" awk '
    BEGIN {
      n = 0
      while ((getline l < ENVIRON["CW_KEPT"]) > 0) pre[++n] = l
      while ((getline e < ENVIRON["CW_ERR"]) > 0) {
        sub(/^[a-z]+: /, "", e)      # du: <path>: Permission denied
        sub(/: [^:]*$/, "", e)
        hit = ""
        for (i = 1; i <= n; i++) {
          if (e == pre[i] || index(e, pre[i] "/") == 1) { hit = pre[i]; break }
        }
        # An error we cannot attribute taints the whole batch: better to
        # understate one group than to claim a completeness we do not have.
        if (hit == "") { for (i = 1; i <= n; i++) print pre[i] } else print hit
      }
    }' | sort -u > "$WORK/aff"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    affect "$(group_of "${path##*/}")"
  done < "$WORK/aff"
}

walk() {
  local root rp dev p i frc relp rest grp dep

  # Register the kind table as claimed prefixes BEFORE the roots, so that
  # CLAUDE_WATCH_REPO_ROOTS=$HOME cannot count a hit under ~/Library/Containers
  # twice — once in its own group and once inside the containers total. Each
  # entry is <relpath-from-$HOME>:<group>:<detail_depth>: depth 0 means the
  # whole directory is one measurement; depth > 0 means the entry ALSO gets a
  # descendant row per child at exactly that depth (Library/Developer needs its
  # immediate grandchildren — CoreSimulator/Devices, Xcode/DerivedData — broken
  # out, not folded into one opaque total).
  : > "$WORK/entries"
  for i in "Downloads:downloads:0" \
           "Library/Caches:caches:0" \
           "Library/Containers:containers:0" \
           ".claude/projects:transcripts:0" \
           ".codex/sessions:transcripts:0" \
           "Library/Developer:developer:2"; do
    relp=${i%%:*}
    rest=${i#*:}
    grp=${rest%%:*}
    dep=${rest#*:}
    p="$HOME/$relp"
    [ -d "$p" ] || continue
    rp=$(physdir "$p") || continue
    [ -n "$rp" ] || continue
    case "$rp" in *"$TAB"*|*"$NL"*) printf 'U\n' >> "$RAWOUT"; affect "$grp"; continue ;; esac
    dev=$(stat -f %d "$rp" 2>/dev/null)
    if [ -n "$HOMEDEV" ] && [ "$dev" != "$HOMEDEV" ]; then
      printf 'V\n' >> "$RAWOUT"; affect "$grp"; continue
    fi
    printf '%s\n' "$rp" >> "$CLAIM"
    printf '%s\t%s\t%s\n' "$rp" "$grp" "$dep" >> "$WORK/entries"
  done

  # --- configured repo roots ---
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    # The cheap between-batch clock check: an early exit that costs nothing.
    # It cannot replace the parent's deadline — the case the deadline exists for
    # is a single find blocked on a mount, where this line is never reached.
    if past_deadline; then printf 'D\n' >> "$RAWOUT"; return 0; fi
    if [ ! -d "$root" ]; then printf 'S\n' >> "$RAWOUT"; continue; fi
    # A mode-000 root passes `[ -d ]` — the test only stats it — and then fails
    # to resolve. Recording that as "scanned" reports affected=0 on a group whose
    # measurement is missing whatever that root held, and affected=0 on an
    # incomplete number is what tells the reader a short total is trustworthy.
    # A root we could not enter is an UNATTRIBUTABLE failure: neither repo group
    # may still claim to be complete, and the root does not count as scanned.
    rp=$(physdir "$root")
    if [ -z "$rp" ]; then affect node_modules; affect rebuildable; continue; fi
    # `du -x` does not reject a root that STARTS on another volume, and sizes
    # from another volume are not comparable against this volume's total.
    dev=$(stat -f %d "$rp" 2>/dev/null)
    if [ -n "$HOMEDEV" ] && [ "$dev" != "$HOMEDEV" ]; then
      # A skipped root could have held either kind of hit, so neither repo group
      # may still claim to be complete.
      printf 'V\n' >> "$RAWOUT"; affect node_modules; affect rebuildable; continue
    fi

    # -xdev on the FIND, not just -x on the du: without it find descends the
    # network mount long before du is ever reached, which is the whole failure.
    find "$rp" -maxdepth "$MAXDEPTH" -xdev -type d \
      \( -name node_modules -o -name .venv -o -name venv -o -name target \
         -o -name .next -o -name DerivedData \) -prune -print0 \
      > "$WORK/hits" 2>"$WORK/ferr"
    frc=$?
    # Exit status AND stderr: a walk can come back non-zero having printed
    # nothing, and a silently partial discovery has the same unsafe result as a
    # noisy one. A directory discovery could not read might have held either kind.
    if [ "$frc" != 0 ] || [ -s "$WORK/ferr" ]; then
      cat "$WORK/ferr" >> "$ERRLOG"; affect node_modules; affect rebuildable
    fi

    # du's OUTPUT is newline-delimited and tab-separated, so a path containing a
    # tab or a newline corrupts the cache no matter how careful discovery was.
    # Partition: representable paths are measured, the rest are counted only.
    : > "$WORK/cand"
    while IFS= read -r -d '' p; do
      case "$p" in
        *"$TAB"*|*"$NL"*) printf 'U\n' >> "$RAWOUT"; affect "$(group_of "${p##*/}")"; continue ;;
      esac
      printf '%s\n' "$p" >> "$WORK/cand"
    done < "$WORK/hits"

    # Drop any candidate that is already inside something claimed, so nested
    # roots and the shortlist cannot be summed twice.
    CW_CAND="$WORK/cand" CW_CLAIM="$CLAIM" awk '
      BEGIN {
        n = 0
        while ((getline line < ENVIRON["CW_CLAIM"]) > 0) { pre[++n] = line }
        close(ENVIRON["CW_CLAIM"])
        while ((getline line < ENVIRON["CW_CAND"]) > 0) {
          drop = 0
          for (i = 1; i <= n; i++) {
            if (line == pre[i] || index(line, pre[i] "/") == 1) { drop = 1; break }
          }
          if (!drop) { pre[++n] = line; print line }
        }
        close(ENVIRON["CW_CAND"])
      }' > "$WORK/kept" 2>>"$ERRLOG"
    cat "$WORK/kept" >> "$CLAIM"

    measure "$WORK/kept"
    printf 'S\n' >> "$RAWOUT"
  done < "$WORK/roots"

  # --- one $HOME sweep, run last so the repo roots get first claim on the
  # deadline budget. It measures every kind-table entry above from a SINGLE
  # `du -kxd 4 $HOME`, into a file, never a pipe (same reason as measure()'s own
  # du call above: in a pipeline du's exit status is unreadable). -x bounds it
  # to one volume; -d 4 bounds which rows are PRINTED, not what is traversed —
  # deep enough for Library/Developer's grandchildren (Library=1, Developer=2, +2 = 4).
  if past_deadline; then printf 'D\n' >> "$RAWOUT"; return 0; fi
  local homerp sout="$WORK/sweep.out" serr="$WORK/sweep.err" src wholesale g
  local hometot ucount=0 cov_complete=1 inhome=1
  homerp=$(physdir "$HOME")
  [ -n "$homerp" ] || homerp=$HOME
  du -kxd "$MAXDEPTH" "$homerp" > "$sout" 2>"$serr"
  src=$?

  # Emit T/H rows for the registered kind-table entries from this one sweep.
  # Everything else $sout sees (the bulk of $HOME) matches no entry and is
  # silently dropped here — an unattributed residual for step 4b's `cover` row
  # to account for, never folded into a group.
  CW_ENTRIES="$WORK/entries" LC_ALL=C awk -F'\t' '
    BEGIN {
      m = 0
      while ((getline line < ENVIRON["CW_ENTRIES"]) > 0) {
        split(line, f, "\t")
        m++; epath[m] = f[1]; egrp[m] = f[2]; edepth[m] = f[3] + 0
      }
      close(ENVIRON["CW_ENTRIES"])
    }
    {
      size = $1; path = $2
      for (i = 1; i <= m; i++) {
        if (path == epath[i]) {
          if (edepth[i] == 0) printf "H\t%s\t%s\tlikely\t%s\n", egrp[i], size, path
          else                printf "T\t%s\t%s\n", egrp[i], size
          next
        }
        if (edepth[i] > 0) {
          pre = epath[i] "/"
          if (substr(path, 1, length(pre)) == pre) {
            rest = substr(path, length(pre) + 1)
            if (split(rest, seg, "/") == edepth[i]) {
              printf "H\t%s\t%s\tlikely\t%s\n", egrp[i], size, path
              next
            }
          }
        }
      }
    }' "$sout" >> "$RAWOUT"

  [ -s "$serr" ] && cat "$serr" >> "$ERRLOG"

  # Failure attribution (:41-49): a denial must never mute a group it says
  # nothing about. Each stderr line is matched to the table entry whose
  # registered path is that path or a prefix of it — only THAT entry's group is
  # affected. A line under no entry falls in the residual and affects no group
  # (step 4b's coverage count, not severity). Only a line no path can be
  # recovered from, or a non-zero exit with no stderr at all, taints every
  # sweep-fed group — mirroring measure()'s own hit == "" fallback.
  wholesale=0
  if [ -s "$serr" ]; then
    CW_ENTRIES="$WORK/entries" CW_ERR="$serr" LC_ALL=C awk -F'\t' '
      BEGIN {
        m = 0
        while ((getline line < ENVIRON["CW_ENTRIES"]) > 0) {
          split(line, f, "\t")
          m++; epath[m] = f[1]; egrp[m] = f[2]
        }
        close(ENVIRON["CW_ENTRIES"])
        while ((getline e < ENVIRON["CW_ERR"]) > 0) {
          sub(/^[a-z]+: /, "", e)
          sub(/: [^:]*$/, "", e)
          if (e !~ /^\//) { print "WHOLESALE"; continue }
          hit = ""
          for (i = 1; i <= m; i++) {
            if (e == epath[i] || index(e, epath[i] "/") == 1) { hit = egrp[i]; break }
          }
          print (hit == "") ? "RESIDUAL" : hit
        }
      }' > "$WORK/sweepraw"
    # Counted BEFORE the dedup: `note coverage_incomplete` states how many
    # errors landed outside every entry, not how many distinct kinds of them.
    # -E, not a BRE `\|`: BSD grep anchors a basic RE only at the two ends of
    # the whole pattern, so `^A$\|^B$` quietly matches neither and the count
    # would be a permanent 0.
    ucount=$(grep -cE '^(RESIDUAL|WHOLESALE)$' "$WORK/sweepraw" 2>/dev/null)
    ucount=${ucount:-0}
    sort -u "$WORK/sweepraw" > "$WORK/sweepaff"
    while IFS= read -r g; do
      case "$g" in
        ''|RESIDUAL) : ;;
        WHOLESALE)   wholesale=1 ;;
        *)           affect "$g" ;;
      esac
    done < "$WORK/sweepaff"
  elif [ "$src" != 0 ]; then
    wholesale=1
  fi
  if [ "$wholesale" = 1 ]; then
    cut -f2 "$WORK/entries" | sort -u > "$WORK/sweepgroups"
    while IFS= read -r g; do
      [ -n "$g" ] && affect "$g"
    done < "$WORK/sweepgroups"
  fi

  # The coverage measurements for the `cover` row (:29-39). The sweep's own
  # $HOME row is the whole; the parts are the group totals the assembly sums.
  # Nothing is subtracted here — an over-count must reach the reader as the two
  # numbers that produced it, never as a difference this script clamped.
  hometot=$(CW_HOME="$homerp" LC_ALL=C awk -F'\t' '
    $2 == ENVIRON["CW_HOME"] { v = $1 } END { if (v != "") print v }' "$sout")
  [ "$src" = 0 ] || cov_complete=0
  [ "$ucount" -gt 0 ] && cov_complete=0
  # A sweep that printed no $HOME row measured no whole to compare against.
  if [ -z "$hometot" ]; then hometot='-'; cov_complete=0; fi
  # The note must never claim zero reasons for a figure it calls short.
  [ "$cov_complete" = 0 ] && [ "$ucount" -lt 1 ] && ucount=1
  # The parts-<=-whole check on these two numbers is only meaningful when every
  # claimed path lies inside $HOME: CLAUDE_WATCH_REPO_ROOTS may legitimately
  # point outside it, and that mass is attributed without being in the sweep.
  CW_HOME="$homerp" LC_ALL=C awk '
    BEGIN { h = ENVIRON["CW_HOME"]; p = h "/" }
    $0 != h && substr($0, 1, length(p)) != p { exit 1 }' "$CLAIM" || inhome=0
  printf 'C\t%s\t%s\t%s\t%s\n' "$hometot" "$cov_complete" "$ucount" "$inhome" >> "$RAWOUT"
  return 0
}

# ------------------------------------------------------------------ deadline --
# `timeout` is not available on this machine and installing coreutils for it is
# a new runtime dependency, which this project does not take. So: the walk runs
# in a background subshell in its OWN PROCESS GROUP (that is what `set -m` buys)
# and the parent enforces the clock, signalling the whole group so a find or du
# blocked inside the subshell dies with it.
#
# Honest residual: a process wedged in uninterruptible I/O on an unresponsive
# mount does not die on a signal. The parent stops waiting and writes what it
# has; the worker may linger until the mount answers.
set -m
( walk; printf 'Z\n' >> "$RAWOUT" ) &
worker=$!
set +m

deadline_hit=0
while :; do
  grep -q '^Z$' "$RAWOUT" 2>/dev/null && break
  kill -0 "$worker" 2>/dev/null || break
  if past_deadline; then deadline_hit=1; break; fi
  sleep 0.2
done

if [ "$deadline_hit" = 1 ]; then
  # Braced with stderr closed: bash 3.2 announces the death of a monitored job
  # on stderr, and that notice is not an error the user needs.
  {
    kill -TERM -"$worker" 2>/dev/null
    t=0
    while kill -0 "$worker" 2>/dev/null && [ "$t" -lt $(( GRACE * 10 )) ]; do
      sleep 0.1; t=$((t + 1))
    done
    kill -KILL -"$worker" 2>/dev/null
    wait "$worker"
  } 2>/dev/null
else
  wait "$worker" 2>/dev/null
fi
worker=""

# ---------------------------------------------------------------- assembly --
partial=0
[ "$deadline_hit" = 1 ] && partial=1
grep -q '^D$' "$RAWOUT" 2>/dev/null && { deadline_hit=1; partial=1; }

# grep -c prints 0 AND exits 1 on no match, so a `|| printf 0` fallback would
# yield "00". Count through one helper that only defaults a missing file.
count_re() { local c; c=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${c:-0}"; }
roots_scanned=$(count_re '^S$' "$RAWOUT")
n_offvol=$(count_re '^V$' "$RAWOUT")
n_unrep=$(count_re '^U$' "$RAWOUT")
n_perm=$(count_re 'Permission denied\|Operation not permitted' "$ERRLOG")
[ "$roots_scanned" -lt "$roots_total" ] && partial=1
[ "$n_offvol" -gt 0 ] && partial=1
[ "$n_unrep" -gt 0 ] && partial=1
[ "$n_perm" -gt 0 ] && partial=1

# df -k on the volume holding $HOME. NOT `df -k /`: that reports the sealed
# system volume (46% here) while $HOME lives on /System/Volumes/Data (96%).
# Same free space, wildly different used — and no symptom if you pick wrong.
vol_row=$(df -k "$HOME" 2>/dev/null | LC_ALL=C awk 'NR == 2 {
    m = $0
    for (i = 1; i <= 8; i++) sub(/^[^ ]+[ ]+/, "", m)
    printf "vol\t%s\t%s\t%s\t%s\n", m, $3, $4, $2
  }')
[ -n "$vol_row" ] || partial=1

# The per-group `affected` flag. `partial` answers "was the scan as a whole less
# than total" and drives the summary banner; `affected` answers "was THIS group's
# own measurement short" and drives severity capping. Two different questions —
# do not collapse them: a denial under ~/Library/Containers must not mute a
# fully measured ~/Dev.
AFF="$WORK/affected"
LC_ALL=C awk -F'\t' '$1 == "A" && $2 != "" { print $2 }' "$RAWOUT" 2>/dev/null | sort -u > "$AFF"
# Anything that shortened a group shortened the scan. Deriving `partial` from the
# note reasons alone left it at 0 for a failed idle probe or a silently non-zero
# du — a whole-scan flag saying "total" over a measurement that was not.
[ -s "$AFF" ] && partial=1
# The deadline is the one reason that cannot be attributed: the walk was killed
# mid-stride and cannot say what it had left to do, so nothing claims complete.
if [ "$deadline_hit" = 1 ]; then
  LC_ALL=C awk -F'\t' '$1 == "H" { print $2 }' "$RAWOUT" 2>/dev/null >> "$AFF"
  sort -u "$AFF" -o "$AFF"
fi

# The coverage measurements ride back on the worker's C record. No record at all
# means the sweep never ran — skipped or killed before it finished — and an
# unmeasured number is written `-`, never a zero the reader would take as a fact.
cov_home='-'; cov_complete=0; cov_count=1; cov_inhome=0; cov_swept=0
cov_rec=$(LC_ALL=C awk -F'\t' '$1 == "C" { print; exit }' "$RAWOUT" 2>/dev/null)
if [ -n "$cov_rec" ]; then
  cov_home=$(printf '%s' "$cov_rec" | cut -f2)
  cov_complete=$(printf '%s' "$cov_rec" | cut -f3)
  cov_count=$(printf '%s' "$cov_rec" | cut -f4)
  cov_inhome=$(printf '%s' "$cov_rec" | cut -f5)
  cov_swept=1
fi
# A coverage figure this run already knows is short makes the scan partial: a
# `note` row alongside `scan partial=0` is a cache the reader calls malformed.
[ "$cov_complete" = 1 ] || partial=1

tmp="$CACHE_DIR/.disk.tsv.$$"
{
  printf 'epoch\t-\t%s\t-\t-\n' "$START"
  printf 'scan\t%s\t%s\t%s\t%s\n' "$partial" "$deadline_hit" "$roots_scanned" "$roots_total"
  [ "$deadline_hit" = 1 ] && printf 'note\tdeadline\t1\t-\t-\n'
  [ "$n_perm"    -gt 0 ] && printf 'note\tpermission_denied\t%s\t-\t-\n' "$n_perm"
  [ "$n_offvol"  -gt 0 ] && printf 'note\troot_off_home_volume\t%s\t-\t-\n' "$n_offvol"
  [ "$n_unrep"   -gt 0 ] && printf 'note\tpath_unrepresentable\t%s\t-\t-\n' "$n_unrep"
  [ "$cov_complete" = 0 ] && printf 'note\tcoverage_incomplete\t%s\t-\t-\n' "$cov_count"
  [ -n "$vol_row" ] && printf '%s\n' "$vol_row"
  # Group totals cover every hit; dir rows are capped at the top 20 per group.
  # Size, confidence and path travel in three PARALLEL arrays, never packed into
  # one value. Packing them with SUBSEP and splitting again silently truncates
  # any path containing awk's own separator byte (0x1c) — and a truncated path is
  # a real, different directory that a `confirmed` row would authorise removing.
  CW_AFF="$AFF" LC_ALL=C awk -F'\t' -v topn="$TOPN" \
      -v covhome="$cov_home" -v covcomp="$cov_complete" -v covswept="$cov_swept" '
    BEGIN { while ((getline a < ENVIRON["CW_AFF"]) > 0) if (a != "") aff[a] = 1 }
    $1 == "H" {
      g = $2
      if (!(g in seen0)) { glist[++gn] = g; seen0[g] = 1 }
      tot[g] += $3 + 0; cnt[g]++
      k = ++seen[g]
      KB[g, k] = $3 + 0; CF[g, k] = $4; PT[g, k] = $5
    }
    # A kind-table entry sweep total (T) is the true size of its whole
    # subtree; the summed H rows are only its depth-N children and can fall
    # short of that (content outside any tracked child, intermediate dirs).
    # T wins whenever present — dir_count and the dir sample stay H-derived.
    $1 == "T" {
      g = $2
      if (!(g in seen0)) { glist[++gn] = g; seen0[g] = 1 }
      Ttot[g] = $3 + 0; hasT[g] = 1
    }
    END {
      OFS = "\t"
      # `attributed` is the sum of the very group totals printed below it, so
      # the two can never drift: a group the reader can see is a group the
      # coverage figure counted. Without a sweep there is no whole to compare
      # against, and an unmeasured number is `-`, not a plausible zero.
      att = 0
      for (gi = 1; gi <= gn; gi++) {
        g = glist[gi]
        GT[g] = (g in hasT) ? Ttot[g] : tot[g] + 0
        att += GT[g]
      }
      print "cover", "home", covhome, (covswept == 1) ? att : "-", covcomp
      for (gi = 1; gi <= gn; gi++) {
        g = glist[gi]
        print "group", g, GT[g], cnt[g] + 0, (g in aff) ? 1 : 0
      }
      for (gi = 1; gi <= gn; gi++) {
        g = glist[gi]
        m = seen[g]
        # A selection sort over at most a few hundred rows, to avoid depending on
        # a sort implementation for the top-N cut.
        for (i = 1; i <= m && i <= topn; i++) {
          best = i
          for (j = i + 1; j <= m; j++) if (KB[g, j] > KB[g, best]) best = j
          t = KB[g, i]; KB[g, i] = KB[g, best]; KB[g, best] = t
          t = CF[g, i]; CF[g, i] = CF[g, best]; CF[g, best] = t
          t = PT[g, i]; PT[g, i] = PT[g, best]; PT[g, best] = t
          print "dir", PT[g, i], KB[g, i], g, CF[g, i]
        }
      }
    }' "$RAWOUT"
# stderr is redirected FIRST so that a failing `> $tmp` on a read-only $STATE
# reports through E7 below instead of printing bash's own diagnostic.
} 2>/dev/null > "$tmp" || die_write
[ -s "$tmp" ] || die_write

# Scanner-side sanity: the parts can never exceed the whole. A violation means
# something was double-counted, which is a bug in this script, not a fact.
if [ -n "$vol_row" ]; then
  used_kb=$(printf '%s' "$vol_row" | cut -f3)
  sum_kb=$(LC_ALL=C awk -F'\t' '$1 == "group" { s += $3 } END { printf "%d", s + 0 }' "$tmp")
  if [ "$sum_kb" -gt "$used_kb" ] 2>/dev/null; then
    printf 'claude-watch disk: group totals (%s KB) exceed the volume used (%s KB) — double counting.\n' \
      "$sum_kb" "$used_kb" >&2
  fi
fi
# The same invariant one level down, on the coverage row: what the groups claim
# cannot exceed the $HOME sweep they were measured out of. This is where an
# over-count gets SAID — the row itself carries both measurements untouched,
# because clamping a residual to zero in the cache is how a double count becomes
# invisible again. Only meaningful when every claimed path is inside $HOME:
# CLAUDE_WATCH_REPO_ROOTS may point outside it, and that mass is attributed
# without ever being part of the sweep total.
cov_attr=$(LC_ALL=C awk -F'\t' '$1 == "cover" { print $4; exit }' "$tmp")
if [ "$cov_inhome" = 1 ] && [ "$cov_attr" -gt "$cov_home" ] 2>/dev/null; then
  printf 'claude-watch disk: attributed group totals (%s KB) exceed the $HOME sweep total (%s KB) — double counting.\n' \
    "$cov_attr" "$cov_home" >&2
fi

# The rename is atomic only because $tmp is on the cache's own volume.
mv "$tmp" "$CACHE" 2>/dev/null || die_write
tmp=""
exit 0
