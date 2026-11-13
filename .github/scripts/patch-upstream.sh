#!/usr/bin/env bash
# Rewrite a docker-library/postgres checkout in place so every image it builds
# drops privileges with util-linux setpriv instead of gosu, and carries the
# distribution's pending updates on top of its base image.
#
#   .github/scripts/patch-upstream.sh <upstream-checkout> [<major>/<variant> ...]
#
# With no directories named, every <major>/<variant> listed in versions.json
# is patched. Each rewrite is asserted: if upstream reshapes the gosu block or
# the step-down line, this script fails instead of shipping an image that
# still carries gosu or no longer steps down at all.
set -euo pipefail

upstream="${1:?usage: $0 <upstream-checkout> [<major>/<variant> ...]}"
shift
cd "${upstream}"

if [[ "$#" -eq 0 ]]; then
  mapfile -t dirs < <(jq -r 'to_entries[] | .key as $m | .value.variants[] | "\($m)/\(.)"' versions.json)
  set -- "${dirs[@]}"
fi

# The same identity switch gosu performed: real and effective UID/GID, the
# supplementary groups from /etc/group, and HOME. setpriv does not touch the
# environment unless --reset-env is given, and that would also drop
# POSTGRES_PASSWORD and friends, so HOME is set explicitly. The text is
# written into the scripts verbatim, hence single quotes.
# shellcheck disable=SC2016
stepdown='HOME="$(getent passwd postgres | cut -d: -f6)" exec setpriv --reuid=postgres --regid=postgres --init-groups "$BASH_SOURCE" "$@"'

patch_dockerfile() {
  local file="$1" variant="$2" install
  case "${variant}" in
    alpine*)
      # Alpine splits setpriv out of util-linux into its own small package.
      install='RUN set -eux; apk add --no-cache setpriv; setpriv --reuid=65534 --regid=65534 --clear-groups true'
      ;;
    *)
      # Debian ships setpriv in util-linux, which is Essential: nothing to add.
      install='RUN set -eux; setpriv --reuid=65534 --regid=65534 --clear-groups true'
      ;;
  esac

  # Drop the whole "grab gosu" stanza: its comment header, ENV GOSU_VERSION and
  # the RUN that downloads and verifies the binary, up to the first line that
  # does not continue with a backslash. The su-exec compatibility symlink some
  # Alpine variants add is dropped with it.
  awk -v install="${install}" '
    BEGIN { state = 0; replaced = 0 }
    state == 0 && /^# grab gosu for easy step-down from root$/ { state = 1; next }
    state == 1 && /^RUN / { state = 2 }
    state == 1 { next }
    # Dockerfile comment lines inside a RUN do not continue or end it.
    state == 2 && /^#/ { next }
    state == 2 {
      if ($0 !~ /\\$/) {
        state = 0
        if (!replaced) {
          print "# step down from root with util-linux setpriv"
          print install
          replaced = 1
        }
      }
      next
    }
    /ln -svf gosu \/usr\/local\/bin\/su-exec/ { next }
    { print }
    END { if (!replaced || state != 0) exit 3 }
  ' "${file}" > "${file}.new" || {
    echo "${file}: gosu stanza not found where expected; upstream changed shape" >&2
    rm -f "${file}.new"
    return 1
  }
  mv "${file}.new" "${file}"
}

# Apply the distribution's pending updates on top of the base image, right
# after FROM. A fix published in trixie-security or Alpine's repositories then
# reaches the image the next time it is built, instead of waiting for Docker
# to rebuild the base. Packages installed later in the recipe come from the
# same repositories and are already current. On Debian this runs before
# PostgreSQL's own apt repository is added, so only Debian packages move;
# PostgreSQL itself stays at the version the recipe pins.
patch_updates() {
  local file="$1" variant="$2" upgrade froms
  case "${variant}" in
    alpine*) upgrade='RUN set -eux; apk upgrade --no-cache' ;;
    *) upgrade='RUN set -eux; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; rm -rf /var/lib/apt/lists/*' ;;
  esac
  froms="$(grep -c '^FROM ' "${file}" || true)"
  if [[ "${froms}" != "1" ]]; then
    echo "${file}: expected exactly one FROM, found ${froms}" >&2
    return 1
  fi
  UPGRADE="${upgrade}" perl -pi -e 'if (/^FROM /) { $_ .= "\n# apply the distribution'"'"'s pending updates to the base image\n$ENV{UPGRADE}\n" }' "${file}"
  grep -qxF "${upgrade}" "${file}"
}

patch_script() {
  local file="$1" before
  # shellcheck disable=SC2016 # a literal pattern, not an expansion
  before="$(grep -c 'exec gosu postgres "\$BASH_SOURCE" "\$@"' "${file}" || true)"
  if [[ "${before}" != "1" ]]; then
    echo "${file}: expected exactly one gosu step-down, found ${before}" >&2
    return 1
  fi
  STEPDOWN="${stepdown}" perl -pi -e 's/exec gosu postgres "\$BASH_SOURCE" "\$@"/$ENV{STEPDOWN}/' "${file}"
}

for dir in "$@"; do
  variant="${dir#*/}"
  [[ -f "${dir}/Dockerfile" ]] || { echo "${dir}: no Dockerfile" >&2; exit 1; }

  patch_dockerfile "${dir}/Dockerfile" "${variant}"
  patch_updates "${dir}/Dockerfile" "${variant}"
  for script in docker-entrypoint.sh docker-ensure-initdb.sh; do
    if [[ -f "${dir}/${script}" ]]; then
      patch_script "${dir}/${script}"
    fi
  done

  if grep -rniw -e gosu -e su-exec "${dir}"; then
    echo "${dir}: gosu is still referenced after patching" >&2
    exit 1
  fi
  grep -q 'exec setpriv --reuid=postgres' "${dir}/docker-entrypoint.sh"
  echo "patched ${dir}"
done
