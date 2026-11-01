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

# prune <jq filter on media_type>: delete untagged manifests older than the
# cutoff whose media type matches.
prune() {
  local kind="$1" label="$2" candidates response
  mapfile -t candidates < <(list | jq -r --arg cutoff "${cutoff}" "
    select((.tags | length) == 0 and .last_pushed < \$cutoff and (.media_type | ${kind}))
    | .manifest_digest")
  echo "${label}: ${#candidates[@]} untagged and older than ${days} days"
  local i
  for ((i = 0; i < ${#candidates[@]}; i += 50)); do
    response="$(jq -n '{digests: $ARGS.positional}' --args "${candidates[@]:i:50}" \
      | curl -fsS -X DELETE "${auth[@]}" -H 'Content-Type: application/json' --data @- "${api}")"
    jq -r '.status | to_entries[] | "  \(.key) \(.value.status.status)\(if .value.status.message then ": " + .value.status.message else "" end)"' <<<"${response}"
    if jq -e '.status | to_entries | any(.value.status.status != "success" and .value.status.status != "blocked")' <<<"${response}" >/dev/null; then
      echo "::warning::Some Docker Hub deletions in ${repository} failed; see the log above"
    fi
  done
}

echo "Pruning ${repository}: untagged manifests last pushed before ${cutoff}"
prune 'test("index|manifest\\.list")' "Indexes"
prune 'test("index|manifest\\.list") | not' "Image and attestation manifests"
