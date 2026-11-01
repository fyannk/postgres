#!/usr/bin/env bash
# Assert that a built image keeps upstream's behaviour while carrying no gosu.
#
#   .github/scripts/check-image.sh <image>
#
# Every check runs against the image as built, not the recipe, so a regression
# anywhere between the patch and the final layer is caught.
set -euo pipefail

image="${1:?usage: $0 <image>}"
fail=0
name="pg-check-$$"
init_dir="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { docker rm -f "${name}" >/dev/null 2>&1 || true; rm -rf "${init_dir}"; }
trap cleanup EXIT

echo "::group::No gosu or su-exec anywhere in the filesystem"
# Read the exported filesystem rather than searching from inside a container,
# so every directory is visible regardless of permissions.
cid="$(docker create "${image}")"
found="$(docker export "${cid}" | tar -tf - | grep -E '(^|/)(gosu|su-exec)$' || true)"
docker rm "${cid}" >/dev/null
if [[ -n "${found}" ]]; then
  echo "FAIL: found ${found}"
  fail=1
fi
if docker image inspect "${image}" --format '{{json .Config.Env}}' | grep -q GOSU_VERSION; then
  echo "FAIL: GOSU_VERSION is still set in the image environment"
  fail=1
fi
echo "::endgroup::"

echo "::group::setpriv is available"
docker run --rm --entrypoint setpriv "${image}" --version
echo "::endgroup::"

# The init script runs inside the stepped-down entrypoint; if it exits non-zero
# initialisation aborts and the server never becomes ready.
cat > "${init_dir}/00-identity.sh" <<'SH'
#!/bin/bash
set -e
expected_home="$(getent passwd postgres | cut -d: -f6)"
echo "initdb.d: uid=$(id -u) gid=$(id -g) groups=$(id -G) HOME=${HOME}"
[ "$(id -u)" = "$(id -u postgres)" ]
[ "$(id -g)" = "$(id -g postgres)" ]
[ "$(id -G | tr ' ' '\n' | sort | tr '\n' ' ')" = "$(id -G postgres | tr ' ' '\n' | sort | tr '\n' ' ')" ]
[ "${HOME}" = "${expected_home}" ]
SH
chmod 0755 "${init_dir}" "${init_dir}/00-identity.sh"

wait_ready() {
  local _
  for _ in $(seq 1 60); do
    # The entrypoint runs a temporary server during init; wait for the final
    # one, which is PID 1 once init is over.
    if docker exec "${name}" sh -c 'pg_isready -q -U postgres && [ "$(cat /proc/1/comm)" = postgres ]' 2>/dev/null; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "${name}")" != "true" ]]; then
      break
    fi
    sleep 1
  done
  docker logs "${name}" || true
  return 1
}

echo "::group::Started as root, the server steps down to postgres"
docker run -d --name "${name}" \
  -e POSTGRES_PASSWORD=ci-only-password \
  -v "${init_dir}:/docker-entrypoint-initdb.d:ro" \
  "${image}" >/dev/null
if wait_ready; then
  docker logs "${name}" 2>&1 | grep 'initdb.d:'
  pid1="$(docker exec "${name}" sh -c 'awk "/^Uid:/ { print \$2, \$3, \$4, \$5 }" /proc/1/status')"
  expected="$(docker exec "${name}" id -u postgres)"
  echo "PID 1 real/effective/saved/fs UID: ${pid1}"
  if [[ "${pid1}" != "${expected} ${expected} ${expected} ${expected}" ]]; then
    echo "FAIL: PID 1 does not run as postgres (${expected})"
    fail=1
  fi
  docker exec -u postgres "${name}" psql -tAc 'select current_user, version()'
else
  echo "FAIL: the server did not come up"
  fail=1
fi
docker rm -f "${name}" >/dev/null
echo "::endgroup::"

echo "::group::Started directly as postgres, nothing steps down"
uidgid="$(docker run --rm --entrypoint sh "${image}" -c 'echo "$(id -u postgres):$(id -g postgres)"')"
docker run -d --name "${name}" --user "${uidgid}" \
  -e POSTGRES_PASSWORD=ci-only-password "${image}" >/dev/null
if ! wait_ready; then
  echo "FAIL: the server did not come up as ${uidgid}"
  fail=1
fi
docker rm -f "${name}" >/dev/null
echo "::endgroup::"

echo "::group::docker-ensure-initdb.sh steps down and initialises"
if ! docker run --rm -e POSTGRES_PASSWORD=ci-only-password "${image}" docker-ensure-initdb.sh; then
  echo "FAIL: docker-ensure-initdb.sh"
  fail=1
fi
echo "::endgroup::"

exit "${fail}"
