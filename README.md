# CompStats for Recycle

Un script PowerShell amélioré pour générer des statistiques matérielles détaillées sur les ordinateurs utilisés avant recyclage.

## ✨ Nouvelles fonctionnalités (Version améliorée)

### 🔧 Corrections et améliorations
- **Données SMART** : secteurs réalloués, heures d'utilisation, température, niveau d'usure SSD
- **Rapport de batterie amélioré** : Meilleure lecture des fichiers battery-report.html et informations supplémentaires
- **Date du BIOS** : Extraction automatique de la date depuis les informations BIOS
- **Résumé exécutif** : Aperçu rapide de l'état général avec badges visuels
- **Détection SMART multi-disques fiabilisée** : le mapping de périphérique et le choix du protocole (SATA/NVMe) suivent désormais le bus réel de chaque disque au lieu de supposer un ordre fixe
- **Gestion d'erreurs** : les échecs de lecture WMI/CIM produisent un rapport partiel au lieu de faire planter le script

### 📊 Rapport HTML amélioré
- **Mise en forme moderne** : Styles CSS améliorés avec couleurs d'état
- **Badges visuels** : Statut OK / Attention / KO par composant
- **Informations détaillées** : Plus de données SMART et meilleures descriptions

## Fonctionnalités complètes

Le script collecte et génère un rapport HTML avec les informations suivantes :

### 🖥️ Système
- Marque et modèle
- **Numéro de série**
- **Date du BIOS** (extraction automatique)

### ⚡ CPU
- Marque et modèle
- Vitesse maximale

### 💾 RAM
- **Total et nombre de slots** (occupés/vides)
- Détails par module : statut, marque, modèle, capacité

### 💿 Disques (SSD/HDD)
- Type et taille
- **Informations détaillées** : modèle, numéro de série, firmware (via le fallback WMI, quand `smartctl` ne les fournit pas)
- **Données SMART** (via `smartctl`, avec repli WMI si indisponible) :
  - Secteurs réalloués
  - Heures d'utilisation
  - Température actuelle
  - **Niveau d'usure SSD** (24% used, etc.)

### 🔋 Batterie
- Nom de la batterie
- Age approximatif (cycles)
- Capacité constructeur vs mesurée
- **État de santé avec classification** (Excellent/Bon/Attention/Critique)

### 📈 Résumé exécutif
- **Aperçu synthétique** en tête de rapport (modèle, état des disques, état de la batterie)
- **Badges colorés** (OK / Attention / KO) par disque et pour la batterie

## Utilisation

### 🚀 Lancement rapide
```powershell
.\CompStats.ps1
```

### 📋 Prérequis
- Windows avec PowerShell 5.1+
- **Optionnel** : smartctl.exe pour les données SMART (téléchargement automatique)

### 📄 Fichiers générés
- **Rapport principal** : `Rapports\Marque_Modele_NumeroSerie_YYYY-MM-DD_CS4Rv1.0.html` (nommage automatique avec identifiant unique, dossier créé automatiquement)
- **Rapport batterie** : `battery-report.html` (généré à la racine du script, réutilisé s'il a moins de 24h)

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

### 🏷️ Lecture rapide
Le résumé exécutif en tête de rapport affiche un badge par disque et pour la batterie
(vert = OK, orange = Attention, rouge = KO) pour repérer d'un coup d'œil les composants
à surveiller avant réemploi ou recyclage.

## Prérequis

- Windows avec PowerShell 5.1+
- Accès administrateur pour certaines informations CIM
- smartctl.exe pour les données SMART (optionnel, mais recommandé)

## Licence

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)

Ce script fait partie du projet [CompStats for Recycle](https://github.com/eskiiom/compstats4recycle).

Libre d'utilisation pour le recyclage d'ordinateurs.

---

*Version 1.1 - Dernière modification : 2026-09-09*