# CompStats for Recycle

Un script PowerShell amélioré pour générer des statistiques matérielles détaillées sur les ordinateurs utilisés avant recyclage.

## ✨ Nouvelles fonctionnalités (Version améliorée)

### 🔧 Corrections et améliorations
- **RAM intégrée/soudée** : Meilleure détection et affichage pour les systèmes avec RAM non modulaire
- **Données SMART étendues** : Récupération complète des informations de santé des disques (secteurs alloués, en attente, erreurs hors ligne)
- **Rapport de batterie amélioré** : Meilleure lecture des fichiers battery-report.html et informations supplémentaires
- **Date de famise a jour du BIOS** : Extraction automatique de la date depuis les informations BIOS
- **Résumé exécutif** : Aperçu rapide de l'état général avec alertes visuelles

### 📊 Rapport HTML amélioré
- **Mise en forme moderne** : Styles CSS améliorés avec couleurs d'état
- **Alertes visuelles** : Boîtes d'avertissement pour problèmes critiques
- **Informations détaillées** : Plus de données SMART et meilleures descriptions

## Fonctionnalités complètes

Le script collecte et génère un rapport HTML avec les informations suivantes :

### 🖥️ Système
- Marque et modèle
- **Date de mise a jour du BIOS** (extraction BIOS)
- **Numéro de série**
- **Date BIOS**

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
  - **Niveau d'usure SSD** (24% used, etc.)

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
- **Rapport principal** : `Marque_Modele_NumeroSerie_YYYY-MM-DD_CS4Rv1.0.html` (nommage automatique avec identifiant unique)
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

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)

Ce script fait partie du projet [CompStats for Recycle](https://github.com/eskiiom/compstats4recycle).

Libre d'utilisation pour le recyclage d'ordinateurs.

---

*Version 1.0 - Dernière modification : 2026-03-16*