**English** · [中文](architecture.zh-CN.md)

# How the container is put together

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
- **It runs unprivileged.** As `PUID`/`PGID` (`1000:1000` by default), no docker socket, no host directories beyond the two volumes you map. Credentials are stored in `/data` — the reason that volume must be persistent.
- **The command sandbox has two legs**: bubblewrap (bundled here, unlike most community images) and Landlock (upstream's `landlock-run`, which needs a kernel that compiled it in). Where Landlock is missing, bubblewrap plus the two `--security-opt` values is what keeps model-generated commands inside the workspace: [sandbox.md](sandbox.md).
- **A password over plain HTTP is not safe on the internet.** The gate protects the app, not the wire: terminate TLS in whatever you put in front before exposing this. Details: [security.md](security.md).

The rules behind the first two bullets — the two modes, Host/Origin handling and the allowlist — are in [security.md](security.md); the sandbox's two legs are in [sandbox.md](sandbox.md).
