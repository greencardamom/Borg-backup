#!/bin/bash
#
# borg-backup.sh - manifest-driven borg backups for the whole fleet.
#
# ONE manifest, MANY executors. Unlike collect-secrets.sh (which PULLS: a central host
# tars remote files over ssh and encrypts locally), borg reads LOCAL files -- that is how
# it decides which chunks changed. So this script runs on every machine being backed up,
# pushing to remote repos. The manifest is authored once on the hub and distributed by
# push-manifest.sh; each host filters to its own rows.
#
# The manifest is NOT in this repo: it names every host, path and destination in the fleet,
# which is a topology map. Same reasoning as collect-secrets.sh keeping its manifest local.
#
# Repos are ENCRYPTED (repokey). That is deliberate: it means nothing has to be excluded on
# secrecy grounds. Excluding "files that might be secret" by path is guesswork that fails
# silently -- an API key in a directory nobody thought of ends up in plaintext on a drive.
# With an encrypted repo the only exclusions are churn and bulk, which is a rule you can
# actually state. The cost is a passphrase to manage; see RESTORE in README.md.
#
#   usage: borg-backup.sh [-n] [-v] [host]
#          -n  dry run, print what would happen
#          -v  verbose, borg --stats to the log
#          host  override the hostname used to select manifest rows
#
set -uo pipefail

CONFDIR="${BORG_BACKUP_CONF:-$HOME/.config/borg-backup}"
MANIFEST="$CONFDIR/manifest"
LOG="$CONFDIR/borg-backup.log"
LOCK="$CONFDIR/.lock"
STALE_DAYS=30

DRYRUN=0; VERBOSE=0; THISHOST="$(hostname -s)"
while [ $# -gt 0 ]; do
  case "$1" in
    -n) DRYRUN=1 ;;
    -v) VERBOSE=1 ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    -*) echo "borg-backup: unknown option: $1" >&2; exit 2 ;;
    *)  THISHOST="$1" ;;
  esac
  shift
done

say()  { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG"; }
fail() { printf 'borg-backup: %s\n' "$*" >&2; say "ERROR: $*"; }

mkdir -p "$CONFDIR"

# A missing or stale manifest means push-manifest.sh stopped working. Backing up nothing
# looks identical to having nothing configured, so refuse rather than exit 0 quietly.
[ -f "$MANIFEST" ] || { fail "no manifest at $MANIFEST - has it been pushed to this host?"; exit 1; }
if [ -n "$(find "$MANIFEST" -mtime +$STALE_DAYS 2>/dev/null)" ]; then
  fail "manifest is older than $STALE_DAYS days ($(date -r "$MANIFEST" '+%F')) - distribution may be broken"
fi

exec 9>"$LOCK"
flock -n 9 || { fail "another run is in progress"; exit 1; }

# ---- parse -------------------------------------------------------------------
declare -A DEST_PATH DEST_KEEP
RETENTION="keep-daily=3,keep-weekly=6,keep-monthly=24"
COMPRESSION="zstd"
PASSFILE=""
KEYDIR=""
ROWS=()

while read -r f1 f2 f3 f4 rest; do
  case "$f1" in ''|'#'*) continue ;; esac
  case "$f1" in
    set)  case "$f2" in
            retention)       RETENTION="$f3" ;;
            compression)     COMPRESSION="$f3" ;;
            passphrase-file) PASSFILE="$f3" ;;
            key-export-dir)  KEYDIR="$f3" ;;
            *) fail "unknown 'set' key: $f2" ;;
          esac ;;
    dest) DEST_PATH[$f2]="$f3"; [ -n "${f4:-}" ] && DEST_KEEP[$f2]="$f4" ;;
    *)    [ "$f1" = "$THISHOST" ] && ROWS+=("$f2|$f3|$f4|${rest:-}") ;;
  esac
done < "$MANIFEST"

