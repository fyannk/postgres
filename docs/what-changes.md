# What changes compared with the official image

The privilege step-down, and the distribution's pending updates. Every image
is built from upstream's own Dockerfile and scripts for that version and
variant, with these changes applied by
[`patch-upstream.sh`](../.github/scripts/patch-upstream.sh):

| Upstream | Here |
| --- | --- |
| Starts from the base image as Docker last built it | Applies the distribution's pending updates right after `FROM`: `apt-get upgrade` on Debian, before PostgreSQL's own repository is added, and `apk upgrade` on Alpine. PostgreSQL stays at the version the recipe pins |
| Downloads and verifies `gosu`, sets `ENV GOSU_VERSION` | Removed. Alpine installs the `setpriv` package; Debian already has it |
| `ln -s gosu su-exec` compatibility link (Alpine, PostgreSQL 14–16) | Removed |
| `exec gosu postgres "$BASH_SOURCE" "$@"` in `docker-entrypoint.sh` and `docker-ensure-initdb.sh` | `HOME=<postgres home> exec setpriv --reuid=postgres --regid=postgres --init-groups "$BASH_SOURCE" "$@"` |

The identity after the switch is the same as with `gosu`: real, effective and
saved UID and GID of `postgres`, its supplementary groups (for example
`ssl-cert` on Debian), and its `HOME`. The environment is otherwise passed
through untouched, so `POSTGRES_*` variables, `/docker-entrypoint-initdb.d`,
`PGDATA` and running with `--user` all behave exactly as documented for the
[official image](https://hub.docker.com/_/postgres).

Each patch is asserted. If upstream reshapes the `gosu` block or the
step-down line, the patch fails and nothing is published, instead of shipping
an image that still contains `gosu` or no longer steps down.

## Migrating

The one thing that changes for users is that `gosu` and `su-exec` are no longer
in the image. If your own scripts or `docker exec` commands call them, use
`setpriv` instead, or let Docker do the switch:

```text
# before
docker exec -it db gosu postgres psql
# after
docker exec -it -u postgres db psql
```

Inside an image derived from this one:

```text
setpriv --reuid=postgres --regid=postgres --init-groups <command>
```

## Scope

This repository does not fork docker-library/postgres. It carries no copy of
upstream's Dockerfiles or scripts; it fetches them at build time and rewrites
only the privilege step-down and the update step above.
