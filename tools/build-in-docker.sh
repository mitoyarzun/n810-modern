#!/usr/bin/env bash
# Build and test everything in a container, so the host needs only Docker.
#
#   tools/build-in-docker.sh [--no-test]
#
# Ubuntu 24.04 because that is what tools/env.sh was verified against, and
# several of its flags exist to work around that image's cross-toolchain
# specifically. A different base may need different workarounds.
#
# Runs NATIVE by default. gcc-arm-linux-gnueabi is packaged for amd64 and
# arm64 alike, so an Apple Silicon host cross-compiles at full speed; forcing
# linux/amd64 there would emulate x86 for no reason. Override with
# PLATFORM=linux/amd64 to match a specific build host.
#
# THE BUILD TREE LIVES IN A DOCKER VOLUME, NOT ON A BIND MOUNT. That is not a
# preference. Diablo's libc6 contains hardlinked zone files:
#     hrw-r--r-- ./usr/share/zoneinfo/Etc/GMT-0 link to .../Etc/Greenwich
# and unpacking it onto a macOS bind mount (colima/virtiofs, and 9p/sshfs
# behave no better) fails outright:
#     tar: ./usr/share/zoneinfo/localtime: Cannot open: Permission denied
#     dpkg-deb: error: tar subprocess returned error exit status 2
# --no-same-owner and --no-same-permissions make no difference: the host
# filesystem is refusing, not the extraction. The same command on a Linux bind
# mount works, which is why this went unnoticed until someone tried a Mac.
#
# Building in a volume sidesteps every host filesystem's semantics, and is
# faster besides. Only the finished artefacts cross back.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${IMAGE:-ubuntu:24.04}"
VOLUME="${VOLUME:-n810-build}"
DIST="${DIST:-$ROOT/dist}"
PLATFORM="${PLATFORM:-}"
PLATFORM_ARG=""
[ -n "$PLATFORM" ] && PLATFORM_ARG="--platform $PLATFORM"
TEST=1
[ "${1:-}" = "--no-test" ] && TEST=0

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null
mkdir -p "$DIST"

# shellcheck disable=SC2086  # PLATFORM_ARG is intentionally unquoted/empty
docker run --rm $PLATFORM_ARG \
  -v "$VOLUME:/work" \
  -v "$ROOT/tools:/src/tools:ro" \
  -v "$DIST:/dist" \
  -w /work "$IMAGE" bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo '==> Container prerequisites'
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  sudo ca-certificates curl perl make file xz-utils \
  gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi dpkg-dev qemu-user

# Copy the tools into the volume; everything else is built here and stays here.
mkdir -p /work/tools && cp -a /src/tools/. /work/tools/

tools/setup-host.sh
tools/mk-sysroot.sh
tools/build-openssl.sh
tools/mk-truststore.sh
tools/build-stunnel.sh
if [ $TEST -eq 1 ]; then
  echo
  tools/qemu-smoke.sh
  echo
  tools/qemu-stunnel-test.sh
fi

echo
echo '==> Packaging'
tar czf /dist/n810-modern-diablo-armel.tar.gz -C out opt
sha256sum /dist/n810-modern-diablo-armel.tar.gz
"

echo
echo "Artefacts in $DIST"
echo "Build tree kept in the '$VOLUME' volume; 'docker volume rm $VOLUME' to reset."
