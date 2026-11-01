# run_sim.do -- cplx_mul 自检仿真 (ModelSim/Questa)
# 用法: 在 sim 目录下执行  vsim -c -do run_sim.do
cd [file dirname [info script]]
vlib work
vlog ../rtl/cplx_mul.v
vlog tb_cplx_mul.v
vsim -c tb_cplx_mul -do "run -all; quit -f"
