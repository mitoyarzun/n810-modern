# The GUI overlay

Files here are copied over the emulator's rootfs at the end of
`tools/emulator-gui-build.sh`, after every built-in patch. Use it to change
the menus, the panels or anything else in the image, without a patch to the
script.

```sh
cp -a gui-overlay.example gui-overlay      # the default location
tools/emulator-gui-build.sh                # build the image
tools/emulator-gui.sh                      # boot it
```

`GUI_OVERLAY=/path/to/other` selects a different directory. The step is
skipped when the directory does not exist.

## How it works

The tree here is the tree of the device. This file:

    gui-overlay/etc/hildon-desktop/tasknavigator.conf

lands at `/etc/hildon-desktop/tasknavigator.conf` on the tablet.

Two names are the directory's own and are never copied: this `README.md`, and
`overlay.sh`. The build runs `overlay.sh` after the copy, with the rootfs as
the working directory. Use it for the edits a whole file cannot express, such
as one line removed from a stock config.

Each build starts from `rootfs.stock`, the untouched extraction, so the image
is the firmware plus this overlay. A file you delete here disappears from the
next image.

Run the build as root, which the container does. `mkfs.jffs2` keeps the owner
of every file, and the device does not know your host user.

## What you can change

| File | Controls |
| --- | --- |
| `etc/hildon-desktop/tasknavigator.conf` | The buttons in the left bar |
| `etc/hildon-desktop/statusbar.conf` | The icons in the top right |
| `etc/hildon-desktop/home.conf` | The applets on the desktop |
| `etc/hildon-desktop/home-layout.conf` | Where those applets sit |
| `etc/hildon-desktop/top-panel.conf`, `bottom-panel.conf` | The two panels |
| `etc/xdg/menus/applications.menu` | The applications menu tree |
| `usr/share/applications/hildon/*.desktop` | The applications themselves |
| `usr/share/applications/hildon-navigator/*.desktop` | The task navigator plugins |

Every `.conf` above is a list of `.desktop` paths, one per line, in square
brackets. The order is the order on screen. A plugin whose line you remove is
never loaded. Keep these files free of comments: hildon-desktop reads them
with its own parser, and a bad line costs you a ten-minute boot to find.

`applications.menu` is freedesktop menu XML. Each `<Menu>` holds a `<Name>`
that is a translation key, such as `tana_fi_internet`, and a list of
`<Filename>` entries from `usr/share/applications/hildon/`.

Read the stock files first:

```sh
docker run --rm -v n810-build:/work ubuntu:24.04 \
  cat /work/emulator/rootfs.stock/etc/hildon-desktop/tasknavigator.conf
```

## What is in this example

`etc/hildon-desktop/tasknavigator.conf` keeps three of the four stock buttons
and drops the web bookmarks. `overlay.sh` is commented out and does nothing.
Delete either one if you do not want it.
