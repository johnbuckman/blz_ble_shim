# blz_ble_shim.tcl --
#
# An AndroWish-compatible `ble` command implemented on top of undroidwish's
# built-in `blz` (BlueZ) command, so Tcl code written against the AndroWish BLE
# API runs UNALTERED on Linux/BlueZ.
#
# Copyright (C) 2026 John Buckman
# SPDX-License-Identifier: TCL
#
# Usage (the ONLY change an AndroWish app needs):
#     package require blz_ble_shim 1.0
# ...placed before the app's own `package require ble` / `ble ...` calls.
#
# It installs a global `ble` command AND `package provide ble 1.0`, so an app's
# existing `package require ble` (which fails on Linux undroidwish, that ships
# only `blz`) is satisfied too.  It is inert where it must not act:
#   * if a real `ble` command already exists (Android, or macOS tcl-ble-osx), it
#     defers and does not clobber it;
#   * if `blz` is unavailable (not undroidwish-on-Linux), it does nothing.
#
# ---------------------------------------------------------------------------
# API presented (matches AndroWish / tcl-ble-osx exactly):
#
#   ble scanner   <callback>                       -> scanner token (starts scan)
#   ble start     <token>                          -> (re)start scanning
#   ble stop      <token>                          -> stop scanning
#   ble connect   <address> <callback> ?<reconnect>? -> connection handle "ble<n>"
#   ble reconnect <handle>                         -> re-attempt connect
#   ble disconnect/close <handle>                  -> disconnect / stop scanner
#   ble info      ?<handle>?                        -> handles / info dict
#   ble enable    <h> <suuid> <si> <cuuid> <ci>    -> 1  (+ synth descriptor ack)
#   ble disable   <h> <suuid> <si> <cuuid> <ci>    -> 1
#   ble write     <h> <suuid> <si> <cuuid> <ci> ?<wt>? <data> -> 1 (+ synth w-ack)
#   ble read      <h> <suuid> <si> <cuuid> <ci>    -> 1  (+ synth r-event)
#   ble mtu       <h> ?<value>?                     -> mtu (best-effort)
#   ble userdata  <h> ?<value>?                     -> per-handle scratch
#   ble state                                       -> adapter state
#   ble expand/shorten/equal ...                    -> pure-Tcl UUID helpers
#   ble abort/unpair/pair/begin/execute/getrssi     -> accepted (no-op/best effort)
#
# Callback:  {*}$callback $event $datadict
#   event in: scan connection characteristic descriptor
#   AndroWish keys: handle address name rssi state suuid sinstance cuuid
#                   cinstance duuid access value ...   (value = binary byte array)
#
# The hard part -- and the reason this is more than a rename -- is that `blz`
# emits ONLY three callbacks (scan, connection, notification) and its read/write
# are SYNCHRONOUS with no event.  AndroWish apps sequence on write-ACK
# (characteristic access=w), read-completion (access=r), discovery
# (characteristic state=discovery) and CCCD-ack (descriptor access=w) events, so
# this shim SYNTHESIZES those, delivered via `after 0` to reproduce AndroWish's
# asynchronous ordering.
# ---------------------------------------------------------------------------

package require Tcl 8.5

namespace eval ::blzshim {
    variable BASE 0000%s-0000-1000-8000-00805F9B34FB   ;# 16-bit -> 128-bit
    variable CCCD 00002902-0000-1000-8000-00805F9B34FB ;# Client Char Config desc

    variable adapter     "hci0" ;# BlueZ adapter blz opens (override before first use)
    variable handleseq   0      ;# -> ble1, ble2, ...
    variable scannerseq  0      ;# -> blzscanner1, ...
    variable scanctx     ""     ;# blz handle used for scanning
    variable scannercb   ""     ;# app callback for scan events
    variable scannertok  ""     ;# outstanding scanner token

