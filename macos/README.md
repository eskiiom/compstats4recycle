# CompStats for Recycle — macOS

[← Retour au projet](../README.md)

Script Python (bibliothèque standard uniquement, aucune dépendance à installer) qui génère un rapport HTML/JSON/CSV sur l'état matériel d'un Mac avant recyclage : système, CPU, GPU, RAM, disques (avec statut SMART), batterie, réseau, chiffrement FileVault — avec un score global et une recommandation, comme la version Windows.

## ⚠️ À savoir avant utilisation

Ce script a été écrit et testé (35 tests unitaires + un scénario de bout en bout) en simulant les sorties de `system_profiler`, `diskutil`, `fdesetup`, etc. — **pas encore validé sur un vrai Mac** au moment de l'écriture. Le CI GitHub Actions le fait tourner réellement sur un runner `macos-latest` à chaque push, ce qui donne une vraie validation sur du matériel Apple — mais si tu rencontres un champ manquant ou un plantage sur ta machine, n'hésite pas à remonter la sortie exacte de la commande en cause pour affiner le parsing (le format JSON de `system_profiler SPPowerDataType` en particulier varie selon les versions de macOS).

## Utilisation

```bash
python3 compstats.py
python3 compstats.py --asset-tag "REF-1234"
python3 compstats.py --disk-temp-warning-threshold 45 --purge-reports-older-than-days 90
```

Aucune installation requise : Python 3 est inclus par défaut sur macOS.

### Paramètres

| Paramètre | Effet |
|-----------|-------|
| `--no-json` | N'écrit pas l'export JSON |
| `--no-csv-log` | N'ajoute pas de ligne au CSV consolidé (`Rapports/resume.csv`) |
| `--no-index` | Ne régénère pas `Rapports/index.html` |
| `--asset-tag "REF"` | Référence d'inventaire interne, ajoutée au nom de fichier, au CSV et au JSON |
| `--battery-good-threshold` / `--battery-warning-threshold` / `--battery-critical-threshold` | Seuils de santé batterie en % (défauts 80/60/40) |
| `--disk-temp-warning-threshold` | Température disque (°C) déclenchant "Attention" (défaut 50) |
| `--score-good-threshold` / `--score-warning-threshold` | Seuils du score global (défauts 80/50) |
| `--purge-reports-older-than-days` | Supprime les rapports HTML/JSON plus vieux que N jours (désactivé par défaut) |

### Données SMART complètes (optionnel)

Sans `smartctl`, le script utilise le statut SMART basique fourni par `diskutil` (Vérifié / Défaillant). Pour les données détaillées (secteurs réalloués, heures d'utilisation, usure SSD), installez [smartmontools](https://formulae.brew.sh/formula/smartmontools) :

```bash
brew install smartmontools
```

La lecture SMART complète nécessite généralement `sudo` ; le script l'essaie automatiquement et se rabat sur `diskutil` si l'accès est refusé.

### Chiffrement (FileVault)

Contrairement à BitLocker sur Windows (par volume), FileVault protège l'ensemble du disque système — le rapport affiche donc un statut unique (Chiffré / Non chiffré) plutôt qu'une liste par volume.

## Tests

```bash
python3 -m unittest test_compstats -v
```

35 tests couvrant le parsing SMART (ATA/NVMe), la classification des disques, le score global, l'échappement HTML et le parsing des sorties `system_profiler`/`fdesetup` (mockées).

## Licence

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org) — Libre d'utilisation pour le recyclage d'ordinateurs.
