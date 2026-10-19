**English** · [中文](extending.zh-CN.md)

# Your own CLI tools and plugins

Everything you install yourself lives under `/data` — the volume, never the image — which is
why it survives `docker pull` and a container recreate. Two rules cover almost every mistake:

- **Install as `PUID`** (`docker exec -u <PUID>:<PGID> …`; `1000:1000` unless you changed
  it, `99:100` on Unraid). As root the files land in `/data` owned by root, and the DSH
  process — `PUID` — can no longer read them.
- **Restart the container afterwards.** The entrypoint scans for your tools once, at start.

## Installing your own CLI tools

`docker exec … npm i -g` is a trap: the global prefix lives in the image's layered
filesystem, so the tool is gone the next time the container is recreated. Install under
`/data` instead and it survives every update — the entrypoint puts two layouts on the
PATH of the DSH process (and of everything DSH spawns, which is what a plugin shells out
to):

```bash
# an npm CLI — no symlink needed, tools/<name>/node_modules/.bin is picked up as it is
docker exec -u <PUID>:<PGID> <container> npm i --prefix /data/dsh/tools/codegraph @colbymchenry/codegraph

# a single binary — drop it in, or symlink it from wherever it was installed
docker exec -u <PUID>:<PGID> <container> ln -s /data/dsh/tools/codegraph/node_modules/.bin/codegraph /data/dsh/bin/codegraph
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
docker exec -u <PUID>:<PGID> <container> dsh plugin --profile web add @scope/some-plugin
docker exec -u <PUID>:<PGID> <container> dsh plugin --profile web add github:owner/repo
docker exec -u <PUID>:<PGID> <container> dsh plugin --profile web why @scope/some-plugin   # what the profile carries
docker exec -u <PUID>:<PGID> <container> dsh plugin --profile web remove @scope/some-plugin
```

`dsh plugin` forwards its arguments to pnpm inside `$DSH_HOME/profiles/web`
(`/data/dsh/profiles/web` by default), and the launcher composes whatever that profile
declares — restart the container to load it. Two details that bite:

- **Run it as `PUID`** (`docker exec -u <PUID>:<PGID> …`). As root the package lands in
  `/data` owned by root, and the DSH process — `PUID` — can no longer read it.
- **A plugin that shells out to its own command-line tool** needs that tool on the PATH of
  the DSH process as well; install it under `/data` first
  ([Installing your own CLI tools](#installing-your-own-cli-tools)) and the entrypoint
  picks it up at the next start.

Nothing else is installed into the image: your plugins are yours, and they sit on the
volume that survives `docker pull` and a recreate. The remote sign-in plugin is the one
deliberate exception — it ships inside the image, pinned to a release tag, so that a
default install can sign in from a remote browser ([remote-signin.md](remote-signin.md)).

## Ownership: PUID, PGID and the volumes

The container runs as the `PUID:PGID` pair, and every start hands the writable paths to it
(`$DSH_HOME`, `/home/node`, `${DSH_HOME%/dsh}/caddy`, and the workspace one level deep).
That sentence is the whole feature — it exists because on a NAS the directory behind `/data`
already belongs to somebody, and a process running as a third identity can neither read what
is there nor write what it creates:

```bash
# Unraid: appdata belongs to nobody:users, so the container should be that identity too
docker run --detach --name dsh --env PUID=99 --env PGID=100 … ghcr.io/2220545672/dsh:latest
```

The defaults are `1000:1000` — this image's own `node` account — so a compose or plain
`docker run` deployment keeps working untouched. `UMASK` (`022`, or `002` for a
group-writable workspace) decides what mode new files get. Both are refused loudly when they
cannot work: a non-numeric or `0` value, a uid or gid one of the image's own system accounts
holds, and a `DSH_PASSWORD_FILE` the chosen identity could not read all stop the container
instead of half-applying.

What the handover touches, and what it deliberately does not:

- **Ownership only.** Modes and contents are left alone: `0600` credentials stay `0600`, an
  operator's executables stay executable, and no file is rewritten.
- **`$DSH_HOME`, `/home/node`, Caddy's state, workspace top level.** The workspace's
  *contents* keep whatever ownership they have — its projects may belong to other services —
  while the directory itself is taken over, because DSH creates session directories in it.
- **`plugin-backup/` is skipped**: it is a whole-`node_modules` copy no running process
  reads, so walking it would only cost time.
- **Idempotent.** A path already owned by the pair costs one `find`; the handover itself runs
  only when something is not — a changed `PUID`, or a file another identity wrote. A rewrite
  too large for its time budget is reported and resumes at the next start.
- **One volume, one container.** Two containers with different `PUID`/`PGID` on the same
  `/data` rewrite each other's ownership at every start. Give each its own volume.

Changing `PUID` later is safe and ordinary: the next start notices and rewrites. On a large
`/data` that is a recursive `chown`, so give it the time or expect a second start to finish
the job.

To check what the container sees:

```bash
docker exec <container> sh -c 'id; ls -ln /data/dsh/profiles/web | head'
docker logs <container> 2>&1 | grep 'ownership of'   # what was handed over, and when
```
