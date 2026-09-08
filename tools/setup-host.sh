#!/usr/bin/env bash
# Install what a Debian/Ubuntu host needs to cross-build for Maemo Diablo.
# Verified on Ubuntu 24.04.4 with gcc-arm-linux-gnueabi 13.3.0.
set -euo pipefail

need=(gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi dpkg-dev curl perl make file)
missing=()
for p in "${need[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done

if [ ${#missing[@]} -eq 0 ]; then
  echo "All prerequisites present."
else
  echo "Installing: ${missing[*]}"
  # gcc-arm-linux-gnueabi is in universe on Ubuntu. armel, not armhf: the device's
  # loader is ld-linux.so.3, which is the base-AAPCS (soft-float) ABI.
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

echo
arm-linux-gnueabi-gcc --version | head -1
echo
echo "Next:"
echo "  tools/mk-sysroot.sh          # ~27 MB, from the Maemo mirrors"
echo "  tools/build-openssl.sh       # ~10 min on 4 cores"
