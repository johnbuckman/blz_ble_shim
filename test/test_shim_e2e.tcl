# test_shim_e2e.tcl --
#
# End-to-end tests: drive blz_ble_shim through the AndroWish `ble` API over a
# SIMULATED blz backend with virtual DE1 + Skale devices. Runs under plain tclsh
# (macOS included), no radio. Exercises the full stack an AndroWish app uses:
# scan -> name resolution -> connect -> discovery -> enable/notify ->
# write-ACK-gated command flow -> read -> multi-connection -> disconnect.
#
#   tclsh test_shim_e2e.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root blz_sim.tcl]        ;# provides `blz` + virtual devices
lappend auto_path $root
package require blz_ble_shim                 ;# installs `ble` on top of sim blz

# ---- tiny harness ----
set ::PASS 0; set ::FAIL 0
proc ok {cond msg} {
    if {[uplevel 1 [list expr $cond]]} { incr ::PASS; puts "  ok   - $msg" } \
    else { incr ::FAIL; puts "  FAIL - $msg" }
}
proc pump {ms} { set ::_d 0; after $ms {set ::_d 1}; vwait ::_d }

# Event collector keyed by a tag (one per ble connection / scanner)
proc collector {tag} { return [list ::ev_record $tag] }
proc ev_record {tag event data} { lappend ::EV($tag) [list $event $data] }
proc evs {tag} { return [expr {[info exists ::EV($tag)] ? $::EV($tag) : {}}] }
proc reset {tag} { set ::EV($tag) {} }
# events of a given type; optionally filtered by a key=val in the dict
proc pick {tag event args} {
    set out {}
    foreach e [evs $tag] {
        if {[lindex $e 0] ne $event} continue
        set d [lindex $e 1]; set match 1
        foreach {k v} $args { if {![dict exists $d $k] || [dict get $d $k] ne $v} { set match 0; break } }
        if {$match} { lappend out $d }
    }
    return $out
}

puts "== blz_ble_shim end-to-end (simulated DE1 + Skale, no radio) =="
ok {[llength [info commands ble]] == 1} "shim installed the ble command over simulated blz"

# ---------------------------------------------------------------- 1. SCAN
puts "\n-- scan / name resolution --"
set ::EV(scan) {}
set tok [ble scanner [collector scan]]
ble start $tok
pump 300
ble stop $tok
set names {}
foreach d [pick scan scan] { lappend names [dict get $d name] }
ok {"DE1" in $names}   "scan resolved DE1 name from advertising data"
ok {"Skale" in $names} "scan resolved Skale name from advertising data"
# capture addresses like a real app would
foreach d [pick scan scan] { set ADDR([dict get $d name]) [dict get $d address] }
ok {[info exists ADDR(DE1)] && [info exists ADDR(Skale)]} "captured device addresses from scan"

# ---------------------------------------------------------------- 2. DE1 connect+discovery
puts "\n-- DE1 connect + discovery synthesis --"
reset de1
array unset SI; array unset CI    ;# instance maps, as a real app records them
set de1 [ble connect $ADDR(DE1) [collector de1] 0]
pump 200
# discovery characteristic events (state=discovery) then connected, in order
set disc [pick de1 characteristic state discovery]
ok {[llength $disc] >= 4} "DE1 discovery produced characteristic events ([llength $disc])"
foreach d $disc { set SI([dict get $d cuuid]) [dict get $d sinstance]; set CI([dict get $d cuuid]) [dict get $d cinstance] }
set conn [pick de1 connection state connected]
ok {[llength $conn] == 1} "DE1 connection state=connected delivered"
# ordering: connected comes after all discovery
set order {}; foreach e [evs de1] { lappend order [list [lindex $e 0] [expr {[dict exists [lindex $e 1] state] ? [dict get [lindex $e 1] state] : {}}]] }
set idxC [lsearch -exact $order {connection connected}]
set idxD 0; set i 0; foreach e $order { if {[lindex $e 0] in {characteristic service} && [lindex $e 1] eq "discovery"} { set idxD $i }; incr i }
ok {$idxD < $idxC} "discovery events precede connected (correct ordering)"

# UUIDs the DE1 exposes
set A002 [::blzsim::u A002]  ;# RequestedState (write)
set A001 [::blzsim::u A001]  ;# Versions (read)
set A00E [::blzsim::u A00E]  ;# StateInfo (notify, event-driven)
set A000 [::blzsim::u A000]
ok {[info exists CI($A002)]} "recorded sinstance/cinstance for RequestedState"

