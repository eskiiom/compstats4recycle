#Requires -Version 5.1

# CompStats for Recycle - PowerShell Script to Generate Hardware Statistics
# Generates an HTML report with system, CPU, RAM, HDD (with SMART), and Battery info

param()
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Function to get system information
function Get-SystemInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    return @{
        Brand = $cs.Manufacturer
        Model = $cs.Model
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
    $total = ($rams | Measure-Object -Property Capacity -Sum).Sum / 1GB
    $array = Get-CimInstance Win32_PhysicalMemoryArray
    $maxSlots = $array.MemoryDevices
    $occupiedSlots = $rams.Count
    $details = @()
    for ($i = 0; $i -lt $maxSlots; $i++) {
        if ($i -lt $occupiedSlots) {
            $ram = $rams[$i]
            $details += @{
                Slot = "Slot $($i+1)"
                Manufacturer = $ram.Manufacturer
                Model = $ram.PartNumber
                Capacity = "$([math]::Round($ram.Capacity / 1GB, 2)) GB"
                Status = "Occupé"
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

# Function to get SMART data using smartctl.exe
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
                try {
                    $zipUrl = "https://www.smartmontools.org/files/smartmontools-7.4-1.win32.zip"
                    $zipPath = Join-Path $env:TEMP "smartmontools.zip"
                    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
                    if ((Get-Item $zipPath).Length -lt 1000000) { throw "File too small" }
                    $extractPath = Join-Path $env:TEMP "smartmontools"
                    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                    $sourceSmartctl = Join-Path $extractPath "bin\smartctl.exe"
                    Copy-Item $sourceSmartctl $smartctl -Force
                    $smartctlPath = $smartctl
                    Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Warning "Echec telechargement smartctl: $($_.Exception.Message)"
                    return "smartctl.exe non trouve et telechargement echoue"
                }
            }
        }
    }
    try {
        $output = & $smartctlPath -a "\\.\PHYSICALDRIVE$deviceID" 2>$null
        $errors = ($output | Select-String "Reallocated_Sector_Ct" | ForEach-Object { ($_.Line -split '\s+')[-1] }) -join ""
        $hours = ($output | Select-String "Power_On_Hours" | ForEach-Object { ($_.Line -split '\s+')[-1] }) -join ""
        $temp = ($output | Select-String "Temperature_Celsius" | ForEach-Object { ($_.Line -split '\s+')[-1] }) -join ""
        return @{
            Errors = $errors
            Hours = $hours
            Temp = $temp
        }
    } catch {
        return "Error reading SMART data"
    }
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
    </style>
</head>
<body>
    <div class="container">
        <h1>Statistiques Ordinateur pour Recyclage</h1>
        <p><strong>Date de génération:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>

        <div class="section">
            <h2>Syst&egrave;me</h2>
            <table>
                <tr><th>Marque</th><td>$($system.Brand)</td></tr>
                <tr><th>Mod&egrave;le</th><td>$($system.Model)</td></tr>
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
                $healthClass = if ($smart.Errors -and [int]$smart.Errors -gt 0) { "health-bad" } elseif ($smart.Temp -and [int]$smart.Temp -gt 50) { "health-warning" } else { "health-good" }
                "<div style='margin-bottom: 20px; border: 1px solid #ddd; padding: 10px; border-radius: 5px;'>"
                "<table>"
                "<tr><th>Type</th><td>$($_.Type)</td></tr>"
                "<tr><th>Taille</th><td>$($_.Size)</td></tr>"
                if ($smart -is [hashtable]) {
                    "<tr><th>Erreurs d&eacute;tect&eacute;es (secteurs r&eacute;allou&eacute;s)</th><td class='$healthClass'>$($smart.Errors)</td></tr>"
                    "<tr><th>Nombre d'heures d'utilisation</th><td>$($smart.Hours)</td></tr>"
                    "<tr><th>Temp&eacute;rature actuelle</th><td class='$healthClass'>$($smart.Temp) &deg;C</td></tr>"
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

[System.IO.File]::WriteAllText($path, $html, [System.Text.Encoding]::UTF8)
Write-Host "Rapport généré à $path"