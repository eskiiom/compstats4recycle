#Requires -Version 5.1

# CompStats for Recycle - Version 1.5
# Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)
# Project homepage: https://github.com/eskiiom/compstats4recycle
#
# Generates an HTML report with system, CPU, GPU, RAM, HDD (with SMART), and Battery info

param(
    [switch]$Silent,
    [switch]$NoJson,
    [switch]$NoCsvLog
)

# Version info
$scriptVersion = "1.5"
$scriptDate = "2026-09-09"

# Check for elevated privileges (admin rights)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Yellow
    Write-Host "ATTENTION: Droits administrateur requis" -ForegroundColor Yellow
    Write-Host "======================================" -ForegroundColor Yellow
    Write-Host "smartctl necessite des privileges eleves pour fonctionner correctement." -ForegroundColor Yellow
    Write-Host ""
    if ($Silent) {
        Write-Host "Mode -Silent : poursuite sans elevation (donnees SMART limitees au fallback WMI)." -ForegroundColor Yellow
        Write-Host ""
    } else {
        $response = Read-Host "Voulez-vous redemarrer le script en mode administrateur? (O/N)"
        if ($response -eq "O" -or $response -eq "o") {
            Write-Host "Redemarrage en cours..." -ForegroundColor Green
            Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
            exit
        } else {
            Write-Host "Le script continuera sans les donnees SMART complete." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

# Force UTF-8 encoding for input and output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[System.Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Display version info
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "CompStats for Recycle v$scriptVersion ($scriptDate)" -ForegroundColor Cyan
Write-Host "Copyright (c) 2026 Guillaume COQUEBLIN" -ForegroundColor Cyan
Write-Host "https://github.com/eskiiom/compstats4recycle" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# Function to get system information
function Get-SystemInfo {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop

        # Extract full BIOS date
        $biosDate = "N/A"
        if ($bios.ReleaseDate) {
            $biosDate = $bios.ReleaseDate.ToString("dd/MM/yyyy")
        }

        return @{
            Brand = $cs.Manufacturer
            Model = $cs.Model
            SerialNumber = $bios.SerialNumber
            BiosDate = $biosDate
        }
    } catch {
        Write-Host "Erreur lors de la lecture des informations systeme: $($_.Exception.Message)" -ForegroundColor Yellow
        return @{ Brand = "N/A"; Model = "N/A"; SerialNumber = "N/A"; BiosDate = "N/A" }
    }
}

# Function to get CPU information
function Get-CPUInfo {
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return @{
            Brand = $cpu.Manufacturer
            Model = $cpu.Name
            Speed = "$($cpu.MaxClockSpeed) MHz"
        }
    } catch {
        Write-Host "Erreur lors de la lecture des informations CPU: $($_.Exception.Message)" -ForegroundColor Yellow
        return @{ Brand = "N/A"; Model = "N/A"; Speed = "N/A" }
    }
}

# Win32_VideoController.AdapterRAM is a 32-bit field: it wraps/truncates to ~4GB
# on GPUs with more VRAM, so read the accurate value from the driver's registry
# key when available and fall back to AdapterRAM otherwise
function Get-GpuVRamFromRegistry {
    param($driverDesc)
    $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    # -ErrorAction SilentlyContinue: some subkeys can be access-denied (unrelated
    # phantom entries, restricted ACLs) - one bad subkey must not abort the whole
    # enumeration and hide every GPU's VRAM behind the AdapterRAM fallback
    $subKeys = Get-ChildItem -Path $classPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
    foreach ($key in $subKeys) {
        try {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
            if ($props.DriverDesc -eq $driverDesc -and $props.'HardwareInformation.qwMemorySize') {
                return [uint64]$props.'HardwareInformation.qwMemorySize'
            }
        } catch { }
    }
    return $null
}

# Function to get GPU information (one entry per video controller: integrated + dedicated)
function Get-GPUInfo {
    try {
        $controllers = Get-CimInstance Win32_VideoController -ErrorAction Stop
    } catch {
        Write-Host "Erreur lors de la lecture de la carte graphique: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    $results = $controllers | ForEach-Object {
        $vramBytes = Get-GpuVRamFromRegistry -driverDesc $_.Name
        if (-not $vramBytes -and $_.AdapterRAM) { $vramBytes = [uint64]$_.AdapterRAM }
        $vram = if ($vramBytes -and $vramBytes -gt 0) { "$([math]::Round($vramBytes / 1GB, 2)) GB" } else { "N/A" }

        $resolution = if ($_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution) {
            "$($_.CurrentHorizontalResolution) x $($_.CurrentVerticalResolution)"
        } else { "N/A" }

        $driverDate = "N/A"
        if ($_.DriverDate) {
            try { $driverDate = $_.DriverDate.ToString("dd/MM/yyyy") } catch { }
        }

        @{
            Name = $_.Name
            VRAM = $vram
            DriverVersion = $_.DriverVersion
            DriverDate = $driverDate
            Resolution = $resolution
            Status = $_.Status
        }
    }
    return @($results)
}