[ ${#ROWS[@]} -gt 0 ] || { say "no manifest rows for host $THISHOST - nothing to do"; exit 0; }

[ -n "$PASSFILE" ] || { fail "no 'set passphrase-file' in manifest"; exit 1; }
[ -r "$PASSFILE" ] || { fail "passphrase file not readable: $PASSFILE"; exit 1; }

# PASSCOMMAND, not BORG_PASSPHRASE: keeps the secret out of the environment and off any
# command line. segartd's visible --cb-pass in ps is the counter-example.
export BORG_PASSCOMMAND="cat $PASSFILE"

# export_key - keep a copy of each repo's key outside the repo.
#
# With repokey the key lives in the repo's own config, wrapped by the passphrase, so
# passphrase + intact repo = access. This covers the other case: if that config is
# damaged, a correct passphrase alone recovers nothing.
#
# Written into the secrets dir, which collect-secrets.sh already age-encrypts and ships
# offsite - so the paper burden stays at two items (age key, borg passphrase) no matter
# how many repos exist. Exporting per repo onto paper does not scale.
export_key() {
  local repo="$1" name="$2" dest
  [ -n "$KEYDIR" ] || return 0
  dest="$KEYDIR/$name.key"
  [ -s "$dest" ] && return 0                       # already held; keys do not rotate
  mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
  if borg key export "$repo" "$dest" >>"$LOG" 2>&1; then
    chmod 600 "$dest"; say "$name: key exported to $dest"
  else
    fail "$name: borg key export failed"; return 1
  fi
}

# ---- run ---------------------------------------------------------------------
rc_overall=0; n_ok=0; n_fail=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r label dests source excludes <<< "$row"

  if [ ! -d "$source" ]; then
    fail "$label: source does not exist: $source"; n_fail=$((n_fail+1)); rc_overall=1; continue
  fi

  exargs=()
  if [ -n "$excludes" ]; then
    IFS=',' read -ra ex <<< "$excludes"
    # A bare name like "node_modules" matches only a path exactly equal to it, so it
    # silently excludes NOTHING - borg gives no warning. Bare names are therefore given
    # the sh:**/ prefix so they match at any depth; anything already carrying a borg
    # pattern prefix (sh: fm: re: pp: pf:) or a slash is passed through untouched.
    for e in "${ex[@]}"; do
      case "$e" in
        sh:*|fm:*|re:*|pp:*|pf:*|*/*) exargs+=( --exclude "$e" ) ;;
        *)                            exargs+=( --exclude "sh:**/$e" ) ;;
      esac
    done
  fi

  IFS=',' read -ra dlist <<< "$dests"
  for d in "${dlist[@]}"; do
    base="${DEST_PATH[$d]:-}"
    if [ -z "$base" ]; then
      fail "$label: destination '$d' not defined in manifest"; n_fail=$((n_fail+1)); rc_overall=1; continue
    fi
    repo="$base/$THISHOST-$label"
    keep="${DEST_KEEP[$d]:-$RETENTION}"

    if [ "$DRYRUN" -eq 1 ]; then
      echo "would: borg create $repo::{now} $source ${exargs[*]-}  (keep: $keep)"
      continue
    fi

    # Auto-init so a new host or a new destination needs no manual step.
    if ! borg info "$repo" >/dev/null 2>&1; then
      say "$label -> $d: initialising encrypted repo $repo"
      if ! borg init --encryption=repokey "$repo" >>"$LOG" 2>&1; then
        fail "$label -> $d: borg init failed"; n_fail=$((n_fail+1)); rc_overall=1; continue
      fi
    fi

    export_key "$repo" "$THISHOST-$label" || { n_fail=$((n_fail+1)); rc_overall=1; }

    stats=(); [ "$VERBOSE" -eq 1 ] && stats=(--stats)
    borg create --compression "$COMPRESSION" "${stats[@]}" "${exargs[@]}" \
        "$repo::{now:%Y-%m-%d_%H:%M}" "$source" >>"$LOG" 2>&1
    rc=$?

    # borg: 0 = ok, 1 = warnings (a file changed while being read - routine on a live
    # tree), 2+ = error. Only 2+ is a failure, so warnings do not generate cron mail.
    if [ "$rc" -ge 2 ]; then
      fail "$label -> $d: borg create failed (exit $rc) - NOT pruning"
      n_fail=$((n_fail+1)); rc_overall=1; continue
    fi
    [ "$rc" -eq 1 ] && say "$label -> $d: create completed with warnings"

    # Prune is gated on a successful create. Pruning after a failed create ages out good
    # archives while no new one arrives, walking the retention window backwards.
    pargs=(); IFS=',' read -ra ks <<< "$keep"
    for k in "${ks[@]}"; do pargs+=( "--${k%%=*}=${k#*=}" ); done
    borg prune "${pargs[@]}" "$repo" >>"$LOG" 2>&1
    rc=$?
    if [ "$rc" -ge 2 ]; then
      fail "$label -> $d: borg prune failed (exit $rc)"; n_fail=$((n_fail+1)); rc_overall=1; continue
    fi

    say "$label -> $d: OK"
    n_ok=$((n_ok+1))
  done
done

say "run complete: $n_ok ok, $n_fail failed (host $THISHOST)"
[ "$rc_overall" -ne 0 ] && fail "$n_fail of $((n_ok+n_fail)) backups FAILED on $THISHOST - see $LOG"
exit $rc_overall
