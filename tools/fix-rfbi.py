"""Guard the RFBI DMA completion callback.

Run from the root of the patched 2.6.28 tree; see tools/mk-kernel-2628.sh.

drivers/video/omap/rfbi.c registers rfbi_dma_callback() as the DISPC interrupt
handler at init:

    omap_dispc_request_irq(rfbi_dma_callback, NULL)

but rfbi.lcdc_callback is only set later, by rfbi_transfer_area(). If a DISPC
interrupt arrives before the first transfer, the handler calls a NULL pointer.

On real hardware that apparently never happens. Under QEMU it does, and the
result is brutal: a prefetch abort with no exception-table fixup, so
do_page_fault -> __do_kernel_fault -> die -> panic. The panic happens before
the console is up, so the machine simply goes quiet, still taking timer
interrupts, with the CPU spinning in panic()'s delay loop.

Checking the pointer is correct regardless of who fires the interrupt.
"""

PATH = 'drivers/video/omap/rfbi.c'

OLD = """static void rfbi_dma_callback(void *data)
{
\t_stop_transfer();
\trfbi.lcdc_callback(rfbi.lcdc_callback_data);
}"""

NEW = """static void rfbi_dma_callback(void *data)
{
\t_stop_transfer();
\t/* The DISPC interrupt is requested at init, but lcdc_callback is only
\t * set by rfbi_transfer_area(). An interrupt before the first transfer
\t * would otherwise call NULL. */
\tif (rfbi.lcdc_callback)
\t\trfbi.lcdc_callback(rfbi.lcdc_callback_data);
}"""


def main():
    try:
        s = open(PATH, encoding='latin-1').read()
    except IOError:
        print('    SKIP (%s absent)' % PATH)
        return
    if 'if (rfbi.lcdc_callback)' in s:
        print('    SKIP (already guarded)')
        return
    if OLD not in s:
        print('    SKIP (rfbi_dma_callback not in the expected shape)')
        return
    open(PATH, 'w', encoding='latin-1').write(s.replace(OLD, NEW, 1))
    print('    rfbi_dma_callback: NULL callback guarded')


if __name__ == '__main__':
    main()
