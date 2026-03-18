# Script de validation syntaxique pour CompStats.ps1
# Vérifie la syntaxe et la structure du script amélioré

param(
    [switch]$Verbose
)

Write-Host "=== VALIDATION SYNTAXIQUE COMPSTATS.PS1 ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: Existence du fichier
if (-not (Test-Path "CompStats.ps1")) {
    Write-Host "❌ ERREUR: CompStats.ps1 non trouvé" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Fichier CompStats.ps1 trouvé" -ForegroundColor Green

# Test 2: Syntaxe PowerShell
try {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile("CompStats.ps1", [ref]$null, [ref]$parseErrors)
    
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Write-Host "❌ ERREURS DE SYNTAXE DÉTECTÉES:" -ForegroundColor Red
        foreach ($parseError in $parseErrors) {
            Write-Host "  Ligne $($parseError.Extent.StartLineNumber): $($parseError.Message)" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "✅ Syntaxe PowerShell valide" -ForegroundColor Green
} catch {
    Write-Host "❌ ERREUR LORS DE LA VÉRIFICATION SYNTAXE: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test 3: Fonctions requises
$scriptContent = Get-Content "CompStats.ps1" -Raw

$requiredFunctions = @(
    @{ Name = "Get-ManufactureYear"; Description = "Extraction année fabrication BIOS" },
    @{ Name = "Get-SystemInfo"; Description = "Informations système étendues" },
    @{ Name = "Get-CPUInfo"; Description = "Informations CPU" },
    @{ Name = "Get-RAMInfo"; Description = "Informations RAM avec support intégré" },
    @{ Name = "Get-HDDInfo"; Description = "Informations disques" },
    @{ Name = "Get-BatteryInfo"; Description = "Informations batterie améliorées" },
    @{ Name = "Get-SMARTData"; Description = "Données SMART étendues" }
)

Write-Host "`n=== VÉRIFICATION DES FONCTIONS ===" -ForegroundColor Yellow
$functionErrors = 0

foreach ($func in $requiredFunctions) {
    if ($scriptContent -match "function $($func.Name)") {
        Write-Host "✅ $($func.Name) - $($func.Description)" -ForegroundColor Green
    } else {
        Write-Host "❌ $($func.Name) - MANQUANTE ($($func.Description))" -ForegroundColor Red
        $functionErrors++
    }
}

# Test 4: Fonctionnalités spécifiques améliorées
Write-Host "`n=== VÉRIFICATION DES AMÉLIORATIONS ===" -ForegroundColor Yellow

$improvements = @(
    @{ Pattern = "IsIntegrated"; Description = "Support RAM intégrée" },
    @{ Pattern = "ErrorCount"; Description = "Comptage erreurs SMART" },
    @{ Pattern = "HealthStatus"; Description = "Classification état santé" },
    @{ Pattern = "Summary.*Box"; Description = "Résumé exécutif" },
    @{ Pattern = "Year.*=.*Get-ManufactureYear"; Description = "Année fabrication" },
    @{ Pattern = "HealthValue"; Description = "Valeur numérique santé" }
)

$improvementErrors = 0

foreach ($improvement in $improvements) {
    if ($scriptContent -match $improvement.Pattern) {
        Write-Host "✅ $($improvement.Description)" -ForegroundColor Green
    } else {
        Write-Host "❌ $($improvement.Description) - NON TROUVÉE" -ForegroundColor Red
        $improvementErrors++
    }
}

# Test 5: Structure HTML
Write-Host "`n=== VÉRIFICATION STRUCTURE HTML ===" -ForegroundColor Yellow

$htmlElements = @(
    @{ Pattern = "<!DOCTYPE html>"; Description = "Déclaration HTML5" },
    @{ Pattern = "chart\.js"; Description = "Graphiques Chart.js" },
    @{ Pattern = "health-good.*color.*#4CAF50"; Description = "Styles CSS améliorés" },
    @{ Pattern = "batteryChart"; Description = "Graphique batterie" },
    @{ Pattern = "Résumé exécutif"; Description = "Section résumé" }
)

$htmlErrors = 0

foreach ($element in $htmlElements) {
    if ($scriptContent -match $element.Pattern) {
        Write-Host "✅ $($element.Description)" -ForegroundColor Green
    } else {
        Write-Host "❌ $($element.Description) - MANQUANT" -ForegroundColor Red
        $htmlErrors++
    }
}

# Test 6: Gestion d'erreurs
Write-Host "`n=== VÉRIFICATION GESTION ERREURS ===" -ForegroundColor Yellow

$errorHandling = @(
    @{ Pattern = "try.*catch"; Description = "Blocs try-catch" },
    @{ Pattern = "Test-Path"; Description = "Vérifications fichiers" },
    @{ Pattern = "Out-Null"; Description = "Suppression sortie" }
)

foreach ($pattern in $errorHandling) {
    if ($scriptContent -match $pattern.Pattern) {
        Write-Host "✅ $($pattern.Description)" -ForegroundColor Green
    } else {
        Write-Host "⚠️  $($pattern.Description) - PARTIELLEMENT IMPLÉMENTÉ" -ForegroundColor Yellow
    }
}

# Résumé final
Write-Host "`n=== RÉSUMÉ DE LA VALIDATION ===" -ForegroundColor Cyan

$totalErrors = $functionErrors + $improvementErrors + $htmlErrors

if ($totalErrors -eq 0) {
    Write-Host "🎉 VALIDATION RÉUSSIE !" -ForegroundColor Green
    Write-Host "Le script CompStats.ps1 est prêt à être exécuté." -ForegroundColor Green
    Write-Host ""
    Write-Host "Pour l'exécuter :" -ForegroundColor White
    Write-Host "powershell.exe -ExecutionPolicy Bypass -File .\CompStats.ps1" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "⚠️  VALIDATION PARTIELLE" -ForegroundColor Yellow
    Write-Host "Erreurs détectées: $totalErrors" -ForegroundColor Red
    Write-Host ""
    Write-Host "Fonctions manquantes: $functionErrors" -ForegroundColor Red
    Write-Host "Améliorations manquantes: $improvementErrors" -ForegroundColor Red
    Write-Host "Éléments HTML manquants: $htmlErrors" -ForegroundColor Red
    exit 1
}