<#
.SYNOPSIS
    GPU Driver Auto-Downloader
    Automatically download the latest NVIDIA / AMD / Intel graphics drivers from official sources.
.DESCRIPTION
    - NVIDIA: Uses the official AjaxDriverService JSON API (most reliable).
    - AMD:    Scrapes the driver download page HTML.
    - Intel:  Scrapes the download center page HTML, with TechPowerUp as fallback.
.PARAMETER Vendor
    Target vendor: Auto, NVIDIA, AMD, Intel, or All. Default is Auto (detect installed GPU).
.PARAMETER OutputPath
    Directory to save downloaded drivers. Default is ~/Downloads/Drivers.
.PARAMETER NVIDIADriverType
    NVIDIA driver type: GameReady or Studio (for Quadro/RTX Pro). Default is GameReady.
.PARAMETER Beta
    Include beta drivers. Default is WHQL only.
.PARAMETER ListGPUs
    Only list detected GPUs, do not download.
.PARAMETER SkipDownload
    Query and display driver info without downloading.
.EXAMPLE
    .\download_gpu_drivers.ps1
    .\download_gpu_drivers.ps1 -Vendor NVIDIA
    .\download_gpu_drivers.ps1 -Vendor All -OutputPath "D:\Drivers"
    .\download_gpu_drivers.ps1 -ListGPUs
    .\download_gpu_drivers.ps1 -Vendor NVIDIA -Beta
#>

param(
    [ValidateSet("NVIDIA", "AMD", "Intel", "Auto", "All")]
    [string]$Vendor = "Auto",

    [string]$OutputPath = "$env:USERPROFILE\Downloads\Drivers",

    [ValidateSet("GameReady", "Studio")]
    [string]$NVIDIADriverType = "GameReady",

    [switch]$Beta = $false,
    [switch]$ListGPUs,
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# =============================================================================
# Helper Functions
# =============================================================================

function Write-Step { param([string]$M); Write-Host "`n==> " -NoNewline -ForegroundColor Cyan; Write-Host $M -ForegroundColor White }
function Write-OK   { param([string]$M); Write-Host "  [+] " -NoNewline -ForegroundColor Green;  Write-Host $M }
function Write-Warn { param([string]$M); Write-Host "  [!] " -NoNewline -ForegroundColor Yellow; Write-Host $M }
function Write-Err  { param([string]$M); Write-Host "  [x] " -NoNewline -ForegroundColor Red;    Write-Host $M }

function Get-StableWebContent {
    param([string]$Uri, [hashtable]$Headers = @{}, [int]$MaxRetries = 3)
    $h = @{
        "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        "Accept"          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        "Accept-Language" = "en-US,en;q=0.9,zh-CN;q=0.8"
    }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try { return Invoke-WebRequest -Uri $Uri -Headers $h -UseBasicParsing -TimeoutSec 30 }
        catch { if ($i -ge $MaxRetries - 1) { throw }; Write-Warn "Retry ($($i+1)/$MaxRetries)..."; Start-Sleep -Seconds 2 }
    }
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile, [string]$Referer = "")
    $h = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
    if ($Referer) { $h["Referer"] = $Referer }
    Write-Host "  ... Downloading " -NoNewline
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $h -UseBasicParsing
        $sizeMB = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
        Write-Host "OK ($sizeMB MB)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "FAILED" -ForegroundColor Red
        Write-Err $_.Exception.Message
        return $false
    }
}

# =============================================================================
# GPU Detection
# =============================================================================

function Get-InstalledGPU {
    Write-Step "Detecting installed GPUs..."
    $gpus = @()
    try {
        $wmi = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        foreach ($g in $wmi) {
            $n = $g.Name; $v = "Unknown"
            if ($n -match "NVIDIA|GeForce|RTX|GTX|Quadro|TITAN")      { $v = "NVIDIA" }
            elseif ($n -match "AMD|Radeon|ATI|RX")                     { $v = "AMD" }
            elseif ($n -match "Intel|Arc|Iris|UHD")                    { $v = "Intel" }
            $gpus += [PSCustomObject]@{ Name = $n; Vendor = $v; Driver = $g.DriverVersion }
            Write-OK "Found: [$v] $n (driver: $($g.DriverVersion))"
        }
    }
    catch { Write-Err "Cannot query GPU info: $_" }
    return $gpus
}

# =============================================================================
# NVIDIA Driver Download
# =============================================================================

