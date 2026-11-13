**English** · [Français](#politique-de-sécurité)

# Security policy

The composer installs servers that carry confidential conversations between people in distress and
helpline respondents. Please report security problems privately so they can be fixed before they are known.

## Reporting a vulnerability

- Use GitHub's **private vulnerability reporting**: the "Security" tab of this repository, then
  "Report a vulnerability". Do not open a public issue, pull request or discussion.
- Include what you found, how to reproduce it, and what an attacker could do with it.
- Never include real conversations, phone numbers or credentials (your `composer.env` holds all the secrets
  of an installation: never attach it).

You should get an answer within 7 days. Only the latest commit of `main` is supported.

## Scope

In scope: this repository (install.sh / install.ps1, the generated Synapse, MAS and nginx configurations,
verify.sh, the tests, the nightly job). Out of scope: SwitchBoard, SwitchBoardChat and WP Chat (report in
their repositories), and Synapse, MAS, nginx, certbot, Docker and other upstream projects (report to them).

---

# Politique de sécurité

Le composer installe des serveurs qui transportent des conversations confidentielles entre des personnes en
détresse et les répondants d’une ligne d’écoute. Signalez les problèmes de sécurité en privé.

- Utilisez le **signalement privé de vulnérabilité** de GitHub : onglet « Security » de ce dépôt, puis
  « Report a vulnerability ». N’ouvrez pas de signalement, de demande de fusion ni de discussion publics.
- Décrivez ce que vous avez trouvé, comment le reproduire et ce qu’un attaquant pourrait en faire.
- N’y mettez jamais de vraies conversations, de numéros ni d’identifiants (le fichier `composer.env` contient
  tous les secrets d’une installation : ne le joignez jamais).

Réponse en 7 jours au plus. Seul le dernier commit de `main` est maintenu. Hors du périmètre : SwitchBoard,
SwitchBoardChat et WP Chat (signalez-le dans leurs dépôts), ainsi que Synapse, MAS, nginx, certbot et Docker.
