# Building, publishing and maintaining

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

## Release automation

The nightly publish fetches upstream's default branch, patches every variant
up front (if any fails, nothing is published), then builds each variant, runs
the same checks as CI against the built image, and only then pushes it with
SBOM and provenance attestations. The push reuses the checked build's layers,
and the workflow fails if the pushed layers differ from the checked ones. The
verified digest is then signed with cosign, and only after that do the tags
move to it.

An image is rebuilt only when an input that can change its contents has moved:
upstream's directory for that variant, the patch script, or the base image
digest. That fingerprint is recorded on the image as the
`io.fyannk.postgres.inputs` label and compared against the published
`<version>-<variant>` tag. An image is also rebuilt when the distribution has
published an update for one of its packages since it was built: each night
the published image is asked for its pending updates, Debian's own archives
only on Debian, since PostgreSQL's repository carries server builds the recipe
deliberately pins. A rebuild happens regardless once the published image is
more than seven days old, in case that check cannot run. The upstream commit each image was built from is
recorded as `io.fyannk.postgres.upstream-revision`.

A manual run can pin an upstream commit and force a full rebuild.

An image replaced by a newer push stays in both registries, untagged and
pullable by digest, for seven days. After that, the cleanup that runs after
each publish deletes it: on GHCR through
[ghcr-cleanup-action](https://github.com/dataaxiom/ghcr-cleanup-action),
together with the signatures left without an image, on
Docker Hub through [`prune-dockerhub.sh`](../.github/scripts/prune-dockerhub.sh).
Tagged images, including older release tags such as `18.5-trixie`, are never
deleted. Docker Hub's manifest API is not part of Docker's published
reference, so a failed Hub cleanup is reported as a warning rather than
failing the publish.

GHCR is where images are built, checked and tagged. Docker Hub is a mirror:
once the publish jobs are done, a single job copies to Docker Hub every tag
whose digest differs there, attestations included
([`sync-dockerhub.sh`](../.github/scripts/sync-dockerhub.sh)). A Docker Hub
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
`All images` jobs of [`ci.yml`](../.github/workflows/ci.yml), plus the CodeQL
analysis of the workflows, and require that review threads be resolved.
`All images` summarises the whole build matrix, so the required checks do not
change when upstream adds or retires a version.

Dependabot watches the actions every workflow pins; its patch and minor bumps
queue themselves through [`automerge.yml`](../.github/workflows/automerge.yml)
and land once the required checks go green. Anything else is left for a
person.
