@echo off
title GPU Driver Auto-Downloader
cd /d "%~dp0"

echo.
echo ================================================================
echo   GPU Driver Auto-Downloader
echo ================================================================
echo.
echo   [1] Auto-Detect - Detect GPU and download matching driver
echo   [2] NVIDIA only
echo   [3] AMD only
echo   [4] Intel only
echo   [5] All vendors
echo   [6] List installed GPUs only
echo   [0] Exit
echo.
set /p choice="Select (0-6): "

if "%choice%"=="1" powershell -ExecutionPolicy Bypass -File "%~dp0download_gpu_drivers.ps1" -Vendor Auto
if "%choice%"=="2" powershell -ExecutionPolicy Bypass -File "%~dp0download_gpu_drivers.ps1" -Vendor NVIDIA
if "%choice%"=="3" powershell -ExecutionPolicy Bypass -File "%~dp0download_gpu_drivers.ps1" -Vendor AMD
if "%choice%"=="4" powershell -ExecutionPolicy Bypass -File "%~dp0download_gpu_drivers.ps1" -Vendor Intel
if "%choice%"=="5" powershell -ExecutionPolicy Bypass -File "%~dp0download_gpu_drivers.ps1" -Vendor All
if "%choice%"=="6" powershell -ExecutionPolicy Bypass -File "%~dp0download_gpu_drivers.ps1" -ListGPUs
if "%choice%"=="0" exit /b

echo.
pause