# Function to get RAM information
function Get-RAMInfo {
    try {
        $rams = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
    } catch {
        Write-Host "Erreur lors de la lecture des informations RAM: $($_.Exception.Message)" -ForegroundColor Yellow
        return @{ Total = "N/A"; MaxSlots = 0; Modules = @() }
    }

    # No SMBIOS memory module info at all: typical of soldered/integrated RAM
    # that Win32_PhysicalMemory can't enumerate on some modern laptops
    if (-not $rams -or ($rams -is [array] -and $rams.Count -eq 0)) {
        $totalGb = 0
        try {
            $csTotal = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            $totalGb = [math]::Round($csTotal / 1GB, 2)
        } catch { }
        return @{
            Total = "$totalGb GB"
            MaxSlots = 0
            Modules = @()
            Integrated = $true
        }
    }

    # Handle single object vs collection
    if ($rams -is [array]) {
        $ramCount = $rams.Count
    } else {
        $ramCount = 1
    }

    $total = ($rams | Measure-Object -Property Capacity -Sum).Sum / 1GB
    
    # Try to get memory device slots - use a more reliable method
    $array = Get-CimInstance Win32_PhysicalMemoryArray
    if ($array -and $array.MemoryDevices) {
        $maxSlots = $array.MemoryDevices
    } else {
        # Fallback: assume at least as many slots as modules or 2
        $maxSlots = [Math]::Max($ramCount, 2)
    }
    
    $details = @()
    for ($i = 0; $i -lt $maxSlots; $i++) {
        if ($i -lt $ramCount) {
            # Handle array or single object
            if ($ramCount -eq 1 -and $i -eq 0) {
                $ram = $rams
            } else {
                $ram = $rams[$i]
            }
            $details += @{
                Slot = "Slot $($i+1)"
                Manufacturer = $ram.Manufacturer
                Model = $ram.PartNumber
                Capacity = "$([math]::Round($ram.Capacity / 1GB, 2)) GB"
                Status = "Occupe"
            }
        } else {
            $details += @{
                Slot = "Slot $($i+1)"
                Manufacturer = ""
                Model = ""
                Capacity = ""
                Status = "Vide"
            }
        }
    }
    return @{
        Total = "$([math]::Round($total, 2)) GB"
        MaxSlots = $maxSlots
        Modules = $details
        Integrated = $false
    }
}

# Function to get HDD information
function Get-HDDInfo {
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
    } catch {
        Write-Host "Erreur lors de la lecture des disques: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
    $details = $disks | ForEach-Object {
        $size = [math]::Round($_.Size / 1GB, 2)
        # SpindleSpeed is in RPM for HDDs; 0 (or absent) on SSDs
        $rpm = $null
        try { $rpm = $_.SpindleSpeed } catch { }
        @{
            DeviceID = $_.DeviceID
            Type = $_.MediaType
            BusType = $_.BusType
            Size = "$size GB"
            SpindleSpeed = $rpm
            SMART = $null  # Will be filled later
        }
    }
    return $details
}

