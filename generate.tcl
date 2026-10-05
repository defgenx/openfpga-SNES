# Run with quartus_sh -t generate.tcl

# Load Quartus II Tcl Project package
package require ::quartus::project

# Required for compilation
package require ::quartus::flow

# Options after the variant, in any order:
#   release  build without the MSU-1 debug overlay
#   fast     skip the timing analyzer; the bitstream is written before it runs
if { $argc < 1 } {
  puts "Usage: generate.tcl <variant> \[release\] \[fast\]"
  exit
}
set options [lrange $argv 1 end]

project_open projects/snes_pocket.qpf

if { [lsearch -exact $options "release"] >= 0 } {
  puts "Release build: MSU-1 debug overlay off"
  set_parameter -name MSU_DEBUG -entity core_top '0
} else {
  set_parameter -name MSU_DEBUG -entity core_top '1
}

if { [lindex $argv 0] == "ntsc" } {
  puts "NTSC"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "pal" } {
  puts "PAL"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '1
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '1
  set_parameter -name USE_SA1 -entity MAIN_SNES '1
  set_parameter -name USE_DSPn -entity MAIN_SNES '1
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "ntsc_spc" } {
  puts "NTSC SPC"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '1
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '1
  set_parameter -name USE_BSX -entity MAIN_SNES '1
  set_parameter -name USE_MSU -entity MAIN_SNES '1
} elseif { [lindex $argv 0] == "none" } {
  puts "NONE"
  set_parameter -name PAL_PLL -entity core_top '0

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '0
} elseif { [lindex $argv 0] == "none_pal" } {
  puts "NONE PAL"
  set_parameter -name PAL_PLL -entity core_top '1

  set_parameter -name USE_CX4 -entity MAIN_SNES '0
  set_parameter -name USE_SDD1 -entity MAIN_SNES '0
  set_parameter -name USE_GSU -entity MAIN_SNES '0
  set_parameter -name USE_SA1 -entity MAIN_SNES '0
  set_parameter -name USE_DSPn -entity MAIN_SNES '0
  set_parameter -name USE_SPC7110 -entity MAIN_SNES '0
  set_parameter -name USE_BSX -entity MAIN_SNES '0
  set_parameter -name USE_MSU -entity MAIN_SNES '0
} else {
  puts "Unknown bitstream type [lindex $argv 0]"
  project_close
  exit
}

if { [lsearch -exact $options "fast"] >= 0 } {
  puts "Fast build: no timing analysis"
  # execute_module skips the project's PRE_FLOW_SCRIPT_FILE, which writes build_id.mif
  set here [pwd]
  cd projects
  source ../platform/pocket/build_id_gen.tcl
  cd $here
  execute_module -tool map
  execute_module -tool fit
  execute_module -tool asm
} else {
  execute_flow -compile
}

project_close