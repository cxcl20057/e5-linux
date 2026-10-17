#!/bin/sh
# Hot update: skip the charging screen on boot.
#
# The E5's OpenWrt image ships e5-charge-mode (S14), which on a charger boot
# (sprdboot.mode=charger) holds the boot and shows a charging animation until
# the power key is held 1.5 s.  This script disables that gate so the system
# boots straight through to the normal UI, matching the Android-side Magisk
# module that already skips the charging screen.
#
# Usage on the device (as root, over SSH or telnet):
#   sh /tmp/e5-skip-charge-screen.sh          # disable
#   sh /tmp/e5-skip-charge-screen.sh --enable # re-enable
#
# A backup of the init link is kept in /etc/e5-charge-mode.bak.
# Re-enabling restores it; flashing a new image resets to the default (enabled).
set -eu

SERVICE=e5-charge-mode
RC_DIR=/etc/rc.d
INIT_DIR=/etc/init.d
BAK_DIR=/etc/e5-charge-mode.bak

enable=${1:-}

case "$enable" in
    --enable)
        if [ -d "$BAK_DIR" ]; then
            for link in "$BAK_DIR"/S*; do
                [ -e "$link" ] || continue
                name=$(basename "$link")
                ln -sf "$INIT_DIR/$SERVICE" "$RC_DIR/$name"
                echo "restored: $RC_DIR/$name"
            done
            rm -rf "$BAK_DIR"
        else
            echo "no backup found; the service may already be at its default (enabled)"
            /etc/init.d/$SERVICE enable 2>/dev/null || true
        fi
        echo "e5-charge-mode re-enabled; reboot to see the charging screen again"
        ;;

    ''|--disable)
        # Collect all rc.d symlinks for the service (S14e5-charge-mode etc.)
        mkdir -p "$BAK_DIR"
        found=0
        for link in "$RC_DIR"/S*$SERVICE "$RC_DIR"/K*$SERVICE; do
            [ -L "$link" ] || continue
            name=$(basename "$link")
            cp "$link" "$BAK_DIR/$name"
            rm -f "$link"
            echo "removed: $RC_DIR/$name"
            found=1
        done
        if [ "$found" = 0 ]; then
            echo "e5-charge-mode is not enabled in rc.d (already disabled?)"
        fi
        echo "e5-charge-mode disabled; next charger boot goes straight to the system"
        ;;

    *)
        echo "usage: $0 [--enable|--disable]" >&2
        exit 2
        ;;
esac
