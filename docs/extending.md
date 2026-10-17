**English** · [中文](extending.zh-CN.md)

# Your own CLI tools and plugins

Everything you install yourself lives under `/data` — the volume, never the image — which is
why it survives `docker pull` and a container recreate. Two rules cover almost every mistake:

- **Install as uid 1000** (`docker exec -u 1000 …`). As root the files land in `/data` owned
  by root, and the DSH process — uid 1000 — can no longer read them.
- **Restart the container afterwards.** The entrypoint scans for your tools once, at start.

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
default install can sign in from a remote browser ([remote-signin.md](remote-signin.md)).
