# Script de validation syntaxique pour CompStats.ps1
# Verifie la syntaxe et la structure du script

param(
    [switch]$Verbose
)

Write-Host "=== VALIDATION SYNTAXIQUE COMPSTATS.PS1 ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: Existence du fichier
if (-not (Test-Path "CompStats.ps1")) {
    Write-Host "ERREUR: CompStats.ps1 non trouve" -ForegroundColor Red
    exit 1
}
Write-Host "OK - Fichier CompStats.ps1 trouve" -ForegroundColor Green

# Test 2: Syntaxe PowerShell
try {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile("CompStats.ps1", [ref]$null, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Write-Host "ERREURS DE SYNTAXE DETECTEES:" -ForegroundColor Red
        foreach ($parseError in $parseErrors) {
            Write-Host "  Ligne $($parseError.Extent.StartLineNumber): $($parseError.Message)" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "OK - Syntaxe PowerShell valide" -ForegroundColor Green
} catch {
    Write-Host "ERREUR LORS DE LA VERIFICATION SYNTAXE: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test 3: Fonctions requises
$scriptContent = Get-Content "CompStats.ps1" -Raw

$requiredFunctions = @(
    @{ Name = "Get-SystemInfo"; Description = "Informations systeme (marque, modele, numero de serie, date BIOS)" },
    @{ Name = "Get-CPUInfo"; Description = "Informations CPU" },
    @{ Name = "Get-GPUInfo"; Description = "Informations carte(s) graphique(s)" },
    @{ Name = "Get-RAMInfo"; Description = "Informations RAM avec slots et modules" },
    @{ Name = "Get-HDDInfo"; Description = "Informations disques" },
    @{ Name = "Get-BatteryInfo"; Description = "Informations batterie (sante, capacite, cycles)" },
    @{ Name = "Get-SMARTData"; Description = "Donnees SMART (smartctl ou fallback WMI)" },
    @{ Name = "Get-GlobalAssessment"; Description = "Score global et recommandation de recyclage" },
    @{ Name = "ConvertTo-HtmlSafe"; Description = "Encodage HTML des valeurs materielles" },
    @{ Name = "Get-SmartNumericValue"; Description = "Extraction correcte des valeurs SMART (ATA et NVMe)" },
    @{ Name = "Get-Windows11Compatibility"; Description = "Verification indicative de compatibilite Windows 11" },
    @{ Name = "Get-WindowsProductKey"; Description = "Cle de licence Windows embarquee au BIOS" },
    @{ Name = "Get-NetworkInfo"; Description = "Adresses MAC des interfaces reseau" },
    @{ Name = "Get-EncryptionInfo"; Description = "Statut de chiffrement BitLocker des volumes" }
)

Write-Host "`n=== VERIFICATION DES FONCTIONS ===" -ForegroundColor Yellow
$functionErrors = 0

foreach ($func in $requiredFunctions) {
    if ($scriptContent -match "function $($func.Name)") {
        Write-Host "OK - $($func.Name) - $($func.Description)" -ForegroundColor Green
    } else {
        Write-Host "MANQUANTE - $($func.Name) ($($func.Description))" -ForegroundColor Red
        $functionErrors++
    }
}

# Test 4: Fonctionnalites cles du script
Write-Host "`n=== VERIFICATION DES FONCTIONNALITES ===" -ForegroundColor Yellow

$features = @(
    @{ Pattern = "HealthStatus"; Description = "Classification etat de sante batterie" },
    @{ Pattern = "HealthValue"; Description = "Valeur numerique de sante batterie" },
    @{ Pattern = "WearLevel"; Description = "Niveau d'usure SSD" },
    @{ Pattern = "summary-card"; Description = "Resume executif dans le rapport" },
    @{ Pattern = "\`$reportsDir"; Description = "Sortie des rapports dans le dossier Rapports/" },
    @{ Pattern = "\[switch\]\`$Silent"; Description = "Mode -Silent (execution non-interactive)" },
    @{ Pattern = "\[switch\]\`$NoJson"; Description = "Export JSON (option -NoJson pour desactiver)" },
    @{ Pattern = "\[switch\]\`$NoCsvLog"; Description = "Journal CSV consolide (option -NoCsvLog pour desactiver)" },
    @{ Pattern = "Integrated"; Description = "Detection RAM integree/soudee" },
    @{ Pattern = "SpindleSpeed"; Description = "Vitesse de rotation des disques" },
    @{ Pattern = "ConvertTo-Json"; Description = "Export JSON par machine" },
    @{ Pattern = "Export-Csv"; Description = "Journal CSV consolide" },
    @{ Pattern = "qwMemorySize"; Description = "VRAM precise via le registre (contourne le plafond 4GB de AdapterRAM)" },
    @{ Pattern = "smartctlMissing"; Description = "Aide contextuelle si smartctl est absent" },
    @{ Pattern = "\[string\]\`$AssetTag"; Description = "Reference inventaire optionnelle (-AssetTag)" },
    @{ Pattern = "AccessDenied"; Description = "Distinction chiffrement non verifie / non chiffre" }
)

$featureErrors = 0

foreach ($feature in $features) {
    if ($scriptContent -match $feature.Pattern) {
        Write-Host "OK - $($feature.Description)" -ForegroundColor Green
    } else {
        Write-Host "NON TROUVEE - $($feature.Description)" -ForegroundColor Red
        $featureErrors++
    }
}

# Test 5: Structure HTML
Write-Host "`n=== VERIFICATION STRUCTURE HTML ===" -ForegroundColor Yellow

$htmlElements = @(
    @{ Pattern = "<!DOCTYPE html>"; Description = "Declaration HTML5" },
    @{ Pattern = "status-badge"; Description = "Badges de statut (OK/Attention/KO)" },
    @{ Pattern = "health-good"; Description = "Styles CSS d'etat de sante" }
)

$htmlErrors = 0

foreach ($element in $htmlElements) {
    if ($scriptContent -match $element.Pattern) {
        Write-Host "OK - $($element.Description)" -ForegroundColor Green
    } else {
        Write-Host "MANQUANT - $($element.Description)" -ForegroundColor Red
        $htmlErrors++
    }
}

# Test 6: Gestion d'erreurs
Write-Host "`n=== VERIFICATION GESTION ERREURS ===" -ForegroundColor Yellow

$errorHandling = @(
    @{ Pattern = "try\s*\{"; Description = "Blocs try-catch" },
    @{ Pattern = "Test-Path"; Description = "Verifications fichiers" },
    @{ Pattern = "-ErrorAction Stop"; Description = "Appels CIM/WMI proteges" }
)

foreach ($pattern in $errorHandling) {
    if ($scriptContent -match $pattern.Pattern) {
        Write-Host "OK - $($pattern.Description)" -ForegroundColor Green
    } else {
        Write-Host "PARTIELLEMENT IMPLEMENTE - $($pattern.Description)" -ForegroundColor Yellow
    }
}

# Resume final
Write-Host "`n=== RESUME DE LA VALIDATION ===" -ForegroundColor Cyan

$totalErrors = $functionErrors + $featureErrors + $htmlErrors

if ($totalErrors -eq 0) {
    Write-Host "VALIDATION REUSSIE" -ForegroundColor Green
    Write-Host "Le script CompStats.ps1 est pret a etre execute." -ForegroundColor Green
    Write-Host ""
    Write-Host "Pour l'executer :" -ForegroundColor White
    Write-Host "powershell.exe -ExecutionPolicy Bypass -File .\CompStats.ps1" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "VALIDATION PARTIELLE" -ForegroundColor Yellow
    Write-Host "Erreurs detectees: $totalErrors" -ForegroundColor Red
    Write-Host ""
    Write-Host "Fonctions manquantes: $functionErrors" -ForegroundColor Red
    Write-Host "Fonctionnalites manquantes: $featureErrors" -ForegroundColor Red
    Write-Host "Elements HTML manquants: $htmlErrors" -ForegroundColor Red
    exit 1
}
