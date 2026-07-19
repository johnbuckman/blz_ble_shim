#!/bin/sh
# install.sh -- install the blz_ble_shim Tcl package so that, from any Tcl
# program (tclsh, wish, undroidwish, de1app, ...):
#
#     package require blz_ble_shim
#
# just works.  It copies the package files into a "blz_ble_shim" directory under
# a location that is already on Tcl's auto_path.
#
# Usage:
#   ./install.sh                 # -> /usr/local/lib   (auto_path of tclsh/wish/undroidwish; may need sudo)
#   ./install.sh --user          # -> ~/Library/Tcl (macOS) or ~/.local/lib/tcl  (no sudo)
#   ./install.sh /path/to/libdir # -> a directory you choose
#
set -eu
here=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
    --user)
        if [ -d "$HOME/Library" ]; then dest="$HOME/Library/Tcl"; else dest="$HOME/.local/lib/tcl"; fi ;;
    "")  dest="/usr/local/lib" ;;
    *)   dest="$1" ;;
esac

pkg="$dest/blz_ble_shim"
echo "Installing blz_ble_shim -> $pkg"
mkdir -p "$pkg"
cp "$here/pkgIndex.tcl" "$here/blz_ble_shim.tcl" "$here/blz_sim.tcl" "$pkg/"

# pick a tclsh to verify with
for t in tclsh8.6 tclsh8.7 tclsh; do
    if command -v "$t" >/dev/null 2>&1; then TCLSH=$t; break; fi
done

if [ -n "${TCLSH:-}" ]; then
    ver=$(printf 'lappend auto_path {%s}\nputs [package require blz_ble_shim]\n' "$dest" | "$TCLSH" 2>/dev/null || true)
    if [ -n "$ver" ]; then
        echo "Verified: package require blz_ble_shim -> $ver  (using $TCLSH)"
    else
        echo "Installed, but '$dest' may not be on this interpreter's auto_path."
        echo "If 'package require blz_ble_shim' can't find it, add to your shell profile:"
        echo "    export TCLLIBPATH=\"$dest\""
    fi
fi

cat <<'EOF'

Use it:
  package require blz_ble_shim         ;# real blz present (undroidwish on Linux) -> installs `ble`
  # test on any platform (macOS included) with simulated DE1 + Skale:
  package require blz_sim              ;# a simulated `blz` + virtual devices
  package require blz_ble_shim         ;# `ble` on top of the simulator

Single-file alternative (Tcl Module): copy blz_ble_shim.tcl to a directory on
`tcl::tm::path` renamed as `blz_ble_shim-1.0.tm` (e.g. ~/Library/Tcl/tcl8/8.6/).
EOF
