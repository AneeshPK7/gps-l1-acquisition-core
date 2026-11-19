# -----------------------------------------------------------------------------
# fft_width.tcl - Vivado out-of-context build of the 1024-point SDF FFT engine
#                 at 16-bit and 32-bit word length (report Section 6.3)
#
#   cd <project root>
#   vivado -mode batch -source vivado/fft_width.tcl                 (both widths)
#   vivado -mode batch -source vivado/fft_width.tcl -tclargs 32     (one width)
#
# For each width DW: synth (out of context) -> opt -> place -> route on
# xc7z020clg400-1 with a 100 MHz clock, then reports in
#   vivado/fft_width/dw<DW>/{utilization.txt, utilization_hier.txt,
#                            timing_summary.txt, timing_paths.txt}
# Only the FFT engine (hw/rtl/sdf_stage.sv, hw/rtl/fft_sdf.sv) is built; the rest of
# the core is 16-bit only. DW = 16 is the shipped design, DW = 32 the comparison.
# -----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set hw     $root/hw
set part   xc7z020clg400-1
set widths [expr {$argc > 0 ? $argv : {16 32}}]

foreach dw $widths {
    if {$dw == 16} {
        set tw $hw/mem/twiddle.hex
    } elseif {$dw == 32} {
        set tw $hw/mem/twiddle32.hex
    } else {
        error "width must be 16 or 32, got $dw"
    }
    set out $root/vivado/fft_width/dw$dw
    file mkdir $out
    puts "==================== FFT DW=$dw ===================="

    create_project -in_memory -part $part
    read_verilog -sv [list $hw/rtl/sdf_stage.sv $hw/rtl/fft_sdf.sv]
    read_mem $tw
    # 100 MHz clock on the FFT's clk port
    set xdc $out/clock.xdc
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period 10.000 \[get_ports clk\]"
    close $fh
    read_xdc -mode out_of_context $xdc

    synth_design -top fft_sdf -part $part -mode out_of_context \
        -generic DW=$dw -generic "TW_FILE=\"$tw\""
    report_utilization -file $out/utilization_synth.txt
    opt_design
    place_design
    phys_opt_design
    route_design

    report_utilization                -file $out/utilization.txt
    report_utilization -hierarchical  -file $out/utilization_hier.txt
    report_timing_summary -max_paths 5 -file $out/timing_summary.txt
    report_timing -max_paths 5 -sort_by slack -file $out/timing_paths.txt

    set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
    set fh [open $out/summary.txt w]
    puts $fh "DW=$dw part=$part clock=10.000ns WNS=$wns"
    puts $fh "Fmax_est_MHz=[format %.1f [expr {1000.0 / (10.0 - $wns)}]]"
    close $fh
    puts "DW=$dw WNS=$wns ns"
    close_project
}