# ---------------------------------------------------------------- 3. write-ACK flow + device reaction
puts "\n-- DE1 write -> write-ACK + device notification --"
reset de1
ble enable $de1 $A000 $SI($A00E) $A00E $CI($A00E)   ;# subscribe StateInfo
set rc [ble write $de1 $A000 $SI($A002) $A002 $CI($A002) [binary decode hex "05"]]
ok {$rc == 1} "ble write returned 1 (AndroWish contract)"
pump 200
set wack [pick de1 characteristic access w cuuid $A002]
ok {[llength $wack] == 1} "synthesized write-ACK (access=w) delivered for RequestedState"
ok {[llength $wack] && [binary encode hex [dict get [lindex $wack 0] value]] eq "05"} "write-ACK echoes the written byte (05)"
set note [pick de1 characteristic access c cuuid $A00E]
ok {[llength $note] >= 1} "device reacted: StateInfo notification (access=c) after the write"
ok {[llength $note] && [binary encode hex [dict get [lindex $note 0] value]] eq "05"} "StateInfo reflects the requested state (05)"
# CCCD ack from enable
ok {[llength [pick de1 descriptor access w]] >= 1} "enable produced CCCD descriptor ack (access=w)"

# ---------------------------------------------------------------- 4. read
puts "\n-- DE1 read --"
reset de1
ble read $de1 $A000 $SI($A001) $A001 $CI($A001)
pump 100
set rd [pick de1 characteristic access r cuuid $A001]
ok {[llength $rd] == 1} "read produced a characteristic access=r event"
ok {[llength $rd] && [binary encode hex [dict get [lindex $rd 0] value]] eq "03000201"} "read returned the Versions value (03000201)"

# ---------------------------------------------------------------- 5. Skale weight stream
puts "\n-- Skale connect + weight notification stream --"
reset skale
set skale [ble connect $ADDR(Skale) [collector skale] 0]
pump 150
set FF08 [::blzsim::u FF08]; set EF81 [::blzsim::u EF81]; set EF80 [::blzsim::u EF80]
# record instances
foreach d [pick skale characteristic state discovery] { set SI([dict get $d cuuid]) [dict get $d sinstance]; set CI([dict get $d cuuid]) [dict get $d cinstance] }
ok {[llength [pick skale connection state connected]] == 1} "Skale connected"
reset skale
ble enable $skale $FF08 $SI($EF81) $EF81 $CI($EF81)
pump 700     ;# let a few weight ticks arrive (every 200ms)
set wts [pick skale characteristic access c cuuid $EF81]
ok {[llength $wts] >= 2} "received a stream of weight notifications ([llength $wts])"
ok {[llength $wts] && [string length [dict get [lindex $wts 0] value]] == 18} \
   "weight packet is 18 bytes end-to-end (real Atomax Skale length; shim doesn't truncate)"
# decode two samples and confirm weight is increasing (flag byte + LE int16 tenths)
if {[llength $wts] >= 2} {
    binary scan [dict get [lindex $wts 0] value] xs w0
    binary scan [dict get [lindex $wts end] value] xs w1
    ok {$w1 > $w0} "weight increases across the stream ($w0 -> $w1 tenths g)"
} else { ok {0} "weight increases across the stream" }
# tare write -> write ack
reset skale
ble write $skale $FF08 $SI($EF80) $EF80 $CI($EF80) [binary decode hex "03"]
pump 100
ok {[llength [pick skale characteristic access w cuuid $EF80]] == 1} "Skale tare write produced a write-ACK"

# ---------------------------------------------------------------- 6. two simultaneous connections
puts "\n-- concurrent DE1 + Skale: event routing --"
ok {$de1 ne $skale} "DE1 and Skale have distinct handles ($de1 vs $skale)"
reset de1; reset skale
ble write $de1 $A000 $SI($A002) $A002 $CI($A002) [binary decode hex "07"]
pump 200
ok {[llength [pick de1 characteristic access w]] >= 1 && [llength [pick skale characteristic access w]] == 0} \
   "a DE1 write's ACK routed ONLY to the DE1 callback (no cross-talk)"

# ---------------------------------------------------------------- 7. disconnect
puts "\n-- disconnect --"
reset de1
ble close $de1
pump 100
# real blz emits disconnected on disconnect; shim forwards it
catch {ble disconnect $skale}
ok {[llength [info commands ble]] == 1} "shim survived close/disconnect calls"

# ---------------------------------------------------------------- 8. uuid helpers
puts "\n-- UUID helpers --"
ok {[ble expand A002] eq [::blzsim::u A002]} "ble expand short->128-bit"
ok {[ble shorten [::blzsim::u A002]] eq "A002"} "ble shorten 128-bit->short"
ok {[ble equal A002 [string tolower [::blzsim::u A002]]] == 1} "ble equal short vs long (case-insensitive)"

puts "\n== RESULT: $::PASS passed, $::FAIL failed =="
exit [expr {$::FAIL ? 1 : 0}]
