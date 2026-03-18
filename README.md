# CompStats for Recycle

Un script PowerShell amélioré pour générer des statistiques matérielles détaillées sur les ordinateurs utilisés avant recyclage.

## ✨ Nouvelles fonctionnalités (Version améliorée)

### 🔧 Corrections et améliorations
- **RAM intégrée/soudée** : Meilleure détection et affichage pour les systèmes avec RAM non modulaire
- **Données SMART étendues** : Récupération complète des informations de santé des disques (secteurs alloués, en attente, erreurs hors ligne)
- **Rapport de batterie amélioré** : Meilleure lecture des fichiers battery-report.html et informations supplémentaires
- **Année de fabrication** : Extraction automatique de l'année depuis les informations BIOS
- **Résumé exécutif** : Aperçu rapide de l'état général avec alertes visuelles

### 📊 Rapport HTML amélioré
- **Mise en forme moderne** : Styles CSS améliorés avec couleurs d'état
- **Graphiques interactifs** : Graphique en secteurs pour l'état de la batterie
- **Alertes visuelles** : Boîtes d'avertissement pour problèmes critiques
- **Informations détaillées** : Plus de données SMART et meilleures descriptions

## Fonctionnalités complètes

Le script collecte et génère un rapport HTML avec les informations suivantes :

### 🖥️ Système
- Marque et modèle
- **Année de fabrication** (extraction BIOS)
- Nom de l'ordinateur

### ⚡ CPU
- Marque et modèle
- Vitesse maximale

### 💾 RAM
- **Total avec détection intelligente**
- **Support RAM intégrée/soudée**
- Détails par module : statut, marque, modèle, capacité, **vitesse**

### 💿 Disques (SSD/HDD)
- Type et taille
- **Informations détaillées** : modèle, numéro de série, firmware
- **Données SMART complètes** :
  - Secteurs réalloués
  - Secteurs en attente
  - Erreurs hors ligne
  - Heures d'utilisation
  - Température actuelle
  - **Vitesse de rotation** (HDD) ou type SSD
  - **Score de santé global**

### 🔋 Batterie
- Nom de la batterie
- Age approximatif (cycles)
- Capacité constructeur vs mesurée
- **État de santé avec classification** (Excellent/Bon/Attention/Critique)
- **Graphique interactif** de l'état de santé

### 📈 Résumé exécutif
- **Analyse automatique** des problèmes critiques
- **Alertes visuelles** pour batteries faibles ou disques défaillants
- **Recommandations** pour le recyclage

## Utilisation

### 🚀 Lancement rapide
```powershell
.\CompStats.ps1
```

### 📋 Prérequis
- Windows avec PowerShell 5.1+
- **Optionnel** : smartctl.exe pour les données SMART (téléchargement automatique)

### 📄 Fichiers générés
- **Rapport principal** : `YYYY-MM-DD_HH-mm-ss.html` (ouverture directe dans navigateur)
- **Rapport batterie** : `battery-report.html` (généré automatiquement si nécessaire)

### 🔧 Configuration avancée
- Le script génère automatiquement `smartctl.exe` si nécessaire
- Copiez `battery-report.html` existant pour éviter la regeneration
- Modifiez les seuils d'alerte dans le script si besoin

## 📊 Indicateurs de Santé

### 🔋 Batterie
- **> 80%** : Excellent état ✅
- **60-80%** : Bon état ⚠️
- **40-60%** : Attention 🔶
- **< 40%** : Critique ❌

### 💿 Disques (SMART)
- **0 erreur** : Bon état ✅
- **1-9 erreurs** : Attention ⚠️
- **≥ 10 erreurs** : Problématique ❌
- **Température > 50°C** : Avertissement 🌡️

### 🖥️ Températures système
- **CPU/HDD < 50°C** : Normal ✅
- **50-60°C** : Acceptable ⚠️
- **> 60°C** : Élevé ❌

### 🏷️ Classification recyclage
Le rapport inclut un **résumé exécutif** qui classifie automatiquement :
- **État satisfaisant** : Prêt pour réutilisation
- **Avertissements** : Utilisation possible avec monitoring
- **Problèmes critiques** : Recyclage recommandé

## Prérequis

- Windows avec PowerShell 5.1+
- Accès administrateur pour certaines informations CIM
- smartctl.exe pour les données SMART (optionnel, mais recommandé)

## Licence

Libre d'utilisation pour le recyclage d'ordinateurs.