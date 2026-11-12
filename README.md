# DS Bot for Lazycat (微服) — LPK 打包层

把 [DS Bot](https://github.com/Fei2411/DS-Bot) 打包成**懒猫微服**（lazycat.cloud）可以一键安装的 LPK 应用。

上游代码**零改动**：这里只提供「镜像 + 启动脚本 + 平台清单」，构建时从 npm 装固定版本的 `@deepseek-ai/dsh` 与 `ds-bot` 插件，按微服的方式把它们跑起来。

当前包版本 **0.1.9**，服务名 `dsbot`，默认地址 `https://dsbot.<盒子名>.heiyu.space`。

---

## 为什么需要这一层

上游自带的 `docker/` 形态解决不了四件事：

| 问题 | 上游 docker 形态 | 微服上的现实 | 本项目的做法 |
| --- | --- | --- | --- |
| 镜像来源 | `docker.io` / `node:24-bookworm-slim` | 盒子**连不上** docker.io 与 ghcr.io | 全部 `FROM` 走 `docker.m.daocloud.io` 镜像站 |
| 访问控制 | 单用户、只监听容器网段 | 平台把 `*.heiyu.space` 子域名公开，但**先要盒子账号登录** | 默认用平台登录当门；可选再叠 Basic Auth |
| 一次性令牌 | 打开 dsh 打印的 `?token=` 链接 | 平台里没有终端可看 stdout（`app log` 未实现） | 启动脚本抓令牌、自动换 Cookie，并在 dsh 每次重启后重抓 |
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
                  ├─ /healthz  直答 200，不过认证
                  ├─ /login    重新换取 Cookie（打不开时用）
                  ├─ 可选 Basic Auth（DSBOT_BASIC_AUTH=1）
                  └─ 首次访问：302 → /?token=… → DSH 换 Cookie → 回到 /

数据卷
  /data       profile、会话、bot 团队（bot/）、密钥、dsh.log、access.txt、admin.txt、.plugin-version
  /workspace  bot 的工作目录
```

三个脚本各管一段：

- `content/entry.sh`：root 跑一次。铺模板 profile、把 `/data` 里的 ds-bot 插件升到镜像自带版本、改属主（失败即退出，不掩盖），然后 `setpriv` 降权到 uid 1000。
- `content/run.sh`：uid 1000 常驻。起 Caddy 与 dsh；**每次 dsh 启动都重抓 launch token、重写 `access.txt`、热加载 Caddy 配置**；dsh 退出就地重启（日志按次轮转，崩溃现场保留在 `dsh.log.prev`）。
- `image/Dockerfile`：构建期就把 `ds-bot` 装进模板 profile，首启**不需要联网**；`test` 改成校验 `package.json` 里的实际版本。

---

## 构建

本机需要 `lzc-cli` 2.x 并已登录目标盒子。构建在**盒子上**完成（`builder: remote`），本机不需要 Docker。

```powershell
cd ds-bot-lpk
lzc-cli project release .          # 只出包
# 产物：f00700f.ds-bot-v0.1.9.lpk
```

首次构建要拉 `node:24-bookworm` 并 `npm install -g @deepseek-ai/dsh ds-bot`，约 3 分钟、镜像层 791.92 MiB / 15 layers；之后只改 `content/` 会命中 `Reuse cached OCI image package`，几秒出包。

## 安装 / 升级

```powershell
lzc-cli app install .\f00700f.ds-bot-v0.1.9.lpk --apk n
```

安装完打开 `https://dsbot.<盒子名>.heiyu.space`。升级用同一个命令装新包，`/data` 与 `/workspace` 是平台卷，**不会被清空**。

**升级时插件会跟着换**：镜像里带 `.plugin-version`，`entry.sh` 拿它和 `/data/.plugin-version` 比对，不一致就把新镜像里的 `ds-bot` 复制进 `/data/profiles/web/node_modules/` 并改 `package.json` 的依赖版本。profile 里的其它内容（模型服务、bot 设置）不动。所以「改 `DS_BOT_VERSION` → 重打包 → 重装」对老用户是真的生效的。

开发时可以用 `lzc-cli project deploy`（= build + install + start），它会把 dev project 拉起来，这样才能用 `project exec` 进容器。

---

## 登录

三条独立的门，按顺序：

1. **平台账号门**：打开子域名先跳平台的 `Login to LazyCat Microservices`，过了才到本应用。默认就靠这一层。
2. **Basic Auth（可选，默认关）**：应用设置里加 `DSBOT_BASIC_AUTH=1` 才启用，密码随机生成在 `/data/.admin-password`（0600），用户名默认 `admin`（可用 `DSBOT_ADMIN_USER` 改）。想自己指定密码就设 `DSBOT_ADMIN_PASSWORD`。
3. **DSH 自己的令牌**：`dsh` 每次启动生成一次性 `?token=`，只有带它的请求能铸出 `dsh-auth-…` Cookie。

默认行为：**第 3 层自动完成**。第一次打开 `/`（或 `/index.html`）时 Caddy 直接 302 到 `/?token=<当次令牌>`，DSH 铸好 Cookie 再 303 回 `/`，之后浏览器一直带着 Cookie。Cookie 的签名密钥存在 `/data/.credentials.yaml` 的 grant 记录里、有效期 30 天，所以**应用重启不掉登录**。

### 打不开的时候

`/login` 就是为这件事准备的：它把浏览器送到当次令牌的链接上。三种常见情形：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 首次打开就 401 | 令牌链接还没被访问过 | 直接刷新，或访问 `/login` |
| 换了浏览器 / 清了 Cookie | 没有 Cookie | `/login` |
| 一直 401、`/login` 也 401 | 浏览器里存着**失效的旧 Cookie**（重装、重置 `/data`、换域名后） | 访问 `/login`；它带着令牌走，DSH 会覆盖旧 Cookie。仍不行就手动清该站点 Cookie |

也可以直接看 `/data/access.txt`（每次 dsh 重启重写，指向当次令牌）：

```powershell
cd D:\lxf\repos\ds-bot-lpk
lzc-cli project exec --tty=false -s dsbot cat /data/access.txt
```

### 想恢复上游语义（令牌是唯一入口）

设 `DSBOT_STRICT_AUTH=1`：关掉自动 302，只认 `?token=` 链接。

---

## 安全边界（请读）

- **容器内 Caddy 监听 `:3080`（所有网卡）**，平台按容器名转发进来。这意味着**同一台盒子上别的应用**理论上可以直接连 `dsbot.f00700f.ds-bot.lzcapp:3080`，绕过平台登录门，并在默认配置下拿到自动换发的 Cookie —— 也就是 bot 的完整控制权。单用户盒子、只装自己可信的应用时这是可接受的取舍；盒子上跑着别人的应用请加 `DSBOT_BASIC_AUTH=1` 或 `DSBOT_STRICT_AUTH=1`。
- **令牌会出现在 302 的 `Location` 里**，可能进入平台反代日志与浏览器历史；它只在当次 dsh 进程内有效。
- **`/data/.credentials.yaml` 里是模型 API key（明文，0600）**，Full access 的 bot 能读到并外发。别把敏感目录挂进 `/workspace`。
- **审批默认 Full access**（`image/lazycat.patch.yml`）：容器即边界，bot 可以在容器里执行命令。

---

## 验证装好了

在容器里跑这三条，全部通过就是通的（`0.1.9` 实测）：

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

健康检查现在同时看两件事：`/healthz` 回 200 **且** `3081` 上有人监听（`image/healthcheck.mjs`）。dsh 崩在重启循环里时，平台会看到 unhealthy 并重启应用，而不是对着一个只会答 `ok` 的 Caddy 报健康。

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

> 能不能出字只取决于账号侧：`ModelNotOpen` = 该模型没开通，`InvalidSubscription` = Coding Plan 过期。

---

## 与上游 docker 形态的差异

| 项 | 上游 `docker/` | 本项目 |
| --- | --- | --- |
| 基础镜像 | `node:24-bookworm-slim` | `docker.m.daocloud.io/library/node:24-bookworm` |
| 插件来源 | 源码 `npm pack` | npm 上的 `ds-bot@0.3.6` |
| 认证 | 无（靠容器网络边界） | 平台登录 + 自动令牌换 Cookie；可选 Basic Auth |
| 监听 | 容器 IP:3080 | Caddy :3080 → dsh 127.0.0.1:3081 |
| 健康检查 | 容器内 dsh 端口 | `/healthz` + `3081` 存活 |
| 升级 | 重建镜像 | 重装 lpk，插件随镜像更新、profile 保留 |
| 权限 | `danger-full-access` | 相同（容器即边界） |

---

## 已知限制

- **没有 Chrome**：浏览器工具、依赖浏览器的 computer use 不可用。远端云电脑不受影响。
- **SSE 平台层未验证**：容器内已 `flush_interval -1`，平台反向代理是否缓冲事件流无法从容器内观测。若回复「一次性蹦出来」，原因在这层。
- **没有回滚**：平台不保留历史 lpk，升级前自行留旧包。
- **`lzc-cli app log` 未实现**（`not yet realized`），容器日志只能进容器看。
- **插件自更新可用，但 DSH 版本无闸门**：`dsh plugin --profile web add ds-bot@<版本>` 在容器里已跑通（0.1.9 实测，5 秒左右升降级都行），DS Bot 应用内的「更新」走的就是这条通路，写 `/data` 后下次 dsh 启动生效。但 DSH 核心在 `/usr/local`（root、`go-w`）不会跟着动；若新版插件要求更高的 DSH，下次启动会失败 —— 回退到镜像自带版本：`dsh plugin --profile web add ds-bot@0.3.6`。

## 应用内更新（0.1.9 实测）

应用内更新能成功，前提是容器里 pnpm 的 store 路径与构建时记录在 `node_modules/.modules.yaml` 里的一致。本包构建时用 `HOME=/data` 装插件，并把 pnpm 钉在 12.18.0，所以运行时（uid 1000、`HOME=/data`）可以直接 `pnpm add`：

```powershell
cd D:\lxf\repos\ds-bot-lpk
'setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/data sh -c ''cd /data && dsh plugin --profile web add ds-bot@0.3.0''; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
```

实测输出 `dsh-bot 0.3.1 → 0.3.0`、`Done in 5.3s using pnpm v12.18.0`，再升回 0.3.1 同样是 5.9 秒，应用全程 healthy。镜像里的 `.plugin-version` 用 semver 比较：应用内升到更新版本后，重装同版本镜像不会把它拽回去；只有镜像里的插件更新时才覆盖。

### 0.3.1 → 0.3.6（2026-11-13 实测）

同一台实例上把插件从 0.3.1 升到 0.3.6，全程只动 `/data`，镜像与 lpk 未变。

```powershell
# 备份（约 1 MB）
tar -czf /data/backups/ds-bot-0.3.1-<ts>.tgz -C /data/profiles/web/node_modules ds-bot
# 升级
setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/data sh -c 'cd /data && dsh plugin --profile web add ds-bot@0.3.6'
```

`pnpm` 3.7 秒完成（`Packages: +5 -1`，peer 依赖有一条 warning，不影响启动）。升级后把 `/data/.plugin-version` 一并写成 `0.3.6`，否则镜像里若还是旧版本，比较基准会失真。

冒烟结果：`/healthz` 200、`dsh.log` 无 fatal、`state.json` 里 17 个 bot / 1 个群 / 主 Bot 与 `connectors.github` 全在、GitHub MCP `initialize` 200 + `tools/list` 43 个工具。上游 0.3.6 的 `src/host/im/platforms/weixin.js` 已经自带 `SESSION_EXPIRED = -14`、`withSlash`、`isUpdatesAnswer`，之前手打的微信补丁不需要了。

回滚：`tar -xzf /data/backups/ds-bot-0.3.1-<ts>.tgz -C /data/profiles/web/node_modules`，再把 `package.json` 里的 `"ds-bot"` 改回 `0.3.1`，重启 dsh。

## 排障

```powershell
cd D:\lxf\repos\ds-bot-lpk
'ps -eo pid,uid,args | grep -E "caddy|dsh" | grep -v grep; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
'tail -n 50 /data/dsh.log; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
'tail -n 50 /data/dsh.log.prev; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
'cat /tmp/Caddyfile; echo FIN' | lzc-cli project exec --tty=false -s dsbot sh
```

- 必须在 `ds-bot-lpk` 目录里跑 `project exec`，否则报 `Build config file not found`；命令里 `-` 开头的参数会被 yargs 吃掉，所以用 stdin 喂 `sh`，并在末尾补 `; echo FIN`（PowerShell 管道行尾的 `\r` 会粘到最后一个 token）。
- **一直 401**：先试 `/login`；再不行看 `/data/access.txt`。带着失效 Cookie 的情况 `/login` 能自愈（令牌换 Cookie 时不要求无 Cookie，实测 303）。
- **dsh 反复重启**：最新一次日志在 `/data/dsh.log`，上一次在 `dsh.log.prev`。
- **一直 `Status_Starting` / unhealthy**：`ps` 看 caddy 与 dsh 是否都在；Caddyfile 空或校验失败时 `run.sh` 会 `exit 1`，平台会重启应用。
- **页面能开、接口 403**：`--trusted-host` 没拿到平台域名（`LAZYCAT_APP_DOMAIN` 为空）。

## 容器实测记录（0.1.5 – 0.1.9）

在盒子上逐轮装包验证，撞到三个真故障，都是"上一版看着启动成功、换一次就起不来"的类型：

1. **应用内更新被 pnpm store 挡住**：镜像里用 root 构建，`node_modules/.modules.yaml` 记下 `storeDir: /root/.local/share/pnpm/store/v11`；运行时 uid 1000 的 store 是 `/data/.local/share/pnpm/store/v11`，`pnpm add` 直接拒绝改这个 `node_modules`。试过 `npm config set store-dir`（npm 报这不是合法 npm 选项）、`/usr/local/etc/npmrc`（pnpm 不读）、`npm_config_store_dir`（pnpm 12 不认）全部无效。最终构建改用 `HOME=/data` 装插件，让记录的路径与运行时一致；pnpm 从 corepack 的浮动解析改为钉死 12.18.0。
2. **种子不完整**：老逻辑 `cp -a "$TEMPLATE/." /data/` 在中途被打断时只落下几个小文件、没有 `node_modules`，dsh 报 `failed to read profile manifest … ENOENT`。改为先拷到 `profiles/web.tmp` 再 `mv`，并把"profile 是否完整"判定改成同时看 `package.json` 与 `node_modules/ds-bot`。
3. **根属主导致 EACCES**：种子由 root 写，而首启标记 `/data/.owner-fixed` 已存在会让递归 chown 跳过，dsh 以 uid 1000 启动时报 `failed to read profile manifest … EACCES`。改为每次启动都检查 profile 属主，不是 1000 就递归 chown；脚本自己写过东西（种子/换插件）时也强制再走一遍全局 chown。

另一个排查教训：这个容器里的 `ps` 是 busybox，`ps -o …` 只列本会话进程，看不到 caddy/dsh —— 判断进程在不在要用 `curl` 探端口，别信 `ps` 的行数。`lzc-cli app log` 仍是 `not yet realized`，`project log` 在服务未运行时也拿不到，可靠日志只有 `/data/dsh.log` 与 `dsh.log.prev`。

## 审查记录（0.1.4）

独立审查者逐条核对后确认并已修：

1. 升级不生效 —— 旧版只在 `/data/profiles/web` 不存在时铺模板，改 `DS_BOT_VERSION` 对已装用户无用。改用 `.plugin-version` 比对 + 就地替换插件。
2. dsh 重启后 token 不更新 —— 旧版只在启动时抓一次，重启后 302 指向死令牌。改为每次 dsh 启动重抓 + 热加载 Caddy（`admin 127.0.0.1:2019`）。
3. 崩溃现场被毁 —— 旧版每轮 `: > dsh.log` 清空。改为轮转到 `dsh.log.prev`。
4. `/index.html` 直接 401 —— matcher 从 `path /` 扩到 `path / /index.html`。
5. 失效 Cookie 造成永久 401 —— 新增 `/login`（实测带失效 Cookie 请求 `?token=` 仍返回 303）。实现上用命名 matcher `@recover path /login`，不用嵌套 `route`：容器内实测嵌套写法下请求会穿到反代、拿到 dsh 的 404。
6. `chown` 失败被 `|| true` 吞掉 —— 改为失败即 `exit 1`。
7. `admin.txt` 一直停在首启内容（含已作废的密码）—— 每次启动重写。
8. heredoc 注释里的反引号被命令替换（stderr 每次出现 `route: not found`）—— 去掉反引号。
9. 健康检查只看 Caddy —— 改为同时探 `3081`。

**审查者提出但实测不成立**：`chown -R` 会解引用符号链接从而让 bot 提权到 root。容器内实测（`ln -s /usr/bin/tini /tmp/ch3/escape` 后 `chown -R 1000:1000 /tmp/ch3`）目标 `/usr/bin/tini` 仍是 `root:root`，链接本身才改属主；GNU `chown -R` 默认 `-P`。仍显式加了 `-h` 以防语义变化。

## 许可与归属

- 本仓库（打包层）：Apache-2.0。
- 上游 [DS-Bot](https://github.com/Fei2411/DS-Bot)：Apache-2.0，作者 Fei2411。
- 运行时 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)：随 npm 包分发。
- 镜像内 Caddy：Apache-2.0。

本项目与 DeepSeek、懒猫微服均无隶属关系，只是社区打包。
