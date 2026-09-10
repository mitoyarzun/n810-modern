#!/bin/sh
# Runs after the overlay copy, with the rootfs as the working directory.
# WORK and PREFIX are exported: the emulator directory, and the directory of
# the cross-built binaries.
#
# Use it for the edits a whole file cannot express. Examples:
#
#   # Remove one plugin from a config you do not want to copy whole:
#   sed -i '/location\.desktop/d' etc/hildon-desktop/statusbar.conf
#
#   # Start something at boot:
#   printf '#!/bin/sh\n/opt/handshake/bin/my-daemon &\n' > etc/rc2.d/S97mine
#   chmod 0755 etc/rc2.d/S97mine
#
#   # Give the desktop a different wallpaper:
#   cp "$WORK/my-background.png" usr/share/backgrounds/default.png
#
# This example does nothing.
exit 0
