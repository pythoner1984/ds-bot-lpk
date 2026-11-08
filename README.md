# DS Bot for Lazycat (微服) — LPK 打包层

把 [DS Bot](https://github.com/Fei2411/DS-Bot) 打包成**懒猫微服**（lazycat.cloud）可以一键安装的 LPK 应用。

上游代码**零改动**：这里只提供「镜像 + 启动脚本 + 平台清单」，从 npm 安装固定版本的 `@deepseek-ai/dsh` 与 `ds-bot` 插件，再按微服的运行方式把它们跑起来。

---

## 为什么需要这一层

上游自带的 `docker/` 形态解决不了三件事：

| 问题 | 上游 docker 形态 | 微服上的现实 | 本项目的做法 |
| --- | --- | --- | --- |
| 镜像来源 | `docker.io` / `node:24-bookworm-slim` | 盒子**连不上** docker.io 与 ghcr.io | 全部 `FROM` 走 `docker.m.daocloud.io` 镜像站 |
| 访问控制 | 单用户、只监听容器网段 | 平台把 `*.heiyu.space` 子域名**公开**出去 | 容器内 Caddy 加 HTTP Basic 认证 |
| 进程模型 | compose 的 `init: true` | 平台不给 service 配 init | 镜像装 `tini` 作 PID 1 |

此外 DSH 的两个硬约束在容器里需要显式喂参数：

- `--host` **拒绝通配符**，必须绑一个具体 IP → 这里让它绑 `127.0.0.1:3081`，只让 Caddy 进来。
- `/api` 有一道 **browser-trust fence**（防 DNS rebinding / CSRF），靠 `Host` 判定 → 必须用 `--trusted-host <应用域名>` 把平台域名加进白名单，否则页面能开、接口全 403。

---

## 运行结构

```
平台反向代理  ──►  Caddy  :3080   （Basic Auth、/healthz、SSE 立即 flush）
                     │
                     └──►  dsh --profile web  127.0.0.1:3081
                              │
                              ├─ 插件：ds-bot（Bot、群聊、记忆、技能、连接器）
                              └─ profile：/data/profiles/web

数据卷
  /data       profile、会话、bot 团队（bot/）、密钥（.credentials.yaml）、admin.txt
  /workspace  bot 的工作目录
```

三个脚本各管一段：

- `content/entry.sh`：以 root 跑一次，第一启把 `/opt/dsh-template` 铺到 `/data`，改属主，然后 `setpriv` 降权到 uid 1000。
- `content/run.sh`：以 uid 1000 常驻，生成/读取管理员密码，渲染 Caddyfile，起 Caddy，并把 `dsh` 放进**原地重启循环**。
- `image/Dockerfile`：构建期就把 `ds-bot` 装进模板 profile，所以首次启动**不需要联网**。

---

## 构建

需要本机有 `lzc-cli`（2.x）并且已经登录到目标盒子。构建在**盒子上**完成（`builder: remote`），本机不需要 Docker。

```powershell
cd ds-bot-lpk
lzc-cli project release .
# 产物：f00700f.ds-bot-v0.1.0.lpk
```

首次构建要拉 `node:24-bookworm` 并 `npm install -g @deepseek-ai/dsh ds-bot`，大约 5–10 分钟；之后只改变 content 层，镜像层走缓存。

## 安装

```powershell
lzc-cli app install .\f00700f.ds-bot-v0.1.0.lpk --apk n
```

安装完打开 `https://dsbot.<你的盒子>.heiyu.space`。

### 读出用户名和密码

```powershell
lzc-cli project exec --tty=false -s dsbot cat /data/admin.txt
```

也可以直接在应用的文件里打开 `/data/admin.txt`。密码同时存在 `/data/.admin-password`（0600）。

> `lzc-cli project exec` 默认进的是平台的 `app` 容器，本应用的服务名是 `dsbot`，`-s` 不能省；命令里带 `-` 开头的参数会被 yargs 吃掉，所以要用 stdin 喂 `sh`。

### 换密码

```powershell
lzc-cli project exec --tty=false -s dsbot rm /data/.admin-password
# 然后重启应用：密码会重新生成，admin.txt 若已存在需一并删掉
lzc-cli project exec --tty=false -s dsbot rm /data/admin.txt
```

---

## 配置模型

登录后进 **Settings → Model providers**，加一个 provider：

| 字段 | 火山方舟（按量）示例 |
| --- | --- |
| API 协议 | `openai-completions`（OpenAI 兼容） |
| API 地址 | `https://ark.cn-beijing.volces.com/api/v3` |
| API Key | 方舟控制台的 API Key |
| 模型 ID | 控制台里**已开通**的模型 ID，如 `deepseek-v4-1-flash-261017` |

Coding Plan 走的是 anthropic 协议，地址是 `https://ark.cn-beijing.volces.com/api/coding`，协议选 `anthropic-messages`。

> 模型是否可用取决于账号侧是否开通：返回 `ModelNotOpen` 说明该模型没开通，`InvalidSubscription` 说明 Coding Plan 过期。这两类错误和打包无关，换 key 或开通模型即可。

---

## 与上游 docker 形态的差异

| 项 | 上游 `docker/` | 本项目 |
| --- | --- | --- |
| 基础镜像 | `node:24-bookworm-slim` | `docker.m.daocloud.io/library/node:24-bookworm` |
| 插件来源 | 源码 `npm pack` | npm 上的 `ds-bot@0.3.1` |
| 认证 | 无（靠容器网络边界） | Caddy Basic Auth，密码随机生成 |
| 监听 | 容器 IP:3080 | Caddy :3080 → dsh 127.0.0.1:3081 |
| 健康检查 | 容器内 `dsh` 端口 | `/healthz`（Caddy 直答，不经过认证） |
| 数据 | `/data`、`/workspace` | 相同，但挂到平台卷 |

---

## 已知限制

- **没有 Chrome**：浏览器工具、依赖浏览器的 computer use 不可用。
- **审批默认 Full access**：容器即边界。`/data` 里有模型密钥，bot 能读到。
- **SSE 平台层未验证**：容器内已经 `flush_interval -1`，平台反向代理是否缓冲事件流无法从容器内观测；如果回复变成「一次性蹦出来」，就是这个原因。
- **升级要重打包**：`DSH_VERSION` / `DS_BOT_VERSION` 在 `image/Dockerfile`，两个都要跟上游要求对齐（ds-bot 目前面向 dsh `0.2.2-rc.1`）。
- **没有回滚**：平台不保留历史 lpk，升级前自行留一份旧包。

## 排障

```powershell
# 容器里发生了什么
lzc-cli project exec --tty=false -s dsbot sh
#   ps aux / cat /tmp/Caddyfile / ls -la /data / tail -n 50 /data/profiles/web/... 

# 只看健康
lzc-cli project exec --tty=false -s dsbot 'node -e "require(\"node:http\").get(\"http://127.0.0.1:3080/healthz\",r=>console.log(r.statusCode))"'
```

- **一直 401**：密码不对，或 Caddyfile 里 hash 与 `.admin-password` 不一致（改密码后必须重启）。
- **页面能开、接口 403**：`--trusted-host` 没拿到平台域名（`LAZYCAT_APP_DOMAIN` 为空）。
- **状态一直 Starting**：看 `dsh` 是否在重启循环里刷错误，通常是 profile 里插件加载失败。

## 许可与归属

- 本仓库（打包层）：Apache-2.0。
- 上游 [DS-Bot](https://github.com/Fei2411/DS-Bot)：Apache-2.0，作者 Fei2411。
- 运行时 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)：随 npm 包分发。
- 镜像内 Caddy：Apache-2.0。

本项目与 DeepSeek、懒猫微服均无隶属关系，只是社区打包。
