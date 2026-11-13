# sbcomposer: SwitchBoard + SwitchBoardChat + Synapse + MAS in one command

One command installs **or updates** the whole helpline stack on one machine, wired together:

| Piece | How it is installed | Address |
|---|---|---|
| [SwitchBoard](https://github.com/Switchboarders/SwitchBoard) | its own `Docker/up.sh` (reverse-proxy mode) | `https://sb.<domain>` |
| [SwitchBoardChat](https://github.com/Switchboarders/SwitchBoardChat) | its own `scripts/install.sh` | `https://sbchat.<domain>`, web chat under `https://sb.<domain>/web/` |
| Synapse | `matrix/` (pinned in `versions.env`) | `https://matrix.<domain>` |
| MAS (Matrix Authentication Service) | `matrix/` (pinned in `versions.env`) | `https://matrix.<domain>/auth/` |

A front nginx (with certbot for Let's Encrypt) owns ports 80/443 and routes the three names. The installer also creates the bridge's bot account and a first Matrix admin in MAS, the MAS
admin client, SwitchBoard's first admin account, and stores the SBChat admin token and MAS client in
SwitchBoard (encrypted with its `APP_ENCRYPTION_KEY`), so SwitchBoard can create call centers and Matrix accounts
right away.

## Install

Needs Docker with the Compose plugin (2.17+), git, openssl and curl. The DNS of the three names must point
to the machine, and ports 80/443 must be free.

```sh
git clone <this repository> sbcomposer && cd sbcomposer
sudo mkdir -p /opt/switchboard && sudo chown "$USER" /opt/switchboard
./install.sh --domain example.org --email admin@example.org
```

Addresses and first passwords end up in `/opt/switchboard/credentials.txt` (mode 600). All answers and generated
secrets are in `/opt/switchboard/composer.env` (mode 600). Keep a copy of that file; it is the key to the
installation.

For a LAN or a test machine without public DNS, use `--tls selfsigned`: a local CA is created
(`/opt/switchboard/matrix/ca/ca.pem`) and trusted by SwitchBoard and the bridge.

**Behind an existing reverse proxy** (e.g. Nginx Proxy Manager owning 80/443): `--behind-proxy`. Nothing is
published on 80/443. Create one proxy host in the proxy with the three names, forwarding to `http` /
`synapse-nginx` / `8080` on the Docker network `web`, with websockets, a Let's Encrypt certificate and Force SSL.
`tools/npm-proxy-host.py` does this through Nginx Proxy Manager's API.

**A website with the chat widget**: `--wordpress-host www.example.org` also installs a WordPress site with
[WP Chat](https://github.com/Switchboarders/wp_chat) (GPL-2.0-or-later). The plugin comes already connected to
this installation's bridge, and the site's address is allowed for web chats (`WEB_ALLOWED_ORIGINS`). The site
is served by the same front nginx: point its DNS to the machine, or add the name to the upstream proxy's entry
with `--behind-proxy`. It starts with French (Canada), a home page and a privacy page. Updates refresh the
plugin from its repository and keep everything you changed in WordPress. For visitors to reach respondents,
also give `--web-call-center ID`: the SwitchBoard call center whose respondents answer web chats.

**Windows** (Docker Desktop + Git for Windows): `install.cmd` / `.\install.ps1`, same options. The default
folder is `%USERPROFILE%\switchboard`, and databases live in Docker volumes.

`./install.sh --help` lists every option (other host names, ports, branches, web chat origins…).

## Update

```sh
cd sbcomposer && git pull && ./install.sh
```

The same command performs the update:
1. Backs up SwitchBoard's database, MAS's database, Synapse's database and the bridge's data into
   `/opt/switchboard/backups/<date>/`.
2. Fast-forwards both repositories to the branch you follow (`main` by default) and runs SwitchBoard's `up.sh`
   and its application updater (`src/miseajour.php`).
3. Applies the Synapse and MAS versions in `versions.env`, and runs SwitchBoardChat's `install.sh` (rebuild +
   restart).
4. Verifies the result.

Secrets are never regenerated.

## Verify

```sh
./verify.sh                # health checks, changes nothing: safe in production
./verify.sh --functional   # + a real web chat answered by a simulated respondent (test machines only)
```

The health checks cover the containers, the three public addresses with certificate validation, MAS discovery
and delegation, a Matrix password login through MAS, SwitchBoard's admin login, SBChat's own `install.sh --check`,
and SwitchBoard calling the SBChat API and the MAS admin API with the stored credentials.

`--functional` reuses SwitchBoardChat's own e2e helpers (`tests/e2e/lib.py`, `respondent-sim`). A website
visitor writes; a respondent logged in through MAS, using real end-to-end encryption, reads the message and
answers; the visitor receives the answer.

## Full test suite

```sh
tests/suite.sh --confirm [--outside HOST]   # test installations only: creates test accounts and a call center
```

The suite covers:
- **health:** everything `verify.sh` checks.
- **accounts:** created through MAS and through SwitchBoard; a wrong password is refused.
- **web chat:** two respondents, the welcome macro, `!aide`, `#macro`, answers from both, the history, and the
  end of the chat for everyone.
- **SMS:** the voip.ms webhook with key, the hidden caller number, the muted answer in the voip.ms queue, and
  `!oubli`.
- **Law 25:** an ended web chat is purged from Synapse.
- **restarts:** a new chat works after every service restarts.
- **outside network (`--outside HOST`):** DNS, certificates, redirects, discovery, federation, what must NOT be
  exposed, CORS, and a web chat from there answered by a respondent on the server.

## Websites of several committees, committees without voip.ms

A committee links its own website without anyone touching the server. In SwitchBoard, the committee's
*SwitchBoard Chat* page, *Link a website*, shows a one-time string (valid 30 minutes). Paste it in WordPress:
*Settings > WP Chat > Link this website to a committee*. The bridge then accepts that website, and its chats go
to that committee's respondents, so many committees can share one installation. A committee that only uses the
web chat needs no voip.ms account: leave the three voip.ms fields empty in SwitchBoard and request its SBChat
token as usual. (This needs SwitchBoard, SwitchBoardChat and WP Chat versions with these features.)

## Tests

```sh
tests/run-linux.sh --distros debian --errors       # user errors: each must stop with a clear message
tests/run-linux.sh --distros debian --local-repos DIR --quick   # unpushed changes in DIR/{sb,sbchat,wp_chat}
tests/run-linux.sh --distros "debian ubuntu fedora arch alpine"
tests/run-windows.sh [--pc NAME] [--relay HOST]
```

Each distribution gets a throwaway Docker-in-Docker machine (same approach as SwitchBoard's install tests). The
run is: fresh install, then `verify --functional`, then update, then a check that no secret changed, then
`verify --functional` again. Logs go to `tests/results/<distribution>/`.

## Nightly check

`nightly/nightly.sh` runs every night at 00:00 on the test machine (systemd user timer, set up by
`nightly/setup.sh`):
- **Debian:** updates from the last commits that passed to the latest `main`.
- **One rotating distribution:** a fresh install of the latest `main`.

On failure it sends an email and opens or comments a GitHub issue (label `nightly-failure`). The next success
closes the issue. Settings go in `~/.config/sbcomposer/nightly.env` (see `nightly/nightly.env.example`); logs go in
`~/.local/state/sbcomposer/logs/`.

## Design choices

The layout is the one of a working production server (front nginx + certbot, SwitchBoard in reverse-proxy
mode, MAS under `/auth/`), with a few deliberate changes:
- Image versions are pinned instead of `:latest`.
- Synapse and MAS ports are not published on the host; only nginx's 80/443 and the bridge's 3443 are.
- `user_directory.search_all_users` is `false`, as SwitchBoardChat's `docs/homeserver.md` recommends.
- nginx reloads every 6 hours, so renewed certificates are picked up.

## Contributing, security, license

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately, never
in a public issue: see [SECURITY.md](SECURITY.md).

Copyright (C) 2026 Switchboarders. Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE), like
SwitchBoard and SwitchBoardChat: free to use, change and share for any noncommercial purpose. WP Chat, which
the composer can install, is a separate project under GPL-2.0-or-later.
