# AstrBot + NapCat + Gemini Balance on Hugging Face

This repo packages AstrBot (agent chatbot), NapCat (QQ/OneBot bridge), and Gemini Balance (Gemini proxy/load balancer) behind an OpenResty (nginx + Lua) gateway. It targets both local Docker and Hugging Face Spaces (Docker SDK). Processes are orchestrated by `supervisord`, and a GitHub repo is used to persist data/config so Spaces restarts don’t wipe state.

Upstreams:
- AstrBot: https://github.com/AstrBotDevs/AstrBot
- NapCat AppImage Build: https://github.com/NapNeko/NapCatAppImageBuild
- Gemini Balance: https://github.com/MoYangking/gemini-balance-main

Components and ports:
- AstrBot (Python 3.10+): 6185 (proxied)
- NapCat (AppImage + Xvfb): 6099/3001/6199 (proxied)
- Gemini Balance (FastAPI): 8000 (proxied)
- OpenResty gateway: 7860 (public)

Default routes (on 7860):
- `/` → AstrBot dashboard (default backend `http://127.0.0.1:6185`)
- `/webui/`, `/api/ws/` → NapCat (`http://127.0.0.1:6099`)
- `/gemini/` → Gemini Balance (`http://127.0.0.1:8000`)
- `/admin/ui/` → Router admin UI (header `X-Admin-Password`, default `admin`)

Layout:
- `Dockerfile` — build all deps and clone upstream apps
- `supervisor/supervisord.conf` — backup, Xvfb, NapCat, AstrBot, Gemini, nginx
- `nginx/nginx.conf` — OpenResty dynamic routing and admin API
- `scripts/` — NapCat launcher and backup/restore scripts

---

## Environment Variables (Tables)

Core (strongly recommended on Hugging Face for persistence)

| Name | Required | Default | Example | Notes/How to get |
| --- | --- | --- | --- | --- |
| `github_project` | Yes (HF) | — | `yourname/astrbot-data` | Target GitHub repo `owner/repo` to persist configs and data (private recommended). |
| `github_secret` | Yes (HF) | — | `ghp_xxxxxxxxxxxxxxxxxxxxx` | GitHub Personal Access Token with `repo` scope (classic or fine‑grained). Create under GitHub → Settings → Developer settings. |
| `GIT_BRANCH` | No | `main` | `main` | Branch used by the backup repo. |

Alternative credentials (use these instead of the two above if you prefer)

| Name | Required | Default | Example | Notes |
| --- | --- | --- | --- | --- |
| `GITHUB_USER` | No | — | `yourname` | GitHub username, used with `GITHUB_PAT` and `GITHUB_REPO`. |
| `GITHUB_PAT` | No | — | `ghp_xxxxxxxxxxxxxxxxxxxxx` | GitHub token with `repo` scope. |
| `GITHUB_REPO` | No | — | `yourname/astrbot-data` | Repo `owner/repo`. |

Backup/sync (advanced, optional)

| Name | Required | Default | Example | Notes |
| --- | --- | --- | --- | --- |
| `BACKUP_REPO_DIR` | No | `/home/user/.astrbot-backup` | same | Local history repo path (in container). |
| `HIST_DIR` | No | `/home/user/.astrbot-backup` | same | History repo root; same as `BACKUP_REPO_DIR`. |
| `BACKUP_INTERVAL_SECONDS` | No | `180` | `180` | Poll interval for backup/push. |
| `LARGE_THRESHOLD` | No | `52428800` | `52428800` | Large-file threshold (bytes) for pointerization + release asset upload. |
| `RELEASE_TAG` | No | `blobs` | `blobs` | Release tag used for large-file pointers. |
| `STICKY_POINTER` | No | `true` | `true` | Remove original file after pointer generation. |
| `VERIFY_SHA` | No | `true` | `true` | Verify SHA256 after downloads. |
| `READINESS_FILE` | No | `${HIST_DIR}/.backup.ready` | `/home/user/.astrbot-backup/.backup.ready` | Signals backup/restore done; other processes wait on it. |
| `INIT_SYNC_TIMEOUT` | No | `0` | `0` | Initial pull wait timeout (seconds). 0 waits indefinitely; backup init blocks until a successful GitHub fetch/reset completes before signaling readiness. |
| `SYNC_LOG_DIR` | No | `/home/user/synclogs` | same | Sync log directory. |

NapCat (optional)

| Name | Required | Default | Example | Notes |
| --- | --- | --- | --- | --- |
| `NAPCAT_FLAGS` | No | empty | `--disable-gpu` | Extra flags passed to the QQ AppImage. Non‑root run usually doesn’t require `--no-sandbox`. |
| `TZ` | No | `Asia/Shanghai` | `Asia/Shanghai` | Timezone. |

