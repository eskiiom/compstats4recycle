# CompStats for Recycle

Un script PowerShell amélioré pour générer des statistiques matérielles détaillées sur les ordinateurs utilisés avant recyclage.

## ✨ Nouvelles fonctionnalités (Version améliorée)

### 🔧 Corrections et améliorations
- **Données SMART** : secteurs réalloués, heures d'utilisation, température, niveau d'usure SSD, modèle/série/firmware
- **Rapport de batterie amélioré** : Meilleure lecture des fichiers battery-report.html et informations supplémentaires
- **Date du BIOS** : Extraction automatique de la date depuis les informations BIOS
- **Résumé exécutif** : Aperçu rapide de l'état général avec badges visuels et score global
- **Détection SMART multi-disques fiabilisée** : le mapping de périphérique et le choix du protocole (SATA/NVMe) suivent désormais le bus réel de chaque disque au lieu de supposer un ordre fixe
- **Gestion d'erreurs** : les échecs de lecture WMI/CIM produisent un rapport partiel au lieu de faire planter le script
- **Mode `-Silent`** : traitement d'un parc de machines sans prompt d'élévation à chaque poste
- **Exports JSON et CSV** : en plus du HTML, pour un traitement scripté ou le tri d'un lot de machines

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
- **Clé de licence Windows embarquée au BIOS** (si présente — courant sur les machines OEM depuis Windows 8), utile pour une réinstallation lors de la revente
- **Compatibilité Windows 11** (indicative) : TPM, Secure Boot, RAM, stockage — avec un verdict distinct pour "non compatible" et "indéterminé" (TPM/Secure Boot nécessitent les droits administrateur pour être vérifiés)

### 🌐 Réseau
- Adresses MAC des interfaces physiques (Ethernet/WiFi), un identifiant matériel supplémentaire utile pour le suivi d'inventaire

### ⚡ CPU
- Marque et modèle
- Vitesse maximale

### 🎮 Carte(s) graphique(s)
- Une entrée par contrôleur vidéo (intégré **et** dédié sur les portables qui ont les deux)
- Modèle, mémoire vidéo, version et date du pilote, résolution actuelle
- **Mémoire vidéo précise** lue depuis le registre du pilote : `Win32_VideoController.AdapterRAM`
  est un champ 32 bits qui plafonne/tronque à ~4 Go sur les GPU récents (ex. une carte 6 Go
  s'affichait à tort comme 4 Go) — le script lit `HardwareInformation.qwMemorySize` en repli

### 💾 RAM
- **Total et nombre de slots** (occupés/vides)
- Détails par module : statut, marque, modèle, capacité
- **Détection RAM intégrée/soudée** : si aucun module n'est visible via SMBIOS (fréquent sur les portables récents), le rapport l'indique explicitement au lieu d'afficher un tableau vide

### 💿 Disques (SSD/HDD)
- Type, taille et **vitesse de rotation** (RPM pour un HDD, "N/A (SSD)" sinon)
- **Informations détaillées** : modèle, numéro de série, firmware (via `smartctl` ou, à défaut, le fallback WMI)
- **Données SMART** (via `smartctl`, avec repli WMI si indisponible) :
  - Secteurs réalloués
  - Heures d'utilisation
  - Température actuelle
  - **Niveau d'usure SSD** (24% used, etc.)
- Détection fiabilisée sur plusieurs disques : le protocole SMART (SATA/NVMe) suit le bus réel de chaque disque au lieu de supposer un ordre fixe

### 🔒 Chiffrement (BitLocker)
- Statut de chiffrement par volume — savoir qu'un disque est chiffré *avant* de l'effacer évite de se retrouver bloqué sans clé de récupération
- Nécessite les droits administrateur : sans eux, le rapport l'indique explicitement (`Statut non vérifié`) plutôt que d'afficher à tort "non chiffré"

### 🔋 Batterie
- Nom de la batterie
- Age approximatif (cycles)
- Capacité constructeur vs mesurée
- **État de santé avec classification** (Excellent/Bon/Attention/Critique)

### 📈 Résumé exécutif
- **Aperçu synthétique** en tête de rapport (modèle, état des disques, état de la batterie)
- **Badges colorés** (OK / Attention / KO) par disque et pour la batterie
- **Score global sur 100** agrégeant disques et batterie, avec une recommandation
  (Réemploi possible / Vérifier avant réemploi / Recyclage recommandé)

## Utilisation

### 🚀 Lancement rapide
```powershell
.\CompStats.ps1
```

### ⚙️ Paramètres
| Paramètre         | Effet |
|-------------------|-------|
| `-Silent`         | Ne demande pas l'élévation admin (utile pour traiter un parc de machines sans surveiller chaque poste) |
| `-NoJson`         | N'écrit pas l'export JSON par machine |
| `-NoCsvLog`       | N'ajoute pas de ligne au CSV consolidé |
| `-AssetTag "REF"` | Optionnel — référence d'inventaire interne, ajoutée au nom de fichier, au CSV et au JSON |

```powershell
.\CompStats.ps1 -Silent
.\CompStats.ps1 -AssetTag "REF-1234"
```

### 📋 Prérequis
- Windows avec PowerShell 5.1+
- **Optionnel** : `smartctl.exe` pour les données SMART complètes (voir ci-dessous)

### 📄 Fichiers générés
- **Rapport HTML** : `Rapports\[RéférenceInventaire_]Marque_Modele_NumeroSerie_YYYY-MM-DD_CS4Rv1.6.html` (nommage automatique, dossier créé automatiquement ; le préfixe de référence n'apparaît que si `-AssetTag` est fourni)
- **Export JSON** : même nom que le rapport HTML avec l'extension `.json` — toutes les données collectées, pour un traitement scripté (désactivable avec `-NoJson`)
- **CSV consolidé** : `Rapports\resume.csv`, une ligne ajoutée à chaque exécution — pratique pour trier un lot de machines d'un coup d'œil (désactivable avec `-NoCsvLog`)
- **Rapport batterie** : `battery-report.html` (généré à la racine du script, réutilisé s'il a moins de 24h)

### 🔧 Configuration avancée
- `smartctl.exe` n'est **pas** téléchargé automatiquement (le script ne télécharge et n'exécute aucun binaire externe). Pour des données SMART complètes, installez smartmontools (l'installateur Windows `smartmontools-x.x.win32-setup.exe`) depuis [GitHub](https://github.com/smartmontools/smartmontools/releases/latest) (le site officiel [smartmontools.org](https://www.smartmontools.org/) est parfois inaccessible derrière sa protection anti-bot) — le script détecte automatiquement `smartctl.exe` dans `C:\Program Files\smartmontools\bin\`, aucune copie manuelle nécessaire. Sans lui, le script utilise un repli WMI (données plus limitées mais fonctionnel) ; le rapport HTML affiche alors lui-même un rappel de ces étapes (section Disques Durs, bloc repliable)
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
(vert = OK, orange = Attention, rouge = KO), ainsi qu'un score global sur 100 :
- **≥ 80** : Bon état — Réemploi possible ✅
- **50-79** : Attention — Vérifier avant réemploi ⚠️
- **< 50** : Critique — Recyclage recommandé ❌

## Prérequis

- Windows avec PowerShell 5.1+
- Accès administrateur pour certaines informations CIM
- smartctl.exe pour les données SMART (optionnel, mais recommandé)

## Licence

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)

Ce script fait partie du projet [CompStats for Recycle](https://github.com/eskiiom/compstats4recycle).

Libre d'utilisation pour le recyclage d'ordinateurs.

---

*Version 1.6 - Dernière modification : 2026-09-09*