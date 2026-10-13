@echo off
chcp 65001 >nul
title AVIF Compressor
mode con: cols=74 lines=45

powershell -ExecutionPolicy Bypass -File "%~dp0bin\Main.ps1" %*

if %ERRORLEVEL% EQU 99 (
    echo.
    echo     [!] Script crashed with error code: %ERRORLEVEL%
    echo     See logs for details.
    echo     Press any key to exit.
    pause >nul
) else if %ERRORLEVEL% NEQ 0 (
    echo.
    echo     Press any key to exit.
    pause >nul
)
exit /b %ERRORLEVEL%