#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo "provision-common.sh must run as root" >&2
  exit 1
fi

readonly SNAPSHOT='https://snapshot.ubuntu.com/ubuntu/20260615T000000Z/'
readonly CACHE_DIR='/var/cache/outer-loop-debs'
readonly DISABLED_SOURCES='/etc/apt/outer-loop-disabled-sources'

install -d -m 0700 -o root -g root "$CACHE_DIR"
install -d -m 0700 -o root -g root "$DISABLED_SOURCES"
install -d -m 0755 -o root -g root /usr/local/share/outer-loop /usr/local/libexec/outer-loop

if [ -f /etc/apt/sources.list ]; then
  mv /etc/apt/sources.list "$DISABLED_SOURCES/sources.list"
fi
find /etc/apt/sources.list.d -maxdepth 1 -type f \
  ! -name outer-loop.sources -exec mv -t "$DISABLED_SOURCES" {} +

install -m 0644 -o root -g root /dev/null /etc/apt/sources.list.d/outer-loop.sources
printf '%s\n' \
  'Types: deb' \
  "URIs: $SNAPSHOT" \
  'Suites: noble noble-updates noble-security' \
  'Components: main universe' \
  'Architectures: arm64' \
  'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
  'Check-Valid-Until: no' \
  > /etc/apt/sources.list.d/outer-loop.sources

apt-get -o Acquire::Check-Valid-Until=false update

download_and_verify() {
  package=$1
  version=$2
  expected=$3
  (
    cd "$CACHE_DIR"
    apt-get download "${package}=${version}"
  )
  file=$(find "$CACHE_DIR" -maxdepth 1 -type f -name "${package}_*.deb" -print)
  count=$(printf '%s\n' "$file" | sed '/^$/d' | wc -l)
  if [ -z "$file" ] || [ "$count" -ne 1 ]; then
    echo "expected exactly one downloaded artifact for $package" >&2
    exit 1
  fi
  printf '%s  %s\n' "$expected" "$file" | sha256sum --check --status
}

download_and_verify apparmor '4.0.1really4.0.1-0ubuntu0.24.04.7' '965a2b0023da444b260cbcd4ae37ae75e0e842efc8bb4792944e4f58a257f34d'
download_and_verify bubblewrap '0.9.0-1ubuntu0.1' '3fb4ca3a8d2060444836568ed49d6897a403467e4ba29c93440900093fb96a38'
download_and_verify ca-certificates '20240203' '641de77d8f142cfd62a1a6f964ba67b20754d3337c480efb529d086075a06c9a'
download_and_verify curl '8.5.0-2ubuntu10.9' '1aae63bf3f4d271500ae51a440807f33c0b1cbac0efdf1ddda637887e298adb4'
download_and_verify libseccomp2 '2.5.5-1ubuntu3.1' '2feac77a129e336960734586ccdb16eefb040adfe7b662369549e41b82ba0a1b'
download_and_verify python3 '3.12.3-0ubuntu2.1' 'ea792b91e0fc9e249b96b960d14e04a8b7107029988546e8dd3511b74a693a6c'
download_and_verify ripgrep '14.1.0-1' '71fe8a5667bc87d2bca175a3426c6ec518e0679cc821d23ae7056de7096f04de'
download_and_verify rsync '3.2.7-1ubuntu1.5' 'acadec1dfd367c1dd7101e94e8ca19eb9b7e94ddfc3ec22f0b1a49e2bdd60382'
download_and_verify seccomp '2.5.5-1ubuntu3.1' '364154e86215c056121cbaf72ba9ad97bd3d3bb0ae072a90f39e76de5101f12a'
download_and_verify socat '1.8.0.0-4build3' '279771298f436064f544f45d66ba75b2937a9b3e3e63836877760141d3b21983'
download_and_verify tar '1.35+dfsg-3build1' '2df76253d79fd27b8e10b4b1426e2a229c1f374406a80607878eb66bdc1edcf6'
download_and_verify xz-utils '5.6.1+really5.4.5-1ubuntu0.3' '0ffb706ab125224ab5abb99055a239eb74a39a0b5f42e608648f02b2a5489b76'