    # per ble-handle state (parallel arrays keyed by "ble<n>")
    variable blzof   ;# ble handle -> blz handle
    variable bleof   ;# blz handle -> ble handle
    variable addrof  ;# ble handle -> address
    variable cbof    ;# ble handle -> app callback
    variable mtuof   ;# ble handle -> negotiated mtu
    variable udata   ;# ble handle -> userdata scratch
    variable chars   ;# ble handle -> list of {suuid cuuid} discovered
    array set blzof  {}
    array set bleof  {}
    array set addrof {}
    array set cbof   {}
    array set mtuof  {}
    array set udata  {}
    array set chars  {}

    variable debug 0
}

proc ::blzshim::log {args} {
    variable debug
    if {!$debug} return
    set m [join $args " "]
    catch {
        if {[llength [info commands ::msg]]}  { ::msg -DEBUG "blz_shim: $m" } \
        elseif {[llength [info commands msg]]} { msg  -DEBUG "blz_shim: $m" }
    }
    catch { puts stderr "blz_shim: $m" }
}

# ---------------------------------------------------------------------------
# UUID helpers (pure Tcl; blz also accepts short forms, but apps pass 128-bit)
# ---------------------------------------------------------------------------
proc ::blzshim::expand_uuid {u} {
    variable BASE
    set s [string toupper $u]
    if {[regexp {^[0-9A-F]{4}$} $s]}      { return [format $BASE $s] }
    if {[regexp {^[0-9A-F]{8}$} $s]}      { return "$s-0000-1000-8000-00805F9B34FB" }
    return $s
}
proc ::blzshim::shorten_uuid {u} {
    set s [string toupper $u]
    if {[regexp {^0000([0-9A-F]{4})-0000-1000-8000-00805F9B34FB$} $s -> x]} { return $x }
    return $s
}
proc ::blzshim::uuid_equal {a b} {
    return [string equal -nocase [expand_uuid $a] [expand_uuid $b]]
}

