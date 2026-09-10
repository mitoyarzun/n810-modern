"""Restore the build wirings that rejected when Nokia's patch met 2.6.28.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

Nokia's source files all apply cleanly, because they are new files. What
rejects, every time, is the line that WIRES a file into the build -- an obj-y
in a Makefile, a source in a Kconfig -- because 2.6.28 rewrote those files
around them. The result is a tree that looks complete and a kernel that is
missing the driver, with no error until the final link.

Each entry below is one such line.
"""
import os

# (file, marker meaning "already wired", text to append)
APPENDS = [
    # gpio-switch.c drives the N810's slide, cover and headphone switches.
    ('arch/arm/plat-omap/Makefile',
     'gpio-switch.o',
     'obj-$(CONFIG_OMAP_GPIO_SWITCH)\t+= gpio-switch.o\n'),

    # The TUSB6010 is the N810's USB bridge. 2.6.28 ships the driver but only
    # wires it for the boards it knows about.
    ('arch/arm/mach-omap2/Makefile',
     'usb-tusb6010.o',
     'obj-$(CONFIG_MACH_OMAP2_TUSB6010)\t+= usb-tusb6010.o\n'),

    # drivers/cbus holds retu and tahvo: the power button, RTC, watchdog and
    # the N810 keyboard backlight.
    ('drivers/Makefile',
     'cbus/',
     'obj-$(CONFIG_CBUS)\t\t+= cbus/\n'),

]

# Not an append: this Makefile ends with
#
#     omapfb-objs := $(objs-yy)
#
# and `:=` is evaluated immediately, so a line added after it is collected into
# nothing. The object must be added BEFORE that assignment. Appending looks
# right, builds cleanly, and silently produces a kernel with no panel driver.
INSERTS = [
    # lcd_mipid.c drives the N810's ls041y3 panel. 2.6.28 ships the source but
    # builds it for no board, so omapfb comes up with no panel, never
    # initialises, and /dev/fb0 does not exist. Userspace then fails with
    # "cannot open display" and the kernel says nothing at all about it.
    ('drivers/video/omap/Makefile',
     'lcd_mipid.o',
     'omapfb-objs := $(objs-yy)',
     'objs-y$(CONFIG_FB_OMAP_LCD_MIPID) += lcd_mipid.o\n\nomapfb-objs := $(objs-yy)'),
]

# ARM does NOT source drivers/Kconfig. arch/arm/Kconfig sources each driver
# Kconfig itself -- 48 of them. Adding cbus to drivers/Kconfig therefore looks
# right, changes nothing, and produces a link failure much later for a symbol
# in a driver whose config option silently does not exist.
KCONFIG_INSERTS = [
    ('arch/arm/Kconfig',
     'drivers/cbus/Kconfig',
     'source "drivers/i2c/Kconfig"',
     'source "drivers/i2c/Kconfig"\n\nsource "drivers/cbus/Kconfig"'),

    # The panel driver above needs a config symbol to be selected by.
    ('drivers/video/omap/Kconfig',
     'FB_OMAP_LCD_MIPID',
     'config FB_OMAP_LCDC_EXTERNAL',
     'config FB_OMAP_LCD_MIPID\n'
     '\tbool "MIPI DBI-C/DCS compatible LCD support"\n'
     '\tdepends on FB_OMAP\n'
     '\tselect SPI\n'
     '\thelp\n'
     '\t  The Nokia N810 uses an ls041y3 panel behind this interface.\n'
     '\n'
     'config FB_OMAP_LCDC_EXTERNAL'),
]


def main():
    for path, marker, text in APPENDS:
        if not os.path.exists(path):
            print('    SKIP %s (absent)' % path)
            continue
        s = open(path).read()
        if marker in s:
            print('    SKIP %s (already wired)' % path)
            continue
        open(path, 'a').write(text)
        print('    %-32s += %s' % (path, marker))

    for path, marker, anchor, replacement in KCONFIG_INSERTS + INSERTS:
        if not os.path.exists(path):
            print('    SKIP %s (absent)' % path)
            continue
        s = open(path).read()
        if marker in s:
            print('    SKIP %s (already sources it)' % path)
            continue
        if anchor not in s:
            print('    SKIP %s (anchor %r not found)' % (path, anchor))
            continue
        open(path, 'w').write(s.replace(anchor, replacement, 1))
        print('    %-32s sources %s' % (path, marker))


if __name__ == '__main__':
    main()
