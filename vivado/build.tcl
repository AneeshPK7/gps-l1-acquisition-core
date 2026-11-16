# -----------------------------------------------------------------------------
# build.tcl - Zynq-7020 block design, bitstream and XSA for the acquisition core
#
#   cd <project root>
#   vivado -mode batch -source vivado/build.tcl                   (PYNQ-Z2, default)
#   vivado -mode batch -source vivado/build.tcl -tclargs zedboard
#
# Block design (report Figure 1):
#   PS7  M_AXI_GP0 --> AXI interconnect --> gps_acq (s_axi, 0x43C0_0000)
#                                       \-> AXI DMA (S_AXI_LITE)
#   AXI DMA M_AXI_MM2S --> PS7 S_AXI_HP0 (DDR);  M_AXIS_MM2S --> gps_acq s_axis
#   gps_acq irq, DMA mm2s_introut --> concat --> PS7 IRQ_F2P
#   FCLK_CLK0 = 100 MHz drives the whole PL.
#
# Outputs: vivado/build/ (project), vivado/reports/ (utilisation, timing),
#          vivado/gps_acq.xsa (hardware platform for Vitis, bitstream included)
# Board files for the chosen board must be installed so the PS7 DDR/MIO preset
# can be applied; without them the script continues with Vivado defaults.
# -----------------------------------------------------------------------------
set root  [file normalize [file join [file dirname [info script]] ..]]
set hw    $root/hw
set out   $root/vivado
set board [expr {$argc > 0 ? [lindex $argv 0] : "pynq-z2"}]

switch -- $board {
    zedboard { set part xc7z020clg484-1; set bpat *zedboard* }
    default  { set part xc7z020clg400-1; set bpat *pynq-z2* }
}

create_project gps_acq $out/build -part $part -force
set bp [lsort -decreasing [get_board_parts -quiet $bpat]]
if {[llength $bp] > 0} {
    set_property board_part [lindex $bp 0] [current_project]
    set preset 1
} else {
    puts "WARNING: no board files matching $bpat - PS7 uses default (not board) settings"
    set preset 0
}

# ---------------------------------------------------------------- sources
add_files [glob $hw/rtl/*.sv] $hw/rtl/gps_acq_top.v
add_files -norecurse [list $hw/mem/twiddle.hex $hw/mem/code_rom.hex]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------- block design
create_bd_design system

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config [list make_external "FIXED_IO, DDR" apply_board_preset $preset \
             Master "Disable" Slave "Disable"] $ps7
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1}] $ps7

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_sg_length_width {16} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16}] $dma

set acq [create_bd_cell -type module -reference gps_acq_top acq]
set_property -dict [list \
    CONFIG.TW_FILE  "$hw/mem/twiddle.hex" \
    CONFIG.ROM_FILE "$hw/mem/code_rom.hex"] $acq

# AXI4-Lite control (GP0) for the core and the DMA
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} [get_bd_intf_pins acq/s_axi]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} [get_bd_intf_pins dma/S_AXI_LITE]
# DMA reads DDR through HP0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/dma/M_AXI_MM2S" Clk "Auto"} [get_bd_intf_pins ps7/S_AXI_HP0]
# sample stream
connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S] [get_bd_intf_pins acq/s_axis]
# Vivado 2024.2's HP0 automation already clocks the DMA master; connect only if not
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins dma/m_axi_mm2s_aclk]]] == 0} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dma/m_axi_mm2s_aclk]
}

# interrupts
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_concat]
set_property CONFIG.NUM_PORTS {2} $cc
connect_bd_net [get_bd_pins acq/irq]          [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins dma/mm2s_introut] [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins irq_concat/dout]  [get_bd_pins ps7/IRQ_F2P]

# address map: core at 0x43C0_0000 (matches ACQ_BASE in sw/main.c)
assign_bd_address
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] {
    if {[string match -nocase *acq* $seg]} {
        set_property range  64K        $seg
        set_property offset 0x43C00000 $seg
    }
}

validate_bd_design
save_bd_design

set wrapper [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------- implementation
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

file mkdir $out/reports
open_run impl_1
report_utilization    -hierarchical -file $out/reports/utilization_hier.txt
report_utilization                  -file $out/reports/utilization.txt
report_timing_summary -max_paths 10 -file $out/reports/timing_summary.txt
write_hw_platform -fixed -include_bit -force $out/gps_acq.xsa

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "Worst negative slack @100 MHz: $wns ns"
puts "XSA written to $out/gps_acq.xsa"
