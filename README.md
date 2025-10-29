# Astrbot-Napcat-Huggingface

A comprehensive Docker-based solution that integrates **AstrBot**, **NapCat**, and **Gemini Balance** services with dynamic Nginx routing and automatic GitHub backup capabilities.

## 🌟 Features

- **Multi-Service Integration**: Runs AstrBot, NapCat, and Gemini Balance in a single container
- **Dynamic Nginx Routing**: Web-based route management with real-time configuration updates
- **Automatic Backup**: Persistent data backup to GitHub with large file handling via Release assets
- **Non-Root Execution**: Runs as UID 1000 for enhanced security
- **Supervisor Management**: All services managed by supervisord with automatic restart
- **Web Admin Panel**: User-friendly interface for managing routes and configurations

## 📋 Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Service Endpoints](#service-endpoints)
- [Backup System](#backup-system)
- [Route Management](#route-management)
- [Environment Variables](#environment-variables)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## 🏗️ Architecture

The project consists of the following components:

1. **AstrBot**: Python-based bot framework (port 6099)
2. **NapCat**: QQ bot client running in Xvfb (virtual display)
3. **Gemini Balance**: API balance service (port 8000)
4. **OpenResty (Nginx)**: Dynamic reverse proxy with Lua scripting (port 7860)
5. **Backup Service**: Automated GitHub synchronization with large file support
6. **Supervisor**: Process management and monitoring

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Container                      │
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
│              │ Backup Service  │                        │
│              │  (GitHub Sync)  │                        │
│              └─────────────────┘                        │
└─────────────────────────────────────────────────────────┘
```

## 📦 Prerequisites

- Docker installed on your system
- GitHub account (for backup functionality)
- GitHub Personal Access Token (PAT) with `repo` permissions
- A GitHub repository for storing backups

## 🚀 Quick Start

### 1. Pull the Docker Image

```bash
docker pull ghcr.io/YOUR_USERNAME/astrbot-napcat-huggingface:latest
```

### 2. Create a GitHub Repository

Create a new private repository on GitHub to store your bot's configuration and data backups.

### 3. Generate GitHub Personal Access Token

1. Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click "Generate new token (classic)"
3. Select scopes: `repo` (Full control of private repositories)
4. Generate and save the token securely

### 4. Run the Container

```bash
docker run -d \
  --name astrbot-napcat \
  -p 7860:7860 \
  -e GITHUB_USER="your-github-username" \
  -e GITHUB_PAT="your-github-token" \
  -e GITHUB_REPO="your-username/your-backup-repo" \
  -e GIT_BRANCH="main" \
  ghcr.io/YOUR_USERNAME/astrbot-napcat-huggingface:latest
```

### 5. Access the Services

- **Main Entry**: http://localhost:7860
- **Admin Panel**: http://localhost:7860/admin/ui/
- **AstrBot WebUI**: http://localhost:7860/webui/
- **Gemini Balance**: http://localhost:7860/gemini/

## ⚙️ Configuration

### Environment Variables

#### GitHub Backup Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GITHUB_USER` | Yes | - | GitHub username |
| `GITHUB_PAT` | Yes | - | GitHub Personal Access Token |
| `GITHUB_REPO` | Yes | - | Repository in format `owner/repo` |
| `GIT_BRANCH` | No | `main` | Git branch for backups |
| `BACKUP_INTERVAL_SECONDS` | No | `180` | Backup interval in seconds (3 minutes) |

#### Service Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_TYPE` | No | `sqlite` | Database type for Gemini Balance |
| `SQLITE_DATABASE` | No | `/home/user/gemini-data/gemini_balance.db` | SQLite database path |
| `TZ` | No | `Asia/Shanghai` | Timezone |
| `NAPCAT_FLAGS` | No | - | Additional flags for NapCat |

#### Advanced Backup Options

| Variable | Default | Description |
|----------|---------|-------------|
| `LARGE_THRESHOLD` | `52428800` | File size threshold (50MB) for Release asset storage |
| `RELEASE_TAG` | `blobs` | GitHub Release tag for large files |
| `VERIFY_SHA` | `true` | Verify SHA256 checksums when downloading |
| `DOWNLOAD_RETRY` | `3` | Number of download retry attempts |

### Persistent Data Locations

The following directories are automatically backed up to GitHub:

- `/home/user/AstrBot/data` - AstrBot configuration and data
- `/home/user/config` - General configuration files
- `/app/napcat/config` - NapCat configuration
- `/app/.config/QQ` - QQ client data
- `/home/user/gemini-data` - Gemini Balance database
- `/home/user/nginx/admin_config.json` - Nginx route configuration

## 🌐 Service Endpoints

### Default Routes

The Nginx reverse proxy provides the following default routes:

| Path | Backend | Description |
|------|---------|-------------|
| `/webui/` | AstrBot (6099) | AstrBot web interface |
| `/api/ws/` | AstrBot (6099) | WebSocket API |
| `/gemini/` | Gemini Balance (8000) | Gemini API service |
| `/admin/ui/` | Static files | Route management UI |
| `/admin/routes.json` | Lua API | Route configuration API |
| `/*` (default) | AstrBot (6185) | Default backend |

### Route Priority

Routes are matched by priority (higher number = higher priority):

1. Priority 200: WebSocket API (`/api/ws/`)
2. Priority 195: Referer-based routing (gemini, webui)
3. Priority 180-190: Path prefix routing
4. Priority 0: Default backend

## 💾 Backup System

### How It Works

The backup system automatically:

1. **Initializes** on container start
2. **Migrates** target directories to a Git repository
3. **Creates symlinks** from original paths to the Git repository
4. **Monitors** for changes every 3 minutes (configurable)
5. **Handles large files** (>50MB) by uploading to GitHub Releases
6. **Commits and pushes** changes to GitHub

### Large File Handling

Files larger than 50MB are:
- Uploaded to GitHub Releases as assets
- Replaced with `.pointer` files containing metadata
- Automatically downloaded when restoring from backup

### Pointer File Format

```json
{
  "type": "release-asset",
  "repo": "owner/repo",
  "release_tag": "blobs",
  "asset_name": "sha256-filename",
  "download_url": "https://github.com/...",
  "original_path": "path/to/file",
  "size": 123456789,
  "sha256": "abc123...",
  "generated_at": "2024-01-01T00:00:00Z"
}
```

### Manual Backup Operations

```bash
# Check backup status
docker exec astrbot-napcat cat /home/user/.astrbot-backup/.backup.ready

# View backup logs
docker exec astrbot-napcat tail -f /home/user/synclogs/backup.log

# Force immediate backup
docker exec astrbot-napcat pkill -USR1 -f backup_to_github.sh
```

## 🎛️ Route Management

### Web Admin Panel

Access the admin panel at `http://localhost:7860/admin/ui/`

**Default Password**: `admin`

#### Features:

1. **Change Admin Password**: Secure your admin panel
2. **Set Default Backend**: Configure fallback routing
3. **Manage Routes**: Add/edit/delete routing rules
4. **Visual Editor**: User-friendly interface for route configuration
5. **JSON Editor**: Advanced configuration with full control

### Route Configuration Format

```json
{
  "default_backend": "http://127.0.0.1:6185",
  "rules": [
    {
      "id": "unique-rule-id",
      "action": "proxy",
      "priority": 100,
      "backend": "http://127.0.0.1:8000",
      "match": {
        "host": "example.com",
        "path_prefix": "/api/",
        "path_equal": "/exact/path",
        "referer_substr": "substring",
        "referer_regex": "regex-pattern",
        "method": "GET",
        "headers": [
          {
            "name": "X-Custom-Header",
            "contains": "value",
            "regex": "pattern"
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
      "id": "redirect-rule",
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

### Match Conditions

- `host`: Exact hostname match
- `path_prefix`: URL path starts with
- `path_equal`: Exact path match
- `referer_substr`: Referer header contains substring
- `referer_regex`: Referer header matches regex
- `method`: HTTP method (GET, POST, etc.)
- `headers`: Array of header conditions

### Actions

- `proxy`: Reverse proxy to backend
- `redirect`: HTTP redirect (301/302)

## 🔧 Troubleshooting

### Container Won't Start

```bash
# Check container logs
docker logs astrbot-napcat

# Check supervisor status
docker exec astrbot-napcat supervisorctl status
```

### Backup Not Working

```bash
# Verify GitHub credentials
docker exec astrbot-napcat env | grep GITHUB

# Check backup logs
docker exec astrbot-napcat cat /home/user/synclogs/backup.log

# Manually test Git connection
docker exec -it astrbot-napcat bash
cd /home/user/.astrbot-backup
git remote -v
git fetch origin
```

### Service Not Responding

```bash
# Restart specific service
docker exec astrbot-napcat supervisorctl restart astrbot
docker exec astrbot-napcat supervisorctl restart napcat
docker exec astrbot-napcat supervisorctl restart nginx

# Restart all services
docker restart astrbot-napcat
```

### Route Changes Not Applied

1. Check admin password is correct
2. Verify JSON syntax in route configuration
3. Check Nginx logs: `docker exec astrbot-napcat tail -f /home/user/logs/nginx.error.log`
4. Restart Nginx: `docker exec astrbot-napcat supervisorctl restart nginx`

### Large Files Not Downloading

```bash
# Check pointer files
docker exec astrbot-napcat find /home/user/.astrbot-backup -name "*.pointer"

# Manually trigger hydration
docker exec astrbot-napcat bash -c 'cd /home/user && /home/user/scripts/backup_to_github.sh restore'
```

## 🛠️ Development

### Building from Source

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/astrbot-napcat-huggingface.git
cd astrbot-napcat-huggingface

# Build the Docker image
docker build -t astrbot-napcat:local .

# Run locally
docker run -d \
  --name astrbot-napcat-dev \
  -p 7860:7860 \
  -e GITHUB_USER="your-username" \
  -e GITHUB_PAT="your-token" \
  -e GITHUB_REPO="your-username/backup-repo" \
  astrbot-napcat:local
```

### Project Structure

```
.
├── Dockerfile              # Main container definition
├── nginx/
│   ├── nginx.conf         # OpenResty configuration with Lua
│   └── route-admin/       # Web admin panel
│       └── index.html
├── scripts/
│   ├── backup_to_github.sh    # Backup automation script
│   ├── run-napcat.sh          # NapCat launcher
│   └── wait_for_backup.sh     # Startup synchronization
├── supervisor/
│   └── supervisord.conf   # Process management config
└── .github/
    └── workflows/
        └── main.yml       # CI/CD pipeline
```

### Modifying Routes

Edit `nginx/nginx.conf` and rebuild the image, or use the web admin panel for runtime changes.

### Adding New Services

1. Add service to `supervisor/supervisord.conf`
2. Configure routing in Nginx or via admin panel
3. Update backup targets in `scripts/backup_to_github.sh` if needed

## 📝 License

This project integrates multiple open-source components:
- [AstrBot](https://github.com/AstrBotDevs/AstrBot)
- [NapCat](https://github.com/NapNeko/NapCatAppImageBuild)
- [Gemini Balance](https://github.com/MoYangking/gemini-balance-main)

Please refer to each project's license for usage terms.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## 📧 Support

For issues and questions:
- Open an issue on GitHub
- Check the troubleshooting section above
- Review logs: `docker logs astrbot-napcat`

---

**Note**: This project is designed for deployment on platforms like Hugging Face Spaces, but can run anywhere Docker is supported.
