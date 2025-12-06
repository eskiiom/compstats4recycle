# CompStats for Recycle

Un script PowerShell pour générer des statistiques matérielles sur les ordinateurs utilisés avant recyclage.

## Fonctionnalités

Le script collecte et génère un rapport HTML avec les informations suivantes :

- **Système** : Marque, modèle, année de fabrication approximative
- **CPU** : Marque, modèle, vitesse maximale
- **RAM** : Total, détails par module (marque, modèle, capacité)
- **Disques** : Type (SSD/HDD), taille, données SMART (erreurs détectées, secteurs défaillants, heures d'utilisation, température actuelle)
- **Batterie** : Age approximatif, capacité constructeur, capacité mesurée, état de santé (avec graphique)

Le rapport HTML est moderne, lisible et inclut des graphiques (état de santé de la batterie).

## Utilisation

1. Téléchargez le script `CompStats.ps1`.
2. Pour les données SMART, téléchargez `smartctl.exe` depuis [smartmontools](https://www.smartmontools.org/) et placez-le dans le même dossier que le script (ou téléchargez l'installateur et extrayez smartctl.exe).
3. Exécutez le script avec PowerShell :
   ```
   powershell.exe -ExecutionPolicy Bypass -File .\CompStats.ps1
   ```
4. Le rapport HTML sera généré dans `c:\compstats4recycle\` avec un nom basé sur la date.

## Indicateurs de Santé

- **Batterie** : Santé < 80% indique un remplacement recommandé.
- **Disques** : Erreurs SMART > 0 ou température > 50°C signalent des problèmes potentiels.
- **Températures** : CPU et HDD devraient être < 60°C en charge normale.

## Prérequis

- Windows avec PowerShell 5.1+
- Accès administrateur pour certaines informations CIM
- smartctl.exe pour les données SMART (optionnel, mais recommandé)

## Licence

Libre d'utilisation pour le recyclage d'ordinateurs.