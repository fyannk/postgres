<!--
Thanks for contributing. Keep one focused change per PR. This repository ships
a patch over docker-library/postgres, not a fork of it: the patch script is the
source of truth and the README explains what the resulting images guarantee.
-->

## What and why

<!-- What does this change, and what problem does it solve? -->

## How it was verified

<!-- Commands you ran, and behavior you confirmed. -->

- [ ] `.github/scripts/patch-upstream.sh` applies cleanly to current upstream
- [ ] At least one Debian and one Alpine variant build from the patched recipe
- [ ] `.github/scripts/check-image.sh` passes on the built image

## Invariants

<!-- These boundaries are the reason the images exist. CI enforces them in
     check-image.sh; confirm the change keeps them. -->

- [ ] No `gosu` or `su-exec` binary, and no `GOSU_VERSION` in the environment
- [ ] Started as root, the server and init scripts run as `postgres` with its
      supplementary groups and `HOME`
- [ ] Everything else is upstream's recipe, unchanged
- [ ] README updated if the tags, guarantees, or release automation changed
