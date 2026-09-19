Borg-backup
===========

Manifest-driven [borg](https://borgbackup.org) backups across a fleet of machines.

One manifest, many executors
----------------------------

`collect-secrets.sh` (a sibling tool) works centrally because it **pulls**: the hub opens
an ssh, runs `tar` on the far end and encrypts the stream locally. The remote needs only
ssh and tar.

borg cannot work that way. `borg create` reads **local** files — that is how it stats them
to decide which chunks changed. The repository may be remote, the source may not. So
`borg-backup.sh` runs on **every** machine being backed up, and the single manifest is
distributed to them by `push-manifest.sh`. Each host filters to its own rows.

```
   hub: ~/.config/borg-backup/manifest   (authoritative, NOT in this repo)
          |
          |  push-manifest.sh   (ssh; the host column IS the worker list)
          v
   worker: ~/.config/borg-backup/manifest
          |
          |  borg-backup.sh     (from cron, filters rows for $(hostname -s))
          v
   dest:  <base>/<host>-<label>            e.g. rabbit:~/Backup/acre-toolforge
```

The manifest is pushed rather than pulled because not every worker can reach every git
host, and because it names every host, path and destination in the fleet — a topology map
that does not belong in a repo.

Manifest
--------

```
set passphrase-file /home/greenc/scripts/secrets/borg.passphrase
set retention       keep-daily=3,keep-weekly=6,keep-monthly=24
set compression     zstd

dest rabbit  rabbit:/home/greenc/Backup
dest sheep   sheep:/mnt/big/Backup   keep-daily=7,keep-weekly=12,keep-monthly=36

#<host> <label>    <dests>       <source>               [excludes]
acre     toolforge rabbit,sheep  /home/greenc/toolforge
acre     projects  rabbit        /home/greenc/projects  node_modules,__pycache__,venv
```

`<host>`+`<label>` is the unique key and the repo name is derived from it, so two rows can
never collide on one destination. `<dests>` is a list: name two for data you want held on
two separate machines.

Encryption, and why nothing is excluded for secrecy
---------------------------------------------------

Repos are created with `--encryption=repokey`. That is the point of the design.

The alternative — an unencrypted repo plus a list of paths to exclude because they hold
credentials — is guesswork. You exclude the two you remember and an API key in a directory
nobody thought of is written to a drive in plaintext, silently, forever. "Exclude things
that might be secret" is not a rule.

With an encrypted repo, exclusions are only ever about **churn and bulk**:
`node_modules`, `__pycache__`, `venv`. That is a rule you can state and check.

Bare exclude names are automatically anchored as `sh:**/<name>` so they match at any
depth. borg matches `--exclude` against the whole stored path, so a bare `node_modules`
silently excludes nothing and gives no warning. Patterns that already carry a borg prefix
(`sh:` `fm:` `re:` `pp:` `pf:`) or contain a slash are passed through unchanged.

Restore
-------

The passphrase is read with `BORG_PASSCOMMAND` so it never enters the environment or a
command line. It lives in the secrets directory, which `collect-secrets.sh` already
age-encrypts and pushes offsite.

That creates a chain, and the order matters:

1. **age key** — kept on a second machine and on paper
2. `restore-secrets.sh` → recovers the secrets directory
3. **borg passphrase** → from that directory
4. `borg extract` → the data

**The passphrase must not live only inside a tree that borg is backing up.** That is a
circular dependency in exactly the situation where it is needed. Keep it in the age backup
and on paper, alongside the age key.

Behaviour
---------

* Silent on success. Failures go to stderr, so cron mails them; detail lands in
  `~/.config/borg-backup/borg-backup.log`.
* borg exit 1 (warnings — a file changed while being read) is tolerated and logged.
  Only exit 2+ is a failure.
* `prune` is gated on a successful `create`. Pruning after a failed create ages out good
  archives while no new one arrives, walking the retention window backwards until nothing
  recent is left.
* A destination failure does not block the others: list two destinations and one being
  down still leaves you with a backup.
* Repos are auto-initialised, so a new host or destination needs no manual step.
* A missing or stale (>30 days) manifest is an error, not a quiet no-op — otherwise a
  broken distribution looks exactly like "nothing configured".
* `flock` prevents overlapping runs.

Usage
-----

```
borg-backup.sh          # from cron
borg-backup.sh -n       # dry run, print what would happen
borg-backup.sh -v       # verbose, borg --stats into the log
push-manifest.sh [-n]   # on the hub, after editing the manifest
```

Requires `borg` on every worker and passwordless ssh from each worker to its destinations.

by GreenC · MIT License
