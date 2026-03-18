#Requires -Version 5.1

# CompStats for Recycle - PowerShell Script to Generate Hardware Statistics
# Generates an HTML report with system, CPU, RAM, HDD (with SMART), and Battery info

param()

# Check for elevated privileges (admin rights)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Yellow
    Write-Host "ATTENTION: Droits administrateur requis" -ForegroundColor Yellow
    Write-Host "======================================" -ForegroundColor Yellow
    Write-Host "smartctl necessite des privileges eleves pour fonctionner correctement." -ForegroundColor Yellow
    Write-Host ""
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

# Force UTF-8 encoding for input and output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[System.Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Function to get system information
function Get-SystemInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    
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
}

# Function to get CPU information
function Get-CPUInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    return @{
        Brand = $cpu.Manufacturer
        Model = $cpu.Name
        Speed = "$($cpu.MaxClockSpeed) MHz"
    }
}

# Function to get RAM information
function Get-RAMInfo {
    $rams = Get-CimInstance Win32_PhysicalMemory
    
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
    }
}

# Function to get HDD information
function Get-HDDInfo {
    $disks = Get-PhysicalDisk
    $details = $disks | ForEach-Object {
        $size = [math]::Round($_.Size / 1GB, 2)
        @{
            DeviceID = $_.DeviceID
            Type = $_.MediaType
            Size = "$size GB"
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

# Function to get SMART data using smartctl.exe or WMI fallback
function Get-SMARTData {
    param($deviceID)
    $smartctlPath = $null
    
    # Enable TLS 1.2 for secure downloads
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    
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
                Write-Host "smartctl not found, using WMI fallback"
            }
        }
    }
    
    $smartData = $null
    $smartAvailable = $false
    
    # Try smartctl with different device types
    if ($smartctlPath) {
        # Map device ID to Linux device names
        # PhysicalDrive0 = /dev/sda, PhysicalDrive1 = /dev/sdb
        $linuxDevice = if ($deviceID -eq "0") { "/dev/sda" } elseif ($deviceID -eq "1") { "/dev/sdb" } else { "/dev/sda" }
        
        # Try sat for SATA drives, nvme for NVMe drives
        $deviceTypes = if ($deviceID -eq "0") { @('sat', 'ata', 'scsi') } else { @('nvme', 'ata', 'sat') }
        
        foreach ($devType in $deviceTypes) {
            try {
                $args = @("-d", $devType, "-a", $linuxDevice)
                $output = & $smartctlPath @args 2>&1
                
                # Check if we got SMART data (including NVMe format)
                if ($output -match "Reallocated_Sector_Ct" -or $output -match "Power_On_Hours" -or $output -match "Power-On_Hours" -or $output -match "Data Units Written" -or $output -match "Percentage Used") {
                    $smartAvailable = $true
                    
                    # Parse errors (reallocated sectors)
                    $errors = "0"
                    $errMatch = $output | Select-String "Reallocated_Sector_Ct"
                    if ($errMatch) {
                        $errLine = $errMatch.Line
                        if ($errLine -match "(\d+)") { $errors = $matches[1] }
                    }
                    
                    # Parse power-on hours (ATA format)
                    $hours = "N/A"
                    $hoursMatch = $output | Select-String "Power_On_Hours"
                    if (-not $hoursMatch) { $hoursMatch = $output | Select-String "Power-On_Hours" }
                    if ($hoursMatch) {
                        $hoursLine = $hoursMatch.Line
                        if ($hoursLine -match "(\d+)") { $hours = $matches[1] }
                    }
                    
                    # Parse temperature - look for Current Temperature
                    $temp = "N/A"
                    $tempMatch = $output | Select-String "Current Temperature"
                    if (-not $tempMatch) { $tempMatch = $output | Select-String "Temperature_Celsius" }
                    if ($tempMatch) {
                        $tempLine = $tempMatch.Line
                        # Try to find a number in the line
                        if ($tempLine -match "(\d+)") { 
                            $tempVal = [int]$matches[1]
                            # Reasonable temperature check (0-100 C)
                            if ($tempVal -gt 0 -and $tempVal -lt 100) {
                                $temp = $tempVal
                            }
                        }
                    }
                    
                    # Parse wear level for SSDs
                    $wearLevel = "N/A"
                    $wearMatch = $output | Select-String "Percent_Lifetime_Remain"
                    if (-not $wearMatch) { $wearMatch = $output | Select-String "Wear_Leveling_Count" }
                    if (-not $wearMatch) { $wearMatch = $output | Select-String "Percentage Used" }
                    if ($wearMatch) {
                        $wearLine = $wearMatch.Line
                        if ($wearLine -match "(\d+)") { 
                            $wearVal = [int]$matches[1]
                            # For Percentage Used, lower is better (100% = new, 0% = worn)
                            # For Percent_Lifetime_Remain, higher is better
                            if ($wearLine -match "Percentage Used") {
                                $wearLevel = "$wearVal% used"
                            } else {
                                $wearLevel = "$wearVal% remaining"
                            }
                        }
                    }
                    
                    $smartData = @{
                        Errors = $errors
                        Hours = $hours
                        Temp = $temp
                        Source = "smartctl"
                        WearLevel = $wearLevel
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

# Main script execution
$system = Get-SystemInfo
$cpu = Get-CPUInfo
$ram = Get-RAMInfo
$hdds = Get-HDDInfo
$battery = Get-BatteryInfo

# Add SMART data to HDDs
foreach ($hdd in $hdds) {
    $hdd.SMART = Get-SMARTData -deviceID $hdd.DeviceID
}

# Generate HTML report
$date = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$path = Join-Path $PSScriptRoot "$date.html"

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
$summaryModel = "$($system.Model) ($($system.SerialNumber))"
$summaryHDDs = ""
$summaryBatteryHtml = ""
$hddIndex = 1
foreach ($hdd in $hdds) {
    $smart = $hdd.SMART
    $hddStatus = "OK"
    $hddClass = "health-good"
    $capacity = $hdd.Size -replace " GB$", ""
    $capacity = [math]::Floor([double]$capacity)
    
    if ($smart -is [hashtable]) {
        if ($smart.Errors -and $smart.Errors -ne "N/A" -and $smart.Errors -ne "0") {
            $hddStatus = "KO"
            $hddClass = "health-bad"
        } elseif ($smart.Temp -and $smart.Temp -ne "N/A" -and [int]$smart.Temp -gt 50) {
            $hddStatus = "KO"
            $hddClass = "health-bad"
        } elseif ($smart.Health -and $smart.Health -eq "Warning") {
            $hddStatus = "Attention"
            $hddClass = "health-warning"
        }
    }
    if ($hddIndex -gt 1) { $summaryHDDs += " | " }
    $statusBadge = if ($hddStatus -eq "OK") { "status-ok" } elseif ($hddStatus -eq "Attention") { "status-warning" } else { "status-bad" }
    $summaryHDDs += "HDD $hddIndex ${capacity}GB : <span class='status-badge $statusBadge'>$hddStatus</span>"
    $hddIndex++
}

# Battery summary with color
if ($battery -is [hashtable]) {
    $batHealth = $battery.Health
    $batBadge = "status-ok"
    if ($batHealth -match '(\d+)') {
        $h = [int]$matches[1]
        if ($h -lt 60) { $batBadge = "status-bad" }
        elseif ($h -lt 80) { $batBadge = "status-warning" }
    }
    $summaryBattery = "<span class='status-badge $batBadge'>$batHealth</span> ($($battery.BatteryLifeFull))"
} else {
    $summaryBattery = "N/A"
}

# HTML content with embedded Chart.js for simple charts
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
    </style>
</head>
<body>
    <div class="container">
        <h1>Statistiques Ordinateur pour Recyclage</h1>
        <p><strong>Date de génération:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>

        <div class="summary-card">
            <h2>Résumé deSanté</h2>
            <div class="summary-grid">
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
        </div>

        <div class="section">
            <h2>Syst&egrave;me</h2>
            <table>
                <tr><th>Marque</th><td>$($system.Brand)</td></tr>
                <tr><th>Mod&egrave;le</th><td>$($system.Model)</td></tr>
                <tr><th>Num&eacute;ro de s&eacute;rie</th><td>$($system.SerialNumber)</td></tr>
                <tr><th>Derniere mise a jour BIOS</th><td>$($system.BiosDate)</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>CPU</h2>
            <table>
                <tr><th>Marque</th><td>$($cpu.Brand)</td></tr>
                <tr><th>Mod&egrave;le</th><td>$($cpu.Model)</td></tr>
                <tr><th>Vitesse maximale</th><td>$($cpu.Speed)</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>RAM</h2>
            <p><strong>Total:</strong> $($ram.Total) - <strong>Slots:</strong> $($ram.MaxSlots)</p>
            <table>
                <tr><th>Slot</th><th>Statut</th><th>Marque</th><th>Mod&egrave;le</th><th>Capacit&eacute;</th></tr>
                $($ram.Modules | ForEach-Object { "<tr><td>$($_.Slot)</td><td>$($_.Status)</td><td>$($_.Manufacturer)</td><td>$($_.Model)</td><td>$($_.Capacity)</td></tr>" })
            </table>
        </div>

        <div class="section">
            <h2>Disques Durs</h2>
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
                
                "<div style='margin-bottom: 20px; border: 1px solid #ddd; padding: 10px; border-radius: 5px;'>"
                "<table>"
                "<tr><th>Type</th><td>$($_.Type)</td></tr>"
                "<tr><th>Taille</th><td>$($_.Size)</td></tr>"
                if ($smart -is [hashtable]) {
                    # Add model and serial if available
                    if ($smart.Model) {
                        "<tr><th>Modele</th><td>$($smart.Model)</td></tr>"
                    }
                    if ($smart.Serial -and $smart.Serial -ne "N/A") {
                        "<tr><th>Numero de serie</th><td>$($smart.Serial)</td></tr>"
                    }
                    if ($smart.Firmware) {
                        "<tr><th>Firmware</th><td>$($smart.Firmware)</td></tr>"
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
</body>
</html>
"@

# Add UTF-8 BOM for proper encoding
$utf8Bom = [System.Text.Encoding]::UTF8.GetPreamble()
$htmlBytes = $utf8Bom + [System.Text.Encoding]::UTF8.GetBytes($html)
[System.IO.File]::WriteAllBytes($path, $htmlBytes)
Write-Host "Rapport genere a $path"