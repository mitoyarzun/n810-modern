"""Close the race that leaves the N810 display blank.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

THE BUG. drivers/video/omap/rfbi.c starts a transfer like this:

    BUG_ON(callback == NULL);
    rfbi_enable_clocks(1);                  <- can deliver a pending FRAMEDONE
    omap_dispc_set_lcd_size(width, height); <- so can this
    rfbi.lcdc_callback = callback;          <- only stored HERE
    ...
    rfbi_write_reg(RFBI_CONTROL, w);        <- trigger

and completes it like this:

    static void rfbi_dma_callback(void *data)
    {
            _stop_transfer();
            rfbi.lcdc_callback(rfbi.lcdc_callback_data);
    }

The completion interrupt can arrive before the callback is stored. On real
hardware the window is harmless: a 384000-pixel transfer takes milliseconds
and cannot finish inside a register write. Under QEMU it does exactly that --
omap_rfbi_transfer_start() copies the whole frame and raises FRAMEDONE
synchronously, inside the MMIO write -- and a FRAMEDONE left pending from
earlier is delivered the moment the clocks come back on.

The consequence is total and silent. The one completion that matters is
dropped, so the blizzard request that owns it never finishes, the request
queue stalls forever, and every later blizzard_sync() times out. Exactly one
transfer is ever performed, pushing whatever the framebuffer held at boot --
a black screen. Userspace runs fine: Matchbox and Hildon Desktop both start
and draw, and none of it ever reaches the panel.

THE FIX. Store the callback before touching any register, so the window does
not exist. Measured over one boot, before and after:

                        transfers   completions        blizzard_sync
    before                      1   1 with NULL cb     2 ok, 9 timed out
    after                    1934   1934 delivered    11 ok, 0 timed out

The NULL check stays as a guard. It is correct on its own terms -- the
interrupt is requested at init, long before any transfer -- but it must not be
the thing that hides a dropped completion.
"""

PATH = 'drivers/video/omap/rfbi.c'

# 1. The real fix: store the callback before any register access.
ORDER_OLD = """\tBUG_ON(callback == NULL);

\trfbi_enable_clocks(1);
\tomap_dispc_set_lcd_size(width, height);

\trfbi.lcdc_callback = callback;
\trfbi.lcdc_callback_data = data;
"""

ORDER_NEW = """\tBUG_ON(callback == NULL);

\t/* Store the completion callback BEFORE touching any register. Enabling
\t * the clocks or programming DISPC can deliver a FRAMEDONE left pending
\t * from an earlier transfer, and an emulator may complete the transfer
\t * synchronously inside the RFBI_CONTROL write below. Either way the
\t * interrupt can arrive before this assignment, and rfbi_dma_callback()
\t * would find NULL and drop the completion, stalling the queue for good. */
\trfbi.lcdc_callback = callback;
\trfbi.lcdc_callback_data = data;

\trfbi_enable_clocks(1);
\tomap_dispc_set_lcd_size(width, height);
"""

# 2. The guard, for an interrupt that genuinely predates any transfer.
GUARD_OLD = """static void rfbi_dma_callback(void *data)
{
\t_stop_transfer();
\trfbi.lcdc_callback(rfbi.lcdc_callback_data);
}"""

GUARD_NEW = """static void rfbi_dma_callback(void *data)
{
\t_stop_transfer();
\t/* The DISPC interrupt is requested at init, before any transfer has set
\t * a callback. With the ordering fix above this should not fire for a
\t * real completion; it is a guard, not a substitute for that fix. */
\tif (rfbi.lcdc_callback)
\t\trfbi.lcdc_callback(rfbi.lcdc_callback_data);
}"""


def main():
    try:
        s = open(PATH, encoding='latin-1').read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    changed = []
    if ORDER_OLD in s:
        s = s.replace(ORDER_OLD, ORDER_NEW, 1)
        changed.append('callback stored before register access')
    elif 'Store the completion callback BEFORE' not in s:
        print('    SKIP (rfbi_transfer_area not in the expected shape)')
        return
    if GUARD_OLD in s:
        s = s.replace(GUARD_OLD, GUARD_NEW, 1)
        changed.append('NULL completion guarded')
    if not changed:
        print('    SKIP (already fixed)')
        return
    open(PATH, 'w', encoding='latin-1').write(s)
    for c in changed:
        print('    %s' % c)


if __name__ == '__main__':
    main()
