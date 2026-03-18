# Guide d'Exécution - CompStats.ps1

## 🚀 Comment exécuter le script

### Méthode 1 : PowerShell (Recommandée)
```powershell
# Ouvrir PowerShell en tant qu'administrateur
# Naviguer vers le dossier contenant CompStats.ps1
cd "C:\chemin\vers\compstats4recycle"

# Exécuter le script
.\CompStats.ps1
```

### Méthode 2 : PowerShell avec politique d'exécution
```powershell
# Si erreur de politique d'exécution
powershell.exe -ExecutionPolicy Bypass -File .\CompStats.ps1
```

### Méthode 3 : Double-clic
- Copier `CompStats.ps1` sur le Bureau
- Double-cliquer sur le fichier
- Choisir "Ouvrir avec" → PowerShell

## 📋 Prérequis
- Windows 10/11
- PowerShell 5.1 ou supérieur
- Droits administrateur (recommandé)
- Connexion Internet (pour téléchargement smartctl.exe si nécessaire)

## 🔧 En cas de problème

### Erreur "Execution of scripts is disabled"
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Erreur "smartctl.exe not found"
Le script téléchargera automatiquement smartctl.exe depuis smartmontools.org
- Assurez-vous d'avoir une connexion Internet
- Si le téléchargement échoue, téléchargez manuellement depuis : https://www.smartmontools.org/

### Erreur "Access denied"
- Exécutez PowerShell en tant qu'administrateur
- Vérifiez les permissions du dossier

### Problème de batterie
Le script cherche d'abord un fichier `battery-report.html` existant
- Si absent, il en générera un automatiquement avec `powercfg /batteryreport`
- Assurez-vous que l'ordinateur a une batterie

## 📊 Sortie attendue

Le script génère :
1. **Messages console** : Informations sur l'avancement
2. **Fichier HTML** : Rapport complet avec nom `YYYY-MM-DD_HH-mm-ss.html`
3. **Fichier batterie** : `battery-report.html` (si généré)

## 🐛 Dépannage avancé

### Vérifier la syntaxe
```powershell
# Tester la syntaxe sans exécuter
powershell.exe -Command "Get-Command Test-Path; exit 0" -File CompStats.ps1 -Syntax
```

### Mode debug
Modifiez la première ligne du script pour activer le debug :
```powershell
# Remplacer :
param()

# Par :
param([switch]$Debug)
$DebugPreference = if ($Debug) { "Continue" } else { "SilentlyContinue" }
```

Puis exécutez :
```powershell
.\CompStats.ps1 -Debug
```

### Logs détaillés
Le script affiche maintenant des messages informatifs :
- "Utilisation du rapport de batterie existant"
- "Génération d'un nouveau rapport de batterie"
- "Rapport généré à [chemin]"

## ✅ Validation du succès

Le script a fonctionné si vous voyez :
1. Messages de progression dans la console
2. Un fichier HTML créé dans le dossier
3. Aucune erreur fatale

Ouvrez le fichier HTML pour voir le rapport complet avec les graphiques.