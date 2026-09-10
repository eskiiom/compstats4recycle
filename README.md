# CompStats for Recycle

Des scripts pour générer des statistiques matérielles détaillées sur les ordinateurs avant recyclage : état des disques, de la batterie, compatibilité, chiffrement — un score global et une recommandation (réemploi / vérification / recyclage).

Un script dédié par système d'exploitation, chacun utilisant les outils natifs de son OS plutôt qu'une couche d'abstraction commune :

| OS | Script | Langage | Statut |
|----|--------|---------|--------|
| Windows | [`windows/CompStats.ps1`](windows/) | PowerShell | ✅ Disponible |
| macOS | `macos/compstats.py` | Python | 🚧 À venir |
| Linux | `linux/compstats.sh` | Bash | 🚧 À venir |

Voir le README de chaque dossier pour l'utilisation détaillée, les paramètres et les prérequis propres à cet OS.

## Licence

Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)

Libre d'utilisation pour le recyclage d'ordinateurs.
