#!/usr/bin/env bash
# Check out docker-library/postgres into <dest> and print the commit it is at.
#
#   .github/scripts/fetch-upstream.sh <dest> [<ref>]
#
# <ref> defaults to the default branch. Pass the commit a previous job printed
# so every job of a run builds the very same upstream revision, even if
# upstream moves while the run is in flight.
set -euo pipefail

dest="${1:?usage: $0 <dest> [<ref>]}"
ref="${2:-HEAD}"
url="https://github.com/docker-library/postgres.git"

git init -q "${dest}"
git -C "${dest}" fetch -q --depth 1 "${url}" "${ref}"
git -C "${dest}" checkout -q --detach FETCH_HEAD
git -C "${dest}" rev-parse HEAD
