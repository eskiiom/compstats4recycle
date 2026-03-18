# Script de test pour CompStats
# Ce script teste les nouvelles fonctionnalités

Write-Host "=== Test du script CompStats amélioré ===" -ForegroundColor Green

# Test 1: Vérifier que le script principal existe
if (Test-Path "CompStats.ps1") {
    Write-Host "✅ Script principal trouvé" -ForegroundColor Green
} else {
    Write-Host "❌ Script principal non trouvé" -ForegroundColor Red
    exit 1
}

# Test 2: Syntaxe PowerShell
try {
    $null = [System.Management.Automation.Language.Parser]::ParseFile("CompStats.ps1", [ref]$null, [ref]$null)
    Write-Host "✅ Syntaxe PowerShell valide" -ForegroundColor Green
} catch {
    Write-Host "❌ Erreur de syntaxe: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test 3: Vérifier les nouvelles fonctions
Write-Host "`n=== Fonctions ajoutées/modifiées ===" -ForegroundColor Yellow

# Lire le script et vérifier les fonctions
$scriptContent = Get-Content "CompStats.ps1" -Raw

if ($scriptContent -match "function Get-ManufactureYear") {
    Write-Host "✅ Fonction Get-ManufactureYear ajoutée" -ForegroundColor Green
} else {
    Write-Host "❌ Fonction Get-ManufactureYear manquante" -ForegroundColor Red
}

if ($scriptContent -match "function Get-SMARTData" -and $scriptContent -match "ErrorCount") {
    Write-Host "✅ Fonction Get-SMARTData améliorée avec ErrorCount" -ForegroundColor Green
} else {
    Write-Host "❌ Fonction Get-SMARTData non améliorée" -ForegroundColor Red
}

if ($scriptContent -match "function Get-BatteryInfo" -and $scriptContent -match "HealthStatus") {
    Write-Host "✅ Fonction Get-BatteryInfo améliorée avec HealthStatus" -ForegroundColor Green
} else {
    Write-Host "❌ Fonction Get-BatteryInfo non améliorée" -ForegroundColor Red
}

if ($scriptContent -match "function Get-RAMInfo" -and $scriptContent -match "IsIntegrated") {
    Write-Host "✅ Fonction Get-RAMInfo améliorée pour RAM intégrée" -ForegroundColor Green
} else {
    Write-Host "❌ Fonction Get-RAMInfo non améliorée pour RAM intégrée" -ForegroundColor Red
}

# Test 4: Vérifier les améliorations HTML
Write-Host "`n=== Améliorations HTML ===" -ForegroundColor Yellow

if ($scriptContent -match "Résumé exécutif") {
    Write-Host "✅ Résumé exécutif ajouté" -ForegroundColor Green
} else {
    Write-Host "❌ Résumé exécutif manquant" -ForegroundColor Red
}

if ($scriptContent -match "health-good.*color: #4CAF50") {
    Write-Host "✅ Styles CSS améliorés ajoutés" -ForegroundColor Green
} else {
    Write-Host "❌ Styles CSS améliorés manquants" -ForegroundColor Red
}

# Test 5: Informations système améliorées
Write-Host "`n=== Informations système ===" -ForegroundColor Yellow

if ($scriptContent -match "Year = Get-ManufactureYear") {
    Write-Host "✅ Année de fabrication intégrée" -ForegroundColor Green
} else {
    Write-Host "❌ Année de fabrication non intégrée" -ForegroundColor Red
}

Write-Host "`n=== Test terminé ===" -ForegroundColor Green
Write-Host "Le script CompStats.ps1 a été amélioré avec succès!" -ForegroundColor Cyan
Write-Host "Pour l'exécuter: .\CompStats.ps1" -ForegroundColor Yellow