function Get-NVIDIAProductIDs {
    param([string]$GpuName)
    Write-Step "Looking up NVIDIA GPU product IDs..."

    # Get all product families from NVIDIA Download API
    $url = "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3"
    Write-OK "Querying: $url"
    try {
        $h = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
        [xml]$xml = Invoke-RestMethod -Uri $url -Headers $h
        $all = $xml.LookupValueSearch.LookupValues.LookupValue

        # Tokenize the GPU name for fuzzy matching
        $clean = $GpuName -replace "NVIDIA\s*" -replace "GeForce\s*" -replace "RTX\s*" -replace "GTX\s*" -replace "Radeon\s*"
        $clean = $clean.Trim()
        $tokens = @($clean -split '\s+' | Where-Object { $_.Length -gt 1 })

        # Score each entry
        $scored = foreach ($item in $all) {
            $nm = $item.Name
            $score = 0
            if ($nm -like "*$clean*") { $score += 80 }
            foreach ($tk in $tokens) { if ($nm -match [regex]::Escape($tk)) { $score += 20 } }
            if ($score -gt 0) { [PSCustomObject]@{ Name = $nm; pfid = [int]$item.Value; psid = [int]$item.ParentID; Score = $score } }
        }
        $scored = $scored | Sort-Object -Property Score -Descending

        if ($scored.Count -gt 0) {
            $best = $scored[0]
            Write-OK "Best match: $($best.Name) (pfid=$($best.pfid), psid=$($best.psid))"

            # Show alternatives
            if ($scored.Count -gt 1) {
                Write-Host "  Other matches:" -ForegroundColor DarkGray
                for ($i = 0; $i -lt [Math]::Min($scored.Count, 5); $i++) {
                    Write-Host "    [$i] $($scored[$i].Name) (pfid=$($scored[$i].pfid), psid=$($scored[$i].psid))" -ForegroundColor Gray
                }
            }
            return $best
        }
        Write-Err "No match found for: $GpuName"
        return $null
    }
    catch { Write-Err "Product lookup failed: $_"; return $null }
}

function Get-NVIDIAOSID {
    $arch = (Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture
    try {
        $dv = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
        if ($dv -match "^2[2-9]|^3") { return 135 }  # Windows 11
    } catch {}
    if ($arch -eq "64-bit") { return 57 }   # Windows 10/11 64-bit
    return 56  # Windows 10 32-bit
}

function Get-NVIDIADriver {
    param([string]$GpuName)

    Write-Host "`n" -NoNewline
    Write-Host ("=" * 60) -ForegroundColor DarkGreen
    Write-Host "  NVIDIA Driver Download" -ForegroundColor Green
    Write-Host ("=" * 60) -ForegroundColor DarkGreen

    # 1. Product ID lookup
    $prod = Get-NVIDIAProductIDs -GpuName $GpuName
    if (-not $prod) { return $null }

    # 2. OS ID
    $osID = Get-NVIDIAOSID
    Write-OK "OS ID: $osID"

    # API base URL - use .cn for better CDN access in China
    if ($languageCode -eq 2052) {
        $apiBase = "https://gfwsl.geforce.cn/services_toolkit/services/com/nvidia/services/AjaxDriverService.php"
    } else {
        $apiBase = "https://gfwsl.geforce.cn/services_toolkit/services/com/nvidia/services/AjaxDriverService.php"
    }

    $apiParams = @(
        "func=DriverManualLookup",
        "psid=$($prod.psid)",
        "pfid=$($prod.pfid)",
        "osID=$osID",
        "languageCode=2052",
        "beta=$(if ($Beta) {'1'} else {'0'})",
        "isWHQL=$(if (-not $Beta) {'1'} else {'0'})",
        "dltype=-1",
        "dch=1",
        "upCRD=null",
        "qnf=0",
        "ctk=null",
        "sort1=0",
        "numberOfResults=3"
    )
    $apiUrl = $apiBase + "?" + ($apiParams -join "&")

    Write-Step "Querying NVIDIA driver API..."
    Write-OK "API: $apiUrl"

    try {
        $h = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://www.nvidia.cn/"
        }
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers $h

        if (-not $resp.IDS -or $resp.IDS.Count -eq 0) {
            Write-Err "No drivers found for this GPU"
            return $null
        }

        # Pick the first (newest) result
        $info = $resp.IDS[0].downloadInfo
        $dlUrl = [System.Web.HttpUtility]::HtmlDecode($info.DownloadURL)
        $whqlLabel = if ($info.IsWHQL -eq "1") { "WHQL" } else { "BETA" }

        Write-OK "Version : $($info.Version) ($whqlLabel)"
        Write-OK "Release : $($info.ReleaseDateTime)"
        Write-OK "Size    : $($info.DownloadURLFileSize)"
        Write-OK "File    : $($dlUrl.Split('/')[-1])"

        if (-not $SkipDownload) {
            # Use original filename from URL
            $fn = $dlUrl.Split('/')[-1].Split('?')[0]
            $outFile = Join-Path $OutputPath $fn
            Invoke-Download -Url $dlUrl -OutFile $outFile -Referer "https://www.nvidia.cn/"
        }

        return [PSCustomObject]@{
            Version     = $info.Version
            DownloadURL = $dlUrl
            ReleaseDate = $info.ReleaseDateTime
            IsWHQL      = $whqlLabel
        }
    }
    catch {
        Write-Err "NVIDIA API query failed: $_"
        return $null
    }
}

# =============================================================================
# AMD Driver Download
# =============================================================================

