@echo off
REM Testes de falha: script com erro, monitor parado e reinicializacao da VM
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File %~dp0TESTES-FALHA.ps1'"
