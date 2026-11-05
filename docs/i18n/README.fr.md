<p align="center"><img src="../../Resources/AppIcon.png" alt="Logo TokSpeed" width="120" /></p>
<h1 align="center">TokSpeed</h1>
<p align="center"><strong>Vérifiez dans la barre des menus si votre IA se la coule douce.</strong></p>
<p align="center">
  <a href="../../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> · <strong>Français</strong> · <a href="README.es.md">Español</a>
</p>

---

TokSpeed est une application légère pour la barre des menus de macOS. Elle lit les enregistrements locaux de **Codex, OpenCode, Claude Code et Antigravity** pour afficher la vitesse de génération des tokens et les tendances des derniers appels. Aucune clé API ni appel supplémentaire aux modèles.

## Compilation et lancement

Nécessite **macOS 13 ou ultérieur** et les Xcode Command Line Tools compatibles avec le mode Swift 5. Utilise AppKit et SQLite du système, sans dépendance tierce. La compilation cible l’architecture de votre Mac (Apple Silicon ou Intel), pas un binaire universel.

Installez les outils de ligne de commande si nécessaire, puis lancez ces commandes dans le dépôt téléchargé ou cloné :

```sh
xcode-select --install
bash scripts/build.sh
open build/TokSpeed.app
```

L’application apparaît uniquement dans la barre des menus, pas dans le Dock. Les outils non installés sont masqués dans le résumé, le choix de source et l’ordre personnalisé. Les outils installés sans enregistrements affichent « Aucune donnée ». L’interface suit les langues préférées du système : anglais, chinois simplifié/traditionnel, japonais, coréen, allemand, français et espagnol, avec l’anglais en repli. Redémarrez l’application après un changement de langue.

- **Réglages…** ouvre une fenêtre native macOS et enregistre immédiatement les modifications. « Quitter » reste en fin de menu.
- **Source / Affichage** : « Automatique » ou outil fixe ; « Nombre et unité », « Nombre seul » ou « Icône seule ». En attente : secondes (`s`), pas vitesse (`tok/s`). Au repos : éclair seul.
- **Ordre des outils** : faites glisser les cartes directement dans le panneau ouvert. Une ligne indique la position ; relâchez pour enregistrer. Déposez hors des cartes ou appuyez sur Échap pour annuler. Ordre par défaut : Claude Code → Codex → OpenCode → Antigravity. Le choix automatique de source reste inchangé ; VoiceOver propose des actions Monter / Descendre.
- Les courbes lissées restent dans l’intervalle des valeurs des points adjacents.

Vous pouvez déplacer `build/TokSpeed.app` dans Applications. Pour désinstaller, quittez puis supprimez l’application. Les préférences de source, d’affichage et d’ordre sont dans UserDefaults ; après avoir quitté, effacez-les avec `defaults delete io.github.thinkofuture.tokspeed`.

Le projet est actuellement distribué sous forme de code source. Le script applique uniquement une signature ad-hoc locale, sans signature Developer ID ni notarisation Apple. L’icône est produite à partir de `Resources/AppIcon.png` avec les outils système.

## Sources de données et confidentialité

| Source | Emplacement par défaut |
| --- | --- |
| Codex | Rollout JSONL dans `~/.codex/sessions/` et `~/.codex/archived_sessions/` ; respecte `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode/opencode.db` ; schémas V1/V2 implémentés par le lecteur |
| Claude Code | JSONL dans `~/.claude/projects/`, hors sous-agents ; respecte `CLAUDE_CONFIG_DIR` |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` et `conversations/*.db` |

- Inutile d’installer tous les outils. Les applications de bureau et CLI exécutables dans `PATH` ou les emplacements habituels sont détectés localement ; des journaux résiduels ne suffisent pas. La détection est actualisée automatiquement. Si la source fixée disparaît, le choix automatique prend temporairement le relais sans effacer la préférence. Chaque source sélectionne ses enregistrements récents indépendamment de la fenêtre au premier plan.
- Les journaux peuvent contenir des conversations. TokSpeed analyse les champs utiles aux statistiques, sans téléverser de données, lancer de requêtes réseau ni modifier les sources. SQLite est ouvert en lecture seule.
- Seules les préférences de source, d’affichage et d’ordre sont enregistrées, pas de copies des conversations. Masquez les identifiants de session et chemins locaux des diagnostics avant de les partager.
- Les applications lancées depuis le Finder n’héritent généralement pas des variables du terminal. Pour des chemins personnalisés, définissez les variables et lancez directement l’exécutable dans le paquet de l’application depuis le terminal.

## Mesures et limites

Les vitesses sont estimées à partir des enregistrements locaux : **ni mesure instantanée par token, ni benchmark contrôlé entre outils.**

- Pour Codex, OpenCode et Claude Code : total des tokens de sortie des appels terminés / somme de leurs durées enregistrées pour la réponse en cours. Avant le premier appel terminé, seules les secondes peuvent apparaître.
- Les limites temporelles varient et peuvent inclure le délai du premier token. Claude Code nécessite un enregistrement du début de requête et mesure jusqu’au premier bloc de sortie complet. Des champs manquants peuvent empêcher l’affichage.
- Antigravity affiche les tokens de sortie du dernier appel / (délai du premier token + durée du streaming), après sa fin.
- Les compteurs suivent chaque source et peuvent inclure les tokens de raisonnement. Les courbes montrent au plus les 12 derniers appels, pas des échantillons par seconde ; chaque source a sa propre échelle.
- Les formats amont ne sont pas sous notre contrôle. Mises à jour, chemins personnalisés ou champs absents peuvent causer des données manquantes ou des erreurs d’estimation. La compatibilité avec toutes les versions n’est pas garantie.

## Vérifications de base

Sans lire de vraies conversations ni modifier les préférences : vérifiez détection et masquage des outils, huit langues et repli, modes d’affichage, sauvegarde de l’ordre, courbes, couleurs claires/sombres, icônes et écritures partielles de Codex.

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

Ajoutez `-AppleLanguages '("fr-FR")'` pour choisir la langue et `--preview-directory <répertoire>` pour enregistrer les aperçus clairs/sombres.

## Licence

Le code est sous [MIT License](../../LICENSE). Les sources et licences des icônes tierces figurent dans [Resources/Logos/NOTICE.md](../../Resources/Logos/NOTICE.md), fourni avec l’application. Les marques appartiennent à leurs propriétaires. TokSpeed n’est ni affilié aux fournisseurs ni approuvé par eux ; la licence du code n’accorde aucun droit sur les marques.
