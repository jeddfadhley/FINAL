# ==============================================================================
# Vivado Build Script for CmdProc on Cmod A7
# Target: xc7a35tcpg236-1 (Digilent Cmod A7-35T)
#
# Usage:
#   1. Clone the repo
#   2. Open Vivado, in the Tcl Console:
#        cd C:/path/to/FINAL
#        source build.tcl
#
#   For signed dataConsume, copy signed/dataConsume.edn to dataConsume.edn
#   For unsigned (default), copy unsigned/dataConsume.edn to dataConsume.edn
# ==============================================================================

set src_dir [file normalize [pwd]]
set proj_name "cmdproc_fpga"
set proj_dir [file join $src_dir $proj_name]
set part "xc7a35tcpg236-1"

puts "Source directory: $src_dir"

# --- Verify source files exist -----------------------------------------------
set src_files [list \
    "common_pack.vhd" \
    "top.vhd" \
    "cmdProc.vhd" \
    "UART_RX_CTRL.vhd" \
    "UART_TX_CTRL.vhd" \
    "dataGen.vhd" \
    "dataConsumeWrapper.vhd" \
    "unsigned/dataConsume.edn" \
    "Cmod-A7-Master.xdc" \
]

set missing 0
foreach f $src_files {
    if {![file exists [file join $src_dir $f]]} {
        puts "ERROR: Missing file: $f"
        set missing 1
    }
}
if {$missing} {
    puts "Aborting. Make sure you cd into the repo folder first."
    return
}
puts "All source files found."

# --- Create Project ----------------------------------------------------------
if {[file exists $proj_dir]} {
    puts "Project already exists. Opening..."
    open_project [file join $proj_dir "$proj_name.xpr"]
} else {
    create_project $proj_name $proj_dir -part $part
    set_property target_language VHDL [current_project]

    # Add all sources
    foreach f $src_files {
        set fpath [file join $src_dir $f]
        if {[string match "*.xdc" $f]} {
            add_files -fileset constrs_1 $fpath
        } elseif {[string match "*.edn" $f]} {
            # Black box netlist for dataConsume
            add_files $fpath
            set_property FILE_TYPE "EDIF" [get_files $fpath]
        } else {
            add_files $fpath
        }
    }

    set_property top top [current_fileset]

    # Clock Wizard IP (12 MHz -> 100 MHz)
    # Port names must match top.vhd: clk_in, clk_out (no reset, no locked)
    create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_0
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ {12.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
        CONFIG.USE_LOCKED {false} \
        CONFIG.USE_RESET {false} \
        CONFIG.CLK_IN1_BOARD_INTERFACE {Custom} \
        CONFIG.CLK_OUT1_PORT {clk_out} \
        CONFIG.PRIM_SOURCE {No_buffer} \
        CONFIG.CLK_IN1_PORT {clk_in} \
    ] [get_ips clk_wiz_0]
    generate_target all [get_ips clk_wiz_0]
    synth_ip [get_ips clk_wiz_0]

    puts "Project created."
}

# --- Synthesis ---------------------------------------------------------------
puts "Running synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed."
    return
}

# --- Implementation + Bitstream ----------------------------------------------
puts "Running implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] != "write_bitstream Complete!"} {
    puts "ERROR: Implementation failed."
    return
}

set bitfile [file join $proj_dir "$proj_name.runs" "impl_1" "top.bit"]
puts ""
puts "============================================"
puts "BUILD COMPLETE!"
puts "Bitstream: $bitfile"
puts ""
puts "To program: Hardware Manager -> Auto Connect -> Program Device"
puts "============================================"
