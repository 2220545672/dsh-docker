[English](extending.md) · **中文**

# 自己装的命令行工具与插件

凡是你自己装的东西都放在 `/data`（卷上，永远不在镜像里）——这正是它能扛过 `docker pull`
与容器重建的原因。两条规则基本覆盖了所有踩坑方式：

- **用 `PUID` 安装**（`docker exec -u <PUID>:<PGID> …`；没改过就是 `1000:1000`，Unraid 上是 `99:100`）。用 root 装，文件在 `/data` 里属 root，
  随后以 `PUID` 运行的 DSH 进程就读不到了。
- **装完重启容器。** entrypoint 只在启动时扫一次你的工具目录。

## 自己装命令行工具

`docker exec … npm i -g` 是个陷阱：全局安装目录在镜像的分层文件系统里，容器一重建工具就没了。装到 `/data` 下面才能跨更新存活——entrypoint 会把下面两种布局加到 DSH 进程（以及它派生的一切，也就是插件 shell 出去执行命令时的环境）的 `PATH` 上：

```bash
# npm 装的 CLI：不用建软链，tools/<名字>/node_modules/.bin 本身就会被扫到
docker exec -u <PUID>:<PGID> <容器名> npm i --prefix /data/dsh/tools/codegraph @colbymchenry/codegraph

# 单个可执行文件：直接放进去，或者从装好的位置软链过来
docker exec -u <PUID>:<PGID> <容器名> ln -s /data/dsh/tools/codegraph/node_modules/.bin/codegraph /data/dsh/bin/codegraph
```

两者都在启动时扫一次 —— `/data/dsh/bin` 与所有 `/data/dsh/tools/*/node_modules/.bin`（没改过 `DSH_HOME` 时就是这些路径）—— 并且是**追加**到 `PATH` 末尾、不是插到前面，所以你装的工具不可能盖掉镜像自带的 `node`/`git`/`curl`。两个目录都不存在时行为完全不变；扫到东西时容器日志会说明：

```text
[entrypoint] operator tools on PATH: /data/dsh/bin:/data/dsh/tools/codegraph/node_modules/.bin
```

装完要重启容器（扫描只在启动时做一次）。`docker exec` 进去的会话仍是镜像原本的 `PATH`，在那里请用绝对路径调用。

## 装插件

DSH 插件由 **profile** 加载，而 profile 就在持久卷上 —— 所以装过的插件在容器重建后依然在：

```bash
docker exec -u <PUID>:<PGID> <容器名> dsh plugin --profile web add @scope/some-plugin
docker exec -u <PUID>:<PGID> <容器名> dsh plugin --profile web add github:owner/repo
docker exec -u <PUID>:<PGID> <容器名> dsh plugin --profile web why @scope/some-plugin   # 看 profile 里现在有什么
docker exec -u <PUID>:<PGID> <容器名> dsh plugin --profile web remove @scope/some-plugin
```

`dsh plugin` 把参数原样转发给 profile 目录（默认 `/data/dsh/profiles/web`）里的 pnpm，启动时 launcher 会把该 profile 声明的层组合起来 —— **装完重启容器**才会加载。两个容易踩的点：

- **必须用 `PUID` 执行**（`docker exec -u <PUID>:<PGID> …`）。用 root 装，文件在 `/data` 里属 root，随后以 `PUID` 运行的 DSH 进程就读不到了。
- **插件若还要调自己的命令行工具**，那个工具也得在 DSH 进程的 `PATH` 上：先按上一节把它装到 `/data` 下，entrypoint 下次启动就会带上它。

除此之外镜像里不预装任何插件：你的插件是你的，且都在能扛过 `docker pull` + 重建的那个卷里。唯一的例外是远程登录插件——它**有意**待在镜像里（钉住一个发行 tag），好让默认安装就能从远程浏览器登录（见 [remote-signin.zh-CN.md](remote-signin.zh-CN.md)）。

## 属主：PUID、PGID 与那几个卷

容器以 `PUID:PGID` 这对身份运行，每次启动都会把「自己要写的地方」交给它（`$DSH_HOME`、
`/home/node`、`${DSH_HOME%/dsh}/caddy`，以及工作区的一层）。这一句就是全部功能——它存在
的原因是：NAS 上 `/data` 背后的目录早就属于某个人了，而以第三种身份运行的进程既读不到里面
已有的东西，也写不出自己能读的东西：

```bash
# Unraid：appdata 属于 nobody:users，容器就应该用同一个身份
docker run --detach --name dsh --env PUID=99 --env PGID=100 … ghcr.io/meixu6693/dsh:latest
```

默认值是 `1000:1000`（镜像自带的 `node` 账号），所以 compose / 裸 `docker run` 部署一字不改
照常工作。`UMASK`（`022`；共享可写工作区用 `002`）决定新建文件的权限位。两者只要不可用都会
**明确拒绝启动**而不是半生效：非数字或 `0`、与镜像自带系统账号撞号、以及所选身份读不了的
`DSH_PASSWORD_FILE`。

接管动作碰什么、不碰什么：

- **只改属主。** 权限位与内容一律不动：`0600` 的凭据还是 `0600`，操作者的可执行文件照样可执行，没有任何文件被重写。
- **`$DSH_HOME`、`/home/node`、Caddy 状态目录、工作区顶层。** 工作区的**内容**保持原属主（里面的项目可能属于别的服务），只接管目录本身——因为 DSH 要在里面建会话目录。
- **跳过 `plugin-backup/`**：那是整包 `node_modules` 备份，没有运行期读者，遍历它只浪费时间。
- **幂等。** 已经属于这对身份的路径只花一次 `find`；只有当某处不符（改了 `PUID`，或别的身份写过）才真正执行接管。超出时间预算的大规模重写会打印警告，并在下次启动继续。
- **一个卷只给一个容器。** 两个不同 `PUID`/`PGID` 的容器挂同一个 `/data`，每次启动都会互相重写属主。各给各的卷。

以后改 `PUID` 是安全的常规操作：下次启动会发现并重写。`/data` 很大时那是一次递归 `chown`——
留够时间，或者接受第二次启动把活干完。

查看容器看到的东西：

```bash
docker exec <容器名> sh -c 'id; ls -ln /data/dsh/profiles/web | head'
docker logs <容器名> 2>&1 | grep 'ownership of'   # 交接过什么、什么时候
```
