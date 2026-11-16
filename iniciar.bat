@echo off
title Clipping - Senador Alan Rick
cd /d "%~dp0"
start "" http://localhost:8080/
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0servidor.ps1"
pause
