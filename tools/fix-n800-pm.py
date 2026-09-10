"""Adapt Nokia's board-n800-pm.c to the 2.6.28 menelaus API.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

Nokia's 2.6.21 menelaus took its platform data through a global setter,
menelaus_set_platform_data(). 2.6.28's takes it from the i2c client's
dev.platform_data instead, and Nokia's board code predates I2C_BOARD_INFO, so
there is no i2c_board_info here to attach it to.

CAUTION: this STUBS the call. The consequence is that n800_menelaus_init()
never runs, so the Menelaus late-init (VCORE and VMMC setup) does not happen.
MMC still gets power from board-n800-mmc.c's own set_power path, which is why
this is survivable for a first boot -- but it is a real gap, and wiring the
platform data through a proper i2c_board_info is the correct fix.
"""

PATH = 'arch/arm/mach-omap2/board-n800-pm.c'

OLD = """static inline void menelaus_config(void)
{
\tmenelaus_set_platform_data(&n800_menelaus_platform_data);
}"""

NEW = """static inline void menelaus_config(void)
{
\t/* 2.6.28 takes this through the i2c client's dev.platform_data, and
\t * this board file predates I2C_BOARD_INFO. STUBBED: n800_menelaus_init()
\t * does not run, so Menelaus late-init (VCORE, VMMC) is skipped. */
\t(void)&n800_menelaus_platform_data;
}"""


def main():
    try:
        s = open(PATH).read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    if 'STUBBED' in s:
        print('    SKIP (already adapted)')
        return
    if OLD not in s:
        print('    SKIP (menelaus_config not in the expected shape)')
        return
    open(PATH, 'w').write(s.replace(OLD, NEW, 1))
    print('    menelaus_set_platform_data stubbed (late-init skipped)')


if __name__ == '__main__':
    main()
