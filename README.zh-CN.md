<h1 align="center">DSH — DeepSeek Harness 容器版</h1>

<p align="center">把 <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>（在浏览器里驱动的 AI 编程智能体）装进一个自包含镜像，任何 Docker 主机都能跑：一个端口、两个卷、一条命令。</p>

<p align="center"><a href="README.md">English</a> · <b>中文说明</b><br>
<a href="https://github.com/2220545672/dsh-docker/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-docker/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
<a href="https://github.com/2220545672/dsh-docker/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-docker?label=tracking&color=orange" alt="tracking"></a>
<img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
<img src="https://img.shields.io/badge/license-MIT-green" alt="license"></p>

> **开发者预览。** 上游迭代很快，破坏兼容性的变更会持续出现。本镜像自动跟随上游发布——想自己掌握节奏就钉住[版本标签](#更新)。

## 这个镜像的优势

| | 自己跑上游 | `ghcr.io/2220545672/dsh` |
|---|---|---|
| 启动 | 自己装 npm 包、手工配置 | `docker compose up -d` |
| 没有 Landlock 的内核上（Unraid 7.x、部分设备内核）的命令沙箱 | 起不来 | 可用——内置 bubblewrap，[`compose.yaml`](compose.yaml) 里已带那两个 `--security-opt` |
| 从另一台机器用 DeepSeek **账号**登录 | 登录页还没打开就失败 | 内置，只多一步粘贴（[说明](docs/remote-signin.zh-CN.md)） |
| 插件要调用的命令行工具 | 自己挂到 `PATH` 上 | 装在 `/data` 下，[启动时自动挂上](docs/extending.zh-CN.md)，并扛过 `docker pull` 与重建 |
| 跟随上游 | 你自己的活 | 每小时：取版本 → 构建 amd64 + arm64 → 冒烟 → 全绿才发布 |

**已知限制。** 单用户设计——没有账户体系，能打开界面的人就是同一个工作区主人。从另一台机器用 DeepSeek **账号**登录要多一步粘贴（粘进页面自己弹出的面板），用 API Key 则完全不需要。镜像约 0.9 GB。

## 快速开始

```bash
docker compose up -d          # compose.yaml 里已经带好下面的设置
```

打开 **`http://<你的主机>:8080`**，用户名 `dsh`；口令只在日志里打印过一次：

```bash
docker logs dsh | grep -i password
```

<details>
<summary>不用 Compose，直接 <code>docker run</code></summary>

```bash
docker run -d --name dsh --restart unless-stopped -p 8080:8080 \
  -e ALLOWED_CLIENTS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,fc00::/7,fe80::/10 \
  -v "$PWD/dsh/data:/data" \
  -v "$PWD/dsh/workspace:/workspace" \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

</details>

**然后：** 设 `DSH_PASSWORD`、把智能体指向你的项目（目录选择器默认落在 `/workspace`，`~/workspace` 是指向它的软链）、填 API Key 或用账号登录。

`403`、`SANDBOX_UNAVAILABLE`、或登录标签页停在 `127.0.0.1`？三种都在[常见问题](#常见问题)里，附能分辨“真故障”与“误报”的命令。

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

已经上了 SSO（Authelia、Authentik、NAS 自带门户……）？`AUTH_MODE=none` 加 `PUBLIC_URL`，**不要再叠一层登录**——代理自身必须在 `ALLOWED_CLIENTS` 里，取舍见 [docs/security.zh-CN.md](docs/security.zh-CN.md)：

```yaml
# 放在鉴权反代后面的容器，compose.yaml 的覆盖写法
environment:
  AUTH_MODE: none                       # 由前面的代理鉴权
  PUBLIC_URL: https://dsh.example.com   # Host 会被改写成它；外来 Origin 一律拒绝
  TRUSTED_PROXY_CIDRS: 172.30.0.0/24    # 可选：按 X-Forwarded-For 判定真实客户端 IP
```

卷的属主会被接管为 `1000:1000`，别改成 NAS 习惯的 `99:100`。

## 自己装的工具与插件

装到 `/data` 下、用 **uid 1000** 装，再重启容器，它们就能扛过 `docker pull` 与重建——entrypoint 会把它们挂到 DSH 进程的 `PATH` 上。用 root 跑 `docker exec … npm i -g` 则一样都做不到。两份配方：[docs/extending.zh-CN.md](docs/extending.zh-CN.md)。

## 更新

```bash
docker pull ghcr.io/2220545672/dsh:latest
docker compose up -d          # 或重建你自己的容器
```

`/data` 与 `/workspace` 里的东西都不会动。

| 标签 | 含义 |
|---|---|
| `:latest` | 最新构建（含上游预发布版） |
| `:0.2.1-alpha.5` | 钉住某个确切版本 |
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
| [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md) | 容器里逐层跑着什么 |
| [docs/extending.zh-CN.md](docs/extending.zh-CN.md) | 能扛过更新的命令行工具与插件 |
| [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md) | 构建、测试、发布 |

## 支持

- **本镜像（构建、容器、文档）：**[GitHub Issues](https://github.com/2220545672/dsh-docker/issues)——请附上 `docker logs <容器名> | head -30`、宿主系统与内核版本（`uname -r`）、以及 `PUBLIC_URL` / `ALLOWED_CLIENTS` 的设置方式。
- **Unraid 模板与 Community Applications：**[论坛帖](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)（CA 条目就指向那里）或 [2220545672/dsh-unraid](https://github.com/2220545672/dsh-unraid)。
- **DSH 自身的问题**（模型、插件、界面）：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 许可

MIT，见 [LICENSE](LICENSE)。DeepSeek Harness 本身由 DeepSeek 以 MIT 发布，本仓库只做打包。

与 DeepSeek、Lime Technology 均无隶属或授权关系。
