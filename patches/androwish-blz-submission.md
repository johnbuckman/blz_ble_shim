# AndroWish `blz` — BLE scanning/notifications never delivered under the Tcl event loop (fix)

**For:** Christian Werner (AndroWish / undroidwish), via the androwish.org Fossil
forum or email.
**Affects:** the bundled `blz` (BlueZ) extension — `tclblz.c` and its vendored
`blzlib.c`. Reproduced on undroidwish (SDL) on Linux/BlueZ 5.x (Ubuntu 24.04
aarch64 and x86_64) driving a real DE1 espresso machine + Decent scale over a
TP-Link UB500 adapter.

## Symptom

`blz scan` starts BlueZ discovery successfully (adapter shows `Discovering: yes`,
`sd_bus` `StartDiscovery` returns OK) but the Tcl scan callback **never fires** —
zero device callbacks, even though `bluetoothctl` / `dbus-monitor` show BlueZ
emitting `InterfacesAdded` for the devices at the same moment. Likewise
notifications after `blz connect` are laggy/dropped. The Tcl event loop itself
stays alive (timers keep firing); `blz` simply never pumps `sd_bus`.

## Root cause

Two issues in how `blz` services `sd_bus` from inside the Tcl notifier:

1. **`tclblz.c` `SetupHandlers()` — no pump gets armed after `StartDiscovery`.**
   `blz` hooks the Tcl event loop via a file handler (from `sd_bus_get_events`)
   and a timer (from `sd_bus_get_timeout`). Right after `StartDiscovery`, sd_bus
   reports an effectively infinite timeout (`ms == -1`) **and** the bus fd does
   not reliably deliver a readable (POLLIN) event through undroidwish's SDL
   notifier — so **neither** the timer nor the file handler is scheduled, and
   `sd_bus_process()` is never called again. Incoming `InterfacesAdded` /
   `PropertiesChanged` sit unprocessed forever.

2. **`blzlib.c` `blz_handle_read()` — one message per call.**
   `sd_bus_process()` dispatches at most one message per call; a single call per
   wakeup can't keep up with the continuous `RSSI PropertiesChanged` stream
   during discovery, so events lag badly even once the pump runs.

## Fix

**`tclblz.c`, `SetupHandlers()`** — while scanning or connected, guarantee a
periodic pump by clamping the timer to ≤200 ms regardless of what sd_bus
requests:

```c
    /* While scanning or connected, guarantee a periodic pump so sd_bus is
     * serviced even if the notifier never delivers a POLLIN for its fd. */
    if (blz->scanning || blz->connected) {
        if (ms < 0 || ms > 200) {
            ms = 200;
        }
    }
    if (ms >= 0) {
        blz->timer = Tcl_CreateTimerHandler(ms, TimerHandler, (ClientData) blz);
    }
```

**`blzlib.c`, `blz_handle_read()`** — drain a bounded burst per call (a bounded
loop, not `while (r > 0)`, so it can't spin forever on a continuous stream):

```c
void blz_handle_read(blz_ctx* ctx)
{
    int r, i;
    for (i = 0; i < 16; i++) {
        r = sd_bus_process(ctx->bus, NULL);
        if (r < 0) {
            LOG_ERR("BLZ: Handle read process error: %s", strerror(-r));
            return;
        }
        if (r == 0)
            break;
    }
}
```

(The `blzlib.c` half is also submitted upstream to infsoft-locaware/blzlib#8.
The `tclblz.c` half is AndroWish-specific.)

## After the fix

`blz scan` delivers devices immediately; a full de1app BLE session
(scan → connect → GATT notifications) works on undroidwish/Linux with the main
thread staying responsive.

Unified diff of both hunks is in `patches/blz-linux-eventloop-fix.diff`.