function Get-AMDProcessorSlug {
    <#
    .SYNOPSIS
        Detect the installed AMD CPU via WMI, parse its name, and return
        the matching AMD.com driver download page URL.
    .DESCRIPTION
        AMD.com URL rules (verified June 2026 via 200/404 tests):
          Ryzen 9 8945HS  -> /processors/ryzen/ryzen-8000-series/amd-ryzen--9-8945hs  (8000 Ryzen 9=double hyph)
          Ryzen 7 8845HS  -> /processors/ryzen/ryzen-8000-series/amd-ryzen-7-8845hs
          Ryzen 7 7840U   -> /processors/ryzen/ryzen-7000-series/amd-ryzen-7-7840u
          Ryzen 9 7945HX  -> /processors/ryzen/ryzen-7000-series/amd-ryzen-9-7945hx
          Ryzen 7 6800H   -> /processors/ryzen/ryzen-6000-series/amd-ryzen-7-6800h
          Ryzen 7 5800H   -> /processors/ryzen/ryzen-5000-series/amd-ryzen-7-5800h
          Ryzen 7 4800H   -> /processors/ryzen/ryzen-4000-series/amd-ryzen-7-4800h
          Ryzen 9 9950X   -> /processors/ryzen/ryzen-9000-series/amd-ryzen-9-9950x
          Ryzen AI 9 HX370-> /processors/ryzen/ryzen-ai-300-series/amd-ryzen-ai-9-hx-370
          Ryzen AI 7 350  -> /processors/ryzen/ryzen-ai-300-series/amd-ryzen-al-7-350   (AMD typo: "al")
          Ryzen AI 5 340  -> /processors/ryzen/ryzen-ai-300-series/amd-ryzen-ai-5-340
          Ryzen AI Max+395-> /processors/ryzen/ryzen-ai-max-series/amd-ryzen-ai-max-plus-395
    .OUTPUTS
        PSCustomObject with Series, Slug, FullUrl, or $null if not an AMD CPU.
    #>

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    } catch { return $null }

    $name = $cpu.Name
    if ($name -notmatch "AMD|Ryzen") { return $null }

    # Clean: strip "AMD", "with/w/ Radeon ... Graphics ...", standalone "PRO"
    $c = $name -replace "AMD\s*" -replace "\s+(with|w/)\s+Radeon.*Graphics\s*.*" -replace "\bPRO\b\s*"
    $c = $c.Trim()

    $series = $null
    $slug   = $null

    # --- Ryzen AI Max ---  e.g. "Ryzen AI Max 380", "Ryzen AI Max+ 395"
    if ($c -match "^Ryzen\s+AI\s+Max\s*\+?\s*(.*)") {
        $rest = ($Matches[1]).Trim().ToLower()
        $series = "ryzen-ai-max-series"
        $slug = "amd-ryzen-ai-max-plus-${rest}"
    }
    # --- Ryzen AI HX ---  e.g. "Ryzen AI 9 HX 370"
    #     HX models use 'ai' in the slug
    elseif ($c -match "^Ryzen\s+AI\s+(\d+)\s+HX\s+(\d+)") {
        $tier  = $Matches[1]
        $model = $Matches[2]
        $series = "ryzen-ai-300-series"
        $slug = "amd-ryzen-ai-${tier}-hx-${model}"
    }
    # --- Ryzen AI (non-HX) ---  e.g. "Ryzen AI 7 350", "Ryzen AI 5 340"
    #     Inconsistent: 7 350 uses 'al', 5 340 uses 'ai' — check model number
    elseif ($c -match "^Ryzen\s+AI\s+(\d+)\s+(\d+)") {
        $tier  = $Matches[1]
        $model = $Matches[2]
        $series = "ryzen-ai-300-series"
        # AMD typo: model 350 has 'al' instead of 'ai'
        if ($model -eq "350") {
            $slug = "amd-ryzen-al-${tier}-${model}"
        } else {
            $slug = "amd-ryzen-ai-${tier}-${model}"
        }
    }
    # --- Standard Ryzen ---  e.g. "Ryzen 9 8945HS", "Ryzen 7 5800H"
    elseif ($c -match "^Ryzen\s+(\d+)\s+(\d{4})(\w*)$") {
        $tier  = $Matches[1]
        $model = $Matches[2]
        $suf   = $Matches[3].ToLower()
        $firstDigit = $model.Substring(0,1)
        $series = "ryzen-${firstDigit}000-series"
        $fullModel = $model + $suf
        # 8000 series: Ryzen 9 uses double hyphen, others single
        if ($firstDigit -eq "8" -and $tier -eq "9") {
            $slug = "amd-ryzen--${tier}-${fullModel}"
        } else {
            $slug = "amd-ryzen-${tier}-${fullModel}"
        }
    }
    else { return $null }

    $url = "https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/${series}/${slug}.html"
    return [PSCustomObject]@{ Series = $series; Slug = $slug; FullUrl = $url; CpuName = $name }
}

