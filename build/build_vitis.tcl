######################################################################
# task4 Vitis headless build: platform (FSBL + standalone BSP w/ xilffs)
# + application task4_app.
# Usage: xsct build_vitis.tcl
######################################################################
set script_dir [file dirname [file normalize [info script]]]
set root [file dirname $script_dir]
set ws   "$root/vitis_ws"
set xsa  "$root/task4_system.xsa"

file delete -force $ws
setws $ws

# ---- platform ----
platform create -name task4_plat -hw $xsa -proc ps7_cortexa9_0 -out $ws
domain create -name a9std -os standalone -proc ps7_cortexa9_0
domain active a9std
bsp setlib -name xilffs
platform generate

# ---- application ----
app create -name task4_app -platform task4_plat -domain a9std -lang C
foreach f {helloworld.c platform.c platform.h platform_config.h} {
    file delete -force "$ws/task4_app/src/$f"
}
importsources -name task4_app -path $root/vitis_src
app build -name task4_app

puts "VITIS_APP_BUILT: $ws/task4_app/Debug/task4_app.elf"
