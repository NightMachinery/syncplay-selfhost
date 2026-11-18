# Self-hosting Syncplay

This repo self-hosts the upstream [`Syncplay/syncplay`](https://github.com/Syncplay/syncplay) server without Docker.

Syncplay is a native-client service: clients connect to a raw TCP server (default port `8999`). Caddy cannot serve or reverse-proxy that raw protocol with a normal HTTP Caddyfile, so Caddy is used only for a static landing page with the server address and client downloads.

## Quick start

```zsh
./self_host.zsh setup [url]
```

If `url` is omitted it defaults to:

```text
http://syncplay.pinky.lilf.ir
```

The script:

1. stops any existing tmux session for this service,
2. checks that the Syncplay TCP port is free,
3. clones/updates upstream Syncplay into `.runtime/syncplay`,
4. creates `.runtime/venv` and installs only Syncplay server dependencies,
5. writes `public/index.html` and persistent runtime files in `data/`,
6. adds a managed block to `~/Caddyfile`,
7. starts the server in tmux session `syncplay-server`.

## Commands

```zsh
./self_host.zsh setup [url]      # stop, install/update, configure Caddy, start
./self_host.zsh redeploy [url]   # refresh local runtime/config and restart
./self_host.zsh start [url]      # stop any old session and start
./self_host.zsh stop             # stop tmux session
./self_host.zsh dev-start [url]  # unsupported; exits with an explanation
```

## Development mode

`dev-start` is intentionally unsupported for this repo. The deployed component is the upstream Python Syncplay raw TCP server, and this setup does not have a meaningful hot-reload/dev-server mode. After local changes, use:

```zsh
./self_host.zsh redeploy [url]
```

## Configuration

Environment variables:

- `SYNCPLAY_URL`: landing-page URL, equivalent to passing `[url]`.
- `SYNCPLAY_PORT`: raw Syncplay TCP port. Default: `8999`.
- `SYNCPLAY_PASSWORD`: optional server password passed through to Syncplay.
- `SYNCPLAY_SALT`: optional managed-room salt passed through to Syncplay. If unset, the script creates and reuses `data/salt`.
- `CADDYFILE`: Caddyfile path. Default: `~/Caddyfile`.

Proxy variables from the current environment are preserved for install/start when present; they are not hardcoded.

## Caddy

The script manages this block in `~/Caddyfile`:

```caddyfile
# BEGIN syncplay-selfhost
http://syncplay.pinky.lilf.ir {
	root * /home/ubuntu/base/syncplay-selfhost/public
	file_server
}
# END syncplay-selfhost
```

The block is regenerated for the URL used with `setup`/`redeploy`.

## Client use

Install the Syncplay client on each viewer machine. Connect to:

```text
<host-from-url>:8999
```

Example for the default URL:

```text
syncplay.pinky.lilf.ir:8999
```

Make sure TCP port `8999` (or your `SYNCPLAY_PORT`) is reachable on the server/firewall.

## Intranet notes

- No Docker is used.
- No external captcha or hosted assets are used.
- The landing page has no external fonts/scripts and works over plain HTTP.
- Copy-to-clipboard on HTTP uses a local fallback instead of requiring HTTPS-only clipboard APIs.

## Download page

Edit `site/index.html` and run `./self_host.zsh render-site [url]` to regenerate the served page. Use the same URL and `SYNCPLAY_PORT` as the installation. This command works while viewers are connected.

The desktop link follows the fork's latest GitHub release. Homebrew installs the SyncPlayU cask from the NightMachinery tap. The Android link selects the full universal APK from the latest upstream release. An explicitly versioned direct link and the upstream releases page remain usable if the browser cannot reach the GitHub API. Downloading an installer requires access to GitHub.
