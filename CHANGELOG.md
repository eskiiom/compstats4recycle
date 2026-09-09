# Changelog - CompStats for Recycle

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

## [1.3.0] - 2026-09-09

### ✨ Ajouté
- **Section Carte graphique** : une entrée par contrôleur vidéo détecté (intégré et dédié), avec modèle, mémoire vidéo, version/date du pilote et résolution actuelle ; incluse dans le rapport HTML, l'export JSON et la colonne GPU du CSV consolidé
- **Mémoire vidéo précise** : `Win32_VideoController.AdapterRAM` est un champ 32 bits qui plafonne/tronque à ~4 Go sur les GPU récents (une carte 6 Go remontait 4 Go) ; le script lit désormais `HardwareInformation.qwMemorySize` dans le registre du pilote en repli

### 🐛 Corrigé
- **Énumération registre robuste** : la première version de la lecture registre utilisait `-ErrorAction Stop`, ce qui faisait échouer la détection de VRAM précise pour *toutes* les cartes dès qu'une seule sous-clé était inaccessible (retour silencieux à la valeur tronquée) ; corrigé pour ignorer une sous-clé illisible sans abandonner les autres

---

## [1.2.0] - 2026-09-09

### ✨ Ajouté
- **Score global de recyclage** (0-100) agrégeant l'état des disques et de la batterie, avec une recommandation (Réemploi possible / Vérifier avant réemploi / Recyclage recommandé), affiché dans le résumé exécutif du rapport
- **Détection de la RAM intégrée/soudée** : quand `Win32_PhysicalMemory` ne remonte aucun module (fréquent sur les portables récents), le rapport l'indique explicitement au lieu d'afficher un tableau vide ou un total à 0 GB
- **Vitesse de rotation des disques** (RPM) affichée pour les HDD, "N/A (SSD)" pour les SSD
- **Modèle/série/firmware des disques** désormais récupérés aussi via `smartctl` (pas seulement le fallback WMI), pour un rapport homogène quel que soit le chemin de collecte
- **Export JSON par machine** (même nom que le rapport HTML, extension `.json`) pour un traitement scripté ; désactivable avec `-NoJson`
- **CSV consolidé** (`Rapports\resume.csv`, une ligne ajoutée par exécution) pour trier un lot de machines d'un coup d'œil ; désactivable avec `-NoCsvLog`
- **Mode `-Silent`** : saute le prompt d'élévation admin interactif, pour traiter un parc de machines sans surveiller chaque poste

### 🐛 Corrigé
- **Encodage HTML des valeurs matérielles** : marque/modèle/numéro de série système, CPU, RAM et disques sont maintenant échappés avant insertion dans le rapport (un caractère `<` ou `&` dans un firmware ou un numéro de série ne casse plus le rendu)
- **Tableau de disques toujours cohérent** : une machine à un seul disque ne produisait pas un tableau à un élément mais un objet isolé côté JSON (artefact du dépliage automatique des tableaux à un élément par PowerShell) ; corrigé en forçant le typage tableau à l'appel de `Get-HDDInfo`

### 🔧 Modifié
- Suppression du code mort qui activait TLS 1.2 pour un téléchargement automatique de `smartctl.exe` qui n'a jamais existé ; le script n'a jamais téléchargé ni exécuté de binaire externe. Le README a été corrigé en conséquence et pointe vers une installation manuelle (smartmontools)

---

## [1.1.0] - 2026-09-09

