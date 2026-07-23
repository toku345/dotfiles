#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo "provision-codex.sh must run as root" >&2
  exit 1
fi

readonly TMP='/var/lib/outer-loop/install-codex'
install -d -m 0700 -o root -g root "$TMP"

fetch_sha256() {
  url=$1
  expected=$2
  output=$3
  curl --fail --silent --show-error --location --proto '=https' "$url" --output "$output"
  printf '%s  %s\n' "$expected" "$output" | sha256sum --check --status
}

fetch_sha512() {
  url=$1
  expected=$2
  output=$3
  curl --fail --silent --show-error --location --proto '=https' "$url" --output "$output"
  printf '%s  %s\n' "$expected" "$output" | sha512sum --check --status
}

fetch_sha256 \
  'https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-arm64.tar.xz' \
  '58c9520501f6ae2b52d5b210444e24b9d0c029a58c5011b797bc1fe7105886f6' \
  "$TMP/node.tar.xz"
fetch_sha512 \
  'https://registry.npmjs.org/@openai/codex/-/codex-0.144.5.tgz' \
  '8e307e2be38cbf9ef698a852fb642e2f15970c935da706cf7a77fe57ef1b76aef083849caadddc9fa5847a40fcc0fa83559a9c9341d25f5ecaf6b0fd91b0c940' \
  "$TMP/codex-base.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/@openai/codex/-/codex-0.144.5-linux-arm64.tgz' \
  'cc01e08315704764c1c4a9b26d763b64c881d06f033289d8d983ddc0d363c1771ff8b388a8d1a0b30c0d08331b3ff1c47baafc8fe47d657ff2628a3c7fe9ff45' \
  "$TMP/codex-platform.tgz"

install -d -m 0755 -o root -g root /opt/node-24.18.0 /opt/codex-0.144.5/package
tar -xJf "$TMP/node.tar.xz" --strip-components=1 -C /opt/node-24.18.0
tar -xzf "$TMP/codex-platform.tgz" --strip-components=1 -C /opt/codex-0.144.5/package
tar -xzf "$TMP/codex-base.tgz" --strip-components=1 -C /opt/codex-0.144.5/package
chown -R root:root /opt/node-24.18.0 /opt/codex-0.144.5
find /opt/node-24.18.0 /opt/codex-0.144.5 -type d -exec chmod 0755 {} +
find /opt/node-24.18.0 /opt/codex-0.144.5 -type f -perm /111 -exec chmod 0755 {} +
find /opt/node-24.18.0 /opt/codex-0.144.5 -type f ! -perm /111 -exec chmod 0644 {} +

install -m 0755 -o root -g root /dev/null /usr/local/bin/codex
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'exec /opt/node-24.18.0/bin/node /opt/codex-0.144.5/package/bin/codex.js "$@"' \
  > /usr/local/bin/codex

install -m 0644 -o root -g root /usr/local/share/outer-loop/seeds/codex-config.toml /etc/codex/config.toml
install -m 0644 -o root -g root /usr/local/share/outer-loop/seeds/codex-requirements.toml /etc/codex/requirements.toml
test ! -e /etc/codex/managed_config.toml

sudo -u calibration env CODEX_HOME=/home/calibration/.codex /usr/local/bin/codex --version | grep -qx 'codex-cli 0.144.5'
