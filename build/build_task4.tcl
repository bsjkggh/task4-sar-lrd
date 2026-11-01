######################################################################
# task4: 线性RD成像 -- SD -> PS距离FFT -> PL复数乘法(匹配滤波/运动补偿)
#         -> PS方位FFT + 距离IFFT -> RGB LCD
# Vivado 2020.2, xc7z020clg400-2 (Zynq7020)
# Usage:
#   vivado -mode batch -source <this file>
# 工程根目录根据本脚本位置自动推断 (build/ 的上一级), 换盘符/换目录不用改脚本
######################################################################
set script_dir [file dirname [file normalize [info script]]]
set root       [file dirname $script_dir]
set proj_name "sd_rd_lcd"
set part      "xc7z020clg400-2"

#---------------------------------------------------------------------
# 1. 打包显示用 IP (rgb2lcd3, 与任务三相同)
#---------------------------------------------------------------------
proc pkg_one {root ipname} {
    create_project -force pkg_$ipname $root/_pkg/$ipname -part xc7z020clg400-2
    add_files [list $root/rtl/$ipname.v]
    update_compile_order -fileset sources_1
    set ipdir $root/ip_repo/$ipname
    file delete -force $ipdir
    ipx::package_project -root_dir $ipdir -vendor www.alientek.com -library user -taxonomy /UserIP -import_files -set_current true -force
    set_property core_revision 1 [ipx::current_core]
    ipx::create_xgui_files [ipx::current_core]
    ipx::update_checksums  [ipx::current_core]
    ipx::save_core         [ipx::current_core]
    close_project
}
pkg_one $root rgb2lcd3

#---------------------------------------------------------------------
# 2. 主工程
#---------------------------------------------------------------------
create_project -force $proj_name $root/$proj_name -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
add_files -fileset constrs_1 -norecurse [list $root/constrs/LCD.xdc]
add_files -fileset sources_1 -norecurse [list $root/rtl/cplx_mul.v]
update_compile_order -fileset sources_1
set_property ip_repo_paths [list $root/ip_repo] [current_fileset]
update_ip_catalog

#---------------------------------------------------------------------
# 3. Block design (显示链路沿用任务三 + AXI DMA + 复数乘法 IP)
#---------------------------------------------------------------------
source $root/build/system4_bd.tcl
regenerate_bd_layout
save_bd_design

#---------------------------------------------------------------------
# 4. HDL wrapper
#---------------------------------------------------------------------
generate_target all [get_files $root/$proj_name/$proj_name.srcs/sources_1/bd/system/system.bd]
make_wrapper -files [get_files $root/$proj_name/$proj_name.srcs/sources_1/bd/system/system.bd] -top
add_files -norecurse [glob $root/$proj_name/$proj_name.gen/sources_1/bd/system/hdl/system_wrapper.v]
update_compile_order -fileset sources_1

#---------------------------------------------------------------------
# 5. 综合 / 实现 / 比特流
#---------------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
   error "synth_1 failed"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
   error "impl_1 failed"
}

#---------------------------------------------------------------------
# 6. 导出硬件平台
#---------------------------------------------------------------------
write_hw_platform -fixed -include_bit -force $root/task4_system.xsa
puts "BUILD_TASK4_DONE: $root/task4_system.xsa"
