# Tags and registries

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

## Verifying an image

Every image is signed with [cosign](https://github.com/sigstore/cosign),
keylessly: the signature is bound to the publishing workflow's GitHub
identity and recorded in Sigstore's public transparency log, so there is no
key to leak or rotate.

```text
cosign verify ghcr.io/fyannk/postgres:18 \
  --certificate-identity https://github.com/fyannk/postgres/.github/workflows/build-and-publish.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The signature is stored on GHCR. A Docker Hub tag serves the same digest, so
check that digest against GHCR:

```text
digest="$(docker buildx imagetools inspect fyannk/postgres:18 --format '{{json .Manifest}}' | jq -r .digest)"
cosign verify "ghcr.io/fyannk/postgres@${digest}" \
  --certificate-identity https://github.com/fyannk/postgres/.github/workflows/build-and-publish.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The signature covers the image index, and through it the image, its SBOM and
its provenance attestation. Images published before signing was introduced
are signed when they are next rebuilt, which happens at least weekly.
