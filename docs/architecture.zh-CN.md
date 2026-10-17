[English](architecture.md) · **中文**

# 整体是怎么搭的

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
- **命令沙箱有两条腿**：bubblewrap（本镜像内置，多数社区镜像没有）与 Landlock（上游的 `landlock-run`，要求内核编入了它）。没有 Landlock 时，正是 bubblewrap 加上那两个 `--security-opt` 把模型生成的命令关在工作区里：[sandbox.zh-CN.md](sandbox.zh-CN.md)。
- **明文 HTTP 上的口令在公网上不安全。** 门禁保护的是应用而不是链路：对外暴露前，请在它前面终止 TLS。细节见 [security.zh-CN.md](security.zh-CN.md)。

前两条背后的规则——两种模式、Host/Origin 的处理、白名单——见 [security.zh-CN.md](security.zh-CN.md)；沙箱的两条腿见 [sandbox.zh-CN.md](sandbox.zh-CN.md)。
