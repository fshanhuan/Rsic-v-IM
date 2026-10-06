@echo off
REM ============================================================================
REM run_iverilog.bat - v9: one command = compile + simulate + VCD (iverilog/vvp)
REM ----------------------------------------------------------------------------
REM NOTE: this .bat is deliberately ASCII-only. cmd.exe parses batch files with
REM       the OEM codepage (936 on this machine) and UTF-8 Chinese comments get
REM       mangled into bogus commands. The Chinese notes live in
REM       sim/README_iverilog.md and in the .sh twin.
REM
REM usage (from any directory):
REM     sim\run_iverilog.bat               -> sim/prog.hex      (full demo)
REM     sim\run_iverilog.bat prog_mul      -> sim/prog_mul.hex  (8x mul)
REM     sim\run_iverilog.bat prog_div      -> sim/prog_div.hex  (4x div)
REM     sim\run_iverilog.bat prog wave     -> also open GTKWave
REM
REM outputs:
REM     sim\build\tb_iverilog.vvp          compiled model
REM     sim\build\<prog>.log               full run log (incl. GPR snapshot)
REM     wave\tb_iverilog_<prog>.vcd        waveform
REM
REM environment constraints (do not change):
REM   1. iverilog cannot handle non-ASCII absolute paths for $readmemh /
REM      $dumpfile / -o (copying them produces \377 or "Code generator
REM      failure: -1"). So we cd to the v9 root and use relative paths only.
REM   2. iverilog has no $fread, so programs are loaded as text hex with
REM      $readmemh instead of the .bin flow used by cdp-tests.
REM ============================================================================
setlocal
set PROG=%~1
if "%PROG%"=="" set PROG=prog

set IVERILOG=D:\eda_tools\iverilog\bin\iverilog.exe
set VVP=D:\eda_tools\iverilog\bin\vvp.exe
set GTKWAVE=D:\eda_tools\iverilog\gtkwave\bin\gtkwave.exe

REM ---- program name -> expectation table id inside the testbench ----
set PROG_ID=9
if /i "%PROG%"=="prog"     set PROG_ID=0
if /i "%PROG%"=="prog_mul" set PROG_ID=1
if /i "%PROG%"=="prog_div" set PROG_ID=2
REM v9 second-round regression (byte/half offset, load data, backward branch, back-to-back div)
if /i "%PROG%"=="prog_load_lane" set PROG_ID=3
if /i "%PROG%"=="prog_load_use"  set PROG_ID=4
if /i "%PROG%"=="prog_loop"      set PROG_ID=5
if /i "%PROG%"=="prog_div_pair"  set PROG_ID=6

REM ---- go to the v9 root: relative paths only ----
cd /d "%~dp0.."
if not exist wave       mkdir wave
if not exist sim\build  mkdir sim\build

echo [1/3] compile  (iverilog -g2012)
"%IVERILOG%" -g2012 -o sim/build/tb_iverilog.vvp ^
    myCPU.sv IFU.sv ICache.sv Branch_Predictor.sv IDU.sv Reg_Stack.sv ^
    RegisterFile.sv CSR.sv EXU.sv ALU.sv experimental/MDU_pipelined.sv LSU.sv DCache.sv WBU.sv ^
    Data_hazard.sv Control.sv add.sv sext.sv Reg.sv sim/tb_iverilog.sv
if errorlevel 1 (
    echo [FAIL] compile failed
    exit /b 1
)

echo [2/3] run      (vvp  +prog=sim/%PROG%.hex  +prog_id=%PROG_ID%)
"%VVP%" sim/build/tb_iverilog.vvp +prog=sim/%PROG%.hex +prog_id=%PROG_ID% +vcd=wave/tb_iverilog_%PROG%.vcd > sim/build/%PROG%.log 2>&1
set RC=%ERRORLEVEL%
type sim\build\%PROG%.log

echo [3/3] artifacts
if exist wave\tb_iverilog_%PROG%.vcd echo     VCD : wave\tb_iverilog_%PROG%.vcd
echo     LOG : sim\build\%PROG%.log

if not "%RC%"=="0" (
    echo [FAIL] simulation reported FAIL/TIMEOUT ^(exit=%RC%^)
    exit /b 1
)
echo [ OK ] %PROG% passed

if /i "%~2"=="wave" (
    echo opening GTKWave ...
    start "" "%GTKWAVE%" wave\tb_iverilog_%PROG%.vcd
)
endlocal
