connect
targets -set -nocase -filter {name =~ "ARM*#0"}
stop
mrd -force -size w -bin -file D:/task4_lrd_v2/build/mag4m.bin 0x07500000 4194304
puts "DUMP_DONE3"
