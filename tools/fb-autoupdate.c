/*
 * fb-autoupdate -- force the N800/N810 panel into auto-update mode.
 *
 * The Epson "blizzard" controller drives a MANUAL-UPDATE panel: the
 * framebuffer is ordinary SDRAM, and content only reaches the screen when the
 * driver pushes it through the controller's data port. QEMU's emulation is
 * faithful about this -- hw/display/blizzard.c only redraws when the guest
 * writes pixels through register 0x90, and has no continuous redraw loop.
 *
 * fb-progress and show_image push explicitly, which is why the boot splash
 * appears. Xomap evidently does not, so under emulation the desktop draws into
 * memory that nobody flushes and the screen stays frozen on the splash.
 *
 * OMAPFB_SET_UPDATE_MODE with OMAPFB_AUTO_UPDATE makes the driver refresh on
 * its own timer, which turns the panel into something QEMU can follow.
 *
 * Build with the project's cross toolchain:
 *     . tools/env.sh && $CC -O2 -o fb-autoupdate tools/fb-autoupdate.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* include/linux/omapfb.h -- OMAP_IOW(n, t) is _IOW('O', n, t). */
#define OMAPFB_SET_UPDATE_MODE _IOW('O', 40, int)
#define OMAPFB_GET_UPDATE_MODE _IOW('O', 42, int)

enum {
    OMAPFB_UPDATE_DISABLED = 0,
    OMAPFB_AUTO_UPDATE     = 1,
    OMAPFB_MANUAL_UPDATE   = 2
};

static const char *mode_name(int m)
{
    switch (m) {
    case OMAPFB_UPDATE_DISABLED: return "disabled";
    case OMAPFB_AUTO_UPDATE:     return "auto";
    case OMAPFB_MANUAL_UPDATE:   return "manual";
    default:                     return "unknown";
    }
}

int main(int argc, char **argv)
{
    const char *dev = "/dev/fb0";
    int loop = 0, fd, mode, got = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-l"))      loop = 1;
        else                             dev = argv[i];
    }

    fd = open(dev, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "fb-autoupdate: cannot open %s: ", dev);
        perror("");
        return 1;
    }

    if (ioctl(fd, OMAPFB_GET_UPDATE_MODE, &got) == 0)
        printf("fb-autoupdate: %s was in %s mode (%d)\n", dev, mode_name(got), got);
    else
        perror("fb-autoupdate: GET_UPDATE_MODE");

    mode = OMAPFB_AUTO_UPDATE;
    if (ioctl(fd, OMAPFB_SET_UPDATE_MODE, &mode) != 0) {
        perror("fb-autoupdate: SET_UPDATE_MODE");
        close(fd);
        return 1;
    }

    got = -1;
    if (ioctl(fd, OMAPFB_GET_UPDATE_MODE, &got) == 0)
        printf("fb-autoupdate: %s now in %s mode (%d)\n", dev, mode_name(got), got);
    else
        printf("fb-autoupdate: set auto on %s\n", dev);

    /* Something else may put the panel back into manual mode when it takes
     * the framebuffer. Re-assert periodically rather than assume we won. */
    while (loop) {
        sleep(2);
        mode = OMAPFB_AUTO_UPDATE;
        ioctl(fd, OMAPFB_SET_UPDATE_MODE, &mode);
    }

    close(fd);
    return 0;
}
