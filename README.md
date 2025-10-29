<!-- 默认中文文档。English version: README_EN.md -->

# AstrBot + NapCat + Gemini Balance 在 Hugging Face 的部署与使用指南

本仓库将 AstrBot（智能体聊天机器人）、NapCat（QQ/OneBot 桥接）和 Gemini Balance（Gemini 代理/负载均衡）打包到一个 OpenResty 网关（nginx + Lua）下，适配本地与 Hugging Face Spaces（Docker SDK）。通过 `supervisord` 管理多进程，并用 GitHub 仓库做数据/配置的持久化，避免 Spaces 重启导致数据丢失。

上游项目参考：
- AstrBot: https://github.com/AstrBotDevs/AstrBot
- NapCat AppImage Build: https://github.com/NapNeko/NapCatAppImageBuild
- Gemini Balance: https://github.com/MoYangking/gemini-balance-main

主要组件与端口：
- AstrBot（Python 3.10+）：6185（由网关转发）
- NapCat（AppImage + Xvfb）：6099/3001/6199（由网关转发）
- Gemini Balance（FastAPI）：8000（由网关转发）
- OpenResty 网关：7860（对外暴露）

默认路由（监听 7860）：
- `/` → AstrBot 控制台（默认后端 `http://127.0.0.1:6185`）
- `/webui/`、`/api/ws/` → NapCat（`http://127.0.0.1:6099`）
- `/gemini/` → Gemini Balance（`http://127.0.0.1:8000`）
- `/admin/ui/` → 路由管理界面（使用请求头 `X-Admin-Password`，初始值 `admin`）

目录结构概览：
- `Dockerfile`：构建所有依赖并克隆上游应用
- `supervisor/supervisord.conf`：进程编排（备份、Xvfb、NapCat、AstrBot、Gemini、nginx）
- `nginx/nginx.conf`：OpenResty 动态路由与管理 API
- `scripts/`：NapCat 启动与备份/还原脚本

---

## 环境变量一览（表格）

核心（在 Hugging Face 上强烈建议配置，以持久化数据）

| 名称 | 必填 | 默认值 | 参考值 | 说明/如何获取 |
| --- | --- | --- | --- | --- |
| `github_project` | 是（HF） | 无 | `yourname/astrbot-data` | GitHub 仓库 `owner/repo`，用于存放持久化数据与配置（建议私有）。 |
| `github_secret` | 是（HF） | 无 | `ghp_xxxxxxxxxxxxxxxxxxxxx` | GitHub Personal Access Token（需 `repo` 权限，classic 或 fine‑grained 均可）。GitHub → Settings → Developer settings 获取。 |
| `GIT_BRANCH` | 否 | `main` | `main` | 备份仓库使用的分支名。 |

凭据的等价写法（可替代上面两项，择一使用）

| 名称 | 必填 | 默认值 | 参考值 | 说明 |
| --- | --- | --- | --- | --- |
| `GITHUB_USER` | 否 | 无 | `yourname` | GitHub 用户名。与 `GITHUB_PAT`、`GITHUB_REPO` 一起使用。 |
| `GITHUB_PAT` | 否 | 无 | `ghp_xxxxxxxxxxxxxxxxxxxxx` | GitHub Token（需 `repo` 权限）。 |
| `GITHUB_REPO` | 否 | 无 | `yourname/astrbot-data` | 仓库 `owner/repo`。 |

备份与同步（高级，可选）

| 名称 | 必填 | 默认值 | 参考值 | 说明 |
| --- | --- | --- | --- | --- |
| `BACKUP_REPO_DIR` | 否 | `/home/user/.astrbot-backup` | 同默认 | 本地历史仓库路径（容器内）。 |
| `HIST_DIR` | 否 | `/home/user/.astrbot-backup` | 同默认 | 历史仓库根目录；与 `BACKUP_REPO_DIR` 一致。 |
| `BACKUP_INTERVAL_SECONDS` | 否 | `180` | `180` | 备份/推送的轮询周期（秒）。 |
| `LARGE_THRESHOLD` | 否 | `52428800` | `52428800` | 大文件阈值（字节）。超过阈值会指针化并上传至 Release。 |
| `RELEASE_TAG` | 否 | `blobs` | `blobs` | 指针化大文件使用的 Release 标签。 |
| `STICKY_POINTER` | 否 | `true` | `true` | 生成指针后移除原大文件（仅保留指针）。 |
| `VERIFY_SHA` | 否 | `true` | `true` | 下载大文件时校验 SHA256。 |
| `READINESS_FILE` | 否 | `${HIST_DIR}/.backup.ready` | `/home/user/.astrbot-backup/.backup.ready` | 备份/还原完成后写入，其他进程据此继续启动。 |
| `SYNC_LOG_DIR` | 否 | `/home/user/synclogs` | 同默认 | 同步日志目录。 |

NapCat（可选）

| 名称 | 必填 | 默认值 | 参考值 | 说明 |
| --- | --- | --- | --- | --- |
| `NAPCAT_FLAGS` | 否 | 空 | `--disable-gpu` | 传给 QQ AppImage 的额外参数。以非 root 运行，一般无需 `--no-sandbox`。 |
| `TZ` | 否 | `Asia/Shanghai` | `Asia/Shanghai` | 时区。 |

Gemini Balance（使用 Gemini 代理时建议配置，可通过环境变量或 `.env` 文件）

