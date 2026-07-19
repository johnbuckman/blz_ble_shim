# selftest_mock.tcl -- verify blz_ble_shim's API + event translation under a
# MOCK blz, with NO Bluetooth radio.  Runs under plain tclsh.
#
#   tclsh selftest_mock.tcl
#
# It proves the hard logic: scan-name parsing, discovery synthesis, the
# write-ACK / read-completion / CCCD-ack events that AndroWish apps sequence on,
# and the exact AndroWish event-dict shapes.

# ---- a mock `blz` command (records app-driven ops, returns canned data) ----
namespace eval ::mock { variable scancb ""; variable conncb ""; variable seq 0 }
proc blz {sub args} {
    switch -- $sub {
        open  { return "blz[incr ::mock::seq]" }
        scan  { set ::mock::scancb [lindex $args 1]; return "" }
        stop  { return "" }
        connect { set ::mock::conncb [lindex $args 2]; return "" }
        disconnect - close { return "" }
        services { return {0000180A-0000-1000-8000-00805F9B34FB \
                           0000FF08-0000-1000-8000-00805F9B34FB} }
        characteristics {
            set su [lindex $args 1]
            if {[string match "*180A*" $su]} {
                return {00002A29-0000-1000-8000-00805F9B34FB \
                        00002A24-0000-1000-8000-00805F9B34FB}
            }
            return {0000EF80-0000-1000-8000-00805F9B34FB \
                    0000EF81-0000-1000-8000-00805F9B34FB}
        }
        enable - disable { return 1 }
        write { lappend ::mock::writes [list [lindex $args 1] [lindex $args 2] [lindex $args 3]]; return 1 }
        read  { return [binary decode hex "c0ffee"] }
        info  { return {} }
        callback { return "" }
        default { error "mock blz: unknown $sub $args" }
    }
}
package provide blz 1.0

# ---- load the shim under test ----
source [file join [file dirname [file dirname [file normalize [info script]]]] blz_ble_shim.tcl]

# ---- test harness ----
set ::PASS 0; set ::FAIL 0
proc ok {cond msg} {
    if {[uplevel 1 [list expr $cond]]} { incr ::PASS; puts "  ok  - $msg" } \
    else       { incr ::FAIL; puts "  NOT OK - $msg" }
}
proc flush_after {} { update idletasks; update }   ;# run queued after-0 events

# recording app callbacks
set ::EV {}   ;# list of {event data}
proc appcb {event data} { lappend ::EV [list $event $data] }
proc last_of {event} {
    set r {}
    foreach e $::EV { if {[lindex $e 0] eq $event} { set r [lindex $e 1] } }
    return $r
}
proc count_of {event} { set n 0; foreach e $::EV { if {[lindex $e 0] eq $event} { incr n } }; return $n }

puts "== blz_ble_shim self-test (mock blz, no radio) =="

# 1) the shim installed a real `ble` command
ok {[llength [info commands ble]] == 1} "ble command installed"
ok {[package provide ble] eq "1.0"} "package provide ble satisfied"

# 2) scanner + advertising-data name parsing (Complete Local Name 0x09 = "DE1abc")
set tok [ble scanner appcb]
ok {[string match "blzscanner*" $tok]} "ble scanner returns a token"
# craft AD: [len=7][type=09]'DE1abc'  then  [len=3][type=02] 16-bit svc 0xFF08
set ad "\x07\x09DE1abc\x03\x02\x08\xff"
::blzshim::on_blz scan [dict create handle blz1 address AA:BB:CC:DD:EE:FF rssi -55 scandata $ad]
set s [last_of scan]
ok {[dict get $s name] eq "DE1abc"} "scan: parsed Complete Local Name -> '[dict get $s name]'"
ok {[dict get $s address] eq "AA:BB:CC:DD:EE:FF"} "scan: address passed through"
ok {[dict get $s rssi] eq "-55"} "scan: rssi passed through"
ok {[lsearch -exact [dict get $s services] "FF08"] >= 0} "scan: parsed 16-bit service UUID FF08"