function Get-AMDFallbackPages {
    <#
    .SYNOPSIS
        Return a list of known-working AMD driver page URLs for the same Ryzen series.
        Used as fallback when the detected CPU model page fails.
    #>
    param([string]$Series)

    # Map of series -> verified model slugs (all confirmed 200 OK as of June 2026)
    $fallbackMap = @{
        "ryzen-8000-series"     = @("amd-ryzen--9-8945hs", "amd-ryzen-7-8845hs", "amd-ryzen-7-8745hs", "amd-ryzen-5-8645hs", "amd-ryzen-7-8840u", "amd-ryzen-7-8700g", "amd-ryzen-5-8600g")
        "ryzen-7000-series"     = @("amd-ryzen-9-7945hx", "amd-ryzen-7-7840hs", "amd-ryzen-7-7840u", "amd-ryzen-7-7840h", "amd-ryzen-5-7640u")
        "ryzen-6000-series"     = @("amd-ryzen-7-6800h", "amd-ryzen-7-6800u", "amd-ryzen-5-6600h")
        "ryzen-5000-series"     = @("amd-ryzen-7-5800h", "amd-ryzen-5-5600h", "amd-ryzen-5-5600g", "amd-ryzen-7-5700g")
        "ryzen-4000-series"     = @("amd-ryzen-7-4800h", "amd-ryzen-5-4600h")
        "ryzen-9000-series"     = @("amd-ryzen-9-9950x", "amd-ryzen-7-9800x3d")
        "ryzen-ai-300-series"   = @("amd-ryzen-ai-9-hx-370", "amd-ryzen-al-7-350", "amd-ryzen-ai-5-340")
        "ryzen-ai-max-series"   = @("amd-ryzen-ai-max-390", "amd-ryzen-ai-max-385", "amd-ryzen-ai-max-plus-395")
    }

    $slugs = $fallbackMap[$Series]
    if (-not $slugs) { return @() }

    $urls = foreach ($s in $slugs) {
        "https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/${Series}/${s}.html"
    }
    return $urls
}

