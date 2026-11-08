# DS Bot for Lazycat (微服) — LPK 打包层

把 [DS Bot](https://github.com/Fei2411/DS-Bot) 打包成**懒猫微服**（lazycat.cloud）可以一键安装的 LPK 应用。

上游代码**零改动**：这里只提供「镜像 + 启动脚本 + 平台清单」，构建时从 npm 装固定版本的 `@deepseek-ai/dsh` 与 `ds-bot` 插件，按微服的方式把它们跑起来。

当前包版本 **0.1.3**，装在盒子上服务名 `dsbot`，默认地址 `https://dsbot.<盒子名>.heiyu.space`。

---

## 为什么需要这一层

上游自带的 `docker/` 形态解决不了四件事：

| 问题 | 上游 docker 形态 | 微服上的现实 | 本项目的做法 |
| --- | --- | --- | --- |
| 镜像来源 | `docker.io` / `node:24-bookworm-slim` | 盒子**连不上** docker.io 与 ghcr.io | 全部 `FROM` 走 `docker.m.daocloud.io` 镜像站 |
| 访问控制 | 单用户、只监听容器网段 | 平台把 `*.heiyu.space` 子域名公开，但**先要盒子账号登录** | 默认用平台登录当门；可选再叠 Basic Auth |
| 一次性令牌 | 打开 dsh 打印的 `?token=` 链接 | 平台里没有终端可看 stdout（`app log` 未实现） | 启动脚本抓令牌，自动换成浏览器 Cookie |
| 进程模型 | compose 的 `init: true` | 平台不给 service 配 init | 镜像装 `tini` 作 PID 1 |

此外 DSH 的两个硬约束在容器里必须显式喂参数：

- `--host` **拒绝通配符**（"bind one concrete IPv4 or IPv6 literal"）→ 绑 `127.0.0.1:3081`，只有 Caddy 能进。
- `/api` 有一道 **browser-trust fence**（防 DNS rebinding / CSRF），按 `Host` 判定 → 用 `--trusted-host <应用域名>` 把平台域名加进白名单，否则页面能开、接口全 403。

---

## 运行结构

```
平台反向代理 ──► Caddy :3080 ──► dsh --profile web  127.0.0.1:3081
                  │                 │
                  │                 ├─ 插件 ds-bot（Bot、群聊、记忆、技能、连接器）
                  │                 └─ profile /data/profiles/web
                  ├─ /healthz  直答 200，不过任何认证
                  ├─ 可选 Basic Auth（DSBOT_BASIC_AUTH=1）
                  └─ 首次访问：302 → /?token=… → DSH 换 Cookie → 回到 /

数据卷
  /data       profile、会话、bot 团队（bot/）、密钥（.credentials.yaml）、dsh.log、access.txt、admin.txt
  /workspace  bot 的工作目录
```

三个脚本各管一段：

- `content/entry.sh`：root 跑一次。`/data/profiles/web` 不存在就把 `/opt/dsh-template` 铺过去，改属主，然后 `setpriv` 降权到 uid 1000。
- `content/run.sh`：uid 1000 常驻。起 `dsh`（带 3 秒原地重启循环）→ 从 `dsh.log` 抓 launch token → 写 `access.txt` → 渲染 Caddyfile → 校验后起 Caddy → 等 `/healthz` 通过。
- `image/Dockerfile`：构建期就把 `ds-bot` 装进模板 profile，首启**不需要联网**。

---

## 构建

本机需要 `lzc-cli` 2.x 并已登录目标盒子。构建在**盒子上**完成（`builder: remote`），本机不需要 Docker。

```powershell
cd ds-bot-lpk
lzc-cli project release .          # 只出包
# 产物：f00700f.ds-bot-v0.1.3.lpk
```

首次构建要拉 `node:24-bookworm` 并 `npm install -g @deepseek-ai/dsh ds-bot`，约 3 分钟、镜像层 791.92 MiB / 15 layers；之后只改 `content/` 会命中 `Reuse cached OCI image package`，几秒出包。

## 安装 / 升级

```powershell
lzc-cli app install .\f00700f.ds-bot-v0.1.3.lpk --apk n
```

安装完打开 `https://dsbot.<盒子名>.heiyu.space`。升级用同一个命令装新包，`/data` 与 `/workspace` 是平台卷，**不会被清空**。

开发时可以用 `lzc-cli project deploy`（= build + install + start），它会同时把 dev project 拉起来，这样才能用 `project exec` 进容器。

---

## 登录

三条独立的门，按顺序：

1. **平台账号门**：`https://dsbot.<盒子>.heiyu.space` 先跳平台的 `Login to LazyCat Microservices`，过了才到本应用。默认就靠这一层。
2. **Basic Auth（可选，默认关）**：应用设置里加 `DSBOT_BASIC_AUTH=1` 才启用，密码随机生成在 `/data/.admin-password`（0600），用户名默认 `admin`（可用 `DSBOT_ADMIN_USER` 改）。想自己指定密码就设 `DSBOT_ADMIN_PASSWORD`。
3. **DSH 自己的令牌**：`dsh` 每次启动生成一次性 `?token=`，只有带它的请求能铸出 `dsh-auth-…` Cookie。

默认行为（本包的取舍）：**第 3 层自动完成**。第一次打开 `/` 时 Caddy 直接 302 到 `/?token=<当次令牌>`，DSH 铸好 Cookie 再 303 回 `/`，之后浏览器一直带着 Cookie。Cookie 的签名密钥存在 `/data/.credentials.yaml` 的 grant 记录里，所以**重启应用不掉登录**；只有清了浏览器 Cookie 或换了浏览器才需要重新走一次。

### 换浏览器 / 清了 Cookie 怎么办

打开 `/data/access.txt` 里那条链接即可（每次应用重启会重写，指向当次令牌）：

```powershell
lzc-cli project exec --tty=false -s dsbot cat /data/access.txt
```

也可以在应用的文件管理里直接看 `/data/access.txt`。

### 想恢复上游语义（令牌是唯一入口）

设 `DSBOT_STRICT_AUTH=1`：关掉自动 302，只认 `?token=` 链接。适合把应用暴露给多人、又不想让任何过了平台登录的人直接进到你 bot 的情况。

> 注意：默认配置下，**任何能登进这个盒子账号的人**打开子域名都会自动获得 bot 的完整控制权（包括它的密钥与工作目录）。单用户盒子没问题；多人共用盒子请开 `DSBOT_BASIC_AUTH=1` 或 `DSBOT_STRICT_AUTH=1`。

---

## 验证装好了

在容器里跑这三条，全部通过就是通的（`0.1.3` 实测）：

```powershell
lzc-cli project exec --tty=false -s dsbot sh
# 进去以后：
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://127.0.0.1:3080/
#   → 302 http://127.0.0.1:3080/?token=<43 字符>
TOK=$(sed -n 's/.*token=//p' /data/access.txt | head -n1)
curl -s -D - -o /dev/null -c /tmp/c "http://127.0.0.1:3080/?token=$TOK" | head -n 5
#   → 303 See Other + Location: ./ + Set-Cookie: dsh-auth-…
curl -s -b /tmp/c -o /dev/null -w '%{http_code} %{size_download}\n' http://127.0.0.1:3080/
#   → 200 40234（首页 HTML）
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

Coding Plan 走 anthropic 协议，地址 `https://ark.cn-beijing.volces.com/api/coding`，协议选 `anthropic-messages`。

> 能不能出字只取决于账号侧：`ModelNotOpen` = 该模型没开通，`InvalidSubscription` = Coding Plan 过期。这两类和打包无关。

---

## 与上游 docker 形态的差异

| 项 | 上游 `docker/` | 本项目 |
| --- | --- | --- |
| 基础镜像 | `node:24-bookworm-slim` | `docker.m.daocloud.io/library/node:24-bookworm` |
| 插件来源 | 源码 `npm pack` | npm 上的 `ds-bot@0.3.1` |
| 认证 | 无（靠容器网络边界） | 平台登录 + 自动令牌换 Cookie；可选 Basic Auth |
| 监听 | 容器 IP:3080 | Caddy :3080 → dsh 127.0.0.1:3081 |
| 健康检查 | 容器内 dsh 端口 | `/healthz`（Caddy 直答，不过认证） |
| 数据 | `/data`、`/workspace` | 相同，挂到平台卷 |
| 权限 | `danger-full-access` | 相同（容器即边界） |

---

## 已知限制

- **没有 Chrome**：浏览器工具、依赖浏览器的 computer use 不可用。远端云电脑（如果有）不受影响。
- **审批默认 Full access**：见 `image/lazycat.patch.yml`。`/data` 里有模型密钥，bot 能读到；别把不该给 bot 的目录挂进 `workspace`。
- **SSE 平台层未验证**：容器内已 `flush_interval -1`，平台反向代理是否缓冲事件流无法从容器内观测。若回复「一次性蹦出来」，原因在这层。
- **升级要重打包**：`DSH_VERSION` / `DS_BOT_VERSION` 在 `image/Dockerfile`，两者需与上游要求对齐（ds-bot 0.3.1 面向 dsh `0.2.2-rc.1`）。
- **没有回滚**：平台不保留历史 lpk，升级前自行留旧包。
- **`lzc-cli app log` 未实现**（返回 `not yet realized`），容器日志只能进容器看（`/data/dsh.log`）。

## 排障

```powershell
cd ds-bot-lpk
'ps -eo pid,uid,args | grep -E "caddy|dsh" | grep -v grep; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
'cat /tmp/Caddyfile; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
'tail -n 50 /data/dsh.log; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
```

- 必须在 `ds-bot-lpk` 目录里跑 `project exec`，否则报 `Build config file not found`；命令里的 `-` 开头参数会被 yargs 吃掉，所以用 stdin 喂 `sh`，并在末尾补 `; echo FIN`（PowerShell 管道行尾的 `\r` 会粘到最后一个 token）。
- **一直 401 `dsh web authentication required`**：Cookie 没铸上。看 `/data/access.txt` 的链接是否被完整打开过；或确认 Caddyfile 里 `@needsToken` 带了 `not query token=*`（缺这一条会 302 死循环）。
- **302 到自己**：同上，`not query token=*` 缺失。
- **页面能开、接口 403**：`--trusted-host` 没拿到平台域名（`LAZYCAT_APP_DOMAIN` 为空）。
- **一直 `Status_Starting`**：进容器看 `ps`；Caddy 起不来会被 `caddy validate` 拦住并 `exit 1`，平台会重启——这时先看 `/tmp/Caddyfile` 是否为空文件。
- **/tmp/Caddyfile 为空**：脚本在 `set -u` 下遇到了未初始化变量（0.1.1 的老问题，0.1.2 起已预初始化并加双守卫）。

## 许可与归属

- 本仓库（打包层）：Apache-2.0。
- 上游 [DS-Bot](https://github.com/Fei2411/DS-Bot)：Apache-2.0，作者 Fei2411。
- 运行时 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)：随 npm 包分发。
- 镜像内 Caddy：Apache-2.0。

本项目与 DeepSeek、懒猫微服均无隶属关系，只是社区打包。
