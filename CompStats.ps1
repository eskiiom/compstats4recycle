#Requires -Version 5.1

# CompStats for Recycle - PowerShell Script to Generate Hardware Statistics
# Generates an HTML report with system, CPU, RAM, HDD (with SMART), and Battery info

param()

# Function to get system information
function Get-SystemInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $year = if ($bios.ReleaseDate) { $bios.ReleaseDate.Year } else { "Unknown" }
    return @{
        Brand = $cs.Manufacturer
        Model = $cs.Model
        Year = $year
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
    $details = $rams | ForEach-Object {
        @{
            Manufacturer = $_.Manufacturer
            Model = $_.PartNumber
            Capacity = "$([math]::Round($_.Capacity / 1GB, 2)) GB"
        }
    }
    return @{
        Total = "$([math]::Round($total, 2)) GB"
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

# Function to get battery information
function Get-BatteryInfo {
    $battery = Get-CimInstance Win32_Battery
    if ($battery) {
        $design = $battery.DesignCapacity
        $full = $battery.FullChargeCapacity
        $health = if ($design -gt 0) { [math]::Round(($full / $design) * 100, 2) } else { 0 }
        $installDate = $battery.InstallDate
        $age = if ($installDate) { (Get-Date) - $installDate; "$($age.Days) days" } else { "Unknown" }
        return @{
            Age = $age
            DesignCapacity = "$design mWh"
            MeasuredCapacity = "$full mWh"
            Health = "$health%"
        }
    } else {
        return "No battery detected"
    }
}

# Function to get SMART data using smartctl.exe (must be in script directory)
function Get-SMARTData {
    param($deviceID)
    $smartctl = Join-Path $PSScriptRoot "smartctl.exe"
    if (Test-Path $smartctl) {
        try {
            $output = & $smartctl -a "\\.\PHYSICALDRIVE$deviceID" 2>$null
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
    } else {
        return "smartctl.exe not found in script directory"
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
$path = "c:\compstats4recycle\$date.html"
New-Item -Path "c:\compstats4recycle" -ItemType Directory -Force | Out-Null

# Prepare battery HTML
if ($battery -is [hashtable]) {
    $batteryHtml = @"
            <table>
                <tr><th>Age approximatif</th><td>$($battery.Age)</td></tr>
                <tr><th>Capacité constructeur</th><td>$($battery.DesignCapacity)</td></tr>
                <tr><th>Capacité mesurée</th><td>$($battery.MeasuredCapacity)</td></tr>
                <tr><th>État de santé</th><td class='$(if ([double]$battery.Health.Trim('%') -gt 80) { "health-good" } elseif ([double]$battery.Health.Trim('%') -gt 50) { "health-warning" } else { "health-bad" })'>$($battery.Health)</td></tr>
            </table>
            <div class="chart-container">
                <canvas id="batteryChart"></canvas>
            </div>
            <script>
                var ctx = document.getElementById('batteryChart').getContext('2d');
                var batteryHealth = $([double]$battery.Health.Trim('%'));
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
                            title: { display: true, text: 'État de Santé de la Batterie' }
                        }
                    }
                });
            </script>
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
            <h2>Système</h2>
            <table>
                <tr><th>Marque</th><td>$($system.Brand)</td></tr>
                <tr><th>Modèle</th><td>$($system.Model)</td></tr>
                <tr><th>Année de fabrication (approx.)</th><td>$($system.Year)</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>CPU</h2>
            <table>
                <tr><th>Marque</th><td>$($cpu.Brand)</td></tr>
                <tr><th>Modèle</th><td>$($cpu.Model)</td></tr>
                <tr><th>Vitesse maximale</th><td>$($cpu.Speed)</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>RAM</h2>
            <p><strong>Total:</strong> $($ram.Total)</p>
            <table>
                <tr><th>Marque</th><th>Modèle</th><th>Capacité</th></tr>
                $($ram.Modules | ForEach-Object { "<tr><td>$($_.Manufacturer)</td><td>$($_.Model)</td><td>$($_.Capacity)</td></tr>" })
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
                    "<tr><th>Erreurs détectées (secteurs réalloués)</th><td class='$healthClass'>$($smart.Errors)</td></tr>"
                    "<tr><th>Nombre d'heures d'utilisation</th><td>$($smart.Hours)</td></tr>"
                    "<tr><th>Température actuelle</th><td class='$healthClass'>$($smart.Temp) °C</td></tr>"
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
            <h2>Indicateurs de Santé Générale</h2>
            <ul>
                <li><strong>Batterie:</strong> Si la santé est en dessous de 80%, considérer le remplacement.</li>
                <li><strong>Disques:</strong> Erreurs SMART > 0 ou température > 50°C indiquent des problèmes potentiels.</li>
                <li><strong>RAM/CPU:</strong> Pas d'indicateurs directs, mais vérifier la compatibilité et les performances.</li>
                <li><strong>Températures:</strong> CPU et HDD devraient être < 60°C sous charge normale.</li>
            </ul>
        </div>
    </div>
</body>
</html>
"@

Set-Content -Path $path -Value $html -Encoding UTF8
Write-Host "Rapport généré à $path"