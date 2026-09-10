"""Adapt Nokia's board-n800-usb.c to the 2.6.28 musb API.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

Two changes:

  1. 2.6.28 moved the controller details out of musb_hdrc_platform_data into a
     separate musb_hdrc_config that the platform data points at, so Nokia's
     `.multipoint = 1` no longer names a field that exists.

  2. omap2_block_sleep() and omap2_allow_sleep() were Nokia's own, defined in
     their arch/arm/mach-omap2/pm.c. This rebase takes 2.6.28's pm.c instead,
     because Nokia's does not build against the PRCM rewrite.

     CAUTION: the sleep gating is STUBBED, not ported. Nokia used it to keep
     the OMAP awake while the TUSB6010 was active. Without it the SoC may
     sleep during USB transfers.
"""
import sys

PATH = 'arch/arm/mach-omap2/board-n800-usb.c'

OLD = """static struct musb_hdrc_platform_data tusb_data = {
\t.mode\t\t= BOARD_MODE,
\t.multipoint\t= 1,"""

NEW = """/* Nokia gated OMAP sleep around TUSB activity from their own pm.c, which this
 * rebase replaces with 2.6.28's. STUBBED, not ported. */
static inline void omap2_block_sleep(void) {}
static inline void omap2_allow_sleep(void) {}

/* 2.6.28 keeps the controller details in a separate struct. */
static struct musb_hdrc_config tusb_config = {
\t.multipoint\t= 1,
};

static struct musb_hdrc_platform_data tusb_data = {
\t.mode\t\t= BOARD_MODE,
\t.config\t\t= &tusb_config,"""


def main():
    try:
        s = open(PATH).read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    if 'tusb_config' in s:
        print('    SKIP (already adapted)')
        return
    if OLD not in s:
        print('    SKIP (initializer not in the expected shape)')
        return
    open(PATH, 'w').write(s.replace(OLD, NEW, 1))
    print('    musb config split out, sleep gating stubbed')


if __name__ == '__main__':
    main()
