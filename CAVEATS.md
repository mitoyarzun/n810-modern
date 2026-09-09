# Caveats

Things that fail without saying so. Each one cost hours; each is one line to
avoid if you know about it.

## Build

**Build in a container volume, not on a bind mount.** Diablo's `libc6` contains
hardlinked zone files, and unpacking it onto a macOS bind mount fails:

```
tar: ./usr/share/zoneinfo/localtime: Cannot open: Permission denied
```

The named file is a symlink and a red herring — creating it by hand works.
`--no-same-owner --no-same-permissions` change nothing; the host filesystem is
refusing. `tools/build-in-docker.sh` keeps the tree in a Docker volume for this
reason. Do not "simplify" it back to `-v $PWD:/work`.

**`set -o pipefail` plus `grep -q` makes a check that cannot fail.** `grep -q`
exits at the first match, the producer dies of SIGPIPE, and the pipeline
returns 141:

```
match present -> exit 141
no match      -> exit 1
```

Both non-zero, so `if` always takes the else branch. It only bites when the
producer outruns the pipe buffer, so short commands seem fine. Capture the
output and match a variable with a here-string instead. Two checks in
`check-artifact.sh` were silently vacuous because of this.

**A sourced file returns its last command's status.** `env.sh` ended with a
conditional echo, which is false whenever nothing is staged yet -- so sourcing
it returned 1, and every caller written as `. env.sh && $CC ...` silently
skipped the compile. That disabled the display fix in the emulator image, with
one warning as the only symptom and a frozen boot splash much later as the
consequence. End such files with `:`.

**Put the finite producer first in a pipeline.** `tr … < /dev/zero | head -c N`
kills `tr` with SIGPIPE and, under `set -e`, aborts the script mid-run with no
error. Write `head -c N /dev/zero | tr …`.

## Toolchain

**`--sysroot` does not stop the host's headers being found first.** Ubuntu's
cross-GCC searches its own glibc headers ahead of the sysroot. Without
`-nostdinc` and explicit `-isystem`, most of the tree compiles against the
wrong libc and you may never find out. Verify with:

```sh
$CC -v -E -x c /dev/null 2>&1 | sed -n '/search starts here/,/End of/p'
```

**`--sysroot` does not fix startfiles either.** Without `-B$SYSROOT/usr/lib`
the link takes the host's `crt1.o`, whose ABI note demands Linux 3.2. The
device's loader rejects it outright: `FATAL: kernel too old`.

**glibc 2.5 has no IFUNC.** GCC's `libatomic` exports every 64-bit atomic as an
`IFUNC`, so the 2006 loader resolves none of them — shipping the library does
not help, and `libatomic.a` is IFUNC-based too. Build with
`-DBROKEN_CLANG_ATOMICS` so nothing references it, and scrub `-latomic` from
the installed `.pc` files or the next package inherits the dependency.

**Test your checker in both directions.** A check that has only ever returned
"ok" is not evidence. Point it at a known-bad input and confirm it fails.

## Emulator

**The `n810` machine was removed in QEMU 9.2.** Use 9.1 or earlier; Ubuntu
24.04 ships 8.2. Homebrew's QEMU is far newer and cannot run this at all.
`qemu-arm` user-mode is Linux-only, so none of it works natively on macOS.

**A 256 MB OneNAND needs a 264 MB file.** QEMU keeps the out-of-band area in
the same backing file (`size + size/32`). Fill it with `0xFF`, not zeros — a
zero in a block's OOB marker means "bad block".

Get either wrong and every eraseblock reads bad, the kernel skips the chip, and
JFFS2 mounts an **empty filesystem successfully**. The failure surfaces a
second later as `No init found`, which points nowhere near the cause.

**Read the kernel's own partition table.** It prints one on boot. Guessing the
offsets produces the same misleading `No init found`.

**Only the first UART is wired.** A second `-serial` is silently discarded — no
error, no listening socket.

**The panel is manual-update.** QEMU's blizzard model redraws only when the
guest pushes pixels through the controller's data port, and has no continuous
redraw loop. `fb-progress` pushes, `Xomap` does not, so the desktop draws into
memory nobody flushes and the screen freezes on the boot splash while
everything above it is healthy. `tools/fb-autoupdate.c` sets
`OMAPFB_SET_UPDATE_MODE` to auto.

Writing to `/dev/fb0` to test this proves nothing: on a manual-update panel a
plain write never reaches the screen either way.

**DSME is the process supervisor as well as a state machine.** Disabling it
(necessary — the emulator has no battery, so it powers the machine off)
cascades into five further failures, including twenty init scripts that launch
their daemons via `dsmetool -r` and therefore start nothing at all. See
`tools/emulator-gui-build.sh`.

## Firmware extraction

**`jefferson` exits 0 while losing two things.** It drops **uid/gid** — the
whole tree extracts as `root:root`, so anything running as a normal user
cannot write its own config — and it drops **hardlinks**, keeping only the
first name per inode. `/usr/bin/sudo` vanishes while `/usr/bin/sudoedit`, the
identical setuid binary, survives.

Check the result against dpkg's own file lists:

```sh
for l in rootfs/var/lib/dpkg/info/*.list; do
  while read -r f; do [ -e "rootfs$f" ] || echo "$f"; done < "$l"
done
```

Most of what that reports is `/usr/share/doc` and man pages, which Maemo
genuinely strips from the device. Filter to `bin/`, `sbin/` and `.so`.

## Device

**The clock.** A dead RTC backup battery leaves the device in 1970, which makes
every certificate "not yet valid" and fails TLS in a way that reads exactly
like a TLS bug. The emulator reproduces this for its own reasons. Fix with NTP,
which is plain UDP and needs none of this.

**A stock device has no `openssl` CLI, no `wget`, no `curl` and no Python** —
only the `libssl0.9.8` library. Plan the first session accordingly.

**Do not charge a swollen battery.**
