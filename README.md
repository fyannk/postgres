# postgres

![Upstream](https://img.shields.io/badge/recipe-docker--library%2Fpostgres-1f6feb?style=for-the-badge)
[![Security report](https://img.shields.io/badge/security%20report-nightly-4f6b0e?style=for-the-badge)](https://fyannk.github.io/postgres/)

> The official PostgreSQL image, rebuilt from
> [docker-library/postgres](https://github.com/docker-library/postgres) to stay
> as close to zero known, fixable vulnerabilities as possible, and compared with
> upstream every night in a public
> [security report](https://fyannk.github.io/postgres/).

## Why

Most findings in a container image are not in PostgreSQL itself but in the
distribution packages around it and in anything bundled on top. These images
keep them down by:

- **rebuilding when a fix lands**: whenever upstream's recipe or the base
  image changes, and at least weekly regardless, so Debian and Alpine security
  updates are picked up without waiting for the next release;
- **bundling nothing the distribution cannot patch**: the official image
  downloads [`gosu`](https://github.com/tianon/gosu), a Go binary, only to drop
  from root to `postgres` at startup. It carries the Go standard library it was
  compiled with, so scanners report that toolchain's CVEs against every image
  until upstream bumps `GOSU_VERSION`. Here `setpriv` does the same job: it is
  part of `util-linux` on Debian and a small package on Alpine, patched like
  the rest of the distribution;
- **checking every change before it ships**: builds, behaviour tests and a
  grype gate, see [How it is verified](#how-it-is-verified);
- **measuring the result in the open**: SBOMs, a nightly comparison with the
  official image using two scanners, and every remaining finding listed.

## What is different

Only the privilege step-down. Every image is built from upstream's own Dockerfile and
scripts for that version and variant, with three changes applied by
[`patch-upstream.sh`](.github/scripts/patch-upstream.sh):

| Upstream | Here |
| --- | --- |
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

### Migrating

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

## Image tags

Tags mirror the official image, so the registry prefix is the only thing to
change:

| Tag | Example | Points to |
| --- | --- | --- |
| `<version>-<variant>` | `18.6-trixie`, `18.6-alpine3.24` | That release on that base |
| `<major>-<variant>` | `18-trixie`, `17-alpine3.24` | Newest release of that major on that base |
| `<version>`, `<major>` | `18.6`, `18` | The default Debian base |
| `<version>-alpine`, `<major>-alpine` | `18-alpine` | The default Alpine base |
| `<variant>`, `latest`, `alpine` | `trixie`, `latest` | Newest stable major |

Every major upstream maintains is built, pre-releases included, on its
current Debian and Alpine releases (upstream's default `debian` and `alpine`
for that major). Older bases such as `bookworm` or a superseded Alpine release
are not built, so their tags stop updating when upstream moves on.
Pre-releases never take `latest` or the bare variant tags.

```text
docker pull ghcr.io/fyannk/postgres:18
docker pull fyannk/postgres:18
```

Images are published to GHCR and Docker Hub, for `linux/amd64`. A tag
resolves to the same image digest on either.

## Local builds

The build context is the patched upstream directory, not this repository:

```text
.github/scripts/fetch-upstream.sh upstream
.github/scripts/patch-upstream.sh upstream 18/trixie
docker build --pull -t postgres-local:18-trixie upstream/18/trixie
.github/scripts/check-image.sh postgres-local:18-trixie
```

`patch-upstream.sh` with no directory patches every variant. It is not
idempotent: run it on a fresh checkout.

## How it is verified

Every pull request patches the current upstream recipe, builds every variant,
and runs [`check-image.sh`](.github/scripts/check-image.sh) against each
result:

- no `gosu` or `su-exec` file anywhere in the exported filesystem, and no
  `GOSU_VERSION` in the image environment;
- started as root, init scripts run as `postgres` with its groups and `HOME`,
  and the server's PID 1 has `postgres` as real, effective, saved and
  filesystem UID;
- started with `--user postgres`, it initialises and serves without stepping
  down;
- `docker-ensure-initdb.sh` steps down and initialises a cluster.

Each image is also scanned with grype, including the Go standard library of
any Go binary (grype skips that by default). The gate blocks on critical
findings with an applicable fix that the change introduces; one already in the
published image is tracked by a nightly-updated issue, and every other finding
with a fix is published to the repository's code scanning results. See
[SECURITY.md](SECURITY.md).

## Security report

[fyannk.github.io/postgres](https://fyannk.github.io/postgres/) compares every
published image with its official counterpart each night, using two scanners.
Both sides are inventoried with Syft: ours from the SBOM attached when it is
published, upstream by running Syft on the official image. grype scans those
SBOMs and Trivy scans the images. For each image, side and scanner, the page
shows every severity as "with a fix / all findings"; nothing is summed across
images. It leads with the latest stable release on Debian and Alpine, with
its trend over time, and lists every tag with the digest it points to.
The page also records when each scanner's advisory database was built, and
flags one built more than two days before the scan, since a clean result is
only as current as that database. The data and our SBOMs are published
alongside the page.

[`security-report.yml`](.github/workflows/security-report.yml) runs after the
nightly publish and on changes to [`site/`](site) or
[`security-report.sh`](.github/scripts/security-report.sh). Upstream's images
and the Trivy image are pulled through `mirror.gcr.io`, Google's mirror of
Docker Hub, which serves the same digests without touching Docker Hub's rate
limits.

## Release automation

The nightly publish fetches upstream's default branch, patches every variant
up front (if any fails, nothing is published), then builds each variant, runs
the same checks as CI against the built image, and only then pushes it with
SBOM and provenance attestations. The push reuses the checked build's layers,
and the workflow fails if the pushed layers differ from the checked ones.

An image is rebuilt only when an input that can change its contents has moved:
upstream's directory for that variant, the patch script, or the base image
digest. That fingerprint is recorded on the image as the
`io.fyannk.postgres.inputs` label and compared against the published
`<version>-<variant>` tag. A rebuild happens regardless once the published
image is more than seven days old, so distribution package fixes are picked up
with unchanged base images. The upstream commit each image was built from is
recorded as `io.fyannk.postgres.upstream-revision`.

A manual run can pin an upstream commit and force a full rebuild.

An image replaced by a newer push stays in both registries, untagged and
pullable by digest, for seven days. After that, the cleanup that runs after
each publish deletes it: on GHCR through
[ghcr-cleanup-action](https://github.com/dataaxiom/ghcr-cleanup-action), on
Docker Hub through [`prune-dockerhub.sh`](.github/scripts/prune-dockerhub.sh).
Tagged images, including older release tags such as `18.5-trixie`, are never
deleted. Docker Hub's manifest API is not part of Docker's published
reference, so a failed Hub cleanup is reported as a warning rather than
failing the publish.

GHCR is where images are built, checked and tagged. Docker Hub is a mirror:
once the publish jobs are done, a single job copies to Docker Hub every tag
whose digest differs there, attestations included
([`sync-dockerhub.sh`](.github/scripts/sync-dockerhub.sh)). A Docker Hub
account gets 200 registry requests an hour, so the mirror reads Docker Hub's
current tags from the Hub API, skips unchanged tags, and retries a throttled
copy; anything it misses is copied by the next run. Base images are pulled
through Google's Docker Hub mirror, `mirror.gcr.io`, which serves the same
digests without counting against Docker Hub's limits.

Docker Hub is optional: it is used when the `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN` secrets are set (a personal access token with read, write
and delete access), and images go to GHCR only otherwise.

## Merge automation

The ruleset on `main` should require the `Lint and patch upstream` and
`All images` jobs of [`ci.yml`](.github/workflows/ci.yml), plus the CodeQL
analysis of the workflows, and require that review threads be resolved.
`All images` summarises the whole build matrix, so the required checks do not
change when upstream adds or retires a version.

Dependabot watches the actions every workflow pins; its patch and minor bumps
queue themselves through [`automerge.yml`](.github/workflows/automerge.yml)
and land once the required checks go green. Anything else is left for a
person.

## Scope

This repository does not fork docker-library/postgres. It carries no copy of
upstream's Dockerfiles or scripts; it fetches them at build time and rewrites
only the privilege step-down.