# 3) connect -> discovery synthesis -> connected
set ::EV {}
set h [ble connect AA:BB:CC:DD:EE:FF appcb]
ok {[string match "ble*" $h]} "ble connect returns handle '$h'"
# fire blz's connected callback; shim should synth discovery then connection
::blzshim::on_blz connection [dict create handle blz2 address AA:BB:CC:DD:EE:FF connected 1]
flush_after
ok {[count_of service] == 2} "discovery: 2 service events synthesized"
ok {[count_of characteristic] == 4} "discovery: 4 characteristic(discovery) events synthesized"
set disc {}
foreach e $::EV { if {[lindex $e 0] eq "characteristic"} { set disc [lindex $e 1] } }
ok {[dict get $disc state] eq "discovery"} "discovery: characteristic state=discovery"
ok {[dict exists $disc sinstance] && [dict exists $disc cinstance]} "discovery: carries sinstance/cinstance"
set conn [last_of connection]
ok {[dict get $conn state] eq "connected"} "connection: state=connected after discovery"
ok {[dict get $conn mtu] ne ""} "connection: carries mtu"
# ordering: all discovery events precede the connected event
set idx_conn -1; set idx_lastdisc -1
for {set i 0} {$i < [llength $::EV]} {incr i} {
    set ev [lindex [lindex $::EV $i] 0]
    if {$ev eq "connection"} { set idx_conn $i }
    if {$ev in {service characteristic}} { set idx_lastdisc $i }
}
ok {$idx_lastdisc < $idx_conn} "ordering: discovery events precede connected"

# 4) WRITE -> synthesized write-ACK (access=w) with echoed bytes (the crux)
set ::EV {}
set payload [binary decode hex "8401"]
set rc [ble write $h 0000FF08-0000-1000-8000-00805F9B34FB 0 0000EF80-0000-1000-8000-00805F9B34FB 0 $payload]
ok {$rc == 1} "write returns exactly 1 (AndroWish contract)"
ok {[count_of characteristic] == 0} "write-ACK is async (nothing before event loop runs)"
flush_after
set w [last_of characteristic]
ok {[dict get $w access] eq "w"} "write-ACK: access=w delivered"
ok {[dict get $w value] eq $payload} "write-ACK: echoes written bytes"
ok {[lindex [lindex $::mock::writes end] 2] eq $payload} "write: bytes reached blz write"

# 5) READ -> synthesized read-completion (access=r) with the value
set ::EV {}
set rc [ble read $h 0000FF08-0000-1000-8000-00805F9B34FB 0 0000EF81-0000-1000-8000-00805F9B34FB 0]
ok {$rc == 1} "read returns 1"
flush_after
set r [last_of characteristic]
ok {[dict get $r access] eq "r"} "read: access=r delivered"
ok {[binary encode hex [dict get $r value]] eq "coffee" || [binary encode hex [dict get $r value]] eq "c0ffee"} \
    "read: value carried from blz read (c0ffee)"

# 6) ENABLE -> synthesized CCCD descriptor ack (access=w)
set ::EV {}
set rc [ble enable $h 0000FF08-0000-1000-8000-00805F9B34FB 0 0000EF81-0000-1000-8000-00805F9B34FB 0]
ok {$rc == 1} "enable returns 1"
flush_after
set d [last_of descriptor]
ok {[dict get $d access] eq "w"} "enable: descriptor(access=w) CCCD ack delivered"
ok {[string match "*2902*" [dict get $d duuid]]} "enable: CCCD duuid 0x2902"

# 7) NOTIFICATION (blz characteristic) -> access=c
set ::EV {}
::blzshim::on_blz characteristic [dict create handle blz2 address AA:BB:CC:DD:EE:FF \
    suuid 0000FF08-0000-1000-8000-00805F9B34FB cuuid 0000EF81-0000-1000-8000-00805F9B34FB \
    flags 0 value [binary decode hex "01f4"]]
set c [last_of characteristic]
ok {[dict get $c access] eq "c"} "notification: access=c delivered"
ok {[binary encode hex [dict get $c value]] eq "01f4"} "notification: value carried"

# 8) UUID helpers
ok {[ble expand FF08] eq "0000FF08-0000-1000-8000-00805F9B34FB"} "ble expand 16-bit -> 128-bit"
ok {[ble shorten 0000FF08-0000-1000-8000-00805F9B34FB] eq "FF08"} "ble shorten 128-bit -> 16-bit"
ok {[ble equal FF08 0000ff08-0000-1000-8000-00805f9b34fb] == 1} "ble equal short vs long"

# 9) disconnect
set ::EV {}
::blzshim::on_blz connection [dict create handle blz2 address AA:BB:CC:DD:EE:FF connected 0]
set dc [last_of connection]
ok {[dict get $dc state] eq "disconnected"} "disconnect: state=disconnected delivered"

puts ""
puts "== RESULT: $::PASS passed, $::FAIL failed =="
exit [expr {$::FAIL ? 1 : 0}]
