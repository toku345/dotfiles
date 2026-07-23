#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo "provision-claude.sh must run as root" >&2
  exit 1
fi

readonly TMP='/var/lib/outer-loop/install-claude'
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
  'https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.211.tgz' \
  'c86857485f587c7a1519ed12e8df64cb9b9a8f1efd7febede994f71e10492c54a326d88612cebb1f487dde24dd3af3d4ff039f7e28e94d4027efa53ffaf4274d' \
  "$TMP/claude-base.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64/-/claude-code-linux-arm64-2.1.211.tgz' \
  '64fb6163196d6ea03ced7fdabdb0070345d53ee16eaa836b5ca466c741b4a9fc04bb2ca5a1529d694b18d4011b15740844960a659f14bcc9250f68ef9bdf9eb4' \
  "$TMP/claude.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/@anthropic-ai/sandbox-runtime/-/sandbox-runtime-0.0.65.tgz' \
  'd2e5b66cc2012d3e39b5e8542e5a213a7728ef5c42273adbe21ee94125273187cc24027beec30023743d8cfda1f7bde1c39b60e9d7c48f26b273ce6b5e2c6e02' \
  "$TMP/srt.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/@pondwader/socks5-server/-/socks5-server-1.0.10.tgz' \
  '6d0634eb0cf347c0f6faf54252806caf9412d94e9480f51046612b370b6cb88eaf2dcc912a469f8e4af72b16ed1857fd68104857699cbe5b0a0f551868857eb2' \
  "$TMP/socks.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/commander/-/commander-12.1.0.tgz' \
  '570f2a1caddb64cf72fcfd74bb75626fca3f0dd92f0363ad3ed66f0fcef540a8f2ef85a3d5648a1482cc3d13d27544b1e5114ad5aae527312d0383e41609dbb8' \
  "$TMP/commander.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/node-forge/-/node-forge-1.4.0.tgz' \
  '2daac51f4fba55fae2121a8c31c2d7d85ed2c125de5b09c400912c626e50296721895615bc9c95f6fed40ef52ffb0e473b6dd9a504d70effc6c5d0dd3323aea1' \
  "$TMP/node-forge.tgz"
fetch_sha512 \
  'https://registry.npmjs.org/zod/-/zod-3.25.76.tgz' \
  '83352dfeab7cd675ec14628815c0b76277c4031e4d92e9c27e70e5bee0524854b4d9b717bb82e679ad001485306cb5b158fc7777da7c4b94286ae8ca70d43171' \
  "$TMP/zod.tgz"

install -d -m 0755 -o root -g root \
  /opt/node-24.18.0 \
  /opt/claude-2.1.211 \
  /opt/srt-0.0.65/node_modules/@anthropic-ai/sandbox-runtime \
  /opt/srt-0.0.65/node_modules/@pondwader/socks5-server \
  /opt/srt-0.0.65/node_modules/commander \
  /opt/srt-0.0.65/node_modules/node-forge \
  /opt/srt-0.0.65/node_modules/zod
tar -xJf "$TMP/node.tar.xz" --strip-components=1 -C /opt/node-24.18.0
tar -xzf "$TMP/claude.tgz" --strip-components=1 -C /opt/claude-2.1.211
tar -xzf "$TMP/srt.tgz" --strip-components=1 -C /opt/srt-0.0.65/node_modules/@anthropic-ai/sandbox-runtime
tar -xzf "$TMP/socks.tgz" --strip-components=1 -C /opt/srt-0.0.65/node_modules/@pondwader/socks5-server
tar -xzf "$TMP/commander.tgz" --strip-components=1 -C /opt/srt-0.0.65/node_modules/commander
tar -xzf "$TMP/node-forge.tgz" --strip-components=1 -C /opt/srt-0.0.65/node_modules/node-forge
tar -xzf "$TMP/zod.tgz" --strip-components=1 -C /opt/srt-0.0.65/node_modules/zod
chown -R root:root /opt/node-24.18.0 /opt/claude-2.1.211 /opt/srt-0.0.65
find /opt/node-24.18.0 /opt/claude-2.1.211 /opt/srt-0.0.65 -type d -exec chmod 0755 {} +
find /opt/node-24.18.0 /opt/claude-2.1.211 /opt/srt-0.0.65 -type f -perm /111 -exec chmod 0755 {} +
find /opt/node-24.18.0 /opt/claude-2.1.211 /opt/srt-0.0.65 -type f ! -perm /111 -exec chmod 0644 {} +
chmod 0755 /opt/claude-2.1.211/claude

ln -sfn /opt/claude-2.1.211/claude /usr/local/bin/claude
install -m 0755 -o root -g root /dev/null /usr/local/bin/srt
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'exec /opt/node-24.18.0/bin/node /opt/srt-0.0.65/node_modules/@anthropic-ai/sandbox-runtime/dist/cli.js "$@"' \
  > /usr/local/bin/srt

install -d -m 0755 -o root -g root /etc/claude-code
install -m 0644 -o root -g root /usr/local/share/outer-loop/seeds/claude-managed-settings.json /etc/claude-code/managed-settings.json
install -m 0644 -o root -g root /usr/local/share/outer-loop/seeds/claude-managed-mcp.json /etc/claude-code/managed-mcp.json
install -m 0644 -o root -g root /usr/local/share/outer-loop/seeds/claude-srt-settings.json /etc/claude-code/srt-settings.json

sudo -u calibration env CLAUDE_CONFIG_DIR=/home/calibration/.claude /usr/local/bin/claude --version | grep -q '2.1.211'
sudo -u calibration /usr/local/bin/srt --version | grep -q '0.0.65'
