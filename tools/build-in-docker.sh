#!/usr/bin/env bash
# Build and test everything in a container, so the host needs only Docker.
#
#   tools/build-in-docker.sh [--no-test]
#
# Ubuntu 24.04 because that is what tools/env.sh was verified against, and
# several of its flags exist to work around that image's cross-toolchain
# specifically. A different base may need different workarounds.
#
# The container is x86_64 (or whatever the host is). The armel artefacts are
# then run under qemu-arm against the Diablo sysroot, which is the closest we
# get to the device without the device.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${IMAGE:-ubuntu:24.04}"
TEST=1
[ "${1:-}" = "--no-test" ] && TEST=0

command -v docker >/dev/null || { echo "docker not found"; exit 1; }

docker run --rm --platform linux/amd64 -v "$ROOT:/work" -w /work "$IMAGE" bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo '==> Container prerequisites'
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  sudo ca-certificates curl perl make file xz-utils \
  gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi dpkg-dev qemu-user
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
tar czf handshake-diablo-armel.tar.gz -C out opt
sha256sum handshake-diablo-armel.tar.gz
"