# Function to get battery information using powercfg
function Get-BatteryInfo {
    $tempFile = Join-Path $env:TEMP "battery_report.html"
    $scriptDirFile = Join-Path $PSScriptRoot "battery-report.html"
    $rootFile = "C:\battery-report.html"
    $content = $null
    
    # Check if file exists in script directory
    if (Test-Path $scriptDirFile) {
        $fileAge = (Get-Date) - (Get-Item $scriptDirFile).LastWriteTime
        if ($fileAge.TotalDays -lt 1) {
            # File exists and is less than 1 day old - use it
            Write-Host "Utilisation du rapport de batterie existant: $scriptDirFile"
            $content = Get-Content $scriptDirFile -Raw
        } else {
            Write-Host "Rapport de batterie trop ancien, generation d'un nouveau..."
        }
    }
    
    # Check if file exists in C:\
    if (-not $content -and (Test-Path $rootFile)) {
        $fileAge = (Get-Date) - (Get-Item $rootFile).LastWriteTime
        if ($fileAge.TotalDays -lt 1) {
            Write-Host "Utilisation du rapport de batterie: $rootFile"
            $content = Get-Content $rootFile -Raw
            # Copy to script directory for future use
            Copy-Item $rootFile $scriptDirFile -Force
        }
    }
    
    # Generate new report if needed
    if (-not $content) {
        try {
            Write-Host "Generation d'un nouveau rapport de batterie..."
            # Generate to temp first, then move to script directory
            & powercfg /batteryreport /output $tempFile | Out-Null
            if (Test-Path $tempFile) {
                # Copy to script directory
                Copy-Item $tempFile $scriptDirFile -Force
                $content = Get-Content $scriptDirFile -Raw
                Write-Host "Rapport de batterie genere: $scriptDirFile"
            } else {
                return "No battery detected"
            }
        } catch {
            Write-Host "Erreur lors de la generation du rapport: $($_.Exception.Message)"
            return "No battery detected"
        } finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
    
    # Check if content is XML and convert to HTML if needed
    if ($content -match '^<\?xml') {
        # It's XML format - need to regenerate in HTML format
        Write-Host "Rapport au format XML detecté, regeneration en HTML..."
        try {
            & powercfg /batteryreport /output $tempFile | Out-Null
            if (Test-Path $tempFile) {
                Copy-Item $tempFile $scriptDirFile -Force
                $content = Get-Content $scriptDirFile -Raw
            }
        } catch {
            Write-Host "Erreur conversion: $($_.Exception.Message)"
        } finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
    # Parse HTML for battery info - improved patterns for Windows battery report
    # Format: <span class="label">DESIGN CAPACITY</span></td><td>45 730 mWh</td>
    
    # Initialize variables
    $batteryName = $null
    $manufacturer = $null
    $serialNumber = $null
    $chemistry = $null
    $designMatch = $null
    $fullMatch = $null
    $cycleMatch = $null
    
    # Extract battery info
    if ($content -match '<span class="label">DESIGN CAPACITY</span></td><td>(\d[\d\s]*)mWh') { 
        $designMatch = $matches[1] -replace '\s', '' 
    }
    if ($content -match '<span class="label">FULL CHARGE CAPACITY</span></td><td>(\d[\d\s]*)mWh') { 
        $fullMatch = $matches[1] -replace '\s', '' 
    }
    if ($content -match '<span class="label">CYCLE COUNT</span></td><td>(\d+)') { 
        $cycleMatch = $matches[1] 
    }
    
    # Also extract battery name and manufacturer
    if ($content -match '<span class="label">NAME</span></td><td>([^<]+)') { $batteryName = $matches[1].Trim() }
    if ($content -match '<span class="label">MANUFACTURER</span></td><td>([^<]+)') { $manufacturer = $matches[1].Trim() }
    if ($content -match '<span class="label">SERIAL NUMBER</span></td><td>([^<]+)') { $serialNumber = $matches[1].Trim() }
    if ($content -match '<span class="label">CHEMISTRY</span></td><td>([^<]+)') { $chemistry = $matches[1].Trim() }
    
    # Extract battery life estimation
    # Format: <td>Since OS install</td><td class="hms">5:49:46</td>...<td class="hms">7:19:48</td>
    $batteryLifeFull = $null
    $batteryLifeDesign = $null
    
    # Use pattern with class="hms" to be more specific
    if ($content -match '(?s)Since OS install.*?<td class="hms">(\d+:\d+:\d+)</td>.*?<td class="hms">(\d+:\d+:\d+)') {
        $batteryLifeFull = $matches[1]
        $batteryLifeDesign = $matches[2]
    }
    if ($designMatch -and $fullMatch) {
        $design = [int]($designMatch -replace '[^0-9]', '')
        $full = [int]($fullMatch -replace '[^0-9]', '')
        $health = if ($design -gt 0) { [math]::Round(($full / $design) * 100, 2) } else { 0 }
        
        # Determine health status
        $healthStatus = if ($health -ge 80) { "Excellent" } elseif ($health -ge 60) { "Bon" } elseif ($health -ge 40) { "Attention" } else { "Critique" }
        
        return @{
            Name = if ($batteryName) { $batteryName } else { "Non detecte" }
            Manufacturer = if ($manufacturer) { $manufacturer } else { "Non detecte" }
            SerialNumber = if ($serialNumber) { $serialNumber } else { "Non detecte" }
            Chemistry = if ($chemistry) { $chemistry } else { "Non detecte" }
            Age = if ($cycleMatch) { "$cycleMatch cycles" } else { "Inconnu" }
            DesignCapacity = if ($design -gt 0) { "$design mWh" } else { "Non detectee" }
            MeasuredCapacity = if ($full -gt 0) { "$full mWh" } else { "Non mesuree" }
            Health = "$health%"
            HealthStatus = $healthStatus
            HealthValue = $health
            BatteryLifeFull = if ($batteryLifeFull) { $batteryLifeFull } else { "Non disponible" }
            BatteryLifeDesign = if ($batteryLifeDesign) { $batteryLifeDesign } else { "Non disponible" }
        }
    }
    return "No battery detected"
}

# Extract a numeric value from smartctl output for a given attribute/field name.
# ATA attribute table rows (e.g. "  5 Reallocated_Sector_Ct  0x0033  100 100 010  Pre-fail  Always  -  0")
# put the value we want (RAW_VALUE) at the END of the line, not the start - the
# leading number is the attribute ID (5 here), so -Trailing must be used for those.
# NVMe log fields (e.g. "Power On Hours:                    1,234") are simple
# "label: value" lines where the first number after the colon IS the value.
function Get-SmartNumericValue {
    param($Output, [string[]]$Patterns, [switch]$Trailing)
    foreach ($pattern in $Patterns) {
        $match = $Output | Select-String $pattern | Select-Object -First 1
        if (-not $match) { continue }
        if ($Trailing) {
            if ($match.Line.Trim() -match '(\d[\d,]*)\s*$') { return ($matches[1] -replace ',', '') }
        } else {
            if ($match.Line -match ':\s*(\d[\d,]*)') { return ($matches[1] -replace ',', '') }
        }
    }
    return $null
}

# Function to get SMART data using smartctl.exe or WMI fallback
function Get-SMARTData {
    param($deviceID, $busType)
    $smartctlPath = $null

    # Check if smartctl is in script directory
    $smartctl = Join-Path $PSScriptRoot "smartctl.exe"
    if (Test-Path $smartctl) {
        $smartctlPath = $smartctl
    } else {
        # Check multiple installation paths (32-bit and 64-bit)
        $possiblePaths = @(
            "C:\Program Files\smartmontools\bin\smartctl.exe",
            "C:\Program Files (x86)\smartmontools\bin\smartctl.exe"
        )
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) { $smartctlPath = $path; break }
        }
        
        if (-not $smartctlPath) {
            try {
                $cmd = Get-Command smartctl -ErrorAction Stop
                $smartctlPath = $cmd.Source
            } catch {
                Write-Host "smartctl introuvable, utilisation du fallback WMI (donnees SMART limitees)." -ForegroundColor Yellow
                Write-Host "Pour des donnees SMART completes : installez smartmontools" -ForegroundColor Yellow
                Write-Host "(https://github.com/smartmontools/smartmontools/releases/latest) et relancez le script." -ForegroundColor Yellow
            }
        }
    }
    
    $smartData = $null
    $smartAvailable = $false
    
    # Try smartctl with different device types
    if ($smartctlPath) {
        # Map PhysicalDriveN to smartctl's Windows device name (works for any number of disks)
        $linuxDevice = "/dev/sd$([char](97 + [int]$deviceID))"

        # Order device types by the actual bus reported by Get-PhysicalDisk instead of
        # assuming disk 0 is SATA and everything else is NVMe
        $deviceTypes = if ($busType -eq "NVMe") { @('nvme', 'ata', 'sat', 'scsi') } else { @('sat', 'ata', 'nvme', 'scsi') }

        foreach ($devType in $deviceTypes) {
            try {
                $smartArgs = @("-d", $devType, "-a", $linuxDevice)
                $output = & $smartctlPath @smartArgs 2>&1
                
                # Check if we got SMART data (including NVMe format)
                if ($output -match "Reallocated_Sector_Ct" -or $output -match "Power_On_Hours" -or $output -match "Power-On_Hours" -or $output -match "Data Units Written" -or $output -match "Percentage Used") {
                    $smartAvailable = $true
                    
                    # Errors: reallocated sectors (ATA/SATA attribute table) or media/data
                    # integrity errors (NVMe - there is no "reallocated sector" concept there)
                    $errorsVal = Get-SmartNumericValue -Output $output -Patterns @('Reallocated_Sector_Ct') -Trailing
                    if ($null -eq $errorsVal) { $errorsVal = Get-SmartNumericValue -Output $output -Patterns @('Media and Data Integrity Errors:') }
                    $errors = if ($null -ne $errorsVal) { $errorsVal } else { "N/A" }

                    # Power-on hours (ATA attribute table, or NVMe's own log field)
                    $hoursVal = Get-SmartNumericValue -Output $output -Patterns @('Power_On_Hours', 'Power-On_Hours') -Trailing
                    if ($null -eq $hoursVal) { $hoursVal = Get-SmartNumericValue -Output $output -Patterns @('^Power On Hours:') }
                    $hours = if ($null -ne $hoursVal) { $hoursVal } else { "N/A" }

                    # Temperature: smartctl's "Current Drive Temperature:" summary line (ATA) or
                    # NVMe's own "Temperature:" log field share the same "label: value" shape
                    $temp = "N/A"
                    $tempVal = Get-SmartNumericValue -Output $output -Patterns @('Temperature:')
                    if ($null -eq $tempVal) {
                        # Older smartctl without that summary line: fall back to the ATA
                        # attribute table row (RAW_VALUE, at the end of the line)
                        $tempVal = Get-SmartNumericValue -Output $output -Patterns @('Temperature_Celsius') -Trailing
                    }
                    if ($null -ne $tempVal -and [int]$tempVal -gt 0 -and [int]$tempVal -lt 100) {
                        $temp = [int]$tempVal
                    }

                    # Wear level for SSDs: ATA attribute table (Samsung/Micron-style attributes)
                    # or NVMe's own "Percentage Used:" log field
                    $wearLevel = "N/A"
                    $wearVal = Get-SmartNumericValue -Output $output -Patterns @('Percent_Lifetime_Remain', 'Wear_Leveling_Count') -Trailing
                    if ($null -ne $wearVal) {
                        $wearLevel = "$wearVal% remaining"
                    } else {
                        $wearVal = Get-SmartNumericValue -Output $output -Patterns @('Percentage Used')
                        if ($null -ne $wearVal) { $wearLevel = "$wearVal% used" }
                    }
                    
                    # Parse model/serial/firmware so the report is complete even when
                    # smartctl (not just the WMI fallback) is the data source
                    $model = $null
                    $modelMatch = $output | Select-String "Device Model:|Model Number:"
                    if ($modelMatch) { $model = ($modelMatch.Line -replace '^(Device Model:|Model Number:)\s*', '').Trim() }

                    $serial = $null
                    $serialMatch = $output | Select-String "Serial Number:"
                    if ($serialMatch) { $serial = ($serialMatch.Line -replace '^Serial Number:\s*', '').Trim() }

                    $firmware = $null
                    $firmwareMatch = $output | Select-String "Firmware Version:"
                    if ($firmwareMatch) { $firmware = ($firmwareMatch.Line -replace '^Firmware Version:\s*', '').Trim() }

                    $smartData = @{
                        Errors = $errors
                        Hours = $hours
                        Temp = $temp
                        Source = "smartctl"
                        WearLevel = $wearLevel
                        Model = $model
                        Serial = $serial
                        Firmware = $firmware
                    }
                }
            } catch { }
        }
    }
    
    # Fallback to WMI if smartctl failed
    if (-not $smartAvailable) {
        try {
            $wmiDisk = Get-WmiObject -Class Win32_DiskDrive | Where-Object { $_.DeviceID -match "PHYSICALDRIVE$deviceID" }
            if ($wmiDisk) {
                $model = $wmiDisk.Model
                $serial = $wmiDisk.SerialNumber
                $status = $wmiDisk.Status
                $firmware = $wmiDisk.FirmwareRevision
                
                $smartData = @{
                    Errors = "N/A"
                    Hours = "N/A"
                    Temp = "N/A"
                    Source = "WMI"
                    Model = $model
                    Serial = $serial
                    Status = $status
                    Firmware = $firmware
                    Health = if ($status -eq "OK") { "OK" } else { $status }
                }
            }
        } catch {
            return "Unable to read SMART data"
        }
    }
    
    return $smartData
}

