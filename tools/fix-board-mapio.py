"""Give Nokia's board files the 2.6.28 SoC globals call.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

This is the fix that makes the kernel boot at all, and the bug is invisible
from the source.

2.6.28 introduced omap2_set_globals_242x(), which sets `tap_base` -- the
pointer that read_tap_reg() uses to read the SoC revision. Every 2.6.28 OMAP2
board calls it first thing in map_io:

    static void __init omap_h4_map_io(void)
    {
            omap2_set_globals_242x();
            omap2_map_common_io();
    }

Nokia's board files are from 2.6.21, where the function did not exist, so they
call omap2_map_common_io() alone. tap_base stays NULL, and the call chain

    omap2_map_common_io -> omap2_check_revision -> read_tap_reg

dereferences it. The result is a data abort during paging_init, BEFORE the
vector page is mapped, so the CPU cannot even take the abort: it loops on
prefetch aborts at 0xffff1000 forever.

The kernel is silent throughout. There is no oops, because oopsing needs the
console and the vectors, and neither exists yet. With CONFIG_DEBUG_LL you get
"Uncompressing Linux... done, booting the kernel." and then nothing at all.
"""

TARGETS = [
    ('arch/arm/mach-omap2/board-n800.c', 'nokia_n800_map_io'),
    ('arch/arm/mach-omap2/board-n810.c', 'nokia_rx44_map_io'),
]

OLD = "\tomap2_map_common_io();"
NEW = "\t/* 2.6.28 needs this first: it sets tap_base, which\n\t * omap2_check_revision() dereferences. */\n\tomap2_set_globals_242x();\n\tomap2_map_common_io();"


def main():
    for path, func in TARGETS:
        try:
            s = open(path, encoding='latin-1').read()
        except IOError:
            print('    SKIP %s (absent)' % path)
            continue
        if 'omap2_set_globals_242x' in s:
            print('    SKIP %s (already calls it)' % path)
            continue
        if func not in s:
            print('    SKIP %s (%s not found)' % (path, func))
            continue
        if OLD not in s:
            print('    SKIP %s (map_io not in the expected shape)' % path)
            continue
        s = s.replace(OLD, NEW, 1)
        if '#include <mach/common.h>' not in s:
            s = s.replace('#include <mach/gpio.h>',
                          '#include <mach/gpio.h>\n#include <mach/common.h>', 1)
        open(path, 'w', encoding='latin-1').write(s)
        print('    %s: omap2_set_globals_242x() before omap2_map_common_io()' % func)


if __name__ == '__main__':
    main()
