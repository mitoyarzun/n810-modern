"""Bound the Blizzard framebuffer sync wait.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

blizzard_sync() queues a request and then waits for it with no timeout:

    wait_for_completion(&comp);

The request is completed from the RFBI/DISPC DMA interrupt path. Under QEMU
that completion does not always arrive, and the wait is unbounded, so the
first process to close /dev/fb0 blocks forever. On this system that process is
the boot splash, and init waits on it, so the whole boot stops:

    INFO: task show_image:428 blocked for more than 120 seconds.
      wait_for_completion <- blizzard_sync <- omapfb_sync <- omapfb_release

CAUTION: this changes behaviour. A timed-out sync means the display may not be
fully flushed before the file is closed. That is the right trade for an
emulator, where the alternative is a boot that never finishes, but it is a
workaround for a DMA completion that is not arriving -- not a fix for whatever
is not delivering it.
"""

PATH = 'drivers/video/omap/blizzard.c'

OLD = """\tlist_add(&req->entry, &req_list);
\tsubmit_req_list(&req_list);

\twait_for_completion(&comp);
}"""

NEW = """\tlist_add(&req->entry, &req_list);
\tsubmit_req_list(&req_list);

\t/* Bounded: the completion comes from the RFBI/DISPC DMA interrupt, and
\t * under emulation it may never arrive. An unbounded wait here blocks
\t * whoever closes /dev/fb0 forever, which stalls the whole boot. */
\tif (!wait_for_completion_timeout(&comp, msecs_to_jiffies(500)))
\t\tpr_debug("blizzard: sync timed out\\n");
}"""


def main():
    try:
        s = open(PATH, encoding='latin-1').read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    if 'wait_for_completion_timeout' in s:
        print('    SKIP (already bounded)')
        return
    if OLD not in s:
        print('    SKIP (blizzard_sync not in the expected shape)')
        return
    open(PATH, 'w', encoding='latin-1').write(s.replace(OLD, NEW, 1))
    print('    blizzard_sync: wait bounded to 500 ms')


if __name__ == '__main__':
    main()
