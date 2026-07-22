#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "check-mount-policy.sh must run as root" >&2
  exit 1
fi

if ! mount_targets=$(findmnt -rn -o TARGET); then
  echo 'failed to enumerate mounts' >&2
  exit 1
fi

if printf '%s\n' "$mount_targets" \
  | grep -Fvx '/mnt/lima-cidata' \
  | grep -Eq '^/(Users|Volumes|mnt/lima-|home/lima-provision/.*share)'; then
  echo 'unexpected host-style mount detected' >&2
  exit 1
fi
