#!/usr/bin/env bash
# Scan every published image and its official upstream counterpart, and write
# the data behind the security report site into <out-dir>:
#
#   .github/scripts/security-report.sh <upstream-checkout> <out-dir> [<major>-<variant> ...]
#
# With no image named, every image in the build matrix is reported.
#   data/latest.json        one summary per image pair and scanner
#   data/images/<name>.json every finding, for the per-image detail view
#   data/history.json       one aggregate row per day, appended to the
#                           history at $HISTORY_URL when it can be fetched
#   sboms/<name>.spdx.json  the SBOM attached to each published image
#
# Both sides are inventoried by Syft so the comparison is like for like: ours
# from the SBOM attached at publish time, upstream by running Syft on the
# official image (its own attestations come from Docker Scout, which grype
# cannot read distribution packages from). grype scans those SBOMs. Trivy
# scans the images themselves: it does not detect the distribution in a Syft
# SPDX document and would silently report nothing.
#
# Each image is pulled once and scanned from the local daemon, so a run costs
# one Docker Hub pull per upstream image rather than one per tool.
#
# Expects $REPO (our image repository), $GRYPE, $SYFT and $TRIVY (commands),
# and optionally $HISTORY_URL and $UPSTREAM_REPO (a mirror of the official
# image, docker.io/library/postgres by default). Only linux/amd64 is compared, the platform this
# repository publishes.
# shellcheck disable=SC2016 # the single-quoted strings are jq programs
set -euo pipefail

