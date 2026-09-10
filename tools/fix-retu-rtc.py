"""Adapt Nokia's retu-rtc.c to the 2.6.28 driver model.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

2.6.28 removed `kobj` from struct device_driver (it moved into the private
driver data), so

    sysfs_notify(&retu_rtc_driver.driver.kobj, NULL, "alarm_expired");

no longer compiles. It was pointing at the wrong object anyway: every one of
this driver's attributes is created on the platform DEVICE with
device_create_file(&pdev->dev, ...), so the notification belongs on that
device's kobject. Remember it at probe time and use it.
"""

PATH = 'drivers/cbus/retu-rtc.c'

DECL_ANCHOR = 'static struct platform_driver retu_rtc_driver;'
DECL_NEW = """static struct platform_driver retu_rtc_driver;

/* The attributes live on the platform device, not the driver. */
static struct device *retu_rtc_dev;"""

NOTIFY_OLD = '\tsysfs_notify(&retu_rtc_driver.driver.kobj, NULL, "alarm_expired");'
NOTIFY_NEW = """\tif (retu_rtc_dev)
\t\tsysfs_notify(&retu_rtc_dev->kobj, NULL, "alarm_expired");"""

PROBE_OLD = """static int __init retu_rtc_probe(struct platform_device *pdev)
{
\tint ret;
"""
PROBE_NEW = """static int __init retu_rtc_probe(struct platform_device *pdev)
{
\tint ret;

\tretu_rtc_dev = &pdev->dev;
"""


def main():
    try:
        s = open(PATH).read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    if 'static struct device *retu_rtc_dev;' in s:
        print('    SKIP (already adapted)')
        return
    for old, new, what in ((DECL_ANCHOR, DECL_NEW, 'declaration'),
                           (NOTIFY_OLD, NOTIFY_NEW, 'sysfs_notify'),
                           (PROBE_OLD, PROBE_NEW, 'probe')):
        if old not in s:
            print('    SKIP (%s not in the expected shape)' % what)
            return
        s = s.replace(old, new, 1)
    open(PATH, 'w').write(s)
    print('    sysfs_notify now targets the platform device')


if __name__ == '__main__':
    main()
