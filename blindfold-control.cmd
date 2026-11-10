@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\unlock.ps1" %*
if "%~1"=="" pause
