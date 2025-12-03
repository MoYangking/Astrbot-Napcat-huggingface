# AstrBot + NapCat on Hugging Face

This repo packages AstrBot (agent chatbot) and NapCat (QQ/OneBot bridge) behind an OpenResty (nginx + Lua) gateway. It targets both local Docker and Hugging Face Spaces (Docker SDK). Processes are orchestrated by `supervisord`.

Upstreams:
- AstrBot: https://github.com/AstrBotDevs/AstrBot
- NapCat AppImage Build: https://github.com/NapNeko/NapCatAppImageBuild

Components and ports:
- AstrBot (Python 3.10+): 6185 (proxied)
- NapCat (AppImage + Xvfb): 6099/3001/6199 (proxied)
- OpenResty gateway: 7860 (public)

Default routes (on 7860):
- `/` → AstrBot dashboard (default backend `http://127.0.0.1:6185`)
- `/webui/`, `/api/ws/` → NapCat (`http://127.0.0.1:6099`)
- `/admin/ui/` → Router admin UI (header `X-Admin-Password`, default `admin`)

Layout:
- `Dockerfile` — build all deps and clone upstream apps
- `supervisor/supervisord.conf` — nginx, Xvfb, Sync, NapCat, AstrBot
- `nginx/nginx.conf` — OpenResty dynamic routing and admin API
- `scripts/` — NapCat launcher script

---

## Environment Variables (Tables)

NapCat (optional)

| Name | Required | Default | Example | Notes |
| --- | --- | --- | --- | --- |
| `NAPCAT_FLAGS` | No | empty | `--disable-gpu` | Extra flags passed to the QQ AppImage. Non‑root run usually doesn't require `--no-sandbox`. |
| `TZ` | No | `Asia/Shanghai` | `Asia/Shanghai` | Timezone. |

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
  --name astrbot-napcat astrbot-napcat-hf:latest
```
3) Open `http://localhost:7860/`:
- `/` AstrBot dashboard (first boot downloads UI assets)
- `/webui/` NapCat UI (login/QR)
- `/admin/ui/` Router admin UI (`admin` default)

---

## Hugging Face (Docker SDK)
1) Create a Space (Docker SDK). Private is recommended for privacy.
2) Push this repo to the Space or connect via GitHub.
3) Configure Settings → Variables and secrets:
- Optional: `NAPCAT_FLAGS` (e.g. `--disable-gpu`).
4) Hardware: CPU Basic is enough; disable Sleep to keep bots online.
5) Start the Space; wait for build, then open the Space URL (listens on 7860).
6) First‑time:
- Visit `/admin/ui/` and change the admin password.
- Configure AstrBot providers/platforms.
- Login/bind NapCat via `/webui/`.

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

## Troubleshooting
- 502/blank: check `/admin/ui/`; ensure default backend is `http://127.0.0.1:6185`.
- NapCat issues: AppImage runs with `--appimage-extract-and-run` under Xvfb; consider `--disable-gpu`.
- First AstrBot boot slow: downloads dashboard assets; wait a moment.

---

## License
This repo glues upstream projects (each under their own licenses). See upstream repos for details; this repo adds configuration and automation only.
