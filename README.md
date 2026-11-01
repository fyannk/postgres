<p align="center">
  <img src="site/assets/mark.svg" width="140" alt="fyannk/postgres logo: an elephant peeking over a shield bearing an ermine">
</p>

<h1 align="center">postgres</h1>

<p align="center">
  <strong>The official PostgreSQL® image, with the known vulnerabilities that already have a fix left out.</strong><br>
  Rebuilt as soon as a fix lands, signed, and measured against the official image every night, in public.
</p>

<p align="center">
  <a href="https://fyannk.github.io/postgres/"><img src="https://img.shields.io/badge/security_report-nightly-090c0a?style=flat-square&labelColor=1b231d" alt="Nightly security report"></a>
  <a href="https://github.com/fyannk/postgres/actions/workflows/ci.yml"><img src="https://github.com/fyannk/postgres/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="docs/tags.md#verifying-an-image"><img src="https://img.shields.io/badge/signed-cosign-090c0a?style=flat-square&labelColor=1b231d" alt="Signed with cosign"></a>
  <a href="https://github.com/fyannk/postgres/pkgs/container/postgres"><img src="https://img.shields.io/badge/ghcr.io-fyannk%2Fpostgres-090c0a?style=flat-square&logo=github&logoColor=b3bf3a&labelColor=1b231d" alt="On GitHub Container Registry"></a>
  <a href="https://hub.docker.com/r/fyannk/postgres"><img src="https://img.shields.io/badge/docker_hub-fyannk%2Fpostgres-090c0a?style=flat-square&logo=docker&logoColor=b3bf3a&labelColor=1b231d" alt="On Docker Hub"></a>
</p>

Same PostgreSQL, same tags, same settings as the image you already run. The
difference is what surrounds it: these images are rebuilt whenever Debian or
Alpine ship a security fix, and they leave out the one bundled program the
distribution cannot patch. Every night, each one is scanned next to its
official counterpart, and the [report](https://fyannk.github.io/postgres/)
shows the result, including whatever is still left.

> [!IMPORTANT]
> This does not make PostgreSQL itself any safer, and it cannot fix a
> vulnerability before Debian, Alpine or the PostgreSQL project do. "No known,
> fixable vulnerabilities" means none that the scanners know about and that
> have a fix today; the report shows the rest, and how current the scanners'
> data is.

## Why use it?

- **Drop-in**: change the registry prefix, keep everything else.
- **Patched sooner**: rebuilt when a fix lands, and at least once a week.
- **Nothing left behind**: no bundled extra that only a new release could update.
- **Proven, not promised**: a public, nightly comparison with the official image.
- **Signed**: each image is signed as it is published, and comes with the list of what is inside it.

## Quick start

```sh
docker run -d --name db -e POSTGRES_PASSWORD=change-me ghcr.io/fyannk/postgres:18
```

That is the whole switch. Everything documented for the
[official image](https://hub.docker.com/_/postgres) works the same way. The
images are also on Docker Hub as `fyannk/postgres`.

## Project status

Maintained. Every PostgreSQL version the official image maintains is
published, on Debian and Alpine, for `linux/amd64`.

## Documentation

- [Security report](https://fyannk.github.io/postgres/): the nightly comparison, image by image.
- [What changes](docs/what-changes.md) compared with the official image, and how to migrate.
- [Tags and registries](docs/tags.md), and how to verify a signature.
- [How images are checked](docs/verification.md) before they ship, and how they are measured.
- [Maintaining](docs/maintaining.md): local builds and the publishing pipeline.

## Contributing

Contributions are welcome. Read
[CONTRIBUTING.md](https://github.com/fyannk/.github/blob/main/CONTRIBUTING.md)
first. For larger changes, open an issue before writing code.

## Security

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).

---

<sub>PostgreSQL® and the Slonik logo are trademarks or registered trademarks of
the PostgreSQL Community Association of Canada. This project is not affiliated
with or endorsed by the Association, nor with
[docker-library/postgres](https://github.com/docker-library/postgres), whose
recipe it builds.</sub>