| 名称 | 必填 | 默认值 | 参考值 | 说明/如何获取 |
| --- | --- | --- | --- | --- |
| `API_KEYS` | 是（启用时） | 无 | `["AIzaSy...","AIzaSy..."]` | Google Gemini API Keys（JSON 数组）。到 Google AI Studio 创建。 |
| `ALLOWED_TOKENS` | 是 | `[]` | `["admin"]` | 允许客户端访问的 Bearer Token 列表（JSON）。调用需 `Authorization: Bearer <token>`。 |
| `AUTH_TOKEN` | 建议 | 空 | `sk-123` | 默认访问 Token。 |
| `DATABASE_TYPE` | 否 | `sqlite` | `sqlite` | 数据库存储类型。 |
| `SQLITE_DATABASE` | 否 | `/home/user/gemini-data/gemini_balance.db` | 同默认 | SQLite 数据库路径（容器内）。 |
| `BASE_URL` | 否 | `https://generativelanguage.googleapis.com/v1beta` | 同默认 | Gemini API 基础地址。 |
| `PROXIES` | 否 | `[]` | `["http://host:port"]` | 可选代理（HTTP/SOCKS5），JSON 数组。 |

提示：也可将 `.env`（参考上游 `_refs/gemini-balance-main/.env.example`）放到备份仓库路径 `home/user/gemini-balance-main/.env`，备份程序会在服务启动前自动还原。

---

## 如何获取凭据/密钥
- GitHub Token（`github_secret`）：GitHub → Settings → Developer settings → Personal access tokens，授予 `repo` 权限，复制 Token 即可。
- Google Gemini `API_KEYS`：前往 Google AI Studio 创建 API Key，将多个 Key 以 JSON 字符串填入 `API_KEYS`。

---

## 本地快速开始（Docker）
1）构建镜像：
```
docker build -t astrbot-napcat-hf:latest .
```
2）启动容器（按需替换示例值）：
```
docker run -d \
  -p 7860:7860 \
  -e github_project=yourname/astrbot-data \
  -e github_secret=ghp_xxx... \
  -e GIT_BRANCH=main \
  -e API_KEYS='["AIzaSy..."]' \
  -e ALLOWED_TOKENS='["sk-123"]' \
  -e AUTH_TOKEN=sk-123 \
  --name astrbot-napcat astrbot-napcat-hf:latest
```
3）打开 `http://localhost:7860/`：
- `/` AstrBot 控制台；首次启动会自动下载前端资源（可能稍慢）。
- `/webui/` NapCat 管理界面（登录/扫码）。
- `/gemini/` Gemini 代理接口（详见下文测试）。
- `/admin/ui/` 路由管理界面（默认密码 `admin`）。

---

## Hugging Face 部署（Docker SDK）
1）创建 Space：
- SDK 选 Docker；若涉及隐私，建议 Private。
2）推送本仓库到 Space（或连接 GitHub）。
3）在 Settings → Variables and secrets 配置：
- 必填：`github_project`、`github_secret`；可选 `GIT_BRANCH`。
- 若使用 Gemini：`API_KEYS`、`ALLOWED_TOKENS`、`AUTH_TOKEN` 等。
- 可选：`NAPCAT_FLAGS`（如 `--disable-gpu`）。
4）硬件：CPU Basic 即可；如需常驻在线，关闭自动休眠。
5）启动 Space，等待构建完成，访问 Space URL（内部监听 7860）。
6）首次建议：
- 打开 `/admin/ui/` 修改路由管理密码。
- AstrBot：在控制台配置模型与平台（或在备份仓库的 `home/user/AstrBot/data` 预置）。
- NapCat：在 `/webui/` 完成登录与绑定；配置将持久化。
- Gemini：提供 `API_KEYS` 等变量或 `.env`，并测试接口。

持久化说明：Spaces 文件系统重启即丢。本方案通过备份服务克隆你提供的 GitHub 仓库，将关键目录做符号链接，并定期推送改动以持久化。

参考项目：https://huggingface.co/spaces/MoYang303/astrbot

---

## 路由管理 API 速查
- 获取路由：
```
curl -H "X-Admin-Password: <pass>" https://<host>/admin/routes.json
```
- 替换路由：
```
curl -X POST -H "X-Admin-Password: <pass>" -H "Content-Type: application/json" \
  -d '{"default_backend":"http://127.0.0.1:6185","rules":[...]}' \
  https://<host>/admin/routes.json
```
- 修改密码：
```
curl -X POST -H "X-Admin-Password: <old>" -H "Content-Type: application/json" \
  -d '{"new_password":"<new>"}' https://<host>/admin/password
```

---

## Gemini 接口测试示例
- 列模型：
```
curl -H "Authorization: Bearer sk-123" https://<host>/gemini/hf/v1/models
```
- 聊天补全：
```
curl -X POST -H "Authorization: Bearer sk-123" -H "Content-Type: application/json" \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"Hello"}]}' \
  https://<host>/gemini/hf/v1/chat/completions
```

---

## 常见问题（FAQ）
- 访问 502 或空白页：到 `/admin/ui/` 确认默认后端为 `http://127.0.0.1:6185`。
- NapCat 启动异常：已使用 `--appimage-extract-and-run` 与 Xvfb，无 GPU 环境建议 `NAPCAT_FLAGS=--disable-gpu`。
- Gemini 401：需设置 `ALLOWED_TOKENS`/`AUTH_TOKEN`，并在请求中带 `Authorization: Bearer <token>`。
- 首次 AstrBot WebUI 较慢：它会自动下载前端资源，耐心等待即可。

---

## 许可证
本仓库集成上游项目（各自遵循其许可协议），本仓库仅提供配置与自动化胶合代码。请查阅上游仓库了解各自许可。

