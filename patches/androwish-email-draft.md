**To:** chw@ch-werner.de
**Subject:** undroidwish blz: BLE scan/notification callbacks never delivered under the Tcl event loop (patch)

---

Hi Christian,

Thanks for AndroWish/undroidwish — we lean on it heavily at Decent Espresso.

While bringing our espresso-machine app (de1app) up on undroidwish on Linux I hit a bug in the bundled `blz` extension where BLE scanning silently delivers nothing, and I have a small fix I'd like to pass along.

### Symptom

`blz scan` starts BlueZ discovery fine (adapter shows `Discovering: yes`, `StartDiscovery` returns OK), but the Tcl scan callback never fires — zero device callbacks — even though `bluetoothctl` / `dbus-monitor` show BlueZ emitting `InterfacesAdded` for the devices at that moment. Notifications after connect are similarly laggy. The Tcl event loop stays alive; `blz` just never pumps sd_bus. Reproduced on undroidwish (SDL) with BlueZ 5.x on Ubuntu 24.04, both aarch64 and x86_64, against a real DE1 machine + Decent scale via a TP-Link UB500.

### Root cause (two parts)

1. **`tclblz.c`, `SetupHandlers()`:** right after `StartDiscovery`, sd_bus reports an effectively infinite timeout (`ms == -1`) **and** the bus fd doesn't reliably deliver a readable (POLLIN) event through the SDL notifier — so neither the Tcl timer nor the file handler gets armed, and `sd_bus_process()` is never called again. Incoming signals sit unprocessed.
2. **`blzlib.c`, `blz_handle_read()`:** it calls `sd_bus_process()` once per invocation, but that dispatches at most one message per call — it can't keep up with the continuous `RSSI PropertiesChanged` stream during discovery.

### Fix

**`tclblz.c`, `SetupHandlers()`** — while scanning or connected, guarantee a periodic pump by clamping the timer to ≤200 ms regardless of what sd_bus requests:

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

**`blzlib.c`, `blz_handle_read()`** — drain a bounded burst per call (bounded, not `while (r > 0)`, so it can't spin on a continuous stream):

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

After the fix, `blz scan` delivers devices immediately and a full session (scan → connect → GATT notifications) works on undroidwish/Linux with the UI staying responsive.

The `blzlib.c` half I've also submitted to the upstream blzlib repo as [infsoft-locaware/blzlib#8](https://github.com/infsoft-locaware/blzlib/pull/8) (it's a general improvement there); the `SetupHandlers()` change is specific to AndroWish's `tclblz.c`.

Happy to send this in whatever form is easiest for you — a Fossil patch/bundle, a forum post, or just the two diffs. Just let me know.

Thanks again,
John Buckman
Decent Espresso
