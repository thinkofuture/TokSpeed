<p align="center">
  <img src="../../Resources/AppIcon.png" alt="Logo TokSpeed" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>Vérifiez dans la barre des menus si votre IA se la coule douce.</strong><br>
  Application légère pour la barre des menus de macOS affichant la vitesse de génération de tokens pour Codex, OpenCode, Claude Code, Antigravity, Hermes et Cursor.
</p>

<p align="center">
  Lit uniquement les logs locaux — sans clé API, sans téléversement, sans requêtes réseau.
</p>

<br>

---

<br>

## Compilation, tests et lancement

macOS 13+ et Xcode Command Line Tools requis.

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

Compiler un binaire universel ou exécuter la suite de tests :

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## Vues et fonctionnalités

- **Graphique de tendance** : Affiche jusqu’à 60 appels terminés par outil visible sur une échelle commune, avec des couleurs distinctes pour les outils actifs et des repères minimaux sur l’axe Y. Survolez un point ou une carte pour mettre en valeur sa courbe et voir les détails.
- **Liste détaillée** : Basculez via **Réglages → Vue du panneau**. Lorsqu’un outil possède deux sessions actives ou récentes ou plus, des sous-lignes indentées affichent chaque titre et vitesse.
- **Épinglage et tri** : Cliquez sur une carte pour épingler/désépingler la source active ; faites glisser les cartes (ou utilisez les actions VoiceOver) pour réordonner.
- **Réglages et intégrations** : **Lancer à l’ouverture de session**, visibilité des outils, réinitialisation de l’ordre, **Diagnostics** locaux (`TokSpeed --diagnostics`) et gestion explicite du **Hook Cursor** (assistant léger sans AppKit, rotation à 4 Mo) et de l’**extension Hermes** (`--install-hermes-plugin [--force]`).

Pour voir la vitesse de streaming estimée et le temps écoulé des requêtes Hermes en cours, activez l’extension installée avec `hermes plugins enable tokspeed-metrics`. Sans extension, TokSpeed affiche les appels terminés de `logs/agent.log`.

## Licence

[MIT License](../../LICENSE)
