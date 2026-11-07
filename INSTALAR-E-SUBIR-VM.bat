@echo off
REM Clique duas vezes: instala VirtualBox + Vagrant e sobe a VM CitizenTech
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File %~dp0setup-windows.ps1'"
