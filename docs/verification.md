# How the images are checked and measured

## Before an image ships

Every pull request patches the current upstream recipe, builds every variant,
and runs [`check-image.sh`](../.github/scripts/check-image.sh) against each
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
[SECURITY.md](../SECURITY.md).

## The nightly security report

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

[`security-report.yml`](../.github/workflows/security-report.yml) runs after the
nightly publish and on changes to [`site/`](../site) or
[`security-report.sh`](../.github/scripts/security-report.sh). Upstream's images
and the Trivy image are pulled through `mirror.gcr.io`, Google's mirror of
Docker Hub, which serves the same digests without touching Docker Hub's rate
limits.