Gemini Balance (set if you use the Gemini proxy; env or `.env` supported)

| Name | Required | Default | Example | Notes/How to get |
| --- | --- | --- | --- | --- |
| `API_KEYS` | Yes (if enabled) | — | `["AIzaSy...","AIzaSy..."]` | JSON array of Google Gemini API keys (create in Google AI Studio). |
| `ALLOWED_TOKENS` | Recommended | `[]` | `["sk-123"]` | JSON list of allowed client tokens. Clients must send `Authorization: Bearer <token>`. |
| `AUTH_TOKEN` | Recommended | — | `sk-123` | Default access token. |
| `DATABASE_TYPE` | No | `sqlite` | `sqlite` | DB engine. |
| `SQLITE_DATABASE` | No | `/home/user/gemini-data/gemini_balance.db` | same | SQLite DB path (in container). |
| `BASE_URL` | No | `https://generativelanguage.googleapis.com/v1beta` | same | Gemini API base URL. |
| `PROXIES` | No | `[]` | `["http://host:port"]` | Optional HTTP/SOCKS5 proxies array. |

Tip: You can also commit a `.env` file (see `_refs/gemini-balance-main/.env.example`) into your backup repo under `home/user/gemini-balance-main/.env`; the backup step restores it before the service starts.

---

## Getting Tokens/Keys
- GitHub token (`github_secret`): create a PAT with `repo` scope in GitHub → Settings → Developer settings.
- Google Gemini `API_KEYS`: create keys in Google AI Studio; put them as a JSON array string in `API_KEYS`.

---

## Local Quick Start (Docker)
1) Build:
```
docker build -t astrbot-napcat-hf:latest .
```
2) Run (replace examples as needed):
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
3) Open `http://localhost:7860/`:
- `/` AstrBot dashboard (first boot downloads UI assets)
- `/webui/` NapCat UI (login/QR)
- `/gemini/` Gemini proxy
- `/admin/ui/` Router admin UI (`admin` default)

---

## Hugging Face (Docker SDK)
1) Create a Space (Docker SDK). Private is recommended for privacy.
2) Push this repo to the Space or connect via GitHub.
3) Configure Settings → Variables and secrets:
- Required: `github_project`, `github_secret`; optional `GIT_BRANCH`.
- For Gemini: `API_KEYS`, `ALLOWED_TOKENS`, `AUTH_TOKEN`, etc.
- Optional: `NAPCAT_FLAGS` (e.g. `--disable-gpu`).
4) Hardware: CPU Basic is enough; disable Sleep to keep bots online.
5) Start the Space; wait for build, then open the Space URL (listens on 7860).
6) First‑time:
- Visit `/admin/ui/` and change the admin password.
- Configure AstrBot providers/platforms (or pre‑seed under `home/user/AstrBot/data` in backup repo).
- Login/bind NapCat via `/webui/`; settings persist via backup.
- Provide `API_KEYS` or `.env` for Gemini; test endpoints.

Persistence: the Space filesystem is ephemeral. The backup service clones your GitHub repo, symlinks key directories, and pushes changes back on a schedule.

---

## Router Admin API Cheatsheet
- Get routes:
```
curl -H "X-Admin-Password: <pass>" https://<host>/admin/routes.json
```
- Replace routes:
```
curl -X POST -H "X-Admin-Password: <pass>" -H "Content-Type: application/json" \
  -d '{"default_backend":"http://127.0.0.1:6185","rules":[...]}' \
  https://<host>/admin/routes.json
```
- Change password:
```
curl -X POST -H "X-Admin-Password: <old>" -H "Content-Type: application/json" \
  -d '{"new_password":"<new>"}' https://<host>/admin/password
```

---

## Gemini Test Examples
- List models:
```
curl -H "Authorization: Bearer sk-123" https://<host>/gemini/hf/v1/models
```
- Chat completion:
```
curl -X POST -H "Authorization: Bearer sk-123" -H "Content-Type: application/json" \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"Hello"}]}' \
  https://<host>/gemini/hf/v1/chat/completions
```

---

## Troubleshooting
- 502/blank: check `/admin/ui/`; ensure default backend is `http://127.0.0.1:6185`.
- NapCat issues: AppImage runs with `--appimage-extract-and-run` under Xvfb; consider `--disable-gpu`.
- Gemini 401: set `ALLOWED_TOKENS`/`AUTH_TOKEN` and send `Authorization: Bearer <token>`.
- First AstrBot boot slow: downloads dashboard assets; wait a moment.

---

## License
This repo glues upstream projects (each under their own licenses). See upstream repos for details; this repo adds configuration and automation only.
