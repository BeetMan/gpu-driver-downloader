# GPU Driver Auto-Downloader

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/BeetMan/gpu-driver-downloader/pulls)

A PowerShell script that automatically downloads the latest NVIDIA / AMD / Intel graphics drivers from official sources. Supports all three major GPU vendors with smart GPU detection and driver matching.

自動從官方來源下載最新 NVIDIA / AMD / Intel 顯卡驅動程式的 PowerShell 腳本。

## Features

- **NVIDIA** — Queries the official AjaxDriverService JSON API; auto-matches your GPU model. Supports Game Ready & Studio drivers, WHQL & Beta channels.
- **AMD** — Scrapes official driver pages for discrete GPUs and APUs; falls back to the AMD Auto-Detect tool when automatic download fails.
- **Intel** — Intelligent generation detection (Arc → 7th Gen legacy) with CN CDN mirror support.
- **Auto-Detect** — Detects installed GPU(s) via WMI and downloads the correct driver without user input.

## Quick Start

### GUI (Recommended)

Double-click `download_gpu_drivers.bat` and pick an option from the menu.

### Command Line

```powershell
# Auto-detect GPU and download the matching driver
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1

# Specify vendor
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor AMD
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor Intel

# Download drivers for all detected GPUs
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor All

# List installed GPUs without downloading
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -ListGPUs

# Custom output directory
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -OutputPath "D:\Drivers"

# NVIDIA Studio driver (default: Game Ready)
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA -NVIDIADriverType Studio

# Include beta drivers
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA -Beta

# Query only, don't download
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -SkipDownload
```

## Project Structure

```
gpu-driver-downloader/
├── download_gpu_drivers.ps1   # Main PowerShell script
├── download_gpu_drivers.bat   # Interactive menu launcher
├── README.md                  # This file
├── LICENSE                    # MIT
└── .gitignore
```

## Parameters

| 廠商 | 方法 | 可靠性 |
|------|------|--------|
| **NVIDIA** | 使用官方 `AjaxDriverService` JSON API 查詢驅動 | ⭐⭐⭐⭐⭐ 高 |
| **AMD** | 拼接 GPU 頁面 URL，抓取 HTML 提取下載鏈接 | ⭐⭐⭐ 中（頁面為 JS 渲染） |
| **Intel** | 抓取 Intel 下載中心 HTML，備用 TechPowerUp | ⭐⭐⭐ 中（頁面為 JS 渲染） |

## 使用方式

### 圖形介面（推薦）

雙擊 `download_gpu_drivers.bat`，選擇對應選項。

### 命令列

```powershell
# 自動檢測系統顯卡並下載對應驅動
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1

# 指定 NVIDIA 獨顯驅動
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA

# 指定 AMD 獨顯驅動
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor AMD

# 指定 Intel 顯卡驅動
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor Intel

# 下載全部廠商驅動
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor All

# 查看檢測到的顯卡
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -ListGPUs

# 自訂保存路徑
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -OutputPath "D:\Drivers"

# NVIDIA Studio 驅動（預設 Game Ready）
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA -NVIDIADriverType Studio

# 包含 Beta 驅動
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA -Beta

# 只查詢版本不下載
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -SkipDownload
```

## 參數說明

| 參數 | 說明 | 預設值 |
|------|------|--------|
| `-Vendor` | 目標廠商: `Auto`, `NVIDIA`, `AMD`, `Intel`, `All` | `Auto` |
| `-OutputPath` | 驅動保存目錄 | `~/Downloads/Drivers` |
| `-NVIDIADriverType` | NVIDIA 驅動類型: `GameReady` 或 `Studio` | `GameReady` |
| `-Beta` | 是否包含 Beta 版本 | `false` |
| `-ListGPUs` | 僅列出系統中的顯卡 | - |
| `-SkipDownload` | 僅查詢不下載 | `false` |

## 技術細節

### NVIDIA 驅動查詢流程

1. 呼叫 NVIDIA Download API (`lookupValueSearch.aspx`) 獲取所有 GPU 產品 ID
2. 將系統中的 GPU 名稱與產品列表進行模糊匹配
3. 使用匹配到的 `psid` / `pfid` 調用 `AjaxDriverService` 獲取最新驅動
4. 直接下載驅動執行檔（需 Referer header）

### AMD 驅動查詢流程

1. 解析 GPU 名稱獲取型號系列（如 RX 7900 XTX → radeon-rx-7900-series）
2. 拼接 AMD 官網驅動頁面 URL
3. 抓取頁面 HTML，提取 Windows 10/11 的 Adrenalin 驅動下載鏈接
4. 從下載 URL 中提取版本號

### Intel 驅動查詢流程

1. 訪問 Intel 繪圖驅動下載中心
2. 搜索 `downloadmirror.intel.com` 的 .exe 連結
3. 抽取版本號
4. 若官網抓取失敗，使用 TechPowerUp 作為後備來源

## 注意事項

- **NVIDIA** API 可能隨時變更，若失效請提 issue
- **AMD** 和 **Intel** 官網使用 JavaScript 動態渲染，PowerShell 腳本無法完整解析 JS。若腳本失效，腳本會提示手動下載網址
- 下載大檔案（>500MB）時請保持網路穩定
- 部分企業網路可能封鎖驅動下載域名

## 系統需求

- Windows 10 / 11
- PowerShell 5.1+
- 網路連線
