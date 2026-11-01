# Security Policy

## Scope

This repository publishes container images. It contains no PostgreSQL code
and no copy of the image recipe: every image is built from
[docker-library/postgres](https://github.com/docker-library/postgres), rebuilt
to pick up distribution security fixes, with its `gosu` step-down replaced by
`setpriv`.

- A flaw in PostgreSQL belongs to the [PostgreSQL project](https://www.postgresql.org/support/security/).
- A flaw in the official image recipe that this repository merely inherits
  belongs to docker-library/postgres.
- A flaw in what this repository changes belongs here: the step-down not
  dropping to `postgres`, an identity or environment that differs from
  upstream's, `gosu` surviving in an image, or a publishing mistake.

## Supported versions

Every PostgreSQL major and variant upstream currently maintains is rebuilt
nightly when its inputs change, and at least weekly otherwise. Once upstream
drops a major or a base, its tags here stop being rebuilt.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/fyannk/postgres/security/advisories/new)
so the report and any supporting material remain confidential.

Include the affected tag and image digest, the deployment configuration,
impact, and reproduction steps. Do not include live credentials, connection
strings, or other secrets in the report.

Public disclosure should wait until a fix or mitigation is available and a
coordinated disclosure date has been agreed.

## How scan findings are triaged

Every pull request builds every image, scans it with grype, and publishes the
full result to this repository's code scanning alerts. The alerts are an
inventory of what is present, not a queue of outstanding work.

**CI blocks on critical findings that have an applicable fix and that the
change introduces.** That is the only class where a change to this repository
can turn the check green, so it is the only class worth failing a build over.

A fixable critical that is already in a published image, typically because an
advisory was filed after it shipped, does not fail unrelated pull requests. A
nightly scan of the published images tracks it in a single issue that closes
itself once a rebuild clears it.

Findings are left open, and are expected to be left open, when no fix is
published by Debian, Alpine or the PostgreSQL package repositories. The
rebuild picks a fix up automatically once it exists.

An alert is dismissed only when the vulnerable code path is demonstrably
unreachable in the image, and the dismissal comment records the evidence.

To see only what is actionable:

```text
grype ghcr.io/fyannk/postgres:latest --only-fixed
```
