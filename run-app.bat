@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-app.ps1" %*
if errorlevel 1 pause