apt-get install -y --no-install-recommends --allow-downgrades "$CACHE_DIR"/*.deb

verify_snapshot_file() {
  relative=$1
  expected=$2
  output="$CACHE_DIR/index-$(printf '%s' "$relative" | tr '/+' '__')"
  curl --fail --silent --show-error --location --proto '=https' \
    "${SNAPSHOT}${relative}" --output "$output"
  printf '%s  %s\n' "$expected" "$output" | sha256sum --check --status
}

verify_snapshot_file 'dists/noble/InRelease' 'cdb2f31d809f589719a53c6ad15f255b27569c4059542ada282aaa21b8e164b0'
verify_snapshot_file 'dists/noble/main/binary-arm64/Packages.xz' '4a1901e6124fb0a111f5dffc8f5c14474f449e2ecfa71f2eaf0b29917edb53f9'
verify_snapshot_file 'dists/noble/universe/binary-arm64/Packages.xz' '6df230cf5cfebcbd59e4e2713b8eed07dc0aaed66fb471ebf046cb70ccb07275'
verify_snapshot_file 'dists/noble-updates/InRelease' 'ddf83c454984ae0861742cd6a89585888050166315368e0f1e1ba6cdde12b52e'
verify_snapshot_file 'dists/noble-updates/main/binary-arm64/Packages.xz' '4c12b4d49218d98d9cfdf74c6a2668e9f2351a00b439f2704afe380fb7b2ff9f'
verify_snapshot_file 'dists/noble-updates/universe/binary-arm64/Packages.xz' 'df5b2f79219ac45c2b966f9d7319d8e772c6b3e7fa5c80338a8b2ad972621606'
verify_snapshot_file 'dists/noble-security/InRelease' '5644c374ba44e2b79107645f211a6d9867537840b702d53c398d244843d2f2ab'
verify_snapshot_file 'dists/noble-security/main/binary-arm64/Packages.xz' '9ab982553e2ff358c1559da453dd50548b0e1c6b5bc1edf8776f5bea22774ab4'
verify_snapshot_file 'dists/noble-security/universe/binary-arm64/Packages.xz' '0f9222a8b702af69f215c79ca1f2888f7d6528635adac73a861498932dcaac5f'

assert_package_version() {
  actual=$(dpkg-query -W -f='${Version}' "$1")
  [ "$actual" = "$2" ] || {
    echo "installed package version drift: $1" >&2
    exit 1
  }
}

assert_package_version apparmor '4.0.1really4.0.1-0ubuntu0.24.04.7'
assert_package_version bubblewrap '0.9.0-1ubuntu0.1'
assert_package_version ca-certificates '20240203'
assert_package_version curl '8.5.0-2ubuntu10.9'
assert_package_version libseccomp2 '2.5.5-1ubuntu3.1'
assert_package_version python3 '3.12.3-0ubuntu2.1'
assert_package_version ripgrep '14.1.0-1'
assert_package_version rsync '3.2.7-1ubuntu1.5'
assert_package_version seccomp '2.5.5-1ubuntu3.1'
assert_package_version socat '1.8.0.0-4build3'
assert_package_version tar '1.35+dfsg-3build1'
assert_package_version xz-utils '5.6.1+really5.4.5-1ubuntu0.3'

if ! id calibration >/dev/null 2>&1; then
  useradd --create-home --uid 2000 --shell /bin/bash calibration
fi
usermod --lock calibration
gpasswd --delete calibration sudo >/dev/null 2>&1 || true
gpasswd --delete calibration adm >/dev/null 2>&1 || true

install -d -m 0700 -o calibration -g calibration /home/calibration/workspace
install -d -m 0700 -o calibration -g calibration /home/calibration/workspace/harmless
install -d -m 0700 -o calibration -g calibration /home/calibration/.codex
install -d -m 0700 -o calibration -g calibration /home/calibration/.claude
install -d -m 0700 -o root -g root /var/lib/outer-loop

chown -R root:root /usr/local/share/outer-loop /usr/local/libexec/outer-loop
find /usr/local/libexec/outer-loop -type f -exec chmod 0755 {} +
chmod 0644 /usr/local/share/outer-loop/versions.lock.json

apparmor_parser --replace /etc/apparmor.d/outer-loop-bwrap

if sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null | grep -qx '1'; then
  apparmor_status | grep -q 'outer-loop-bwrap'
fi
