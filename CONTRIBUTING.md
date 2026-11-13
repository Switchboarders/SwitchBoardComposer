**English** · [Français](#contribuer)

# Contributing

Thank you for helping. The composer must stay a thin layer: each project is installed with its own
installer (SwitchBoard's `Docker/up.sh`, SwitchBoardChat's `scripts/install.sh`), and fixes that belong to
them go to their repositories (a temporary patch can live in `patches/<repo>/`).

- **Rules.** Re-running `install.sh` is always safe: it never regenerates a secret, never prints one and never
  puts one on a command line (stdin or files with mode 600). Image versions are pinned in `versions.env`.
  Message bodies are confidential (Quebec Law 25): never log them, not even in tests.
- **Before a pull request**: `tests/run-linux.sh` (at least Debian) must pass. It installs, updates and runs
  the full suite (`tests/suite.sh`) in throwaway Docker-in-Docker machines. Run `tests/run-windows.sh` for
  changes that touch Windows. Describe what you changed and how you tested it.
- **Security problems** are never reported in public: see [SECURITY.md](SECURITY.md).
- By contributing you agree that your contribution is licensed under the project's license
  ([LICENSE](LICENSE), PolyForm Noncommercial 1.0.0).

---

# Contribuer

Merci de votre aide. Le composer doit rester une couche mince : chaque projet s’installe avec son propre
installateur, et les corrections qui leur reviennent vont dans leurs dépôts (un correctif temporaire peut
vivre dans `patches/<dépôt>/`).

- **Règles.** Relancer `install.sh` est toujours sans risque : il ne régénère jamais un secret, n’en affiche
  jamais et n’en met jamais sur une ligne de commande. Les versions des images sont fixées dans `versions.env`.
  Le contenu des messages est confidentiel (Loi 25) : ne le journalisez jamais, même dans les tests.
- **Avant une demande de fusion** : `tests/run-linux.sh` (au moins Debian) doit réussir; `tests/run-windows.sh`
  pour ce qui touche Windows. Décrivez le changement et comment vous l’avez testé.
- **Les problèmes de sécurité** ne se signalent jamais en public : voir [SECURITY.md](SECURITY.md).
- En contribuant, vous acceptez que votre contribution soit sous la licence du projet ([LICENSE](LICENSE),
  PolyForm Noncommercial 1.0.0).
