# AstrBot + NapCat + Gemini Balance on Hugging Face

This repo packages AstrBot (agent chatbot), NapCat (QQ/OneBot bridge), and Gemini Balance (Gemini proxy/load balancer) behind an OpenResty (nginx + Lua) gateway. It targets both local Docker and Hugging Face Spaces (Docker SDK). Processes are orchestrated by `supervisord`.

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
- `supervisor/supervisord.conf` — Xvfb, NapCat, AstrBot, Gemini, nginx
- `nginx/nginx.conf` — OpenResty dynamic routing and admin API
- `scripts/` — NapCat launcher script

---

## Environment Variables (Tables)

NapCat (optional)

| Name | Required | Default | Example | Notes |
| --- | --- | --- | --- | --- |
| `NAPCAT_FLAGS` | No | empty | `--disable-gpu` | Extra flags passed to the QQ AppImage. Non‑root run usually doesn't require `--no-sandbox`. |
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

---

## Getting Tokens/Keys
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
- For Gemini: `API_KEYS`, `ALLOWED_TOKENS`, `AUTH_TOKEN`, etc.
- Optional: `NAPCAT_FLAGS` (e.g. `--disable-gpu`).
4) Hardware: CPU Basic is enough; disable Sleep to keep bots online.
5) Start the Space; wait for build, then open the Space URL (listens on 7860).
6) First‑time:
- Visit `/admin/ui/` and change the admin password.
- Configure AstrBot providers/platforms.
- Login/bind NapCat via `/webui/`.
- Provide `API_KEYS` or `.env` for Gemini; test endpoints.

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
