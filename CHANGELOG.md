# Changelog - CompStats for Recycle

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

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