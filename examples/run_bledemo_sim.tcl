# Run the BLE debugger GUI against SIMULATED DE1 + Skale (no radio, any platform).
#   wish8.6 run_bledemo_sim.tcl
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
lappend auto_path $root
package require blz_sim                    ;# simulated blz + virtual DE1/Skale
package require blz_ble_shim               ;# installs the AndroWish `ble` command
source [file join $here bledemo.tcl]       ;# the BLE debugger, unaltered