upstream="${1:?usage: $0 <upstream-checkout> <out-dir> [<major>-<variant> ...]}"
out="${2:?usage: $0 <upstream-checkout> <out-dir> [<major>-<variant> ...]}"
shift 2
only="$(jq -cn '$ARGS.positional' --args "$@")"
: "${REPO:?}" "${GRYPE:?}" "${SYFT:?}" "${TRIVY:?}"
platform="linux/amd64"
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "${out}/data/images" "${out}/sboms"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# One finding per advisory, package and installed version, in a shape shared
# by both scanners: severity lowercased, and the package classed as an OS
# package, a Go module (including the standard library) or anything else.
#
# From an SBOM grype matches the Go standard library twice, by CPE against the
# CVE and by package against the Go vulnerability database, so most Go issues
# arrive as both CVE-x and GO-x. Each finding is keyed on its CVE when it has
# one, and the CVE's own record wins so its severity is the one kept.
grype_findings='[.matches[] | {
    id: (if (.vulnerability.id | startswith("CVE-")) then .vulnerability.id
         else ([.relatedVulnerabilities[]?.id | select(startswith("CVE-"))][0] // .vulnerability.id) end),
    primary: (.vulnerability.id | startswith("CVE-")),
    severity: (.vulnerability.severity | ascii_downcase),
    package: .artifact.name,
    version: .artifact.version,
    kind: (if .artifact.type == "go-module" then "go"
           elif (.artifact.type == "deb" or .artifact.type == "apk") then "os"
           else "other" end),
    fixed: (.vulnerability.fix.state == "fixed"),
    fixed_in: (.vulnerability.fix.versions // [] | join(", ")),
    state: .vulnerability.fix.state
  }] | sort_by(.primary | not) | unique_by([.id, .package, .version])
  | map(del(.primary)) | sort_by(.id, .package)'

trivy_findings='[.Results[]? | .Class as $class | .Type as $type | .Vulnerabilities[]? | {
    id: .VulnerabilityID,
    severity: (.Severity | ascii_downcase),
    package: .PkgName,
    version: .InstalledVersion,
    kind: (if $type == "gobinary" then "go"
           elif $class == "os-pkgs" then "os"
           else "other" end),
    fixed: ((.FixedVersion // "") != ""),
    fixed_in: (.FixedVersion // ""),
    state: (.Status // "")
  }] | unique_by([.id, .package, .version]) | sort_by(.id, .package)'

summary='{
    total: length,
    fixable: (map(select(.fixed)) | length),
    go: (map(select(.kind == "go")) | length),
    severity: (reduce .[] as $f ({critical: 0, high: 0, medium: 0, low: 0, negligible: 0, unknown: 0};
      .[if has($f.severity) then $f.severity else "unknown" end] += 1)),
    fixable_severity: (reduce (.[] | select(.fixed)) as $f ({critical: 0, high: 0, medium: 0, low: 0, negligible: 0, unknown: 0};
      .[if has($f.severity) then $f.severity else "unknown" end] += 1))
  }'

# scan <side> <name> <ref> <sbom-source>: writes ${work}/<side>-<name>.json
# with the image metadata, both scanners' findings, or an error.
scan() {
  local side="$1" name="$2" ref="$3" sbom_source="$4"
  local base="${work}/${side}-${name}" digest created

  if ! docker pull -q --platform "${platform}" "${ref}" >/dev/null 2>"${base}.err"; then
    echo "::warning::${ref} could not be pulled, reporting it as unavailable: $(tail -n 1 "${base}.err")"
    jq -n --arg ref "${ref}" '{ref: $ref, error: "not available"}' > "${base}.json"
    return
  fi
  digest="$(docker image inspect "${ref}" --format '{{json .RepoDigests}}' | jq -r '.[0] // "" | sub("^[^@]*@"; "")')"
  created="$(docker image inspect "${ref}" --format '{{.Created}}')"

  # By digest, not tag: a publish moving the tag mid-run must not pair this
  # image's scans with another image's SBOM.
  if [[ "${sbom_source}" == "attached" ]]; then
    docker buildx imagetools inspect "${ref%:*}@${digest}" --format '{{json .SBOM.SPDX}}' > "${base}.spdx.json"
  else
    "${SYFT}" -q "docker:${ref}" -o "spdx-json=${base}.spdx.json"
  fi
  if ! jq -e '.packages | length > 0' "${base}.spdx.json" >/dev/null 2>&1; then
    echo "::warning::${ref} has no usable SBOM"
    jq -n --arg ref "${ref}" --arg digest "${digest}" '{ref: $ref, digest: $digest, error: "no SBOM"}' > "${base}.json"
    docker image rm -f "${ref}" >/dev/null
    return
  fi

  "${GRYPE}" -q -o json "sbom:${base}.spdx.json" | jq "${grype_findings}" > "${base}.grype.json"
  "${TRIVY}" image -q --image-src docker --scanners vuln -f json "${ref}" | jq "${trivy_findings}" > "${base}.trivy.json"
  # Runners have room for a few images, not two dozen.
  docker image rm -f "${ref}" >/dev/null

  jq -n --arg ref "${ref}" --arg digest "${digest}" --arg created "${created}" \
    --slurpfile grype "${base}.grype.json" --slurpfile trivy "${base}.trivy.json" \
    '{ref: $ref, digest: $digest, created: (if $created == "" then null else $created end),
      findings: {grype: $grype[0], trivy: $trivy[0]}}' > "${base}.json"
}

revision="$(git -C "${upstream}" rev-parse HEAD)"
mapfile -t entries < <("${here}/matrix.sh" "${upstream}" | jq -c --argjson only "${only}" '
  .[] | select(($only | length) == 0 or ("\(.major)-\(.variant)" | IN($only[])))')

for entry in "${entries[@]}"; do
  version="$(jq -r .version <<<"${entry}")"
  variant="$(jq -r .variant <<<"${entry}")"
  name="$(jq -r '"\(.major)-\(.variant)"' <<<"${entry}")"
  echo "::group::${name}"
  scan ours "${name}" "${REPO}:${version}-${variant}" attached
  scan upstream "${name}" "${UPSTREAM_REPO:-docker.io/library/postgres}:${version}-${variant}" syft
  if [[ -f "${work}/ours-${name}.spdx.json" ]] && jq -e '.packages | length > 0' "${work}/ours-${name}.spdx.json" >/dev/null; then
    cp "${work}/ours-${name}.spdx.json" "${out}/sboms/${name}.spdx.json"
  fi
  jq -n --argjson entry "${entry}" --slurpfile ours "${work}/ours-${name}.json" --slurpfile up "${work}/upstream-${name}.json" '
    {name: "\($entry.major)-\($entry.variant)", major: $entry.major, version: $entry.version,
     variant: $entry.variant, ours: $ours[0], upstream: $up[0]}' > "${out}/data/images/${name}.json"
  echo "::endgroup::"
done

if ! compgen -G "${out}/data/images/*.json" >/dev/null; then
  echo "No image was scanned" >&2
  exit 1
fi

tools="$(jq -n --arg grype "$("${GRYPE}" version -o json | jq -r .version)" \
  --arg trivy "$("${TRIVY}" --version -f json | jq -r .Version)" \
  --arg syft "$("${SYFT}" version -o json | jq -r .version)" \
  '{grype: $grype, trivy: $trivy, syft: $syft}')"

# The summary drops the finding lists, which stay in the per-image files.
jq -s --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg revision "${revision}" --argjson tools "${tools}" "
  def side: if .error then {ref, digest, error} else
    {ref, digest, created, scans: (.findings | map_values(${summary}))} end;
  {generated: \$generated, upstream_revision: \$revision, tools: \$tools,
   images: (sort_by(-(.major | tonumber? // 0), .variant) | map({name, major, version, variant,
     ours: (.ours | side), upstream: (.upstream | side)}))}
" "${out}"/data/images/*.json > "${out}/data/latest.json"

# History keeps one aggregate row per day across all images, so the trend
# reads at a glance. Today's row replaces an earlier run of the same day.
# Only a 404 (the first deployment) starts it afresh: any other failure stops
# the run, since publishing would overwrite the accumulated history.
history="[]"
if [[ -n "${HISTORY_URL:-}" ]]; then
  status="$(curl -sSL -o "${work}/history.json" -w '%{http_code}' "${HISTORY_URL}")"
  case "${status}" in
    200)
      if ! history="$(jq -ce 'if type == "array" then . else error("not an array") end' "${work}/history.json")"; then
        echo "${HISTORY_URL} is not a valid history; not publishing over it" >&2
        exit 1
      fi
      ;;
    404) echo "No history at ${HISTORY_URL} yet; starting one." ;;
    *)
      echo "Fetching ${HISTORY_URL} failed with HTTP ${status}; not publishing over the history" >&2
      exit 1
      ;;
  esac
fi
# Totals count only images scanned on both sides with that scanner, as the
# page's tiles do, so one side failing a night does not skew the comparison.
jq --argjson history "${history}" '
  def totals($side; $scanner): [.images[]
      | select(.ours.scans[$scanner] and .upstream.scans[$scanner])
      | .[$side].scans[$scanner]]
    | {total: (map(.total) | add // 0), fixable: (map(.fixable) | add // 0),
       critical: (map(.severity.critical) | add // 0), high: (map(.severity.high) | add // 0),
       images: length};
  (.generated[0:10]) as $date
  | ($history | map(select(.date != $date)))
    + [{date: $date,
        ours: {grype: totals("ours"; "grype"), trivy: totals("ours"; "trivy")},
        upstream: {grype: totals("upstream"; "grype"), trivy: totals("upstream"; "trivy")}}]
  | sort_by(.date) | .[-400:]
' "${out}/data/latest.json" > "${out}/data/history.json"

jq -r '.images[] | "\(.name)\tours: \(.ours.scans.grype.total // .ours.error) grype, \(.ours.scans.trivy.total // "-") trivy\tupstream: \(.upstream.scans.grype.total // .upstream.error) grype, \(.upstream.scans.trivy.total // "-") trivy"' "${out}/data/latest.json"
