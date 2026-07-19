# blz_ble_shim — build & run on Linux/BlueZ

`blz_ble_shim.tcl` installs an AndroWish-compatible `ble` command on top of
undroidwish's `blz` (BlueZ) command, so AndroWish/Android BLE apps run unaltered
on Linux. The only app change is `package require blz_ble_shim 1.0`.

## Verified status (2026-07-19)
- `selftest_mock.tcl` — 32/32 pass under `tclsh8.6` (logic: write-ACK/read/
  discovery/CCCD synthesis, adv-name parsing, event shapes, ordering).
- Built the **real `blz`** extension from AndroWish source (arm64) and confirmed
  the shim drives it: `ble` installed, `ble state`→poweredOn, `ble scanner`→blz.
- `bledemo.tcl` (the BLE debugger) runs live on Linux under native `wish8.6` +
  real `blz` + this shim — see `bledemo_running.png`.
- Only gap: the test VM has no Bluetooth radio, so no live scan/connect. Needs a
  real adapter (or an emulated one via `btvirt`) to exercise device I/O.

## Building the real `blz` extension (Debian/Ubuntu, native)
```sh
sudo apt-get install -y tcl8.6-dev tk8.6 libbluetooth-dev libsystemd-dev git
# 1. AndroWish blz wrapper sources (fossil raw):
B='https://androwish.org/home/raw?ci=tip&name=undroid/blz'
mkdir blzbuild && cd blzbuild
for f in tclblz.c tclrfcomm.c sd_dl.h configure Makefile.in configure.in \
         aclocal.m4 pkgIndex.tcl.in; do curl -s "$B/$f" -o "$f"; done
mkdir -p tclconfig demos blzlib
for f in tcl.m4 install-sh; do curl -s "$B/tclconfig/$f" -o tclconfig/$f; done
for f in tricorder hc09term sppclient sppecho sppechoserv sppechodbus; do \
  curl -s "$B/demos/$f.tcl" -o "demos/$f.tcl"; done
# 2. blzlib — MUST be AndroWish's vendored copy (it adds blz_get_fd/_events/
#    _handle_read for Tcl event-loop integration; upstream github lacks them):
for f in blzlib.c blzlib.h blzlib_internal.h blzlib_log.c blzlib_log.h \
         blzlib_msgs.c blzlib_util.c blzlib_util.h; do \
  curl -s "$B/blzlib/$f" -o "blzlib/$f"; done
# 3. configure + make, then RELINK with -lsystemd -lbluetooth (TEA omits them):
chmod +x configure tclconfig/install-sh
./configure --with-tcl=/usr/lib/tcl8.6
make
gcc -shared -o libblz0.1.so *.o -ltclstub8.6 -lsystemd -lbluetooth -ldl
```

## Running the demo
```sh
# needs an X display (Xvfb :99 works headless) and a BlueZ adapter for real I/O
cat > run_bledemo.tcl <<'EOF'
load /path/to/blzbuild/libblz0.1.so Blz
lappend auto_path /path/to/blz-ble-shim      ;# dir with blz_ble_shim.tcl+pkgIndex
package require blz_ble_shim                  ;# installs `ble`, provides ble 1.0
source /path/to/bledemo.tcl
EOF
DISPLAY=:99 wish8.6 run_bledemo.tcl
```
Override the adapter with env `BLZ_ADAPTER=hciN` (default `hci0`).

## Testing without this build

Real `blz` can't run on macOS (it needs Linux's sd-bus + BlueZ; macOS uses
CoreBluetooth). But the shim is pure API translation, so it's tested against a
**simulated `blz`** (`blz_sim`) backed by virtual DE1 + Skale devices — no
hardware, runs anywhere Tcl runs. See the main [README](../README.md) for the
`test/` suites (`selftest_mock.tcl`, `test_shim_e2e.tcl`) and the
`examples/run_bledemo_sim.tcl` GUI demo.
