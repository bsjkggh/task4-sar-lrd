# jtag_full.tcl -- 完整 JTAG 流程: 诊断 + 系统复位 + PS初始化 + 下载运行
connect
puts "=== targets ==="
catch {targets}
targets -set -nocase -filter {name =~ "ARM*#0"}
catch {stop}
rst -system
after 2000
targets -set -nocase -filter {name =~ "ARM*#0"}
source D:/task4_lrd_v2/vitis_ws/task4_plat/hw/ps7_init.tcl
ps7_init
ps7_post_config
fpga -f D:/task4_lrd_v2/sd_rd_lcd/sd_rd_lcd.runs/impl_1/system_wrapper.bit
dow D:/task4_lrd_v2/vitis_ws/task4_app/Debug/task4_app.elf
con
puts "APP_RESTARTED"
