#!/usr/bin/env bash
# Delete untagged manifests from a Docker Hub repository once they are older
# than a grace period, so an image replaced by a newer push stays pullable by
# digest for a while and then goes:
#
#   .github/scripts/prune-dockerhub.sh <namespace>/<repository> <days>
#
# Expects DOCKERHUB_USERNAME and DOCKERHUB_TOKEN (a personal access token with
# delete permission). How the Hub API behaves, as observed on 2026-11-01:
#
# - GET /v2/namespaces/<ns>/repositories/<repo>/manifests lists every manifest
#   (indexes, platform images, attestations) with its tags and last push,
#   paginated with last_evaluated_key.
# - DELETE on the same path with {"digests": [...]} deletes them one by one.
#   A manifest another one still references is refused ("blocked"), but a
#   tagged one is deleted without complaint. Only untagged digests are ever
#   sent from here, and tags are re-read right before each deletion.
#
# Deletion runs in two passes: untagged indexes first, which releases the
# platform and attestation manifests they reference, then untagged manifests
# that nothing references any more. One still referenced by a kept index is
# refused by Hub and left alone.
set -euo pipefail

repository="${1:?usage: $0 <namespace>/<repository> <days>}"
days="${2:?usage: $0 <namespace>/<repository> <days>}"
: "${DOCKERHUB_USERNAME:?}" "${DOCKERHUB_TOKEN:?}"
api="https://hub.docker.com/v2/namespaces/${repository%%/*}/repositories/${repository#*/}/manifests"
cutoff="$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ)"

token="$(jq -n --arg id "${DOCKERHUB_USERNAME}" --arg secret "${DOCKERHUB_TOKEN}" '{identifier: $id, secret: $secret}' \
  | curl -fsS -X POST https://hub.docker.com/v2/auth/token -H 'Content-Type: application/json' --data @- \
  | jq -r '.access_token // empty')"
[[ -n "${token}" ]] || { echo "Docker Hub authentication failed" >&2; exit 1; }
auth=(-H "Authorization: Bearer ${token}")
failures=0

list() {
  local key="" page
  while :; do
    page="$(curl -fsS -G "${auth[@]}" --data-urlencode page_size=100 \
      ${key:+--data-urlencode "last_evaluated_key=${key}"} "${api}")"
    jq -c '.manifests[]' <<<"${page}"
    key="$(jq -r '.last_evaluated_key // empty' <<<"${page}")"
    [[ -n "${key}" ]] || break
  done
}

# delete <digest>...: ask Hub to delete these manifests. Hub answers some
# batches with a server error instead of a per-digest status (seen on
# 2026-11-13 for image and attestation manifests), so a failed batch is split
# in half and retried, down to single digests; one Hub still refuses on its
# own is reported and left for the next run.
delete() {
  local response status
  response="$(mktemp)"
  status="$(jq -n '{digests: $ARGS.positional}' --args "$@" \
    | curl -sS -o "${response}" -w '%{http_code}' -X DELETE "${auth[@]}" \
      -H 'Content-Type: application/json' --data @- "${api}")" || status=000
  if [[ "${status}" == 2* ]]; then
    jq -r '.status | to_entries[] | "  \(.key) \(.value.status.status)\(if .value.status.message then ": " + .value.status.message else "" end)"' "${response}"  || failures=$((failures + 1))
    if jq -e '.status | to_entries | any(.value.status.status != "success" and .value.status.status != "blocked")' "${response}" >/dev/null; then
      failures=$((failures + 1))
    fi
  elif [[ "$#" -gt 1 ]]; then
    local half=$(($# / 2))
    echo "  HTTP ${status} for ${#} digests; retrying in two halves"
    delete "${@:1:half}"
    delete "${@:half+1}"
  else
    echo "  $1 HTTP ${status}: $(head -c 300 "${response}")"
    failures=$((failures + 1))
  fi
  rm -f "${response}"
}

# prune <jq filter on media_type> <label>: delete untagged manifests older
# than the cutoff whose media type matches.
prune() {
  local kind="$1" label="$2" candidates
  mapfile -t candidates < <(list | jq -r --arg cutoff "${cutoff}" "
    select((.tags | length) == 0 and .last_pushed < \$cutoff and (.media_type | ${kind}))
    | .manifest_digest")
  echo "${label}: ${#candidates[@]} untagged and older than ${days} days"
  local i
  for ((i = 0; i < ${#candidates[@]}; i += 50)); do
    delete "${candidates[@]:i:50}"
  done
}

echo "Pruning ${repository}: untagged manifests last pushed before ${cutoff}"
prune 'test("index|manifest\\.list")' "Indexes"
prune 'test("index|manifest\\.list") | not' "Image and attestation manifests"

if [[ "${failures}" -gt 0 ]]; then
  echo "::warning::${failures} Docker Hub deletion(s) in ${repository} failed; see the log above. The next run retries them."
fi
