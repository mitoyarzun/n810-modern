#!/usr/bin/env bash
# Verify a cross-built binary will actually run on Maemo Diablo (N800/N810).
#
# Every check here corresponds to a way the build can succeed on the host and
# then fail on the device. Run this on everything before it is packaged.
#
# Usage: check-artifact.sh <file> [file...]
set -uo pipefail

T=arm-linux-gnueabi
# glibc 2.5 exports symbol versions up to GLIBC_2.4 on arm (plus GLIBC_PRIVATE).
MAX_GLIBC="2.4"
rc=0

ver_gt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }

for f in "$@"; do
  echo "== $f"
  bad=0

  # 1. Right machine and ABI.
  hdr=$($T-readelf -h "$f" 2>/dev/null) || { echo "   NOT AN ELF FILE"; rc=1; continue; }
  grep -q 'Machine:.*ARM' <<<"$hdr" || { echo "   FAIL  not an ARM binary"; bad=1; }

  # 2. The kernel ABI note. The host toolchain's crt1.o stamps 3.2.0, which the
  #    device's 2.6.21 loader rejects outright with "FATAL: kernel too old".
  #    Shared libraries carry no note; that is expected, not a failure.
  if $T-readelf -h "$f" | grep -q 'Type:.*EXEC\|Type:.*DYN.*'; then
    note=$($T-readelf -n "$f" 2>/dev/null | grep -oE 'ABI: [0-9.]+' | head -1 | cut -d' ' -f2)
    if [ -n "$note" ]; then
      if ver_gt "$note" "2.6.21"; then
        echo "   FAIL  ABI note says Linux $note; device runs 2.6.21 (missing -B?)"; bad=1
      else
        echo "   ok    ABI note $note"
      fi
    fi
  fi

  # 3. No symbol newer than the device's glibc.
  syms=$($T-readelf -V "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV)
  worst=""
  for s in $syms; do
    v=${s#GLIBC_}
    ver_gt "$v" "$MAX_GLIBC" && worst="$v"
  done
  if [ -n "$worst" ]; then
    echo "   FAIL  needs GLIBC_$worst; device has 2.5 (max GLIBC_$MAX_GLIBC)"; bad=1
  else
    echo "   ok    glibc symbols <= GLIBC_$MAX_GLIBC"
  fi

  # 4. The 64-bit time_t transition symbols do not exist in glibc 2.5. Their
  #    presence means host headers leaked into the compile (see env.sh).
  if $T-readelf --dyn-syms -W "$f" 2>/dev/null | grep -qE '_time64|_TIME_BITS'; then
    echo "   FAIL  references *_time64 symbols -- host glibc headers leaked in"; bad=1
  else
    echo "   ok    no 64-bit time_t symbols"
  fi

  # 5. Interpreter must be the armel one. armhf would be ld-linux-armhf.so.3.
  interp=$($T-readelf -l "$f" 2>/dev/null | grep -oE '/lib/ld-linux[^]]*\.so\.[0-9]+' | head -1)
  if [ -n "$interp" ]; then
    if [ "$interp" = "/lib/ld-linux.so.3" ]; then
      echo "   ok    interpreter $interp"
    else
      echo "   FAIL  interpreter $interp (expected /lib/ld-linux.so.3)"; bad=1
    fi
  fi

  # 6. Every NEEDED library must either exist on a stock Diablo device or
  #    travel with us. This is the check that catches libatomic.so.1: GCC 4.7+
  #    emits calls to it for 64-bit atomics on ARMv6, and Diablo -- whose
  #    newest compiler is GCC 4.2 -- has never heard of it. The build succeeds,
  #    the checker used to pass it, and the device says:
  #        libatomic.so.1: cannot open shared object file
  needed=$($T-readelf -d "$f" 2>/dev/null | grep -oE 'Shared library: \[[^]]+\]' | sed 's/.*\[\(.*\)\]/\1/')
  for lib in $needed; do
    case "$lib" in
      # Shipped by glibc 2.5 / the stock Diablo rootfs.
      libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|libcrypt.so.1|\
      libnsl.so.1|libresolv.so.2|libutil.so.1|ld-linux.so.3|libgcc_s.so.1|libz.so.1)
        ;;
      *)
        # Otherwise it must sit next to the artefact, or in $EXTRA_LIBDIR.
        d=$(dirname "$f")
        # Look beside it, one level up (lib/ossl-modules -> lib), and in a
        # sibling lib/ (bin -> ../lib).
        if [ -e "$d/$lib" ] || [ -e "$d/../$lib" ] || [ -e "$d/../lib/$lib" ] ||
           { [ -n "${EXTRA_LIBDIR:-}" ] && [ -e "$EXTRA_LIBDIR/$lib" ]; }; then
          echo "   ok    $lib ships with us"
        else
          echo "   FAIL  needs $lib, which Diablo does not have and we do not ship"; bad=1
        fi
        ;;
    esac
  done
  [ -n "$needed" ] && echo "   note  NEEDED: $(echo $needed | tr '\n' ' ')"

  [ $bad -eq 0 ] || rc=1
done

echo
[ $rc -eq 0 ] && echo "All artefacts look device-safe." || echo "FAILURES ABOVE -- do not ship."
exit $rc
