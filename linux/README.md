# CompStats for Recycle — Linux

[← Retour au projet](../README.md)

Script Bash (aucune dépendance externe — pas de `jq`, pas de `bc`, uniquement les outils déjà présents sur toute installation Linux : coreutils, `lsblk`/`dmidecode`/`ip` de util-linux/iproute2) qui génère un rapport HTML/JSON/CSV sur l'état matériel d'une machine avant recyclage : système, CPU, GPU, RAM, disques (avec statut SMART), batterie, réseau, chiffrement LUKS — avec un score global et une recommandation, comme les versions Windows et macOS.

## ⚠️ À savoir avant utilisation

Écrit et testé (62 tests + un scénario de bout en bout) en simulant les sorties de `dmidecode`, `lsblk`, `smartctl`, etc. — pas encore utilisé par l'auteur sur une machine physique. Le CI GitHub Actions le fait tourner réellement sur un runner `ubuntu-latest` à chaque push (une vraie VM Linux) : les tests passent et le script s'exécute sans planter, mais certains champs y resteront "N/A" faute de batterie ou de droits root (numéro de série, détail des barrettes RAM). Si un champ manque ou qu'une commande se comporte différemment sur ta distribution, remonte la sortie exacte pour affiner le parsing.

## Utilisation

```bash
./compstats.sh
./compstats.sh --asset-tag "REF-1234"
./compstats.sh --disk-temp-warning-threshold 45 --purge-reports-older-than-days 90
```

Aucune installation requise. Certaines informations nécessitent des droits root pour être complètes (numéro de série système, détail des barrettes RAM via `dmidecode`, données SMART complètes) ; sans eux, le script se rabat sur des sources plus limitées et l'indique dans le rapport plutôt que d'échouer.

### Paramètres

| Paramètre | Effet |
|-----------|-------|
| `--no-json` | N'écrit pas l'export JSON |
| `--no-csv-log` | N'ajoute pas de ligne au CSV consolidé (`Rapports/resume.csv`) |
| `--no-index` | Ne régénère pas `Rapports/index.html` |
| `--asset-tag REF` | Référence d'inventaire interne, ajoutée au nom de fichier, au CSV et au JSON |
| `--battery-good-threshold` / `--battery-warning-threshold` / `--battery-critical-threshold` | Seuils de santé batterie en % (défauts 80/60/40) |
| `--disk-temp-warning-threshold` | Température disque (°C) déclenchant "Attention" (défaut 50) |
| `--score-good-threshold` / `--score-warning-threshold` | Seuils du score global (défauts 80/50) |
| `--purge-reports-older-than-days` | Supprime les rapports HTML/JSON plus vieux que N jours (désactivé par défaut) |

### Données SMART complètes (optionnel)

Sans `smartctl`, le disque n'apparaît que sans détail SMART. Pour les données complètes (secteurs réalloués, heures d'utilisation, usure SSD), installez smartmontools via le gestionnaire de paquets de votre distribution :

```bash
sudo apt install smartmontools   # Debian/Ubuntu
sudo dnf install smartmontools   # Fedora
```

La lecture SMART complète nécessite généralement `sudo` ; le script l'essaie automatiquement et se rabat sur le statut basique sinon.

### Chiffrement (LUKS)

Détecté par volume via `lsblk` (type de système de fichiers `crypto_LUKS`), à la manière de BitLocker sur Windows.

## Tests

```bash
bash test_compstats.sh
```

62 tests couvrant le parsing SMART (ATA/NVMe), le parsing `dmidecode -t memory` (barrettes RAM occupées/vides), `lsblk -P`, la classification des disques, le score global, l'échappement HTML/JSON et la génération de l'index — un vrai bug d'échappement HTML (un `&` non échappé dans un remplacement bash est interprété comme une rétro-référence) a été trouvé et corrigé grâce à cette suite.

## Licence

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org) — Libre d'utilisation pour le recyclage d'ordinateurs.