function Get-AMDDriver {
    param([string]$GpuName)

    Write-Host "`n" -NoNewline
    Write-Host ("=" * 60) -ForegroundColor DarkRed
    Write-Host "  AMD Driver Download" -ForegroundColor Red
    Write-Host ("=" * 60) -ForegroundColor DarkRed

    Write-Step "Parsing AMD GPU model..."

    # =====================================================================
    # AMD GPU categories & URL structure:
    #
    #   Discrete GPU (RX):
    #     RX 7900 XTX -> /graphics/radeon-rx-7900-series/amd-radeon-rx-7900-xtx.html
    #     RX 7800 XT  -> /graphics/radeon-rx-7800-series/amd-radeon-rx-7800-xt.html
    #
    #   APU / Integrated (e.g. Radeon 780M, 680M, 890M):
    #     AMD's official FAQ (GPU-56) says APU drivers live under:
    #       /processors/ryzen/{series}/{processor-model}.html
    #     Example: Ryzen 7 7840U -> /processors/ryzen/ryzen-7000-series/amd-ryzen-7-7840u.html
    #
    #     PROBLEM: We only know the GPU name "780M", not the processor model.
    #     780M could be paired with 7840U, 7840HS, 8845HS, etc.
    #     We cannot map GPU name -> exact processor page reliably.
    #
    #   SOLUTION for APUs:
    #     1. Try the Ryzen series page (infer series from GPU model prefix)
    #     2. If that fails, use AMD Auto-Detect tool (official universal fallback)
    #
    #   Auto-Detect tool executable URL (stable, always latest):
    #     https://www.amd.com/en/support/download/drivers.html
    #     -> links to the amd-software-adrenalin-edition-minimalsetup exe
    # =====================================================================

    $downloadUrl = $null
    $driverVersion = $null
    $modelName = ""

    $clean = $GpuName -replace "AMD\s*"
    $clean = $clean.Trim()

    # -------------------------------------------------------------------
    # Case 1: Discrete GPU — "Radeon RX 7900 XTX"
    # -------------------------------------------------------------------
    if ($clean -match "Radeon\s+RX\s+(\d{3,4})\s*(X{1,2}T?)") {
        $num = $Matches[1]
        $suf = if ($Matches[2]) { $Matches[2] } else { "" }
        $seriesNum = $num.Substring(0, [Math]::Min(2, $num.Length)) + "00"
        $seriesUrl = "radeon-rx-${seriesNum}-series"
        $modelSlug = "amd-radeon-rx-$num"
        if ($suf) { $modelSlug += "-" + $suf.ToLower() }
        $modelUrl = "${modelSlug}.html"
        $modelName = "AMD Radeon RX $num $suf".Trim()

        $pages = @(
            "https://www.amd.com/en/support/downloads/drivers.html/graphics/$seriesUrl/$modelUrl",
            "https://www.amd.com/en/support/downloads/drivers.html/graphics/$seriesUrl.html"
        )
        Write-OK "Detected: $modelName (discrete GPU)"
    }
    # -------------------------------------------------------------------
    # Case 2: APU named with model number — "AMD Radeon 780M Graphics"
    #    Infer Ryzen series from leading digit(s): 780M -> 7000 series
    #    Use the series-level /processors/ryzen/ page
    # -------------------------------------------------------------------
    # -------------------------------------------------------------------
    # Case 2: APU — "AMD Radeon 780M Graphics", "Radeon 680M", etc.
    #    Detect CPU model -> build processor page URL -> scrape driver.
    #    Fallback: AMD Auto-Detect minimalsetup.
    # -------------------------------------------------------------------
    elseif ($clean -match "Radeon\s+((?:RX\s+)?\d{3,4}M)\s*(?:Graphics)?") {
        $modelCode = $Matches[1]
        $modelName = "AMD Radeon ${modelCode} Graphics"
        $isAPU = $true
        Write-OK "Detected: $modelName (APU / integrated)"

        # Detect CPU to build processor-specific driver page URL
        $cpuSlug = Get-AMDProcessorSlug
        if ($cpuSlug) {
            Write-OK "CPU identified -> $($cpuSlug.FullUrl)"
            $pages = @($cpuSlug.FullUrl)
        }
        else {
            Write-Warn "Cannot detect AMD processor model, will fall back to Auto-Detect..."
            $pages = @()
        }
    }
    # -------------------------------------------------------------------
    # Case 3: Generic APU — "AMD Radeon Graphics" (no model number)
    # -------------------------------------------------------------------
    elseif ($clean -match "Radeon.*Graphics") {
        $modelName = $clean
        $pages = @("https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen.html")
        Write-OK "Detected: $modelName (generic APU)"
    }
    # -------------------------------------------------------------------
    # Case 4: Unrecognized — fallback to AMD support page
    # -------------------------------------------------------------------
    else {
        Write-Err "Cannot classify AMD GPU: '$clean'"
        Write-Warn "Falling back to AMD support page..."
        $pages = @("https://www.amd.com/en/support/downloads/drivers.html")
        $modelName = $clean
    }

    # ======================== Scrape pages ========================
    foreach ($pageUrl in $pages) {
        try {
            Write-Step "Fetching: $pageUrl"
            $resp = Get-StableWebContent -Uri $pageUrl -Headers @{ "Referer" = "https://www.amd.com/" }
            $html = $resp.Content

            # Extract all drivers.amd.com .exe links
            $pattern = "https://drivers\.amd\.com/drivers/[^\""\s<>]+\.exe"
            $matches = [regex]::Matches($html, $pattern, 'IgnoreCase')
            $candidates = @()

            foreach ($m in $matches) {
                $u = [System.Web.HttpUtility]::HtmlDecode($m.Value)
                # Skip non-driver files
                if ($u -match "firmware|chipset|raid|rgb.*led|led.*exe$|autodetect|detection") { continue }

                $pri = 0
                if ($u -match "whql.*adrenalin.*win1[01].*\.exe$" -and $u -notmatch "minimalsetup|_web") {
                    $pri = 100  # WHQL full offline installer (best)
                }
                elseif ($u -match "whql.*adrenalin.*minimalsetup.*_web\.exe$") {
                    $pri = 80   # WHQL web installer
                }
                elseif ($u -match "adrenalin.*\.exe$") {
                    $pri = 60   # Adrenalin generic
                }
                elseif ($u -match "whql.*\.exe$") {
                    $pri = 50   # WHQL non-Adrenalin
                }
                elseif ($u -notmatch "autodetect|detection") {
                    $pri = 30   # Generic .exe
                }
                if ($pri -gt 0) { $candidates += [PSCustomObject]@{ Url = $u; Priority = $pri } }
            }

            if ($candidates.Count -gt 0) {
                $candidates = $candidates | Sort-Object -Property Priority -Descending
                $best = $candidates[0]
                $downloadUrl = $best.Url
                Write-OK "Found $($candidates.Count) candidate(s)"

                foreach ($c in ($candidates | Select-Object -First 3)) {
                    $lbl = if ($c.Priority -eq 100) { "WHQL Full" }
                           elseif ($c.Priority -eq 80)  { "WHQL Web" }
                           else { "Alt" }
                    Write-OK "[$lbl] $($c.Url)"
                }

                # Extract version from URL
                if ($downloadUrl -match 'adrenalin[^0-9]*(\d+\.\d+\.\d+)') {
                    $driverVersion = $Matches[1]
                }
                elseif ($downloadUrl -match '(\d+\.\d+\.\d+\.\d+)') {
                    $driverVersion = $Matches[1]
                }
                break
            }
            Write-Warn "No driver links found on this page"
        }
        catch { Write-Warn "Failed to access: $pageUrl" }
    }

    if (-not $downloadUrl) {
        Write-Err "Cannot extract AMD driver from product pages, trying sibling models..."
        $fallbackPages = Get-AMDFallbackPages -Series $cpuSlug.Series
        foreach ($fb in $fallbackPages) {
            try {
                Write-Step "Trying sibling: $fb"
                $resp2 = Get-StableWebContent -Uri $fb -Headers @{ "Referer" = "https://www.amd.com/" }
                $html2 = $resp2.Content
                $matches2 = [regex]::Matches($html2, "https://drivers\.amd\.com/drivers/[^\""'`\s<>]+\.exe", 'IgnoreCase')
                $cands2 = @()
                foreach ($m in $matches2) {
                    $u2 = [System.Web.HttpUtility]::HtmlDecode($m.Value)
                    if ($u2 -match "firmware|chipset|raid|rgb.*led|led.*exe$|autodetect|detection") { continue }
                    $pri2 = 0
                    if ($u2 -match "whql.*adrenalin.*win1[01].*\.exe$" -and $u2 -notmatch "minimalsetup|_web") { $pri2 = 100 }
                    elseif ($u2 -match "whql.*adrenalin.*minimalsetup.*_web\.exe$") { $pri2 = 80 }
                    elseif ($u2 -match "adrenalin.*\.exe$") { $pri2 = 60 }
                    if ($pri2 -gt 0) { $cands2 += [PSCustomObject]@{ Url = $u2; Priority = $pri2 } }
                }
                if ($cands2.Count -gt 0) {
                    $cands2 = $cands2 | Sort-Object -Property Priority -Descending
                    $downloadUrl = $cands2[0].Url
                    if ($downloadUrl -match 'adrenalin[^0-9]*(\d+\.\d+\.\d+)') { $driverVersion = $Matches[1] }
                    Write-OK "Found via sibling: $downloadUrl"
                    break
                }
            } catch {}
        }
    }

    if (-not $downloadUrl) {
        Write-Err "Cannot extract AMD driver from any product page, falling back to Auto-Detect."
        Write-Step "Fetching: https://www.amd.com/en/support/download/drivers.html"
        try {
            $adbResp = Get-StableWebContent -Uri "https://www.amd.com/en/support/download/drivers.html" `
                -Headers @{ "Referer" = "https://www.amd.com/" }
            $adbHtml = $adbResp.Content
            $adbPat = "https://drivers\.amd\.com/drivers/[^\""\s<>]*minimalsetup[^\""\s<>]*_web\.exe"
            $adbM = [regex]::Match($adbHtml, $adbPat, 'IgnoreCase')
            if ($adbM.Success) {
                $downloadUrl = [System.Web.HttpUtility]::HtmlDecode($adbM.Value)
                Write-OK "Auto-Detect installer: $downloadUrl"
            }
            else {
                Write-Err "Auto-Detect link not found on the page (site structure may have changed)."
            }
        } catch {
            Write-Err "Cannot reach AMD support page: $_"
        }
        if (-not $downloadUrl) {
            Write-Err "Please visit: https://www.amd.com/en/support/download/drivers.html"
            return $null
        }
    }

    Write-OK "Version: $driverVersion"
    Write-OK "URL: $downloadUrl"

    if (-not $SkipDownload) {
        # Use original filename from URL
        $fn = $downloadUrl.Split('/')[-1].Split('?')[0]
        $outFile = Join-Path $OutputPath $fn
        Invoke-Download -Url $downloadUrl -OutFile $outFile -Referer "https://www.amd.com/"
    }

    return [PSCustomObject]@{ Version = $driverVersion; DownloadURL = $downloadUrl; Model = $modelName }
}

# =============================================================================
# Intel Driver Download
# =============================================================================

function Get-IntelDownloadId {
    <#
    .SYNOPSIS
        Determine which Intel download page ID to use based on CPU generation (primary)
        with GPU name as fallback.
    .DESCRIPTION
        Intel has three separate download pages for different GPU generations:
          ID 785597  Arc discrete / Core Ultra integrated (newest unified driver)
          ID 864990  11th-14th Gen Processor Graphics (Tiger Lake → Raptor Lake Refresh)
          ID 776137  7th-10th Gen Processor Graphics and older (legacy)
        Detection rules (in priority order):
          1. GPU name contains "Arc" (discrete GPU)         -> 785597
          2. CPU model contains "Ultra" (Core Ultra Series)  -> 785597
          3. CPU model implies 11th-14th Gen                 -> 864990
          4. CPU model implies ≤10th Gen                     -> 776137
          5. Fallback: GPU name + driver version heuristics
    #>
    param([string]$GpuName)

    $name = $GpuName

    # Rule 1: Discrete Arc GPU always uses the newest unified driver
    if ($name -match "Arc\b") {
        Write-OK "Detected: Intel Arc (discrete) -> ID 785597"
        return "785597/intel-arc-graphics-windows"
    }

    # --- CPU-based detection (Win32_Processor) ---
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
            Where-Object { $_.Manufacturer -match "GenuineIntel|Intel" } |
            Select-Object -First 1
        $cpuName = $cpu.Name
    } catch { $cpuName = $null }

    if ($cpuName) {
        Write-OK "CPU: $cpuName"

        # Core Ultra (Meteor Lake / Lunar Lake / Arrow Lake) -> 785597
        if ($cpuName -match "\bUltra\b") {
            Write-OK "Detected: Core Ultra -> ID 785597"
            return "785597/intel-arc-graphics-windows"
        }

        # 11th Gen  i?-11xxx  (Tiger Lake)
        # 12th Gen  i?-12xxx  (Alder Lake)
        # 13th Gen  i?-13xxx  (Raptor Lake)
        # 14th Gen  i?-14xxx  (Raptor Lake Refresh)
        # Also matches "N??" (i3-N305) Alder Lake-N -> 864990
        if ($cpuName -match '\b(?:i[3579]-)?(?:11|12|13|14)\d{2,3}[A-Z]*\b' -or
            $cpuName -match '\bN\d{2,4}\b') {
            Write-OK "Detected: 11th-14th Gen -> ID 864990"
            return "864990/intel-11th-14th-gen-processor-graphics-windows"
        }

        # 7th-10th Gen  i?-7xxx through i?-10xxx
        # Kaby Lake / Coffee Lake / Whiskey Lake / Comet Lake / Ice Lake
        if ($cpuName -match '\b(?:i[3579]-)?(?:7|8|9|10)\d{2,3}[A-Z]*\b') {
            Write-OK "Detected: 7th-10th Gen -> ID 776137"
            return "776137/intel-7th-10th-gen-processor-graphics-windows"
        }

        # 4th-6th Gen  i?-4xxx / i?-5xxx / i?-6xxx
        if ($cpuName -match '\b(?:i[3579]-)?[4-6]\d{2,3}[A-Z]*\b') {
            Write-OK "Detected: 4th-6th Gen (legacy) -> ID 776137"
            return "776137/intel-7th-10th-gen-processor-graphics-windows"
        }

        # Pentium / Celeron / Atom -> legacy
        if ($cpuName -match '\b(Pentium|Celeron|Atom)\b') {
            Write-OK "Detected: Legacy CPU ($Matches[1]) -> ID 776137"
            return "776137/intel-7th-10th-gen-processor-graphics-windows"
        }
    }

    # --- Fallback: GPU name + driver version heuristics ---
    try {
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -match "Intel|Arc|Iris|UHD|HD Graphics" } |
            Select-Object -First 1
        $drvVer = $gpu.DriverVersion
    } catch { $drvVer = "32.0" }

    if ($name -match "Iris\s+Xe") {
        Write-OK "Detected: Intel Iris Xe -> ID 785597"
        return "785597/intel-arc-graphics-windows"
    }

    # Driver version hints
    if ($drvVer -match "^15\.|^20\.|^31\." -or $drvVer -match "^10\." -or [version]$drvVer -lt [version]"31.0") {
        Write-OK "Detected: Legacy driver (v$drvVer) -> ID 776137"
        return "776137/intel-7th-10th-gen-processor-graphics-windows"
    }

    if ($name -match "HD\s*Graphics\s*(\d{3,4})") {
        $model = [int]$Matches[1]
        if ($model -lt 700) {
            Write-OK "Detected: HD Graphics $model -> ID 776137 (legacy)"
            return "776137/intel-7th-10th-gen-processor-graphics-windows"
        }
    }

    if ($name -match "UHD\s*Graphics") {
        if ($drvVer -match "^32\.") {
            Write-OK "Detected: UHD Graphics (v32.x) -> ID 864990 (11th-14th Gen)"
            return "864990/intel-11th-14th-gen-processor-graphics-windows"
        } else {
            Write-OK "Detected: UHD Graphics (legacy driver) -> ID 776137"
            return "776137/intel-7th-10th-gen-processor-graphics-windows"
        }
    }

    # Unknown 32.x driver -> try 864990
    if ($drvVer -match "^32\.") {
        Write-OK "Detected: Intel Graphics (v32.x) -> ID 864990"
        return "864990/intel-11th-14th-gen-processor-graphics-windows"
    }

    Write-OK "Detected: Unknown Intel Graphics -> ID 785597"
    return "785597/intel-arc-graphics-windows"
}

function Get-IntelDriver {
    param([string]$GpuName)

    Write-Host "`n" -NoNewline
    Write-Host ("=" * 60) -ForegroundColor DarkBlue
    Write-Host "  Intel Graphics Driver Download" -ForegroundColor Blue
    Write-Host ("=" * 60) -ForegroundColor DarkBlue

    # Intel has separate download pages per GPU generation:
    #   ID 785597  Arc / Iris Xe / Core Ultra (newest, unified)
    #   ID 864990  11th-14th Gen Processor Graphics
    #   ID 776137  7th-10th Gen Processor Graphics
    # Determine which page to use based on GPU name or current driver version.
    $downloadId = Get-IntelDownloadId -GpuName $GpuName

    $pageUrl = "https://www.intel.cn/content/www/cn/zh/download/$downloadId.html"
    Write-Step "Accessing Intel download center..."
    Write-OK "Page: $pageUrl"

    try {
        $resp = Get-StableWebContent -Uri $pageUrl -Headers @{ "Referer" = "https://www.intel.cn/" }
        $html = $resp.Content

        # Extract downloadmirror.intel.com .exe URLs from the page HTML
        $dmPat = "https://downloadmirror\.intel\.com/\d+/[^\""\s<>]+\.exe"
        $dmMatches = [regex]::Matches($html, $dmPat, "IgnoreCase")
        Write-OK "Found $($dmMatches.Count) downloadmirror link(s)"

        if ($dmMatches.Count -gt 0) {
            $downloadUrl = [System.Web.HttpUtility]::HtmlDecode($dmMatches[0].Value)
            Write-OK "  $downloadUrl"

            if ($downloadUrl -match 'gfx_win_(\d+)\.(\d+)\.exe') {
                $driverVersion = "32.0.$($Matches[1]).$($Matches[2])"
            }
            Write-OK "Latest version: $driverVersion"
        }
    }
    catch {
        Write-Err "Cannot access Intel download center: $_"
    }

    if (-not $downloadUrl) {
        # Fallback: if 864990 failed, try 785597 (newest unified driver covers more GPUs)
        if ($downloadId -match "^864990") {
            Write-Warn "864990 page failed, falling back to 785597..."
            $downloadId = "785597/intel-arc-graphics-windows"
            $pageUrl = "https://www.intel.cn/content/www/cn/zh/download/$downloadId.html"
            Write-Step "Accessing fallback Intel download center..."
            Write-OK "Page: $pageUrl"
            try {
                $resp = Get-StableWebContent -Uri $pageUrl -Headers @{ "Referer" = "https://www.intel.cn/" }
                $html = $resp.Content
                $dmPat = "https://downloadmirror\.intel\.com/\d+/[^\""\s<>]+\.exe"
                $dmMatches = [regex]::Matches($html, $dmPat, "IgnoreCase")
                Write-OK "Found $($dmMatches.Count) downloadmirror link(s)"
                if ($dmMatches.Count -gt 0) {
                    $downloadUrl = [System.Web.HttpUtility]::HtmlDecode($dmMatches[0].Value)
                    Write-OK "  $downloadUrl"
                    if ($downloadUrl -match 'gfx_win_(\d+)\.(\d+)\.exe') {
                        $driverVersion = "32.0.$($Matches[1]).$($Matches[2])"
                    }
                    Write-OK "Latest version: $driverVersion"
                }
            } catch {
                Write-Err "Cannot access fallback page either: $_"
            }
        }

        if (-not $downloadUrl) {
            Write-Err "Cannot find Intel driver. Please visit:"
            Write-Warn "  $pageUrl"
            return $null
        }
    }

    $downloadUrl = [System.Web.HttpUtility]::HtmlDecode($downloadUrl)
    Write-OK "Download URL: $downloadUrl"

    if (-not $SkipDownload) {
        # Use original filename from URL
        $fn = $downloadUrl.Split('/')[-1].Split('?')[0]
        $outFile = Join-Path $OutputPath $fn
        Invoke-Download -Url $downloadUrl -OutFile $outFile -Referer "https://www.intel.cn/"
    }

    return [PSCustomObject]@{ Version = $driverVersion; DownloadURL = $downloadUrl; GPUName = $GpuName }
}

