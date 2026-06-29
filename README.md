# GPU Driver Auto-Downloader

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/BeetMan/gpu-driver-downloader/pulls)

A PowerShell script that automatically downloads the latest NVIDIA / AMD / Intel graphics drivers from official sources. Supports all three major GPU vendors with smart GPU detection and driver matching.

自动从官方来源下载最新 NVIDIA / AMD / Intel 显卡驱动程序的 PowerShell 脚本。

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

## How It Works

| 厂商 | 方法 | 可靠性 |
|------|------|--------|
| **NVIDIA** | 使用官方 `AjaxDriverService` JSON API 查询驱动 | ⭐⭐⭐⭐⭐ 高 |
| **AMD** | 拼接 GPU 页面 URL，抓取 HTML 提取下载链接 | ⭐⭐⭐ 中（页面为 JS 渲染） |
| **Intel** | 抓取 Intel 下载中心 HTML，备用 TechPowerUp | ⭐⭐⭐ 中（页面为 JS 渲染） |

## 使用方式

### 图形界面（推荐）

双击 `download_gpu_drivers.bat`，选择对应选项。

### 命令行

```powershell
# 自动检测系统显卡并下载对应驱动
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1

# 指定 NVIDIA 独显驱动
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA

# 指定 AMD 独显驱动
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor AMD

# 指定 Intel 显卡驱动
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor Intel

# 下载全部厂商驱动
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor All

# 查看检测到的显卡
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -ListGPUs

# 自定义保存路径
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -OutputPath "D:\Drivers"

# NVIDIA Studio 驱动（默认 Game Ready）
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA -NVIDIADriverType Studio

# 包含 Beta 驱动
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -Vendor NVIDIA -Beta

# 只查询版本不下载
powershell -ExecutionPolicy Bypass -File download_gpu_drivers.ps1 -SkipDownload
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-Vendor` | 目标厂商: `Auto`, `NVIDIA`, `AMD`, `Intel`, `All` | `Auto` |
| `-OutputPath` | 驱动保存目录 | `~/Downloads/Drivers` |
| `-NVIDIADriverType` | NVIDIA 驱动类型: `GameReady` 或 `Studio` | `GameReady` |
| `-Beta` | 是否包含 Beta 版本 | `false` |
| `-ListGPUs` | 仅列出系统中的显卡 | - |
| `-SkipDownload` | 仅查询不下载 | `false` |

## 技术细节

### NVIDIA 驱动查询流程

1. 调用 NVIDIA Download API (`lookupValueSearch.aspx`) 获取所有 GPU 产品 ID
2. 将系统中的 GPU 名称与产品列表进行模糊匹配
3. 使用匹配到的 `psid` / `pfid` 调用 `AjaxDriverService` 获取最新驱动
4. 直接下载驱动执行文件（需 Referer header）

### AMD 驱动查询流程

1. 解析 GPU 名称获取型号系列（如 RX 7900 XTX → radeon-rx-7900-series）
2. 拼接 AMD 官网驱动页面 URL
3. 抓取页面 HTML，提取 Windows 10/11 的 Adrenalin 驱动下载链接
4. 从下载 URL 中提取版本号

### Intel 驱动查询流程

1. 访问 Intel 图形驱动下载中心
2. 搜索 `downloadmirror.intel.com` 的 .exe 链接
3. 抽取版本号
4. 若官网抓取失败，使用 TechPowerUp 作为后备来源

## 注意事项

- **NVIDIA** API 可能随时变更，若失效请提 issue
- **AMD** 和 **Intel** 官网使用 JavaScript 动态渲染，PowerShell 脚本无法完整解析 JS。若脚本失效，脚本会提示手动下载网址
- 下载大文件（>500MB）时请保持网络稳定
- 部分企业网络可能封锁驱动下载域名

## 系统需求

- Windows 10 / 11
- PowerShell 5.1+
- 网络连接
