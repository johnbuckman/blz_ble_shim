# Minimal scan example using the AndroWish `ble` API via blz_ble_shim.
#
#   tclsh scan.tcl           # uses the real blz (undroidwish on Linux)
#   tclsh scan.tcl --sim     # uses simulated DE1 + Skale (any platform, no radio)
#
set root [file dirname [file dirname [file normalize [info script]]]]
lappend auto_path $root
if {[lindex $argv 0] eq "--sim"} { package require blz_sim }
package require blz_ble_shim

proc cb {event data} {
    if {$event eq "scan"} {
        puts [format "%5s dBm  %-20s %s" \
            [dict get $data rssi] [dict get $data name] [dict get $data address]]
    }
}
puts "scanning 3s ..."
ble scanner cb
after 3000 {set ::done 1}
vwait ::done
