<h1 align="center">DSH — DeepSeek Harness in a container</h1>

<p align="center"><a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> — a coding agent you drive from the browser — packaged as one self-contained image for any Docker host. A command sandbox that works on kernels without Landlock, rebased and smoke-tested automatically for every upstream release.</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">中文说明</a></p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-docker/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-docker/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <a href="https://github.com/2220545672/dsh-docker/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-docker?label=tracking&color=orange" alt="tracking"></a>
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

---

> **Developer preview.** DeepSeek Harness is in _developer preview_ and iterating rapidly. **THERE WILL BE COMPATIBILITY-BREAKING CHANGES.** — quoted from the [upstream project](https://github.com/deepseek-ai/deepseek-harness#developer-preview). This image tracks upstream releases automatically, so pin a [version tag](#update) if you would rather move on your own schedule.

## Why this image

- **Plugins — and the CLIs they call — survive an update.** Both live under `/data`, not in
  the image, so recreating the container does not remove them: [plugins](#installing-plugins)
  are installed into the profile on the volume, and the entrypoint puts the CLIs on the
  PATH of the DSH process ([Installing your own CLI tools](#installing-your-own-cli-tools)).
- **DeepSeek account sign-in works from a remote browser.** Upstream only completes the
  sign-in when the browser runs on the same machine as DSH. This image ships
  [dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin) and enables it by
  default: the login tab ends on a dead `127.0.0.1` page and the paste panel appears in
  the DSH page — one extra step, nothing else
  ([docs/remote-signin.md](docs/remote-signin.md); `REMOTE_SIGNIN=off` opts out).
- **It tracks upstream — and tests what it publishes.** An hourly job resolves the newest
  `@deepseek-ai/dsh` version on npm, builds the image for amd64 and arm64, runs the whole
  smoke suite against the built container, and publishes only when every check passes:
  `:latest` is never an untested build ([Update](#update)).

## Quick start

```bash
docker run -d --name dsh --restart unless-stopped -p 8080:8080 \
  -e ALLOWED_CLIENTS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 \
  -v "$PWD/dsh/data:/data" \
  -v "$PWD/dsh/workspace:/workspace" \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

Then open **`http://<your-host>:8080`** and log in with user `dsh` and the password printed once in the log (`docker logs dsh`).

Or use Compose — [`compose.yaml`](compose.yaml) carries the same settings:

```bash
docker compose up -d
```

Three things that catch people out on the first run:

- **`ALLOWED_CLIENTS` is not optional when you write the command yourself.** The image's own default is loopback only — that is what keeps a freshly published port from being an open door — so a browser on another machine gets `403` until you add your network. `compose.yaml` already ships the line above.
- **Both `--security-opt` values are required on kernels without Landlock** (Unraid 7.x, several appliance kernels), otherwise the agent's command sandbox cannot start. On a Landlock-capable kernel you may drop them. The reasoning, the controlled experiments and the two checks that produce false alarms are in [docs/sandbox.md](docs/sandbox.md).
- **`/data` and `/workspace` must be persistent.** Sessions, credentials and the agent home live in `/data`; your projects live in `/workspace`.

## First five minutes

1. **Change the password.** Without `DSH_PASSWORD` the container generated one and printed it once — `docker logs <container>`. Set `DSH_PASSWORD` (or `DSH_PASSWORD_FILE`) to choose your own; the user name defaults to `dsh` (`AUTH_USER`).
2. **Point it at your project.** The agent works in `/workspace`, and the directory picker starts there (`~/workspace` is a symlink to it).
3. **Add a DeepSeek API key** — *Add API key* in the settings panel. A DeepSeek **account** also works from any browser: a paste box appears in the page itself once the login tab dies on `127.0.0.1` — see [docs/remote-signin.md](docs/remote-signin.md).

## How it is put together

One container, two processes, one port:

```text
browser ──▶ :8080  Caddy (bundled)  ──▶ 127.0.0.1:3080  DSH
                     ├─ optional password gate (on by default)
                     ├─ allowlist: ALLOWED_CLIENTS
                     ├─ security headers, host/origin checks
                     └─ /healthz for the container healthcheck
```

- **The reverse proxy is already in the image.** Caddy serves the port you publish and forwards to DSH, which listens on loopback only — so the published port is the single way in, and the proxy is the layer that adds the security headers, refuses cross-site calls and blocks the endpoints that make no sense remotely. There is nothing extra to install or configure.
- **Authentication is optional, and it is one switch.** `AUTH_MODE=builtin` (the default) asks for a password once through the browser's ordinary login prompt, then keeps you signed in with a cookie that also covers the WebSocket; `AUTH_MODE=none` hands that job to whatever sits in front (a reverse proxy with SSO, a VPN, a trusted LAN). Any other value refuses to start instead of booting unprotected — and never stack two logins. The container's own healthcheck stays open either way.
- **The allowlist lives at the same layer.** `ALLOWED_CLIENTS` decides who may reach the container at all; loopback is always allowed, which is what keeps the healthcheck working.
- **It runs unprivileged.** uid 1000, no docker socket, no host directories beyond the two volumes you map. Credentials are stored in `/data` — the reason that volume must be persistent.
- **The command sandbox has two legs**: bubblewrap (bundled here, unlike most community images) and Landlock (upstream's `landlock-run`, which needs a kernel that compiled it in). Where Landlock is missing, bubblewrap plus the two `--security-opt` values is what keeps model-generated commands inside the workspace: [docs/sandbox.md](docs/sandbox.md).
- **A password over plain HTTP is not safe on the internet.** The gate protects the app, not the wire: terminate TLS in whatever you put in front before exposing this. Details: [docs/security.md](docs/security.md).

## Settings you may need

| Setting | Default | What it does |
|---|---|---|
| `8080` | — | The only port to publish. DSH listens on `127.0.0.1:3080` inside; a bundled proxy serves `:8080`. |
| `/data` · `/workspace` | — | Sessions, credentials and the agent home · your projects. **Both must be persistent.** |
| `ALLOWED_CLIENTS` | loopback only | Who may connect at all: IPs/CIDRs (and hostnames, matched against `Host`). |
| `PUBLIC_URL` | empty | Public origin (`https://dsh.example.com`) when a reverse proxy is in front; leave empty for LAN/Tailscale only. |
| `DSH_TRUSTED_HOSTS` | empty | Extra accepted `host[:port]` authorities, comma separated; only used together with `PUBLIC_URL`. |
| `TRUSTED_PROXY_CIDRS` | empty | Only when a reverse proxy is in front: Caddy then reads `X-Forwarded-For` from these peers only, so `ALLOWED_CLIENTS` sees the real client address. |
| `AUTH_MODE` | `builtin` | `builtin` = password gate inside the container; `none` = your proxy authenticates. Any other value refuses to start. |
| `DSH_PASSWORD` | unset | Password for the built-in gate (or `DSH_PASSWORD_FILE`). Unset = generated on first start, printed once. |
| `AUTH_USER` | `dsh` | User name for the built-in gate. |
| `REMOTE_SIGNIN` | `on` | DeepSeek **account** sign-in from a remote browser: loads [dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin), which puts the paste panel into the page. `off` = upstream's loopback-only behaviour. |
| `TZ` | `Asia/Shanghai` in `compose.yaml` | Container time zone. |

Already running SSO (Authelia, Authentik, a NAS portal, …)? Set `AUTH_MODE=none` and `PUBLIC_URL`, and **do not stack a second login**.

Volumes are taken over as `1000:1000`. Leave that alone — it is not a NAS's usual `99:100`.

## Installing your own CLI tools

`docker exec … npm i -g` is a trap: the global prefix lives in the image's layered
filesystem, so the tool is gone the next time the container is recreated. Install under
`/data` instead and it survives every update — the entrypoint puts two layouts on the
PATH of the DSH process (and of everything DSH spawns, which is what a plugin shells out
to):

```bash
# an npm CLI — no symlink needed, tools/<name>/node_modules/.bin is picked up as it is
docker exec -u 1000 <container> npm i --prefix /data/dsh/tools/codegraph @colbymchenry/codegraph

# a single binary — drop it in, or symlink it from wherever it was installed
docker exec -u 1000 <container> ln -s /data/dsh/tools/codegraph/node_modules/.bin/codegraph /data/dsh/bin/codegraph
```

Both are scanned once at start — `/data/dsh/bin` and every
`/data/dsh/tools/*/node_modules/.bin` (`DSH_HOME` is `/data/dsh` unless you moved it) —
and **appended** to `PATH`, never prepended, so nothing you install can shadow the
image's own `node`, `git` or `curl`. With neither directory present nothing changes at
all, and the container says so in its log when something was picked up:

```text
[entrypoint] operator tools on PATH: /data/dsh/bin:/data/dsh/tools/codegraph/node_modules/.bin
```

Restart the container after installing (the scan runs once, at boot). `docker exec`
sessions keep the image's own `PATH` — inside those, call the tool by its absolute path.

## Installing plugins

A DSH plugin is loaded from the **profile**, which lives on the persistent volume — so a
plugin you add is still installed after the container is recreated:

```bash
docker exec -u 1000 <container> dsh plugin --profile web add @scope/some-plugin
docker exec -u 1000 <container> dsh plugin --profile web add github:owner/repo
docker exec -u 1000 <container> dsh plugin --profile web why @scope/some-plugin   # what the profile carries
docker exec -u 1000 <container> dsh plugin --profile web remove @scope/some-plugin
```

`dsh plugin` forwards its arguments to pnpm inside `$DSH_HOME/profiles/web`
(`/data/dsh/profiles/web` by default), and the launcher composes whatever that profile
declares — restart the container to load it. Two details that bite:

- **Run it as uid 1000** (`docker exec -u 1000 …`). As root the package lands in `/data`
  owned by root, and the DSH process — uid 1000 — can no longer read it.
- **A plugin that shells out to its own command-line tool** needs that tool on the PATH of
  the DSH process as well; install it under `/data` first
  ([Installing your own CLI tools](#installing-your-own-cli-tools)) and the entrypoint
  picks it up at the next start.

Nothing else is installed into the image: your plugins are yours, and they sit on the
volume that survives `docker pull` and a recreate. The remote sign-in plugin is the one
deliberate exception — it ships inside the image, pinned to a release tag, so that a
default install can sign in from a remote browser ([below](#signing-in-with-a-deepseek-account)).

## Signing in with a DeepSeek account

Upstream hands the platform the address **you are browsing from** and asks it to deliver
the login there — and the platform only accepts a *local* one. So pressing *Sign in* with
a DeepSeek account from another machine fails before a login page ever opens ("Could not
complete the operation. Try again."), and the workarounds are an API key or an `ssh -L`
tunnel.

This image ships **[dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin)**
— the plugin has its own repository, its own CI and its own release tags, and the image
pins one of those tags — which registers a `127.0.0.1` address with the platform and puts
a paste box into the DSH page while a sign-in waits. You press *Sign in*, the login page
opens, and when the tab lands on the dead `127.0.0.1` page you paste that address into
the box that has appeared. That paste is the only step it adds; `REMOTE_SIGNIN=off`
gives you upstream behaviour back. How it works and what it deliberately leaves alone:
[docs/remote-signin.md](docs/remote-signin.md).

## Update

```bash
docker pull ghcr.io/2220545672/dsh:latest
docker compose up -d          # or recreate your own container
```

Everything in `/data` and `/workspace` survives.

| Tag | Meaning |
|---|---|
| `:latest` | Newest build, upstream prereleases included |
| `:0.2.1-alpha.4` | Pin an exact version |
| `:alpha` · `:rc` · `:stable` | Follow one upstream channel |

An hourly job checks upstream, rebuilds and smoke-tests the image, and publishes only when the checks pass. Upstream currently ships alpha/rc builds, so `:latest` moves often — pin a version tag if you would rather update on your own schedule.

## Problems

| Symptom | Fix |
|---|---|
| “dsh web authentication required; reopen the URL printed by dsh web” | **Just reload the page.** The browser is holding a session cookie this DSH no longer accepts (it happens after an image update, a container recreation, or another DSH on the same host — cookies ignore ports). The container notices and renews the session by itself; opening `http://<host>:<port>/renew` manually, or clearing that site's cookies, does the same thing. |
| A tool reports `SANDBOX_UNAVAILABLE` | The two `--security-opt` values are missing from your run command (they live in `Extra Parameters` on Unraid). Put them back. When you check, two things mislead people: `systempaths=unconfined` never appears in `docker inspect`'s `SecurityOpt` (it shows up as empty `MaskedPaths`/`ReadonlyPaths` instead), and bwrap only works as **uid 1000** — which is exactly what DSH runs as. Test the way DSH does: `docker exec -u 1000 <container> bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true` → exit 0. Run as root it always fails with *Creating new namespace failed*, which says nothing about the container. `--cap-add SYS_ADMIN` and `--privileged` are not needed, and both weaken the container. |
| The browser gets `403` | Your address is not in `ALLOWED_CLIENTS`; a plain `docker run` allows loopback only. |
| “登录失败 / 操作未完成” when signing in with a DeepSeek account | Upstream only accepts a **loopback** browser origin, so the login tab is redirected to `127.0.0.1` and dies there. **That is the step the plugin finishes:** a panel has appeared in the DSH page by then — copy the dead page's address into it. Do it within ~10 minutes and in the same container (an update or a container recreation discards the attempt). If the panel does not appear, the plugin is not loaded: set `REMOTE_SIGNIN=on` (it is the default) and check `docker logs <container> \| grep remote-signin`. Prefer no paste? Tunnel once and use a loopback origin: `ssh -L 3081:127.0.0.1:<published port> user@<server>`, then open `http://127.0.0.1:3081`. |
| Updated, but nothing changed | Recreate the container — a running container keeps the image it started with. |
| Page never finishes loading | `PUBLIC_URL` must match the address you actually open (scheme + host, no path). `docker logs <container> \| head -30` prints the mode it chose. |

## On Unraid

Unraid needs no special build: install the Community Applications entry **DSH** and keep
its `Extra Parameters` as shipped — the two `--security-opt` values are what the sandbox
needs on an Unraid kernel. Unraid-specific notes (the template's fields, migrating from
another DSH image) and the
[forum support thread](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)
are at **[2220545672/dsh-unraid](https://github.com/2220545672/dsh-unraid)**.

## Learn more

| Document | Contents |
|---|---|
| [docs/security.md](docs/security.md) | Password gate, host/origin checks, `ALLOWED_CLIENTS`, 403 troubleshooting |
| [docs/sandbox.md](docs/sandbox.md) | Why the agent's command sandbox needs bubblewrap and those two `--security-opt` values |
| [docs/remote-signin.md](docs/remote-signin.md) | Signing in with a DeepSeek **account** from another machine |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Building, testing, releasing |

**Known limits.** Single-user by design: there is no account database, so everyone who reaches the UI acts as the same owner. DeepSeek **account** sign-in from a remote browser costs one paste step into a panel the page shows by itself; an API key skips it entirely. Upstream is in developer preview, so breaking changes are expected — see the notice at the top. About 0.9 GB on disk.

## Support

- **This image (build, container, docs):** [GitHub Issues](https://github.com/2220545672/dsh-docker/issues) — please include `docker logs <container> | head -30`, your host OS and kernel (`uname -r`), and how `PUBLIC_URL` / `ALLOWED_CLIENTS` are set.
- **Unraid template and Community Applications:** the [forum thread](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/) (the CA entry links there) or [2220545672/dsh-unraid](https://github.com/2220545672/dsh-unraid).
- **Problems inside DSH itself** (models, plugins, UI): [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness).

## License

MIT — see [LICENSE](LICENSE). DeepSeek Harness itself is MIT, published by DeepSeek; this repository only packages it.

Not affiliated with, endorsed by or authorised by DeepSeek or Lime Technology.
