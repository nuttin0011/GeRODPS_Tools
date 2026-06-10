@echo off
rem ============================================================
rem run.bat — SendToString layer-stack calculator
rem double-click ได้เลย; ผลจะ save ลง sendtostring_layer_stack_result.txt
rem ปรับ beam/nmax ได้: run.bat --beam 1200 --nmax 14
rem ============================================================
cd /d "%~dp0"
chcp 65001 >nul
python sendtostring_layer_stack_calc.py %*
echo.
pause
