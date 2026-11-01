#!/usr/bin/env bash
# Print the build matrix for a docker-library/postgres checkout as a compact
# JSON array, one entry per <major>/<variant> directory. Only each major's
# current Debian and Alpine releases (upstream's .debian and .alpine) are kept;
# older bases such as bookworm or a superseded Alpine are not built:
#
#   {"dir":"18/trixie","major":"18","version":"18.6","variant":"trixie",
#    "base":"debian:trixie-slim","tags":"18.6-trixie 18-trixie 18.6 18 trixie latest"}
#
# Tags follow the scheme of the official image so this one is a drop-in
# replacement: every variant gets <version>-<variant> and <major>-<variant>;
# the default Debian release also gets <version> and <major>; the default
# Alpine release also gets <version>-alpine and <major>-alpine. The newest
# stable major additionally owns the bare variant tags and latest. Pre-releases
# (for example 19rc1) never take those.
set -euo pipefail

upstream="${1:?usage: $0 <upstream-checkout>}"
cd "${upstream}"

entries="$(jq -c '
  ([ to_entries[]
     | select(.value.version | test("^[0-9]+\\.[0-9]+$"))
     | .key | tonumber ] | max | tostring) as $newest
  | [ to_entries[] | .key as $major | .value as $v
      | $v.variants[] as $variant
      | select($variant == $v.debian or $variant == "alpine\($v.alpine)")
      | ($v.version) as $version
      | ($major == $newest) as $isNewest
      | {
          dir: "\($major)/\($variant)",
          major: $major,
          version: $version,
          variant: $variant,
          tags: (
            [ "\($version)-\($variant)", "\($major)-\($variant)" ]
            + (if $variant == $v.debian then [ $version, $major ] else [] end)
            + (if $variant == "alpine\($v.alpine)" then [ "\($version)-alpine", "\($major)-alpine" ] else [] end)
            + (if $isNewest then [ $variant ] else [] end)
            + (if $isNewest and $variant == $v.debian then [ "latest" ] else [] end)
            + (if $isNewest and $variant == "alpine\($v.alpine)" then [ "alpine" ] else [] end)
          ) | join(" ")
        }
    ]
' versions.json)"

# The base image is read from the Dockerfile rather than inferred from the
# variant name, so the publish fingerprint tracks exactly what is pulled.
while IFS= read -r entry; do
  dir="$(jq -r .dir <<<"${entry}")"
  base="$(awk 'toupper($1) == "FROM" { print $2; exit }' "${dir}/Dockerfile")"
  [[ -n "${base}" ]] || { echo "${dir}: no FROM line" >&2; exit 1; }
  jq -c --arg base "${base}" '. + {base: $base}' <<<"${entry}"
done < <(jq -c '.[]' <<<"${entries}") | jq -sc '
  # Two entries claiming one tag would race to overwrite each other.
  ([ .[].tags | split(" ")[] ] | group_by(.) | map(select(length > 1) | .[0])) as $dupes
  | if ($dupes | length) > 0 then error("duplicate tags: \($dupes | join(", "))") else . end
'