# =============================================================================
# Main
# =============================================================================

Write-Host @"

============================================================
    GPU Driver Auto-Downloader v1.0
    NVIDIA / AMD / Intel Graphics Driver Download Tool
============================================================
"@ -ForegroundColor Cyan

Write-Host "Output directory: $OutputPath" -ForegroundColor DarkGray

# Detect GPUs
$installedGpus = Get-InstalledGPU

if ($ListGPUs) {
    Write-Host "`nInstalled GPUs:" -ForegroundColor Cyan
    $installedGpus | Format-Table -AutoSize
    return
}

if ($installedGpus.Count -eq 0) {
    Write-Warn "No GPUs detected!"
    exit 0
}

# Determine target vendors
$targetVendors = @()
if ($Vendor -eq "Auto") {
    $targetVendors = $installedGpus | Where-Object { $_.Vendor -ne "Unknown" } | Select-Object -ExpandProperty Vendor -Unique
    if ($targetVendors.Count -eq 0) { $targetVendors = @("NVIDIA", "AMD", "Intel") }
}
elseif ($Vendor -eq "All") {
    $targetVendors = @("NVIDIA", "AMD", "Intel")
}
else {
    $targetVendors = @($Vendor)
}

Write-Host "Target vendors: $($targetVendors -join ', ')" -ForegroundColor Magenta

# Download drivers
$results = @()
foreach ($v in $targetVendors) {
    $gpu = $installedGpus | Where-Object { $_.Vendor -eq $v } | Select-Object -First 1
    if (-not $gpu) {
        Write-Warn "No ${v} GPU detected, skipping..."
        continue
    }
    try {
        $result = $null
        switch ($v) {
            "NVIDIA" { $result = Get-NVIDIADriver -GpuName $gpu.Name }
            "AMD"    { $result = Get-AMDDriver -GpuName $gpu.Name }
            "Intel"  { $result = Get-IntelDriver -GpuName $gpu.Name }
        }
        if ($result) {
            $results += [PSCustomObject]@{
                Vendor  = $v
                GPU     = $gpu.Name
                Version = $result.Version
                Status  = if ($SkipDownload) { "Queried" } else { "Downloaded" }
            }
        }
    }
    catch { Write-Err "${v} driver download failed: $_" }
}

# Summary
Write-Host "`n"
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
    Write-Host "`nAll drivers saved to: $OutputPath" -ForegroundColor Green
}
else {
    Write-Warn "No drivers were downloaded"
}
