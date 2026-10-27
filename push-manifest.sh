#!/bin/bash
#
# push-manifest.sh - distribute the borg-backup manifest from the hub to every worker.
#
# The host column IS the worker list, so there is no second list to keep in sync: add a
# row for a new machine and it receives the manifest on the next push.
#
# Runs on the hub (the machine holding the authoritative manifest). Workers cannot all
# reach every git host - fox and slater have no route to git.archive.org - so the manifest
# is pushed over ssh rather than pulled from a repo. It is also deliberately not committed:
# it names every host, path and destination in the fleet.
#
set -uo pipefail

CONFDIR="${BORG_BACKUP_CONF:-$HOME/.config/borg-backup}"
MANIFEST="$CONFDIR/manifest"
DRYRUN=0
[ "${1:-}" = "-n" ] && DRYRUN=1

[ -f "$MANIFEST" ] || { echo "push-manifest: no manifest at $MANIFEST" >&2; exit 1; }

hub="$(hostname -s)"
hosts=$(awk '!/^[ \t]*#/ && NF >= 4 && $1 != "set" && $1 != "dest" { print $1 }' "$MANIFEST" | sort -u)
[ -n "$hosts" ] || { echo "push-manifest: no hosts in manifest" >&2; exit 1; }

# Each host has only its own passphrase file, so the hub's 'set passphrase-file
# .../borg.passphrase.<hub>' line is rewritten to <host> in that host's copy. A verbatim
# copy pointed agros at borg.passphrase.acre and every backup there failed (2026-10-27).
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT

rc=0
for h in $hosts; do
  [ "$h" = "$hub" ] && { echo "  $h: hub, skipped"; continue; }
  sed "s|^\(set[ \t][ \t]*passphrase-file[ \t].*borg\.passphrase\.\)$hub[ \t]*\$|\1$h|" "$MANIFEST" > "$tmp"
  pass=$(awk '$1 == "set" && $2 == "passphrase-file" { print $3 }' "$tmp")
  if [ "$DRYRUN" -eq 1 ]; then echo "  would push -> $h:$CONFDIR/manifest (passphrase-file $pass)"; continue; fi
  if ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" "mkdir -p $CONFDIR && test -r $pass" 2>/dev/null &&
     scp -q -o BatchMode=yes -o ConnectTimeout=15 "$tmp" "$h:$CONFDIR/manifest" 2>/dev/null; then
    echo "  $h: pushed"
  else
    echo "push-manifest: FAILED to push to $h (unreachable, or no $pass there)" >&2; rc=1
  fi
done
exit $rc
