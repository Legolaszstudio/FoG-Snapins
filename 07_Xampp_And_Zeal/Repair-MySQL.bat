@echo off
:: ====================================================================
:: Repair-MySQL.bat - One-Click Self-Healing Tool for XAMPP MySQL
:: ====================================================================
:: Repairs crashed Aria tables, clears stale lock/PID files, and restores
:: MySQL health after sudden power outages without touching user databases.
:: ====================================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrative privileges to repair MySQL...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c `\"%~f0`\"' -Verb RunAs"
    exit /b
)

title XAMPP MySQL AutoHeal & Crash Repair Tool
color 0b
echo ====================================================================
echo             XAMPP MySQL Crash Self-Healing Repair Tool
echo ====================================================================
echo.

set SCRIPT_DIR=%~dp0
set PS_SCRIPT=%SCRIPT_DIR%AutoHeal-MySQL.ps1

if not exist "%PS_SCRIPT%" (
    set PS_SCRIPT=C:\xampp\AutoHeal-MySQL.ps1
)

if not exist "%PS_SCRIPT%" (
    color 0c
    echo [ERROR] Could not find AutoHeal-MySQL.ps1!
    echo Looked in: %~dp0 and C:\xampp
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Interactive

