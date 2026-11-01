![fyannk/postgres logo: an elephant peeking over a shield bearing an ermine](https://raw.githubusercontent.com/fyannk/postgres/main/site/assets/mark-160.png)

# fyannk/postgres

**The official PostgreSQL® image, with the known vulnerabilities that already have a fix left out.**

Same PostgreSQL, same tags, same settings as the image you already run. The
difference is what surrounds it: these images are rebuilt whenever Debian or
Alpine ship a security fix, and they leave out the one bundled program the
distribution cannot patch. Every night, each one is scanned next to its
official counterpart, and the
[security report](https://fyannk.github.io/postgres/) shows the result,
including whatever is still left.

> **Its limits.** This does not make PostgreSQL itself any safer, and it
> cannot fix a vulnerability before Debian, Alpine or the PostgreSQL project
> do. "No known, fixable vulnerabilities" means none that the scanners know
> about and that have a fix today; the report shows the rest, and how current
> the scanners' data is.

> **Independent.** A personal project, not affiliated with, endorsed by or
> sponsored by the PostgreSQL project, the PostgreSQL Community Association of
> Canada, docker-library, Docker, or any company.

## Why use it?

- **Drop-in**: change the registry prefix, keep everything else.
- **Patched sooner**: rebuilt when a fix lands, and at least once a week.
- **Nothing left behind**: no bundled extra that only a new release could update.
- **Proven, not promised**: a public, nightly comparison with the official image.
- **Signed**: each image is signed as it is published, and comes with the list of what is inside it.

## Quick start

```sh
docker run -d --name db -e POSTGRES_PASSWORD=change-me fyannk/postgres:18
```

That is the whole switch. Everything documented for the
[official image](https://hub.docker.com/_/postgres) works the same way.

## Tags

The same tags as the official image: `18`, `18.6`, `18-alpine`,
`18-trixie`, `latest` and so on, for every PostgreSQL version the official
image maintains, on Debian and Alpine, for `linux/amd64`. The images are also
on GitHub Container Registry as `ghcr.io/fyannk/postgres`, with the same
digests. [All tags](https://github.com/fyannk/postgres/blob/main/docs/tags.md).

## Learn more

- [Security report](https://fyannk.github.io/postgres/): the nightly comparison, image by image.
- [What changes](https://github.com/fyannk/postgres/blob/main/docs/what-changes.md) compared with the official image, and how to migrate.
- [Verifying a signature](https://github.com/fyannk/postgres/blob/main/docs/tags.md#verifying-an-image).
- [Source and issues](https://github.com/fyannk/postgres) on GitHub.

---

Apache-2.0; the images also contain docker-library/postgres's scripts, under
the MIT license. See
[NOTICE](https://github.com/fyannk/postgres/blob/main/NOTICE).
PostgreSQL® and the Slonik logo are trademarks or registered trademarks of
the PostgreSQL Community Association of Canada. This project is not affiliated
with or endorsed by the Association, nor with docker-library/postgres.
