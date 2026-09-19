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

rc=0
for h in $hosts; do
  [ "$h" = "$hub" ] && { echo "  $h: hub, skipped"; continue; }
  if [ "$DRYRUN" -eq 1 ]; then echo "  would push -> $h:$CONFDIR/manifest"; continue; fi
  if ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" "mkdir -p $CONFDIR" 2>/dev/null &&
     scp -q -o BatchMode=yes -o ConnectTimeout=15 "$MANIFEST" "$h:$CONFDIR/manifest" 2>/dev/null; then
    echo "  $h: pushed"
  else
    echo "push-manifest: FAILED to push to $h" >&2; rc=1
  fi
done
exit $rc
