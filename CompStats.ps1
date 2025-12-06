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
    $rams = Get-WmiObject Win32_PhysicalMemory
    $total = ($rams | Measure-Object -Property Capacity -Sum).Sum / 1GB
    $array = Get-WmiObject Win32_PhysicalMemoryArray
    $maxSlots = $array.MemoryDevices
    $occupiedSlots = $rams.Count
    $details = @()
    if ($occupiedSlots -gt 0) {
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
    } else {
        # Soldered or not detected
        $details += @{
            Slot = "Intégré"
            Manufacturer = "Intégré"
            Model = "N/A"
            Capacity = "$([math]::Round($total, 2)) GB"
            Status = "Intégré"
        }
        $maxSlots = 1
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
    try {
        & powercfg /batteryreport /output $tempFile | Out-Null
        if (Test-Path $tempFile) {
            $content = Get-Content $tempFile -Raw
            # Parse HTML for battery info
            $designMatch = $content | Select-String '<span id="DesignCapacity">(.*?)</span>' | ForEach-Object { $_.Matches.Groups[1].Value }
            $fullMatch = $content | Select-String '<span id="FullChargeCapacity">(.*?)</span>' | ForEach-Object { $_.Matches.Groups[1].Value }
            $cycleMatch = $content | Select-String '<span id="CycleCount">(.*?)</span>' | ForEach-Object { $_.Matches.Groups[1].Value }
            if ($designMatch -and $fullMatch) {
                $design = [int]($designMatch -replace '[^0-9]', '')
                $full = [int]($fullMatch -replace '[^0-9]', '')
                $health = if ($design -gt 0) { [math]::Round(($full / $design) * 100, 2) } else { 0 }
                return @{
                    Age = if ($cycleMatch) { "$cycleMatch cycles" } else { "Unknown" }
                    DesignCapacity = "$design mWh"
                    MeasuredCapacity = "$full mWh"
                    Health = "$health%"
                }
            }
        }
    } catch {
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile }
    }
    return "No battery detected"
}

# Function to get SMART data using smartctl.exe
function Get-SMARTData {
    param($deviceID)
    $smartctlPath = $null
    # Check if smartctl is in script directory
    $smartctl = Join-Path $PSScriptRoot "smartctl.exe"
    if (Test-Path $smartctl) {
        $smartctlPath = $smartctl
    } else {
        # Check default installation path
        $defaultPath = "C:\Program Files\smartmontools\bin\smartctl.exe"
        if (Test-Path $defaultPath) {
            $smartctlPath = $defaultPath
        } else {
            # Check if installed in PATH
            try {
                $cmd = Get-Command smartctl -ErrorAction Stop
                $smartctlPath = $cmd.Source
            } catch {
                # Download smartctl.exe
                try {
                    $zipUrl = "https://www.smartmontools.org/files/smartmontools-7.4-1.win32.zip"
                    $zipPath = Join-Path $env:TEMP "smartmontools.zip"
                    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
                    $extractPath = Join-Path $env:TEMP "smartmontools"
                    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                    $sourceSmartctl = Join-Path $extractPath "bin\smartctl.exe"
                    Copy-Item $sourceSmartctl $smartctl
                    $smartctlPath = $smartctl
                    Remove-Item $zipPath, $extractPath -Recurse -Force
                } catch {
                    return "smartctl.exe not found"
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
    $chartScript = ""
    if ($healthValue -match '^\d') {
        $h = [double]$healthValue.Trim('%')
        $healthClass = if ($h -gt 80) { "health-good" } elseif ($h -gt 50) { "health-warning" } else { "health-bad" }
        $chartScript = @"
            <div class="chart-container">
                <canvas id="batteryChart"></canvas>
            </div>
            <script>
                var ctx = document.getElementById('batteryChart').getContext('2d');
                var batteryHealth = $h;
                var batteryData = {
                    labels: ['Santé', 'Perte'],
                    datasets: [{
                        data: [batteryHealth, 100 - batteryHealth],
                        backgroundColor: ['#4CAF50', '#F44336'],
                        borderWidth: 1
                    }]
                };
                var batteryChart = new Chart(ctx, {
                    type: 'doughnut',
                    data: batteryData,
                    options: {
                        responsive: true,
                        plugins: {
                            legend: { position: 'bottom' },
                            title: { display: true, text: '&Eacute;tat de Sant&eacute; de la Batterie' }
                        }
                    }
                });
            </script>
"@
    }
    $batteryHtml = @"
            <table>
                <tr><th>Age approximatif</th><td>$($battery.Age)</td></tr>
                <tr><th>Capacit&eacute; constructeur</th><td>$($battery.DesignCapacity)</td></tr>
                <tr><th>Capacit&eacute; mesur&eacute;e</th><td>$($battery.MeasuredCapacity)</td></tr>
                <tr><th>&Eacute;tat de sant&eacute;</th><td class='$healthClass'>$healthValue</td></tr>
            </table>
            $chartScript
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
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
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
        .chart-container { width: 50%; margin: 20px auto; }
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