@echo off
rem Double-click entry point. A .ps1 opens in Notepad when double-clicked, so this shim is the
rem only file a new user has to touch. ui.ps1 -Launch spawns the panel detached (it has to
rem outlive this window) and waits for its health endpoint, so a failure to start says so here
rem instead of doing nothing visible.
title Model Pilot
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ui.ps1" -Launch %*
if errorlevel 1 pause
