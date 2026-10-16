<h1 align="center">DSH — DeepSeek Harness 容器版</h1>

<p align="center">把 <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>（浏览器里用的 AI 编程智能体）装进一个自包含镜像，任何 Docker 主机都能跑：命令沙箱在没有 Landlock 的内核上也能用，每次上游发版自动重建并冒烟测试。</p>

<p align="center"><a href="README.md">English</a> · <b>中文说明</b></p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-docker/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-docker/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <a href="https://github.com/2220545672/dsh-docker/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-docker?label=tracking&color=orange" alt="tracking"></a>
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

---

> **开发者预览。** DeepSeek Harness 处于 _开发者预览_ 阶段，正在快速迭代。**未来将出现破坏兼容性的变更。** —— 引自[上游项目](https://github.com/deepseek-ai/deepseek-harness/blob/main/README.zh.md#开发者预览)。本镜像会自动跟随上游发布；想自己掌握节奏，可以钉住[版本标签](#更新)。

## 快速开始

```bash
docker run -d --name dsh --restart unless-stopped -p 8080:8080 \
  -e ALLOWED_CLIENTS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 \
  -v "$PWD/dsh/data:/data" \
  -v "$PWD/dsh/workspace:/workspace" \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

然后打开 **`http://<你的主机>:8080`**，用户名 `dsh`、口令是日志里打印过一次的那一串（`docker logs dsh`）。

也可以用 Compose —— [`compose.yaml`](compose.yaml) 里已经带好同样的设置：

```bash
docker compose up -d
```

**首次运行最容易踩的三点：**

- **自己写命令时 `ALLOWED_CLIENTS` 不能省。** 镜像自身的默认值是「只允许回环」——这正是"刚发布的端口不会变成敞开的门"的原因——所以其它机器上的浏览器会拿到 `403`，直到你把所在网段加进去。`compose.yaml` 里已经写好了上面那一行。
- **没有 Landlock 的内核上（Unraid 7.x 及部分设备内核）两个 `--security-opt` 都必须给**，否则智能体的命令沙箱起不来；有 Landlock 的内核可以去掉。原理、对照实验，以及两种会误报的自查方式，见 [docs/sandbox.zh-CN.md](docs/sandbox.zh-CN.md)。
- **`/data` 与 `/workspace` 必须持久化。** 会话、凭据与智能体主目录在 `/data`，你的项目在 `/workspace`。

## 头五分钟

1. **先改口令。** 没设 `DSH_PASSWORD` 时，容器会在首启生成一个并只在日志里打印一次（`docker logs <容器名>`）。想自己定就设 `DSH_PASSWORD`（或 `DSH_PASSWORD_FILE`）；用户名默认 `dsh`（`AUTH_USER`）。
2. **指向你的项目。** 智能体在 `/workspace` 里干活，目录选择器默认也落在那里（`~/workspace` 是指向它的软链）。
3. **填 DeepSeek API Key**：设置面板里的 *Add API key*。用 DeepSeek **账号**登录现在从任何浏览器都能完成：登录标签页停在打不开的 `127.0.0.1` 页面上时，**页面里会自动出现粘贴框**，把地址粘进去即可收尾——详见 [docs/remote-signin.zh-CN.md](docs/remote-signin.zh-CN.md)。

## 整体是怎么搭的

一个容器、两个进程、一个端口：

```text
浏览器 ──▶ :8080  Caddy（内置）  ──▶ 127.0.0.1:3080  DSH
                    ├─ 可选口令门禁（默认开启）
                    ├─ 白名单：ALLOWED_CLIENTS
                    ├─ 安全响应头、Host/Origin 校验
                    └─ /healthz 供容器健康检查
```

- **反向代理已经内置在镜像里。** 对外提供服务的是 Caddy，它转发给只监听回环的 DSH——所以你发布的那个端口是唯一入口，而安全响应头、跨站请求拦截、"远程无意义端点"的拒绝都在这一层完成。你不需要额外安装或配置任何代理。
- **认证是可选的，而且只是一个开关。** `AUTH_MODE=builtin`（默认）会用浏览器常见的登录框要一次口令，随后以 Cookie 保持登录（该 Cookie 同样覆盖 WebSocket 握手）；`AUTH_MODE=none` 则把鉴权交给前面那一层（带 SSO 的反向代理、VPN、可信内网）。填其它值容器会**拒绝启动**，而不是"看起来有认证"地裸奔——另外**永远不要叠两层登录**。无论哪种模式，容器自身的健康检查都保持免认证。
- **白名单也在同一层。** `ALLOWED_CLIENTS` 决定谁能连进来；回环永远放行，这正是健康检查能工作的原因。
- **以非特权身份运行。** uid 1000、不挂 docker socket、除你映射的两个卷之外不碰任何宿主目录。凭据存在 `/data`——这就是那个卷必须持久化的原因。
- **命令沙箱有两条腿**：bubblewrap（本镜像内置，多数社区镜像没有）与 Landlock（上游的 `landlock-run`，要求内核编入了它）。没有 Landlock 时，正是 bubblewrap 加上那两个 `--security-opt` 把模型生成的命令关在工作区里：[docs/sandbox.zh-CN.md](docs/sandbox.zh-CN.md)。
- **明文 HTTP 上的口令在公网上不安全。** 门禁保护的是应用而不是链路：对外暴露前，请在它前面终止 TLS。细节见 [docs/security.zh-CN.md](docs/security.zh-CN.md)。

## 可能会用到的设置

| 设置 | 默认 | 作用 |
|---|---|---|
| `8080` | — | 唯一需要发布的端口。DSH 自身只监听容器内的 `127.0.0.1:3080`，由内置代理对外提供 `:8080`。 |
| `/data` · `/workspace` | — | 会话、凭据、智能体主目录 · 你的项目。**两者都必须持久化。** |
| `ALLOWED_CLIENTS` | 仅回环 | 谁能连进来：IP/CIDR（也可以写域名，按 `Host` 匹配）。 |
| `PUBLIC_URL` | 空 | 前面有反向代理时填对外地址（`https://dsh.example.com`）；只在局域网/Tailscale 用就留空。 |
| `DSH_TRUSTED_HOSTS` | 空 | 额外可信的 `host[:port]`，逗号分隔；只在设置了 `PUBLIC_URL` 时生效。 |
| `TRUSTED_PROXY_CIDRS` | 空 | 仅当前面有反向代理时填写：Caddy 只对这些来源读取 `X-Forwarded-For`，让 `ALLOWED_CLIENTS` 看到真实客户端地址。 |
| `AUTH_MODE` | `builtin` | `builtin` = 容器内口令门禁；`none` = 交给前面的代理鉴权。填其它值容器会拒绝启动。 |
| `DSH_PASSWORD` | 未设 | 口令门禁的密码（也可用 `DSH_PASSWORD_FILE`）。未设 = 首启生成并打印一次。 |
| `AUTH_USER` | `dsh` | 口令门禁的用户名。 |
| `REMOTE_SIGNIN` | `on` | 远程浏览器用 DeepSeek **账号**登录：加载 [dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin)，由它把粘贴面板注入页面。`off` = 回到上游「仅回环」行为。 |
| `TZ` | `compose.yaml` 里是 `Asia/Shanghai` | 容器时区。 |

已经上了 SSO（Authelia、Authentik、NAS 自带门户……）？把 `AUTH_MODE` 设为 `none` 并填 `PUBLIC_URL`，**不要再叠一层登录**。

卷的属主会被接管为 `1000:1000`，别改成 NAS 习惯的 `99:100`。

## 用 DeepSeek 账号登录

上游会把**你此刻打开界面的地址**交给 DeepSeek 平台，让平台把登录结果送回那里——而平台只接受*本机*地址。于是从另一台机器点「用 DeepSeek 账号登录」，在登录页打开之前就失败了（提示「操作未完成，请重试。」），变通办法一直是改用 API Key 或每次开 `ssh -L` 隧道。

本镜像集成了 **[dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin)**——插件有独立仓库、独立 CI 与独立发版，镜像只钉住其中一个 tag——它会向平台注册一个 `127.0.0.1` 地址，并在有登录等待时把粘贴框放进 DSH 页面。你点「登录账号」，登录页照常打开；当标签页停在打不开的 `127.0.0.1` 页面时，把那个地址粘进已经自动出现的框里即可。**只多这一步**；把 `REMOTE_SIGNIN` 设为 `off`（见[设置](#可能会用到的设置)）就回到上游行为。原理与它刻意不动的东西见 [docs/remote-signin.zh-CN.md](docs/remote-signin.zh-CN.md)。

## 更新

```bash
docker pull ghcr.io/2220545672/dsh:latest
docker compose up -d          # 或重建你自己的容器
```

`/data` 与 `/workspace` 里的东西都不会动。

| 标签 | 含义 |
|---|---|
| `:latest` | 最新构建（含上游预发布版） |
| `:0.2.1-alpha.4` | 钉住某个确切版本 |
| `:alpha` · `:rc` · `:stable` | 跟随某个上游通道 |

每小时有定时任务检查上游、重建并做冒烟测试，全部通过才发布。上游目前只有 alpha/rc，`:latest` 更新较频繁——想自己掌握节奏就钉版本标签。

## 常见问题

| 现象 | 处理 |
|---|---|
| 页面提示 “dsh web authentication required; reopen the URL printed by dsh web” | **刷新页面即可。** 这是浏览器持有一个 DSH 已不再接受的会话 Cookie（镜像更新、容器重建、或同主机另一个 DSH 实例都会造成——Cookie 不区分端口）。容器自己会发现并重新签发会话；手动打开 `http://<主机>:<端口>/renew`、或清掉该站点 Cookie，效果相同。 |
| 工具报 `SANDBOX_UNAVAILABLE` | 启动参数里少了那两个 `--security-opt`（Unraid 上它们在 **Extra Parameters** 里），补回去。自查时有两个坑：`systempaths=unconfined` **不会**出现在 `docker inspect` 的 `SecurityOpt` 里（它表现为 `MaskedPaths`/`ReadonlyPaths` 变空），而 bwrap **只在 uid 1000 下可用** —— DSH 正是以 uid 1000 跑的。所以要按 DSH 的方式测：`docker exec -u 1000 <容器> bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true` → exit 0。用 root（`docker exec` 默认身份）测必然报 *Creating new namespace failed*，那不能说明容器有问题；`--cap-add SYS_ADMIN` 与 `--privileged` 都不需要，而且都会削弱容器隔离。 |
| 浏览器拿到 `403` | 你的地址不在 `ALLOWED_CLIENTS` 里；裸 `docker run` 默认只放行回环。 |
| 用 DeepSeek 账号登录报「登录失败 / 操作未完成」 | 上游只接受**回环**来源，于是登录标签页被重定向到 `127.0.0.1` 后死在那里。**这一步正是插件负责收尾的：**那时 DSH 页面里已经自动出现粘贴面板——把那个打不开页面的地址粘进去。请**在约 10 分钟内、同一个容器里**完成（更新或重建容器都会作废这次尝试）。面板若没出现，就是插件没加载：把 `REMOTE_SIGNIN` 设为 `on`（本来就是默认值），并用 `docker logs <容器名> \| grep remote-signin` 看原因。不想粘贴？开一次隧道用回环地址登录：`ssh -L 3081:127.0.0.1:<发布端口> user@<服务器>`，再打开 `http://127.0.0.1:3081`。 |
| 更新了却没变化 | 重建容器——正在运行的容器一直用它启动时的那份镜像。 |
| 页面一直转圈 | `PUBLIC_URL` 必须与你实际打开的地址一致（协议 + 主机，不带路径）。`docker logs <容器名> \| head -30` 会打印它选定的模式。 |

## 在 Unraid 上

Unraid 不需要专门的构建：在 Community Applications 里装 **DSH**，并保留模板自带的
**Extra Parameters**——那两个 `--security-opt` 是沙箱在 Unraid 内核上工作的前提。Unraid
相关的说明（模板字段、从别的 DSH 镜像迁移）与论坛[支持帖](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)
都在 **[2220545672/dsh-unraid](https://github.com/2220545672/dsh-unraid)**。

## 更多文档

| 文档 | 内容 |
|---|---|
| [docs/security.zh-CN.md](docs/security.zh-CN.md) | 口令门禁、Host/Origin 校验、`ALLOWED_CLIENTS`、403 排障 |
| [docs/sandbox.zh-CN.md](docs/sandbox.zh-CN.md) | 为什么命令沙箱需要 bubblewrap 与那两个 `--security-opt` |
| [docs/remote-signin.zh-CN.md](docs/remote-signin.zh-CN.md) | 从另一台机器用 DeepSeek **账号**登录 |
| [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md) | 构建、测试、发布 |

**已知限制。** 单用户设计：没有账户体系，能打开界面的人就是同一个工作区主人。远程浏览器用 DeepSeek **账号**登录要多一步粘贴（粘进页面自己弹出的面板）；用 API Key 则完全不需要。上游处于开发者预览阶段，破坏兼容性的变更属于预期之内——见开头的提示。镜像约 0.9 GB。

## 支持

- **本镜像（构建、容器、文档）：**[GitHub Issues](https://github.com/2220545672/dsh-docker/issues)——请附上 `docker logs <容器名> | head -30`、宿主系统与内核版本（`uname -r`）、以及 `PUBLIC_URL` / `ALLOWED_CLIENTS` 的设置方式。
- **Unraid 模板与 Community Applications：**[论坛帖](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)（CA 条目就指向那里）或 [2220545672/dsh-unraid](https://github.com/2220545672/dsh-unraid)。
- **DSH 自身的问题**（模型、插件、界面）：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 许可

MIT，见 [LICENSE](LICENSE)。DeepSeek Harness 本身由 DeepSeek 以 MIT 发布，本仓库只做打包。

与 DeepSeek、Lime Technology 均无隶属或授权关系。
