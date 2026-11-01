@echo off
setlocal
rem ============================================================
rem  task4 线性RD成像: 一键构建
rem    Vivado 工程 -> bitstream + XSA -> Vitis(FSBL+app) -> BOOT.BIN
rem  用法: build_all.bat
rem ============================================================
set BUILD_DIR=%~dp0
set ROOT=%BUILD_DIR%..
rem 换电脑时: 在系统里设置同名环境变量 VIVADO_BIN / XSCT_BIN 即可, 否则改下面两行
if not defined VIVADO_BIN set VIVADO_BIN=D:\VIVADO2020.2\Vivado\2020.2\bin
if not defined XSCT_BIN set XSCT_BIN=D:\VIVADO2020.2\Vitis\2020.2\bin

echo [1/3] Vivado: project / BD / synth / impl / XSA ...
call "%VIVADO_BIN%\vivado.bat" -mode batch -source "%BUILD_DIR%build_task4.tcl" -log "%BUILD_DIR%build_task4.log" -journal "%BUILD_DIR%build_task4.jou"
if errorlevel 1 goto :err

echo [2/3] Vitis: platform + FSBL + app ...
call "%XSCT_BIN%\xsct.bat" "%BUILD_DIR%build_vitis.tcl"
if errorlevel 1 goto :err

echo [3/3] BOOT.BIN ...
cd /d "%BUILD_DIR%"
"%VIVADO_BIN%\bootgen.bat" -image task4.bif -arch zynq -o "%ROOT%\sd_card\BOOT.BIN" -w on
if errorlevel 1 goto :err

echo.
echo BUILD OK
echo   bit : %ROOT%\sd_rd_lcd\sd_rd_lcd.runs\impl_1\system_wrapper.bit
echo   elf : %ROOT%\vitis_ws\task4_app\Debug\task4_app.elf
echo   bin : %ROOT%\sd_card\BOOT.BIN
exit /b 0

:err
echo.
echo BUILD FAILED, see build_task4.log / vitis log
exit /b 1