### 🐛 Corrigé
- **Détection SMART multi-disques** : le mapping vers `/dev/sdX` était figé sur 2 disques et retombait sur `/dev/sda` (donc sur les données du disque 0) pour tout disque au-delà ; il est maintenant calculé dynamiquement pour n'importe quel nombre de disques
- **Choix du protocole SMART** : l'ordre `sat`/`nvme`/`ata` supposait à tort que le disque 0 est toujours SATA et les suivants NVMe ; il suit maintenant le `BusType` réel remonté par `Get-PhysicalDisk`
- **Encodage des accents dans le rapport HTML** : le script n'avait pas de BOM UTF-8, ce qui faisait lire ses chaînes accentuées littérales avec l'encodage ANSI système sous Windows PowerShell 5.1 (`Résumé` devenait `RÃ©sumÃ©`)
- **Organisation des rapports** : les rapports HTML sont maintenant écrits dans `Rapports\` (créé automatiquement) au lieu de la racine du script

### 🔧 Modifié
- **Robustesse** : `Get-SystemInfo`, `Get-CPUInfo`, `Get-RAMInfo`, `Get-HDDInfo` sont protégées par `try/catch` — un échec CIM/WMI produit désormais un rapport partiel avec avertissement plutôt qu'un plantage complet
- **Scripts de test** : `validation-syntax.ps1` réécrit pour vérifier les fonctions/fonctionnalités réellement présentes dans le script ; `test-script.ps1` (doublon obsolète testant des fonctionnalités disparues) supprimé
- **Documentation** : README nettoyé des fonctionnalités documentées mais jamais implémentées (graphique Chart.js, RAM soudée, score de santé global, vitesse de rotation HDD, etc.)

---

## [1.0.0] - 2026-03-16

### ✨ Ajouté
- **Version 1.0** : Publication de la version stable
- **Informations de version** : Header du script avec copyright et lien GitHub
- **Nom de fichier avec version** : Format `Marque_Modele_NumeroSerie_YYYY-MM-DD_CS4Rv1.0.html`
- **Footer HTML** : Copyright et lien vers le projet dans le rapport généré
- **Affichage console** : Information de version au lancement du script

### 🔧 Modifié
- **smartctl Windows** : Support amélioré pour format /dev/sdX
- **BIOS** : Ajout du numéro de série et date BIOS
- **SSD** : Détection du niveau d'usure (Wear Level)

---

## [Version Améliorée] - 2025-12-07

### ✨ Ajouté
- **Année de fabrication du système** : Extraction automatique depuis BIOS
- **Résumé exécutif** : Analyse automatique de l'état général avec alertes visuelles
- **Support RAM intégrée/soudée** : Détection intelligente pour les systèmes modernes
- **Informations SMART étendues** : Secteurs en attente, erreurs hors ligne, vitesse de rotation
- **Graphiques interactifs** : Amélioration du graphique de batterie avec Chart.js
- **Classification d'état** : Système de santé (Excellent/Bon/Attention/Critique)
- **Boîtes d'alertes visuelles** : Avertissements colorés pour problèmes critiques

### 🔧 Modifié
- **Système** : Ajout de l'année de fabrication et nom de l'ordinateur
- **RAM** : Affichage de la vitesse et gestion améliorée des modules intégrés
- **Disques** : Présentation détaillée avec modèle, numéro de série, firmware
- **Batterie** : Lecture améliorée du battery-report.html avec parsing robuste
- **HTML** : Styles CSS modernisés avec couleurs d'état et mise en page améliorée
- **SMART** : Calcul d'un score de santé global basé sur multiple critères

### 🐛 Corrigé
- **RAM intégrée** : Problème de détection des modules soudés sur systèmes modernes
- **Parsing batterie** : Amélioration de la lecture des fichiers battery-report.html
- **Données SMART** : Extraction plus robuste des informations de santé des disques
- **Gestion d'erreurs** : Meilleure gestion des cas où smartctl n'est pas disponible
- **Affichage** : Correction des problèmes de mise en forme HTML

### 📊 Métriques ajoutées
- **Erreurs SMART** : Comptage total des secteurs problématiques
- **Température** : Alertes automatiques pour températures élevées
- **Classification automatique** : Recommandations pour recyclage vs réutilisation
- **Heures d'utilisation** : Récupération du temps de fonctionnement des disques

### 🎨 Interface utilisateur
- **Couleurs d'état** : Vert (bon), Orange (attention), Rouge (critique)
- **Mise en page** : Sections mieux organisées avec bordures et espacements
- **Icons** : Emojis pour améliorer la lisibilité des alertes
- **Graphiques** : Visualisation améliorée de l'état de santé de la batterie

### 🔍 Améliorations techniques
- **Parsing robuste** : Meilleure extraction des données depuis multiple sources
- **Gestion mémoire** : Optimisation pour les systèmes avec beaucoup de modules RAM
- **Compatibilité** : Amélioration de la compatibilité avec différents types de matériel
- **Logging** : Messages informatifs pendant l'exécution du script

### 📝 Documentation
- **README mis à jour** : Documentation complète des nouvelles fonctionnalités
- **Changelog créé** : Historique des modifications
- **Guide d'utilisation** : Instructions détaillées pour les nouvelles fonctionnalités
- **Exemples** : Cas d'usage pour différents types de systèmes

---

## [Version Originale] - Version de base

### Fonctionnalités de base
- Collecte des informations système (marque, modèle)
- Détection CPU (marque, modèle, vitesse)
- Inventaire RAM (total, modules individuels)
- Informations disque (type, taille)
- Données SMART de base (erreurs, heures, température)
- État de batterie (capacité, cycles)
- Rapport HTML simple avec graphique de batterie

### Limitations identifiées
- Problèmes avec RAM intégrée/soudée
- Données SMART incomplètes
- Parsing batería imparfait
- Interface utilisateur basique
- Pas d'analyse globale de l'état