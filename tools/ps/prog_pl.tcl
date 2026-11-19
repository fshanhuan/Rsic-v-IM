# tools/ps/prog_pl.tcl -- program a PL bitstream over JTAG (xsdb)
#
# Why this file exists: the PL loses its bitstream on every power cycle, and the
# SD card has to be seated at power-on for the PS to see it. So after the power
# cycle the PL is empty and has to be programmed again before anything that
# touches the recorder MMIO (sd_session.ps1 -Mode Full) can work.
#
# Usage (called from PowerShell):
#   $env:PL_BIT = "E:\FPGA\v9_vivado_ila\_baseline_v9\board_top_ps_rec_S5x.bit"
#   xsdb tools\ps\prog_pl.tcl
#
# Prints [PG] lines; the caller greps for them.
proc P {s} { puts "\[PG\] $s" ; flush stdout }

if {![info exists ::env(PL_BIT)]} { P "PL_BIT not set"; exit 1 }
set bit $::env(PL_BIT)
P "bitfile: $bit"
if {![file exists $bit]} { P "MISSING bitfile"; exit 1 }

connect
targets -set -filter {name =~ "xc7z020*"}
P "prog: [catch {fpga -file $bit} e] $e"
after 2500
P "targets:"
catch {puts [targets]}
P "done"
exit 0