# ---------------------------------------------------------------------------
# Deliver an AndroWish-shaped event to an app callback (never inline: via after 0
# for synthesized ones; blz-sourced ones are already in the event loop).
# ---------------------------------------------------------------------------
proc ::blzshim::deliver {cb event data} {
    if {$cb eq ""} return
    if {[catch {uplevel #0 [list {*}$cb $event $data]} err]} {
        catch {
            if {[llength [info commands ::bgerror]]} { ::bgerror $err } \
            else { puts stderr "ble callback error: $err\n$::errorInfo" }
        }
    }
}
proc ::blzshim::later {cb event data} {
    after 0 [list ::blzshim::deliver $cb $event $data]
}

# ---------------------------------------------------------------------------
# Parse a raw BLE advertising-data byte string into name / services / mfr.
# AD structure: repeated [len][type][len-1 bytes of data].
# ---------------------------------------------------------------------------
proc ::blzshim::parse_adv {scandata} {
    set name ""; set services {}; set mfr ""
    set n [string length $scandata]
    set i 0
    while {$i < $n} {
        binary scan [string index $scandata $i] cu len
        if {$len == 0} { incr i; continue }
        if {$i + $len >= $n + 1} break
        binary scan [string index $scandata [expr {$i+1}]] cu type
        set payload [string range $scandata [expr {$i+2}] [expr {$i+$len}]]
        switch -- $type {
            8 - 9 { set name [encoding convertfrom utf-8 $payload] }
            2 - 3 {
                binary scan $payload su* us
                foreach u $us { lappend services [format %04X [expr {$u & 0xffff}]] }
            }
            6 - 7 {
                # 128-bit UUIDs, little-endian 16 bytes each
                for {set k 0} {$k + 16 <= [string length $payload]} {incr k 16} {
                    set b [string range $payload $k [expr {$k+15}]]
                    set rev ""
                    for {set j 15} {$j >= 0} {incr j -1} { append rev [string index $b $j] }
                    binary scan $rev H* hx
                    lappend services [string toupper [string range $hx 0 7]]
                }
            }
            255 {
                if {[string length $payload] >= 2} {
                    binary scan $payload su cid
                    set mfr [format "0x%04X" [expr {$cid & 0xffff}]]
                }
            }
        }
        incr i [expr {$len + 1}]
    }
    return [list $name $services $mfr]
}

# ---------------------------------------------------------------------------
# blz backend calls, isolated so signature differences are handled in one place.
# (blz `connect`/`scan` take the blz context handle first; verified at runtime.)
# ---------------------------------------------------------------------------
proc ::blzshim::blz_open {} {
    # blz open REQUIRES a btdev name (e.g. hci0); it returns a context handle,
    # or errors "unable to open <dev>" if that adapter is absent.
    variable adapter
    if {[info exists ::env(BLZ_ADAPTER)]} { set adapter $::env(BLZ_ADAPTER) }
    return [blz open $adapter]
}

# ---------------------------------------------------------------------------
# The single blz callback: routes blz events to the right app callback and
# translates blz's dicts to AndroWish's.
# ---------------------------------------------------------------------------
proc ::blzshim::on_blz {event data} {
    variable bleof
    variable addrof
    variable cbof
    variable scanctx
    variable scannercb
    variable mtuof

    set bh ""; catch { set bh [dict get $data handle] }

    switch -- $event {
        scan {
            set addr ""; catch { set addr [string toupper [dict get $data address]] }
            set rssi ""; catch { set rssi [dict get $data rssi] }
            set sd "";   catch { set sd [dict get $data scandata] }
            lassign [parse_adv $sd] name services mfr
            set out [dict create address $addr name $name rssi $rssi]
            if {$services ne ""} { dict set out services $services }
            if {$mfr ne ""}      { dict set out mfr $mfr }
            deliver $scannercb scan $out
        }
        connection {
            if {![info exists bleof($bh)]} return
            set ble $bleof($bh)
            set addr [expr {[info exists addrof($ble)] ? $addrof($ble) : ""}]
            set connected 0; catch { set connected [dict get $data connected] }
            if {$connected} {
                # 1) synthesize discovery from blz's cached services/characteristics
                discover_and_emit $bh $ble $addr
                # 2) then the connected event
                set mtu [expr {[info exists mtuof($ble)] ? $mtuof($ble) : 23}]
                deliver $cbof($ble) connection \
                    [dict create handle $ble address $addr state connected mtu $mtu]
            } else {
                deliver $cbof($ble) connection \
                    [dict create handle $ble address $addr state disconnected]
                forget_handle $ble
            }
        }
        characteristic {
            # blz only emits this for notifications/indications
            if {![info exists bleof($bh)]} return
            set ble $bleof($bh)
            set addr [expr {[info exists addrof($ble)] ? $addrof($ble) : ""}]
            set su ""; catch { set su [dict get $data suuid] }
            set cu ""; catch { set cu [dict get $data cuuid] }
            set val ""; catch { set val [dict get $data value] }
            deliver $cbof($ble) characteristic \
                [dict create handle $ble address $addr state connected access c \
                     suuid $su sinstance 0 cuuid $cu cinstance 0 value $val]
        }
    }
}

# Enumerate services/characteristics on a freshly connected blz handle and push
# AndroWish `characteristic {state discovery ...}` events (with a matching
# `service` marker) into the app callback.
proc ::blzshim::discover_and_emit {bh ble addr} {
    variable cbof
    variable chars
    set chars($ble) {}
    set svcs {}
    catch { set svcs [blz services $bh] }
    foreach su $svcs {
        deliver $cbof($ble) service \
            [dict create handle $ble address $addr state discovery \
                 suuid $su sinstance 0 type primary]
        set clist {}
        catch { set clist [blz characteristics $bh $su] }
        foreach cu $clist {
            lappend chars($ble) [list $su $cu]
            deliver $cbof($ble) characteristic \
                [dict create handle $ble address $addr state discovery \
                     suuid $su sinstance 0 cuuid $cu cinstance 0]
        }
    }
}

proc ::blzshim::forget_handle {ble} {
    variable blzof; variable bleof; variable addrof
    variable cbof;  variable mtuof; variable chars
    if {[info exists blzof($ble)]} {
        set bh $blzof($ble)
        catch { unset bleof($bh) }
        catch { blz close $bh }
    }
    foreach a {blzof addrof cbof mtuof chars} {
        catch { unset ${a}($ble) }
    }
}

# ---------------------------------------------------------------------------
# The `ble` command.
# ---------------------------------------------------------------------------
proc ::blzshim::cmd {sub args} {
    variable handleseq
    variable scannerseq
    variable scanctx
    variable scannercb
    variable scannertok
    variable blzof
    variable bleof
    variable addrof
    variable cbof
    variable mtuof
    variable udata
    variable chars

    switch -- $sub {

        scanner {
            # ble scanner <callback>  -> token (and start scanning)
            set scannercb [lindex $args 0]
            if {$scanctx eq ""} { set scanctx [blz_open] }
            incr scannerseq
            set scannertok "blzscanner$scannerseq"
            catch { blz scan $scanctx ::blzshim::on_blz }
            return $scannertok
        }

        start {
            # ble start <token>  -- (re)start scanning; idempotent
            if {$scanctx ne ""} { catch { blz scan $scanctx ::blzshim::on_blz } }
            return ""
        }

        stop {
            # ble stop <token>
            if {$scanctx ne ""} { catch { blz stop $scanctx } }
            return ""
        }

        connect {
            # ble connect <address> <callback> ?<reconnect>?  -> handle
            set address [string toupper [lindex $args 0]]
            set callback [lindex $args 1]
            incr handleseq
            set ble "ble$handleseq"
            set bh [blz_open]
            set blzof($ble)  $bh
            set bleof($bh)   $ble
            set addrof($ble) $address
            set cbof($ble)   $callback
            # blz connect <handle> <btaddr> <command> ?random?
            set random [expr {[llength $args] >= 3 ? [lindex $args 2] : 0}]
            if {[catch { blz connect $bh $address ::blzshim::on_blz $random } err]} {
                forget_handle $ble
                error $err
            }
            return $ble
        }

        reconnect {
            # ble reconnect <handle>
            set ble [lindex $args 0]
            if {[info exists addrof($ble)] && [info exists blzof($ble)]} {
                catch { blz connect $blzof($ble) $addrof($ble) ::blzshim::on_blz }
            }
            return $ble
        }

        close - disconnect {
            # ble close <handle|scannertoken>
            set h [lindex $args 0]
            if {[string match "blzscanner*" $h]} {
                if {$scanctx ne ""} { catch { blz stop $scanctx } }
                return ""
            }
            if {[info exists blzof($h)]} {
                catch { blz disconnect $blzof($h) }
                forget_handle $h
            }
            return ""
        }

        info {
            if {[llength $args] == 0} { return [array names blzof] }
            set ble [lindex $args 0]
            if {![info exists addrof($ble)]} { return "" }
            set mtu [expr {[info exists mtuof($ble)] ? $mtuof($ble) : 23}]
            return [list handle $ble address $addrof($ble) mtu $mtu state connected]
        }

        enable {
            # ble enable <h> <suuid> <si> <cuuid> <ci>
            lassign $args ble suuid si cuuid ci
            if {![info exists blzof($ble)]} { return 0 }
            set addr $addrof($ble)
            if {[catch { blz enable $blzof($ble) $suuid $cuuid } e]} {
                log "enable failed: $e"; return 0
            }
            # synth the CCCD write acknowledgement AndroWish delivers
            variable CCCD
            later $cbof($ble) descriptor \
                [dict create handle $ble address $addr state connected access w \
                     suuid $suuid sinstance $si cuuid $cuuid cinstance $ci \
                     duuid $CCCD value [binary decode hex 0100]]
            return 1
        }

        disable {
            lassign $args ble suuid si cuuid ci
            if {![info exists blzof($ble)]} { return 0 }
            set addr $addrof($ble)
            if {[catch { blz disable $blzof($ble) $suuid $cuuid } e]} {
                log "disable failed: $e"; return 0
            }
            variable CCCD
            later $cbof($ble) descriptor \
                [dict create handle $ble address $addr state connected access w \
                     suuid $suuid sinstance $si cuuid $cuuid cinstance $ci \
                     duuid $CCCD value [binary decode hex 0000]]
            return 1
        }

        write {
            # ble write <h> <suuid> <si> <cuuid> <ci> ?<writetype>? <data>
            set ble    [lindex $args 0]
            set suuid  [lindex $args 1]
            set si     [lindex $args 2]
            set cuuid  [lindex $args 3]
            set ci     [lindex $args 4]
            if {[llength $args] >= 7} {
                set data [lindex $args 6]
            } else {
                set data [lindex $args 5]
            }
            if {![info exists blzof($ble)]} { return 0 }
            set addr $addrof($ble)
            if {[catch { blz write $blzof($ble) $suuid $cuuid $data } e]} {
                log "write failed: $e"; return 0
            }
            # synth the write-with-response ACK the app's command queue waits on
            later $cbof($ble) characteristic \
                [dict create handle $ble address $addr state connected access w \
                     suuid $suuid sinstance $si cuuid $cuuid cinstance $ci value $data]
            return 1
        }

        read {
            # ble read <h> <suuid> <si> <cuuid> <ci>  -> 1 (value via event)
            lassign $args ble suuid si cuuid ci
            if {![info exists blzof($ble)]} { return 0 }
            set addr $addrof($ble)
            set val ""
            if {[catch { set val [blz read $blzof($ble) $suuid $cuuid] } e]} {
                log "read failed: $e"; return 0
            }
            later $cbof($ble) characteristic \
                [dict create handle $ble address $addr state connected access r \
                     suuid $suuid sinstance $si cuuid $cuuid cinstance $ci value $val]
            return 1
        }

        mtu {
            set ble [lindex $args 0]
            return [expr {[info exists mtuof($ble)] ? $mtuof($ble) : 23}]
        }

        userdata {
            set ble [lindex $args 0]
            if {[llength $args] >= 2} { set udata($ble) [lindex $args 1] }
            return [expr {[info exists udata($ble)] ? $udata($ble) : ""}]
        }

        state {
            # best-effort adapter state
            if {[catch { blz info } ] } { return "unknown" }
            return "poweredOn"
        }

        services {
            set ble [lindex $args 0]
            if {![info exists blzof($ble)]} { return "" }
            set out {}
            catch { foreach su [blz services $blzof($ble)] { lappend out $su 0 primary } }
            return $out
        }

        characteristics {
            lassign $args ble suuid si
            if {![info exists blzof($ble)]} { return "" }
            set out {}
            catch { foreach cu [blz characteristics $blzof($ble) $suuid] { lappend out $cu 0 0 0 2 } }
            return $out
        }

        expand   { return [expand_uuid  [lindex $args end]] }
        shorten  { return [shorten_uuid [lindex $args end]] }
        equal    { return [uuid_equal [lindex $args end-1] [lindex $args end]] }

        abort - unpair - pair - begin - execute - getrssi - callback {
            return ""
        }

        default {
            error "ble: unknown subcommand \"$sub\""
        }
    }
}

# ---------------------------------------------------------------------------
# Install -- guarded so it never clobbers a real `ble` and only acts when `blz`
# is available (i.e. undroidwish on Linux).
# ---------------------------------------------------------------------------
if {[llength [info commands ble]] > 0} {
    ::blzshim::log "a real `ble` command already exists; deferring"
    package provide blz_ble_shim 1.0
    return
}
if {[catch { package require blz }]} {
    ::blzshim::log "no `blz` command available; shim inert (not undroidwish-on-Linux?)"
    package provide blz_ble_shim 1.0
    return
}

proc ::ble {sub args} { return [::blzshim::cmd $sub {*}$args] }
package provide ble 1.0             ;# satisfy apps that `package require ble`
package provide blz_ble_shim 1.0
::blzshim::log "installed: ble -> blz shim"
