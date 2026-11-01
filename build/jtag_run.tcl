# jtag_run.tcl -- JTAG 下载 bitstream + 运行 task4_app
connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000
source D:/task4_lrd_v2/vitis_ws/task4_plat/hw/ps7_init.tcl
ps7_init
ps7_post_config
fpga -f D:/task4_lrd_v2/sd_rd_lcd/sd_rd_lcd.runs/impl_1/system_wrapper.bit
targets -set -nocase -filter {name =~ "ARM*#0"}
dow D:/task4_lrd_v2/vitis_ws/task4_app/Debug/task4_app.elf
con
puts "JTAG_RUN_STARTED"
