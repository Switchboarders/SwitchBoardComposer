# sbcomposer: SwitchBoard + SwitchBoardChat + Synapse + MAS in one command

One command installs **or updates** the whole helpline stack on one machine, wired together:

| Piece | How it is installed | Address |
|---|---|---|
| [SwitchBoard](https://github.com/Switchboarders/SwitchBoard) | its own `Docker/up.sh` (reverse-proxy mode) | `https://sb.<domain>` |
| [SwitchBoardChat](https://github.com/Switchboarders/SwitchBoardChat) | its own `scripts/install.sh` | `https://sbchat.<domain>`, web chat under `https://sb.<domain>/web/` |
| Synapse | `matrix/` (pinned in `versions.env`) | `https://matrix.<domain>` |
| MAS (Matrix Authentication Service) | `matrix/` (pinned in `versions.env`) | `https://matrix.<domain>/auth/` |

A front nginx (with certbot for Let's Encrypt) owns ports 80/443 and routes the three names, as on the
production server. The installer also creates the bridge's bot account and a first Matrix admin in MAS, the MAS
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

## Tests

```sh
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

## Differences from the hand-made production server

The composer follows the production layout, with a few deliberate changes:
- Image versions are pinned instead of `:latest`.
- Synapse and MAS ports are not published on the host; only nginx's 80/443 and the bridge's 3443 are.
- `user_directory.search_all_users` is `false`, as SwitchBoardChat's `docs/homeserver.md` recommends.
- nginx reloads every 6 hours, so renewed certificates are picked up.
