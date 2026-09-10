"""Adapt Nokia's retu-headset.c to the 2.6.28 input API.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

Two renames between 2.6.21 and 2.6.28:

    input_dev->cdev.dev   ->  input_dev->dev.parent
    input_dev->private    ->  input_set_drvdata(dev, ptr)

The second is not just a rename: 2.6.28 routes driver data through the
embedded struct device, so the accessor is the only correct way to set it.
"""

PATH = 'drivers/cbus/retu-headset.c'

OLD = """\ths->idev->cdev.dev = &pdev->dev;
\ths->idev->private = hs;"""

NEW = """\ths->idev->dev.parent = &pdev->dev;
\tinput_set_drvdata(hs->idev, hs);"""


def main():
    try:
        # The copyright header carries a Finnish name in Latin-1, not UTF-8.
        s = open(PATH, encoding='latin-1').read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    if 'input_set_drvdata' in s:
        print('    SKIP (already adapted)')
        return
    if OLD not in s:
        print('    SKIP (not in the expected shape)')
        return
    open(PATH, 'w', encoding='latin-1').write(s.replace(OLD, NEW, 1))
    print('    input_dev cdev.dev -> dev.parent, private -> input_set_drvdata')


if __name__ == '__main__':
    main()
