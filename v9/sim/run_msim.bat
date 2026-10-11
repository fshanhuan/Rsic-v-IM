@echo off
REM ============================================================================
REM run_msim.bat - v9: full ModelSim regression (7 programs x 2 modes + dcache)
REM ----------------------------------------------------------------------------
REM NOTE: ASCII-only by design. cmd.exe parses .bat with the OEM codepage and
REM       UTF-8 Chinese comments get mangled into bogus commands.
REM
REM usage (from anywhere):
REM     sim\run_msim.bat
REM
REM what it does: delegates to sim\run_msim.ps1 (which drives vlib/vlog/vsim in
REM               batch mode and parses "[SELFCHECK] status=..." out of the logs).
REM logs: msim\logs\msim_<prog>_<mode>.log  +  msim\logs\msim_summary.txt
REM ============================================================================
setlocal
set HERE=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%run_msim.ps1"
exit /b %ERRORLEVEL%
