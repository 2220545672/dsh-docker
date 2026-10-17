[English](extending.md) · **中文**

# 自己装的命令行工具与插件

凡是你自己装的东西都放在 `/data`（卷上，永远不在镜像里）——这正是它能扛过 `docker pull`
与容器重建的原因。两条规则基本覆盖了所有踩坑方式：

- **用 uid 1000 安装**（`docker exec -u 1000 …`）。用 root 装，文件在 `/data` 里属 root，
  随后以 uid 1000 运行的 DSH 进程就读不到了。
- **装完重启容器。** entrypoint 只在启动时扫一次你的工具目录。

## 自己装命令行工具

`docker exec … npm i -g` 是个陷阱：全局安装目录在镜像的分层文件系统里，容器一重建工具就没了。装到 `/data` 下面才能跨更新存活——entrypoint 会把下面两种布局加到 DSH 进程（以及它派生的一切，也就是插件 shell 出去执行命令时的环境）的 `PATH` 上：

```bash
# npm 装的 CLI：不用建软链，tools/<名字>/node_modules/.bin 本身就会被扫到
docker exec -u 1000 <容器名> npm i --prefix /data/dsh/tools/codegraph @colbymchenry/codegraph

# 单个可执行文件：直接放进去，或者从装好的位置软链过来
docker exec -u 1000 <容器名> ln -s /data/dsh/tools/codegraph/node_modules/.bin/codegraph /data/dsh/bin/codegraph
```

两者都在启动时扫一次 —— `/data/dsh/bin` 与所有 `/data/dsh/tools/*/node_modules/.bin`（没改过 `DSH_HOME` 时就是这些路径）—— 并且是**追加**到 `PATH` 末尾、不是插到前面，所以你装的工具不可能盖掉镜像自带的 `node`/`git`/`curl`。两个目录都不存在时行为完全不变；扫到东西时容器日志会说明：

```text
[entrypoint] operator tools on PATH: /data/dsh/bin:/data/dsh/tools/codegraph/node_modules/.bin
```

装完要重启容器（扫描只在启动时做一次）。`docker exec` 进去的会话仍是镜像原本的 `PATH`，在那里请用绝对路径调用。

## 装插件

DSH 插件由 **profile** 加载，而 profile 就在持久卷上 —— 所以装过的插件在容器重建后依然在：

```bash
docker exec -u 1000 <容器名> dsh plugin --profile web add @scope/some-plugin
docker exec -u 1000 <容器名> dsh plugin --profile web add github:owner/repo
docker exec -u 1000 <容器名> dsh plugin --profile web why @scope/some-plugin   # 看 profile 里现在有什么
docker exec -u 1000 <容器名> dsh plugin --profile web remove @scope/some-plugin
```

`dsh plugin` 把参数原样转发给 profile 目录（默认 `/data/dsh/profiles/web`）里的 pnpm，启动时 launcher 会把该 profile 声明的层组合起来 —— **装完重启容器**才会加载。两个容易踩的点：

- **必须用 uid 1000 执行**（`docker exec -u 1000 …`）。用 root 装，文件在 `/data` 里属 root，随后以 uid 1000 运行的 DSH 进程就读不到了。
- **插件若还要调自己的命令行工具**，那个工具也得在 DSH 进程的 `PATH` 上：先按上一节把它装到 `/data` 下，entrypoint 下次启动就会带上它。

除此之外镜像里不预装任何插件：你的插件是你的，且都在能扛过 `docker pull` + 重建的那个卷里。唯一的例外是远程登录插件——它**有意**待在镜像里（钉住一个发行 tag），好让默认安装就能从远程浏览器登录（见 [remote-signin.zh-CN.md](remote-signin.zh-CN.md)）。
