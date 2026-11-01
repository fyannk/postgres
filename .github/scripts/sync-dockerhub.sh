#!/usr/bin/env bash
# Mirror the published tags from the source repository (GHCR) to Docker Hub,
# copying only those whose digest differs:
#
#   MATRIX='<matrix.sh output>' .github/scripts/sync-dockerhub.sh <source-repo> <namespace>/<repository>
#
# With DRY_RUN=true it only reports what it would copy.
#
# The source is the one the publish builds, checks and tags. Docker Hub
# receives the very same digest, attestations included, so nothing pushed
# here needs checking again: the digest is the content.
#
# Docker Hub allows an account 200 registry requests an hour, so this avoids
# its registry for everything but the copies themselves: the current Hub tags
# come from the Hub API, an unchanged tag costs nothing, and a copy that is
# throttled waits and retries. Whatever does not make it is copied by the
# next run, which compares again from scratch.
set -euo pipefail

source="${1:?usage: $0 <source-repo> <namespace>/<repository>}"
target="${2:?usage: $0 <source-repo> <namespace>/<repository>}"
: "${MATRIX:?}"
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

declare -A hub=()
while IFS=$'\t' read -r tag digest; do
  hub["${tag}"]="${digest}"
done < <(hub_tags)

# Group the tags to copy by the source digest they point to, so each image is
# copied once with all of its tags.
declare -A pending=()
mapfile -t tags < <(jq -r '.[].tags | split(" ")[]' <<<"${MATRIX}")
missing=0
for tag in "${tags[@]}"; do
  if ! digest="$(docker buildx imagetools inspect "${source}:${tag}" --format '{{json .Manifest}}' 2>/dev/null | jq -r .digest)"; then
    echo "::warning::${source}:${tag} is not published; nothing to mirror"
    missing=$((missing + 1))
    continue
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
  echo "Dry run: ${#pending[@]} image(s) to mirror; ${missing} tag(s) not published at the source."
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
hub=()
while IFS=$'\t' read -r tag digest; do
  hub["${tag}"]="${digest}"
done < <(hub_tags)
wrong=0
for digest in "${!pending[@]}"; do
  for tag in ${pending[${digest}]}; do
    if [[ "${hub[${tag}]:-}" != "${digest}" ]]; then
      echo "::error::docker.io/${target}:${tag} is ${hub[${tag}]:-missing}, expected ${digest}"
      wrong=$((wrong + 1))
    fi
  done
done

echo "Mirrored ${#pending[@]} image(s); ${missing} tag(s) not published at the source."
[[ "${failed}" -eq 0 && "${wrong}" -eq 0 ]]
