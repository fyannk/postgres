#!/usr/bin/env bash
# Mirror every tag of the source repository (GHCR) to Docker Hub, copying
# only those whose digest differs there:
#
#   .github/scripts/sync-dockerhub.sh <source-repo> <namespace>/<repository>
#
# With DRY_RUN=true it only reports what it would copy. GHCR_USER and
# GHCR_TOKEN authenticate the GHCR tag listing; a public package needs none.
#
# The source is where the publish builds, checks and tags. Docker Hub
# receives the very same digest, attestations included, so nothing copied
# here needs checking again: the digest is the content. Every tag the source
# has is considered, not only the current build matrix, so a copy that fails
# is retried by the next run even after upstream has moved on to a newer
# release.
#
# Docker Hub allows an account 200 registry requests an hour, so this avoids
# its registry for everything but the copies themselves: the current Hub tags
# come from the Hub API, an unchanged tag costs nothing, and a copy that is
# throttled waits and retries. A listing that fails stops the run rather than
# being mistaken for missing tags and copied again.
set -euo pipefail

source="${1:?usage: $0 <source-repo> <namespace>/<repository>}"
target="${2:?usage: $0 <source-repo> <namespace>/<repository>}"
[[ "${source}" == ghcr.io/* ]] || { echo "the source must be a ghcr.io repository" >&2; exit 1; }
source_path="${source#ghcr.io/}"
tags_api="https://hub.docker.com/v2/namespaces/${target%%/*}/repositories/${target#*/}/tags"

# tag<TAB>digest for every tag currently on Docker Hub.
hub_tags() {
  local url="${tags_api}?page_size=100" page
  while [[ -n "${url}" ]]; do
    page="$(curl -fsS --retry 3 "${url}")"
    jq -r '.results[] | "\(.name)\t\(.digest)"' <<<"${page}"
    url="$(jq -r '.next // empty' <<<"${page}")"
  done
}

# Every tag of the source repository, from the registry's own tag list.
source_tags() {
  local auth=() token url headers page next
  [[ -n "${GHCR_TOKEN:-}" ]] && auth=(-u "${GHCR_USER:-token}:${GHCR_TOKEN}")
  token="$(curl -fsS "${auth[@]}" "https://ghcr.io/token?service=ghcr.io&scope=repository:${source_path}:pull" | jq -er .token)"
  url="https://ghcr.io/v2/${source_path}/tags/list?n=1000"
  headers="$(mktemp)"
  while [[ -n "${url}" ]]; do
    page="$(curl -fsS --retry 3 -D "${headers}" -H "Authorization: Bearer ${token}" "${url}")"
    jq -r '.tags // [] | .[]' <<<"${page}"
    next="$(sed -n 's/^[Ll]ink: *<\([^>]*\)>.*rel="next".*/\1/p' "${headers}" | tr -d '\r')"
    url="${next:+https://ghcr.io${next}}"
  done
  rm -f "${headers}"
}

# Checked assignments: set -e stops here if a listing failed part-way.
read_hub() {
  local listing
  listing="$(hub_tags)"
  hub=()
  while IFS=$'\t' read -r tag digest; do
    [[ -n "${tag}" ]] && hub["${tag}"]="${digest}"
  done <<<"${listing}"
}

declare -A hub=()
read_hub
listing="$(source_tags)"
mapfile -t tags <<<"${listing}"
[[ -n "${tags[0]:-}" ]] || { echo "${source} has no tags" >&2; exit 1; }
echo "${#tags[@]} tag(s) at ${source}, ${#hub[@]} on docker.io/${target}"

# Group the tags to copy by the source digest they point to, so each image is
# copied once with all of its tags.
declare -A pending=()
errors="$(mktemp)"
trap 'rm -f "${errors}"' EXIT
for tag in "${tags[@]}"; do
  # A tag deleted since the listing (a replaced image's signature, pruned)
  # has nothing left to mirror; any other inspect failure stops the run.
  if ! digest="$(docker buildx imagetools inspect "${source}:${tag}" --format '{{json .Manifest}}' 2>"${errors}" | jq -er .digest)"; then
    if grep -q 'not found' "${errors}"; then
      echo "${tag}: deleted from ${source} since the listing, skipped"
      continue
    fi
    cat "${errors}" >&2
    exit 1
  fi
  if [[ "${hub[${tag}]:-}" == "${digest}" ]]; then
    echo "${tag}: up to date"
  else
    pending["${digest}"]+=" ${tag}"
  fi
done

if [[ "${DRY_RUN:-}" == "true" ]]; then
  for digest in "${!pending[@]}"; do
    echo "would copy ${digest} ->${pending[${digest}]}"
  done
  echo "Dry run: ${#pending[@]} image(s) to mirror."
  exit 0
fi

failed=0
for digest in "${!pending[@]}"; do
  args=()
  for tag in ${pending[${digest}]}; do
    args+=(--tag "docker.io/${target}:${tag}")
  done
  echo "::group::${digest} ->${pending[${digest}]}"
  copied=false
  for attempt in 1 2 3 4; do
    if docker buildx imagetools create "${args[@]}" "${source}@${digest}"; then
      copied=true
      break
    fi
    if [[ "${attempt}" -lt 4 ]]; then
      echo "Copy failed (attempt ${attempt}); retrying in $((attempt * 90))s"
      sleep $((attempt * 90))
    fi
  done
  echo "::endgroup::"
  if [[ "${copied}" != "true" ]]; then
    echo "::error::Could not copy ${digest} to docker.io/${target}; the next run retries it"
    failed=$((failed + 1))
  fi
done

# Confirm through the Hub API, which costs no registry request.
read_hub
wrong=0
for digest in "${!pending[@]}"; do
  for tag in ${pending[${digest}]}; do
    if [[ "${hub[${tag}]:-}" != "${digest}" ]]; then
      echo "::error::docker.io/${target}:${tag} is ${hub[${tag}]:-missing}, expected ${digest}"
      wrong=$((wrong + 1))
    fi
  done
done

echo "Mirrored ${#pending[@]} image(s)."
[[ "${failed}" -eq 0 && "${wrong}" -eq 0 ]]
