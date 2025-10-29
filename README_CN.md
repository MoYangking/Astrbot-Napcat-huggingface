# Astrbot-Napcat-Huggingface

一个基于 Docker 的综合解决方案，集成了 **AstrBot**、**NapCat** 和 **Gemini Balance** 服务，具有动态 Nginx 路由和自动 GitHub 备份功能。

## 🌟 特性

- **多服务集成**：在单个容器中运行 AstrBot、NapCat 和 Gemini Balance
- **动态 Nginx 路由**：基于 Web 的路由管理，支持实时配置更新
- **自动备份**：通过 GitHub Release 资产处理大文件的持久化数据备份
- **非 Root 执行**：以 UID 1000 运行，增强安全性
- **Supervisor 管理**：所有服务由 supervisord 管理，支持自动重启
- **Web 管理面板**：用户友好的路由和配置管理界面

## 📋 目录

- [架构](#架构)
- [前置要求](#前置要求)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [服务端点](#服务端点)
- [备份系统](#备份系统)
- [路由管理](#路由管理)
- [环境变量](#环境变量)
- [故障排除](#故障排除)
- [开发指南](#开发指南)

## 🏗️ 架构

项目由以下组件构成：

1. **AstrBot**：基于 Python 的机器人框架（端口 6099）
2. **NapCat**：运行在 Xvfb（虚拟显示）中的 QQ 机器人客户端
3. **Gemini Balance**：API 负载均衡服务（端口 8000）
4. **OpenResty (Nginx)**：带 Lua 脚本的动态反向代理（端口 7860）
5. **备份服务**：支持大文件的自动 GitHub 同步
6. **Supervisor**：进程管理和监控

```
┌─────────────────────────────────────────────────────────┐
│                    Docker 容器                           │
│  ┌────────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │  AstrBot   │  │  NapCat  │  │ Gemini Balance   │   │
│  │  :6099     │  │  (Xvfb)  │  │     :8000        │   │
│  └─────┬──────┘  └────┬─────┘  └────────┬─────────┘   │
│        │              │                  │              │
│        └──────────────┴──────────────────┘              │
│                       │                                 │
│              ┌────────▼────────┐                        │
│              │  OpenResty      │                        │
│              │  (Nginx + Lua)  │                        │
│              │     :7860       │                        │
│              └────────┬────────┘                        │
│                       │                                 │
│              ┌────────▼────────┐                        │
│              │   备份服务      │                        │
│              │  (GitHub 同步)  │                        │
│              └─────────────────┘                        │
└─────────────────────────────────────────────────────────┘
```

## 📦 前置要求

- 系统已安装 Docker
- GitHub 账号（用于备份功能）
- 具有 `repo` 权限的 GitHub Personal Access Token (PAT)
- 用于存储备份的 GitHub 仓库

## 🚀 快速开始

### 1. 拉取 Docker 镜像

```bash
docker pull ghcr.io/YOUR_USERNAME/astrbot-napcat-huggingface:latest
```

### 2. 创建 GitHub 仓库

在 GitHub 上创建一个新的私有仓库，用于存储机器人的配置和数据备份。

### 3. 生成 GitHub Personal Access Token

1. 访问 GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. 点击 "Generate new token (classic)"
3. 选择权限范围：`repo`（完全控制私有仓库）
4. 生成并安全保存 token

### 4. 运行容器

```bash
docker run -d \
  --name astrbot-napcat \
  -p 7860:7860 \
  -e GITHUB_USER="你的GitHub用户名" \
  -e GITHUB_PAT="你的GitHub令牌" \
  -e GITHUB_REPO="用户名/备份仓库名" \
  -e GIT_BRANCH="main" \
  ghcr.io/YOUR_USERNAME/astrbot-napcat-huggingface:latest
```

### 5. 访问服务

- **主入口**：http://localhost:7860
- **管理面板**：http://localhost:7860/admin/ui/
- **AstrBot WebUI**：http://localhost:7860/webui/
- **Gemini Balance**：http://localhost:7860/gemini/

## ⚙️ 配置说明

### 环境变量

#### GitHub 备份配置

| 变量 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `GITHUB_USER` | 是 | - | GitHub 用户名 |
| `GITHUB_PAT` | 是 | - | GitHub Personal Access Token |
| `GITHUB_REPO` | 是 | - | 仓库格式：`owner/repo` |
| `GIT_BRANCH` | 否 | `main` | 备份使用的 Git 分支 |
| `BACKUP_INTERVAL_SECONDS` | 否 | `180` | 备份间隔（秒），默认 3 分钟 |

#### 服务配置

| 变量 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `DATABASE_TYPE` | 否 | `sqlite` | Gemini Balance 数据库类型 |
| `SQLITE_DATABASE` | 否 | `/home/user/gemini-data/gemini_balance.db` | SQLite 数据库路径 |
| `TZ` | 否 | `Asia/Shanghai` | 时区设置 |
| `NAPCAT_FLAGS` | 否 | - | NapCat 额外启动参数 |

#### 高级备份选项

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LARGE_THRESHOLD` | `52428800` | 大文件阈值（50MB），超过此大小将存储到 Release 资产 |
| `RELEASE_TAG` | `blobs` | 用于存储大文件的 GitHub Release 标签 |
| `VERIFY_SHA` | `true` | 下载时验证 SHA256 校验和 |
| `DOWNLOAD_RETRY` | `3` | 下载重试次数 |

### 持久化数据位置

以下目录会自动备份到 GitHub：

- `/home/user/AstrBot/data` - AstrBot 配置和数据
- `/home/user/config` - 通用配置文件
- `/app/napcat/config` - NapCat 配置
- `/app/.config/QQ` - QQ 客户端数据
- `/home/user/gemini-data` - Gemini Balance 数据库
- `/home/user/nginx/admin_config.json` - Nginx 路由配置

## 🌐 服务端点

### 默认路由

Nginx 反向代理提供以下默认路由：

| 路径 | 后端 | 说明 |
|------|------|------|
| `/webui/` | AstrBot (6099) | AstrBot Web 界面 |
| `/api/ws/` | AstrBot (6099) | WebSocket API |
| `/gemini/` | Gemini Balance (8000) | Gemini API 服务 |
| `/admin/ui/` | 静态文件 | 路由管理界面 |
| `/admin/routes.json` | Lua API | 路由配置 API |
| `/*` (默认) | AstrBot (6185) | 默认后端 |

### 路由优先级

路由按优先级匹配（数字越大优先级越高）：

1. 优先级 200：WebSocket API (`/api/ws/`)
2. 优先级 195：基于 Referer 的路由（gemini、webui）
3. 优先级 180-190：路径前缀路由
4. 优先级 0：默认后端

## 💾 备份系统

### 工作原理

备份系统会自动：

1. **初始化**：容器启动时初始化
2. **迁移**：将目标目录迁移到 Git 仓库
3. **创建符号链接**：从原始路径链接到 Git 仓库
4. **监控**：每 3 分钟检查一次变更（可配置）
5. **处理大文件**：将超过 50MB 的文件上传到 GitHub Releases
6. **提交推送**：将变更提交并推送到 GitHub

### 大文件处理

大于 50MB 的文件会：
- 上传到 GitHub Releases 作为资产
- 替换为包含元数据的 `.pointer` 文件
- 从备份恢复时自动下载

### 指针文件格式

```json
{
  "type": "release-asset",
  "repo": "owner/repo",
  "release_tag": "blobs",
  "asset_name": "sha256-文件名",
  "download_url": "https://github.com/...",
  "original_path": "path/to/file",
  "size": 123456789,
  "sha256": "abc123...",
  "generated_at": "2024-01-01T00:00:00Z"
}
```

### 手动备份操作

```bash
# 检查备份状态
docker exec astrbot-napcat cat /home/user/.astrbot-backup/.backup.ready

# 查看备份日志
docker exec astrbot-napcat tail -f /home/user/synclogs/backup.log

# 强制立即备份
docker exec astrbot-napcat pkill -USR1 -f backup_to_github.sh
```

## 🎛️ 路由管理

### Web 管理面板

访问管理面板：`http://localhost:7860/admin/ui/`

**默认密码**：`admin`

#### 功能：

1. **修改管理员密码**：保护管理面板安全
2. **设置默认后端**：配置回退路由
3. **管理路由**：添加/编辑/删除路由规则
4. **可视化编辑器**：用户友好的路由配置界面
5. **JSON 编辑器**：高级配置，完全控制

### 路由配置格式

```json
{
  "default_backend": "http://127.0.0.1:6185",
  "rules": [
    {
      "id": "唯一规则ID",
      "action": "proxy",
      "priority": 100,
      "backend": "http://127.0.0.1:8000",
      "match": {
        "host": "example.com",
        "path_prefix": "/api/",
        "path_equal": "/exact/path",
        "referer_substr": "子串",
        "referer_regex": "正则表达式",
        "method": "GET",
        "headers": [
          {
            "name": "X-Custom-Header",
            "contains": "值",
            "regex": "模式"
          }
        ]
      },
      "set_headers": [
        {
          "name": "X-Forwarded-Prefix",
          "value": "/api"
        }
      ]
    },
    {
      "id": "重定向规则",
      "action": "redirect",
      "priority": 90,
      "match": {
        "path_equal": "/old-path"
      },
      "redirect_to": "/new-path"
    }
  ]
}
```

### 匹配条件

- `host`：精确主机名匹配
- `path_prefix`：URL 路径前缀匹配
- `path_equal`：精确路径匹配
- `referer_substr`：Referer 头包含子串
- `referer_regex`：Referer 头匹配正则表达式
- `method`：HTTP 方法（GET、POST 等）
- `headers`：请求头条件数组

### 动作类型

- `proxy`：反向代理到后端
- `redirect`：HTTP 重定向（301/302）

## 🔧 故障排除

### 容器无法启动

```bash
# 查看容器日志
docker logs astrbot-napcat

# 检查 supervisor 状态
docker exec astrbot-napcat supervisorctl status
```

### 备份不工作

```bash
# 验证 GitHub 凭据
docker exec astrbot-napcat env | grep GITHUB

# 查看备份日志
docker exec astrbot-napcat cat /home/user/synclogs/backup.log

# 手动测试 Git 连接
docker exec -it astrbot-napcat bash
cd /home/user/.astrbot-backup
git remote -v
git fetch origin
```

### 服务无响应

```bash
# 重启特定服务
docker exec astrbot-napcat supervisorctl restart astrbot
docker exec astrbot-napcat supervisorctl restart napcat
docker exec astrbot-napcat supervisorctl restart nginx

# 重启所有服务
docker restart astrbot-napcat
```

### 路由更改未生效

1. 检查管理员密码是否正确
2. 验证路由配置的 JSON 语法
3. 查看 Nginx 日志：`docker exec astrbot-napcat tail -f /home/user/logs/nginx.error.log`
4. 重启 Nginx：`docker exec astrbot-napcat supervisorctl restart nginx`

### 大文件无法下载

```bash
# 检查指针文件
docker exec astrbot-napcat find /home/user/.astrbot-backup -name "*.pointer"

# 手动触发下载
docker exec astrbot-napcat bash -c 'cd /home/user && /home/user/scripts/backup_to_github.sh restore'
```

## 🛠️ 开发指南

### 从源码构建

```bash
# 克隆仓库
git clone https://github.com/YOUR_USERNAME/astrbot-napcat-huggingface.git
cd astrbot-napcat-huggingface

# 构建 Docker 镜像
docker build -t astrbot-napcat:local .

# 本地运行
docker run -d \
  --name astrbot-napcat-dev \
  -p 7860:7860 \
  -e GITHUB_USER="你的用户名" \
  -e GITHUB_PAT="你的令牌" \
  -e GITHUB_REPO="用户名/备份仓库" \
  astrbot-napcat:local
```

### 项目结构

```
.
├── Dockerfile              # 主容器定义
├── nginx/
│   ├── nginx.conf         # OpenResty 配置（含 Lua）
│   └── route-admin/       # Web 管理面板
│       └── index.html
├── scripts/
│   ├── backup_to_github.sh    # 备份自动化脚本
│   ├── run-napcat.sh          # NapCat 启动器
│   └── wait_for_backup.sh     # 启动同步脚本
├── supervisor/
│   └── supervisord.conf   # 进程管理配置
└── .github/
    └── workflows/
        └── main.yml       # CI/CD 流水线
```

### 修改路由

编辑 `nginx/nginx.conf` 并重新构建镜像，或使用 Web 管理面板进行运行时更改。

### 添加新服务

1. 在 `supervisor/supervisord.conf` 中添加服务
2. 在 Nginx 中配置路由或通过管理面板配置
3. 如需备份，在 `scripts/backup_to_github.sh` 中更新备份目标

## 📝 许可证

本项目集成了多个开源组件：
- [AstrBot](https://github.com/AstrBotDevs/AstrBot)
- [NapCat](https://github.com/NapNeko/NapCatAppImageBuild)
- [Gemini Balance](https://github.com/MoYangking/gemini-balance-main)

请参考各项目的许可证了解使用条款。

## 🤝 贡献

欢迎贡献！请随时提交 issue 和 pull request。

## 📧 支持

如有问题：
- 在 GitHub 上提交 issue
- 查看上方故障排除部分
- 查看日志：`docker logs astrbot-napcat`

---

**注意**：本项目设计用于在 Hugging Face Spaces 等平台上部署，但可以在任何支持 Docker 的环境中运行。