# HTML-encode a value coming from hardware/vendor strings (WMI, smartctl) before
# embedding it in the report, in case it contains characters like < or &
function ConvertTo-HtmlSafe {
    param($Value)
    if ($null -eq $Value) { return "" }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

# Aggregate disk and battery status into a single recycling recommendation
function Get-GlobalAssessment {
    param($diskStatuses, $hasBattery, $batteryHealthValue)

    $score = 100
    foreach ($status in $diskStatuses) {
        if ($status -eq "KO") { $score -= 35 }
        elseif ($status -eq "Attention") { $score -= 12 }
    }
    if ($hasBattery) {
        if ($batteryHealthValue -lt 40) { $score -= 35 }
        elseif ($batteryHealthValue -lt 60) { $score -= 20 }
        elseif ($batteryHealthValue -lt 80) { $score -= 8 }
    }
    $score = [Math]::Max(0, [Math]::Min(100, $score))

    if ($score -ge 80) {
        $label = "Bon etat"
        $recommendation = "Reemploi possible"
        $badgeClass = "status-ok"
    } elseif ($score -ge 50) {
        $label = "Attention"
        $recommendation = "Verifier avant reemploi"
        $badgeClass = "status-warning"
    } else {
        $label = "Critique"
        $recommendation = "Recyclage recommande"
        $badgeClass = "status-bad"
    }

    return @{
        Score = $score
        Label = $label
        Recommendation = $recommendation
        BadgeClass = $badgeClass
    }
}

# Main script execution
$system = Get-SystemInfo
$cpu = Get-CPUInfo
# @() forces array typing even with a single GPU/disk, so downstream JSON/foreach
# code doesn't have to special-case "one vs several"
$gpus = @(Get-GPUInfo)
$ram = Get-RAMInfo
$hdds = @(Get-HDDInfo)
$battery = Get-BatteryInfo

# Add SMART data to HDDs
foreach ($hdd in $hdds) {
    $hdd.SMART = Get-SMARTData -deviceID $hdd.DeviceID -busType $hdd.BusType
}

# Generate HTML report
$date = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$safeModel = $system.Model -replace "[\\/:*?""<>|]", "_"
$safeSerial = $system.SerialNumber -replace "[\\/:*?""<>|]", "_"
$filename = "$($system.Brand)_${safeModel}_${safeSerial}_${date}_CS4Rv$scriptVersion.html"
$reportsDir = Join-Path $PSScriptRoot "Rapports"
if (-not (Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}
$path = Join-Path $reportsDir $filename

# Prepare battery HTML
if ($battery -is [hashtable]) {
    $healthValue = $battery.Health
    $healthClass = ""
    
    # Determine health class
    if ($healthValue -match '^\d') {
        $h = [double]$healthValue.Trim('%')
        $healthClass = if ($h -ge 80) { "health-good" } elseif ($h -ge 60) { "health-warning" } else { "health-bad" }
    }
    
    $batteryHtml = @"
            <table>
                <tr><th>Nom de la batterie</th><td>$($battery.Name)</td></tr>
                <tr><th>Fabricant</th><td>$($battery.Manufacturer)</td></tr>
                <tr><th>Numéro de série</th><td>$($battery.SerialNumber)</td></tr>
                <tr><th>Chimie</th><td>$($battery.Chemistry)</td></tr>
                <tr><th>Age approximatif</th><td>$($battery.Age)</td></tr>
                <tr><th>Capacité constructeur</th><td>$($battery.DesignCapacity)</td></tr>
                <tr><th>Capacité mesurée</th><td>$($battery.MeasuredCapacity)</td></tr>
                <tr><th>État de santé</th><td class='$healthClass'>$($battery.Health) ($($battery.HealthStatus))</td></tr>
                <tr><th>Autonomie estimée (charge complète)</th><td>$($battery.BatteryLifeFull)</td></tr>
                <tr><th>Autonomie estimée (capacité d'origine)</th><td>$($battery.BatteryLifeDesign)</td></tr>
            </table>
"@
} else {
    $batteryHtml = "<p>$battery</p>"
}

# Prepare health summary
$summaryModel = "$(ConvertTo-HtmlSafe $system.Model) ($(ConvertTo-HtmlSafe $system.SerialNumber))"
$summaryHDDs = ""
$summaryHDDsPlain = ""
$diskStatuses = @()
$smartctlMissing = $false
$hddIndex = 1
foreach ($hdd in $hdds) {
    $smart = $hdd.SMART
    $hddStatus = "OK"
    $capacity = $hdd.Size -replace " GB$", ""
    $capacity = [math]::Floor([double]$capacity)

    if ($smart -is [hashtable]) {
        if ($smart.Source -eq "WMI") { $smartctlMissing = $true }
        if ($smart.Errors -and $smart.Errors -ne "N/A" -and $smart.Errors -ne "0") {
            $hddStatus = "KO"
        } elseif ($smart.Temp -and $smart.Temp -ne "N/A" -and [int]$smart.Temp -gt 50) {
            $hddStatus = "KO"
        } elseif ($smart.Health -and $smart.Health -eq "Warning") {
            $hddStatus = "Attention"
        }
    }
    $diskStatuses += $hddStatus
    if ($hddIndex -gt 1) { $summaryHDDs += " | "; $summaryHDDsPlain += " | " }
    $statusBadge = if ($hddStatus -eq "OK") { "status-ok" } elseif ($hddStatus -eq "Attention") { "status-warning" } else { "status-bad" }
    $summaryHDDs += "HDD $hddIndex ${capacity}GB : <span class='status-badge $statusBadge'>$hddStatus</span>"
    $summaryHDDsPlain += "HDD $hddIndex ${capacity}GB : $hddStatus"
    $hddIndex++
}

# Battery summary with color
$hasBattery = $battery -is [hashtable]
if ($hasBattery) {
    $batHealth = $battery.Health
    $batHealthValue = $battery.HealthValue
    $batBadge = "status-ok"
    if ($batHealth -match '(\d+)') {
        $h = [int]$matches[1]
        if ($h -lt 60) { $batBadge = "status-bad" }
        elseif ($h -lt 80) { $batBadge = "status-warning" }
    }
    $summaryBattery = "<span class='status-badge $batBadge'>$batHealth</span> ($($battery.BatteryLifeFull))"
} else {
    $batHealthValue = 100
    $summaryBattery = "N/A"
}

$globalAssessment = Get-GlobalAssessment -diskStatuses $diskStatuses -hasBattery $hasBattery -batteryHealthValue $batHealthValue

# HTML content
$html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>CompStats for Recycle</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
        .container { max-width: 1200px; margin: auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
        h1 { text-align: center; color: #2c3e50; }
        .section { margin-bottom: 30px; }
        h2 { border-bottom: 2px solid #3498db; padding-bottom: 5px; color: #2c3e50; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #f8f9fa; font-weight: bold; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        .health-good { color: green; }
        .health-warning { color: orange; }
        .health-bad { color: red; }
        .summary-card { 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); 
            color: white; 
            padding: 20px; 
            border-radius: 10px; 
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        .summary-card h2 { 
            border: none; 
            color: white; 
            margin-top: 0;
            font-size: 1.2em;
        }
        .summary-grid {
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
            margin-top: 15px;
        }
        .summary-item {
            background: rgba(255,255,255,0.2);
            padding: 10px 15px;
            border-radius: 5px;
            flex: 1;
            min-width: 150px;
        }
        .summary-label { font-weight: bold; font-size: 0.9em; opacity: 0.9; }
        .summary-value { font-size: 1.1em; margin-top: 5px; }
        .status-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: bold; font-size: 0.9em; }
        .status-ok { background: #27ae60; color: white; }
        .status-warning { background: #f39c12; color: white; }
        .status-bad { background: #e74c3c; color: white; }
        .info-box { background: #eaf4fb; border: 1px solid #bcdff5; border-radius: 6px; padding: 10px 15px; margin-bottom: 15px; }
        .info-box summary { cursor: pointer; font-weight: bold; color: #2c3e50; }
        .info-box ol { margin: 10px 0 0 20px; padding: 0; }
        .info-box code { background: #dceefb; padding: 1px 5px; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Statistiques Ordinateur pour Recyclage</h1>
        <p><strong>Date de génération:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>

        <div class="summary-card">
            <h2>Résumé de Santé</h2>
            <div class="summary-grid">
                <div class="summary-item">
                    <div class="summary-label">État global</div>
                    <div class="summary-value"><span class='status-badge $($globalAssessment.BadgeClass)'>$($globalAssessment.Score)/100 - $($globalAssessment.Label)</span></div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Modèle</div>
                    <div class="summary-value">$summaryModel</div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Disques</div>
                    <div class="summary-value">$summaryHDDs</div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Batterie</div>
                    <div class="summary-value">$summaryBattery</div>
                </div>
            </div>
            <p style="margin-top: 15px; margin-bottom: 0;"><strong>Recommandation :</strong> $($globalAssessment.Recommendation)</p>
        </div>

        <div class="section">
            <h2>Syst&egrave;me</h2>
            <table>
                <tr><th>Marque</th><td>$(ConvertTo-HtmlSafe $system.Brand)</td></tr>
                <tr><th>Mod&egrave;le</th><td>$(ConvertTo-HtmlSafe $system.Model)</td></tr>
                <tr><th>Num&eacute;ro de s&eacute;rie</th><td>$(ConvertTo-HtmlSafe $system.SerialNumber)</td></tr>
                <tr><th>Derniere mise a jour BIOS</th><td>$($system.BiosDate)</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>CPU</h2>
            <table>
                <tr><th>Marque</th><td>$(ConvertTo-HtmlSafe $cpu.Brand)</td></tr>
                <tr><th>Mod&egrave;le</th><td>$(ConvertTo-HtmlSafe $cpu.Model)</td></tr>
                <tr><th>Vitesse maximale</th><td>$($cpu.Speed)</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>Carte graphique</h2>
            $($gpus | ForEach-Object {
                "<table style='margin-bottom: 10px;'>"
                "<tr><th>Mod&egrave;le</th><td>$(ConvertTo-HtmlSafe $_.Name)</td></tr>"
                "<tr><th>M&eacute;moire vid&eacute;o</th><td>$($_.VRAM)</td></tr>"
                "<tr><th>Version du pilote</th><td>$(ConvertTo-HtmlSafe $_.DriverVersion)</td></tr>"
                "<tr><th>Date du pilote</th><td>$($_.DriverDate)</td></tr>"
                "<tr><th>R&eacute;solution actuelle</th><td>$($_.Resolution)</td></tr>"
                "</table>"
            })
        </div>

        <div class="section">
            <h2>RAM</h2>
            <p><strong>Total:</strong> $($ram.Total) - <strong>Slots:</strong> $($ram.MaxSlots)</p>
            $(if ($ram.Integrated) {
                "<p><em>RAM int&eacute;gr&eacute;e/soud&eacute;e d&eacute;tect&eacute;e : le d&eacute;tail par module n'est pas disponible via SMBIOS sur ce syst&egrave;me.</em></p>"
            } else {
                "<table><tr><th>Slot</th><th>Statut</th><th>Marque</th><th>Mod&egrave;le</th><th>Capacit&eacute;</th></tr>$($ram.Modules | ForEach-Object { "<tr><td>$($_.Slot)</td><td>$($_.Status)</td><td>$(ConvertTo-HtmlSafe $_.Manufacturer)</td><td>$(ConvertTo-HtmlSafe $_.Model)</td><td>$($_.Capacity)</td></tr>" })</table>"
            })
        </div>

        <div class="section">
            <h2>Disques Durs</h2>
            $(if ($smartctlMissing) {
                "<details class='info-box'>
                    <summary>&#8505;&#65039; Donn&eacute;es SMART limit&eacute;es - comment les compl&eacute;ter ?</summary>
                    <ol>
                        <li>T&eacute;l&eacute;charger <code>smartmontools-x.x.win32-setup.exe</code> depuis <a href='https://github.com/smartmontools/smartmontools/releases/latest' target='_blank' rel='noopener'>GitHub</a> (ou, si accessible, <a href='https://www.smartmontools.org/wiki/Download' target='_blank' rel='noopener'>smartmontools.org</a>)</li>
                        <li>Ex&eacute;cuter l'installateur (emplacement par d&eacute;faut, pas besoin de tout cocher)</li>
                        <li>Relancer le script (id&eacute;alement en tant qu'administrateur) : <code>smartctl.exe</code> est d&eacute;tect&eacute; automatiquement dans <code>C:\Program Files\smartmontools\bin\</code>, aucune copie manuelle n&eacute;cessaire</li>
                    </ol>
                </details>"
            })
            $($hdds | ForEach-Object {
                $smart = $_.SMART
                
                # Determine health class based on available data
                $healthClass = "health-good"
                $healthStatus = "OK"
                $alertMessage = ""
                
                if ($smart -is [hashtable]) {
                    # Check for SMART data errors
                    $errorsVal = 0
                    if ($smart.Errors -and $smart.Errors -ne "N/A" -and [int]::TryParse($smart.Errors, [ref]$errorsVal) -and $errorsVal -gt 0) {
                        $healthClass = "health-bad"
                        $healthStatus = "Problem detected"
                        $alertMessage = "Reallocated sectors detected"
                    }
                    # Check temperature
                    elseif ($smart.Temp -and $smart.Temp -ne "N/A") {
                        $tempVal = 0
                        if ([int]::TryParse($smart.Temp, [ref]$tempVal) -and $tempVal -gt 50) {
                            $healthClass = "health-warning"
                            $healthStatus = "High temperature"
                            $alertMessage = "Temperature > 50C"
                        }
                    }
                    # Check WMI health status
                    elseif ($smart.Health -and $smart.Health -ne "Unknown") {
                        if ($smart.Health -eq "Warning") {
                            $healthClass = "health-warning"
                            $healthStatus = "Warning"
                        }
                    }
                    # Check disk status from WMI
                    elseif ($smart.Status -and $smart.Status -ne "OK") {
                        $healthClass = "health-warning"
                        $healthStatus = $smart.Status
                    }
                }
                
                $rpmDisplay = if ($_.SpindleSpeed -and [int]$_.SpindleSpeed -gt 0) { "$($_.SpindleSpeed) RPM" } elseif ($_.Type -eq "SSD") { "N/A (SSD)" } else { "Not available" }

                "<div style='margin-bottom: 20px; border: 1px solid #ddd; padding: 10px; border-radius: 5px;'>"
                "<table>"
                "<tr><th>Type</th><td>$($_.Type)</td></tr>"
                "<tr><th>Taille</th><td>$($_.Size)</td></tr>"
                "<tr><th>Vitesse de rotation</th><td>$rpmDisplay</td></tr>"
                if ($smart -is [hashtable]) {
                    # Add model and serial if available
                    if ($smart.Model) {
                        "<tr><th>Modele</th><td>$(ConvertTo-HtmlSafe $smart.Model)</td></tr>"
                    }
                    if ($smart.Serial -and $smart.Serial -ne "N/A") {
                        "<tr><th>Numero de serie</th><td>$(ConvertTo-HtmlSafe $smart.Serial)</td></tr>"
                    }
                    if ($smart.Firmware) {
                        "<tr><th>Firmware</th><td>$(ConvertTo-HtmlSafe $smart.Firmware)</td></tr>"
                    }
                    
                    # SMART data with proper display
                    $errorsDisplay = if ($smart.Errors -ne "N/A") { $smart.Errors } else { "Not available" }
                    $hoursDisplay = if ($smart.Hours -ne "N/A") { "$($smart.Hours) hours" } else { "Not available" }
                    $tempDisplay = if ($smart.Temp -ne "N/A") { "$($smart.Temp) C" } else { "Not available" }
                    $wearDisplay = if ($smart.WearLevel -ne "N/A") { $smart.WearLevel } else { "Not available" }
                    
                    "<tr><th>Secteurs realloues</th><td class='$healthClass'>$errorsDisplay</td></tr>"
                    "<tr><th>Heures utilisation</th><td>$hoursDisplay</td></tr>"
                    "<tr><th>Temperature</th><td class='$healthClass'>$tempDisplay</td></tr>"
                    "<tr><th>Niveau d'usure</th><td>$wearDisplay</td></tr>"
                    
                    # Health status row
                    $sourceInfo = if ($smart.Source) { " (via $($smart.Source))" } else { "" }
                    "<tr><th>Etat de sante</th><td class='$healthClass'><strong>$healthStatus</strong>$sourceInfo</td></tr>"
                    
                    if ($alertMessage) {
                        "<tr><th>Alerte</th><td class='health-bad'>$alertMessage</td></tr>"
                    }
                } else {
                    "<tr><th>SMART</th><td>$smart</td></tr>"
                }
                "</table>"
                "</div>"
            })
        </div>

        <div class="section">
            <h2>Batterie</h2>
            $($batteryHtml)
        </div>

        <div class="section">
            <h2>Indicateurs de Sant&eacute; G&eacute;n&eacute;rale</h2>
            <ul>
                <li><strong>Batterie:</strong> Si la sant&eacute; est en dessous de 80%, consid&eacute;rer le remplacement.</li>
                <li><strong>Disques:</strong> Erreurs SMART > 0 ou temp&eacute;rature > 50&deg;C indiquent des probl&egrave;mes potentiels.</li>
                <li><strong>RAM/CPU:</strong> Pas d'indicateurs directs, mais v&eacute;rifier la compatibilit&eacute; et les performances.</li>
                <li><strong>Temp&eacute;ratures:</strong> CPU et HDD devraient &ecirc;tre < 60&deg;C sous charge normale.</li>
            </ul>
        </div>
    </div>
    <footer style="text-align: center; margin-top: 30px; padding: 15px; background: #f8f9fa; border-radius: 5px; font-size: 0.9em; color: #666;">
        <p><strong>CompStats for Recycle v$scriptVersion</strong> - Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)</p>
        <p><a href="https://github.com/eskiiom/compstats4recycle" target="_blank">https://github.com/eskiiom/compstats4recycle</a></p>
    </footer>
</body>
</html>
"@

# Add UTF-8 BOM for proper encoding
$utf8Bom = [System.Text.Encoding]::UTF8.GetPreamble()
$htmlBytes = $utf8Bom + [System.Text.Encoding]::UTF8.GetBytes($html)
[System.IO.File]::WriteAllBytes($path, $htmlBytes)
Write-Host "Rapport genere a $path"

# Structured export for scripted/bulk processing (one JSON file per machine)
if (-not $NoJson) {
    $jsonPath = [System.IO.Path]::ChangeExtension($path, "json")
    try {
        $reportData = @{
            GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            ScriptVersion = $scriptVersion
            System = $system
            CPU = $cpu
            GPU = $gpus
            RAM = $ram
            Disks = $hdds
            Battery = $battery
            GlobalAssessment = $globalAssessment
        }
        $jsonContent = $reportData | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($jsonPath, $jsonContent, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "Export JSON genere a $jsonPath"
    } catch {
        Write-Host "Erreur lors de l'export JSON: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Consolidated CSV (one row per machine) for processing a batch of computers
if (-not $NoCsvLog) {
    $csvPath = Join-Path $reportsDir "resume.csv"
    try {
        $csvRow = [PSCustomObject]@{
            DateHeure = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Marque = $system.Brand
            Modele = $system.Model
            NumeroSerie = $system.SerialNumber
            CPU = $cpu.Model
            GPU = ($gpus | ForEach-Object { $_.Name }) -join " / "
            RAM = $ram.Total
            Disques = $summaryHDDsPlain
            BatterieSante = if ($hasBattery) { $battery.Health } else { "N/A" }
            ScoreGlobal = $globalAssessment.Score
            Recommandation = $globalAssessment.Recommendation
        }
        $csvRow | Export-Csv -Path $csvPath -Append -NoTypeInformation -Encoding UTF8
        Write-Host "Ligne ajoutee au resume: $csvPath"
    } catch {
        Write-Host "Erreur lors de l'ajout au CSV: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}