FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# Base dependencies: git/python/node/build tools + ffmpeg + supervisor + NapCat runtime libs
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg bash \
    git jq rsync \
    python3 python3-pip python3-dev python3-venv \
    build-essential libffi-dev libssl-dev \
    ffmpeg \
    supervisor nginx-full \
    xvfb libfuse2t64 \
    libglib2.0-0 libnspr4 libnss3 libatk1.0-0 libatspi2.0-0 \
    libgtk-3-0 libgdk-pixbuf-2.0-0 libpango-1.0-0 libcairo2 \
    libx11-6 libx11-xcb1 libxext6 libxrender1 libxi6 libxrandr2 \
    libxcomposite1 libxdamage1 libxkbcommon0 libxfixes3 \
    libxcb1 libxcb-render0 libxcb-shm0 \
    libdrm2 libgbm1 \
    libxss1 libxtst6 libasound2t64 \
    libsecret-1-0 libnotify4 libdbus-1-3 libgl1 \
 && rm -rf /var/lib/apt/lists/*

# Node.js LTS (for AstrBot)
RUN apt-get update && apt-get install -y curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install OpenResty (nginx with built-in LuaJIT & ngx_lua)
RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release && \
    curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu $(lsb_release -sc) main" \
      | tee /etc/apt/sources.list.d/openresty.list > /dev/null && \
    apt-get update && apt-get install -y --no-install-recommends openresty && \
    rm -rf /var/lib/apt/lists/*

# Non-root user paths (UID 1000)
RUN mkdir -p /home/user && chown -R 1000:1000 /home/user
ENV HOME=/home/user \
    VIRTUAL_ENV=/home/user/.venv \
    PATH=/home/user/.venv/bin:/home/user/.local/bin:$PATH
WORKDIR /home/user

# X11 socket dir (for Xvfb)
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Clone AstrBot
RUN git clone https://github.com/AstrBotDevs/AstrBot.git /home/user/AstrBot && \
    chown -R 1000:1000 /home/user/AstrBot

# Create AstrBot data dir
RUN mkdir -p /home/user/AstrBot/data && chown -R 1000:1000 /home/user/AstrBot/data

# Python deps (use venv to avoid PEP 668)
RUN python3 -m venv "$VIRTUAL_ENV" && \
    "$VIRTUAL_ENV/bin/pip" install --no-cache-dir --upgrade pip uv && \
    uv pip install -r /home/user/AstrBot/requirements.txt --no-cache-dir && \
    "$VIRTUAL_ENV/bin/pip" install --no-cache-dir socksio pilk \
    "pymilvus>=2.5.4,<3.0.0" \
    "pypinyin>=0.53.0,<1.0.0" \
    "google-genai>=1.11.0,<2.0.0" \
    "fastapi>=0.104.0,<1.0.0" \
    "uvicorn>=0.24.0,<1.0.0" \
    "jinja2>=3.1.0,<4.0.0" \
    "openai>=1.0.0,<2.0.0" \
    "httpx>=0.25.0,<1.0.0" && \
    chown -R 1000:1000 "$VIRTUAL_ENV"

# Clone and setup Gemini Balance service
RUN git clone https://github.com/MoYangking/gemini-balance-main /home/user/gemini-balance-main && \
    chown -R 1000:1000 /home/user/gemini-balance-main && \
    uv pip install -r /home/user/gemini-balance-main/requirements.txt --no-cache-dir && \
    chown -R 1000:1000 "$VIRTUAL_ENV"

# Gemini persistent data dir
RUN mkdir -p /home/user/gemini-data && chown -R 1000:1000 /home/user/gemini-data

# Default env for Gemini (can be overridden at runtime)
ENV DATABASE_TYPE=sqlite \
    SQLITE_DATABASE=/home/user/gemini-data/gemini_balance.db \
    TZ=Asia/Shanghai


# NapCat AppImage: download latest release, extract and keep extracted tree
RUN LATEST_URL=$(curl -sL https://api.github.com/repos/NapNeko/NapCatAppImageBuild/releases/latest | \
    jq -r '.assets[] | select(.name | endswith("-amd64.AppImage")) | .browser_download_url' | head -1) && \
    curl -L -o /home/user/QQ.AppImage "$LATEST_URL" && \
    chown 1000:1000 /home/user/QQ.AppImage && \
    chmod +x /home/user/QQ.AppImage && \
    /home/user/QQ.AppImage --appimage-extract && \
    mv squashfs-root /home/user/napcat && \
    chown -R 1000:1000 /home/user/napcat

# Supervisor and Nginx config + logs
RUN mkdir -p /home/user/logs && chown -R 1000:1000 /home/user/logs
COPY --chown=1000:1000 supervisor/supervisord.conf /home/user/supervisord.conf
RUN mkdir -p /home/user/nginx && chown -R 1000:1000 /home/user/nginx
COPY --chown=1000:1000 nginx/nginx.conf /home/user/nginx/nginx.conf
COPY --chown=1000:1000 nginx/default_admin_config.json /home/user/nginx/default_admin_config.json
COPY --chown=1000:1000 nginx/route-admin /home/user/nginx/route-admin
RUN mkdir -p \
      /home/user/nginx/tmp/body \
      /home/user/nginx/tmp/proxy \
      /home/user/nginx/tmp/fastcgi \
      /home/user/nginx/tmp/uwsgi \
      /home/user/nginx/tmp/scgi \
    && chown -R 1000:1000 /home/user/nginx

# Sync service (daemon + web)
COPY --chown=1000:1000 sync /home/user/sync
RUN chown -R 1000:1000 /home/user/sync

# NapCat runtime dirs and launcher
RUN mkdir -p /app/.config/QQ /app/napcat/config && chown -R 1000:1000 /app
RUN mkdir -p /home/user/scripts && chown -R 1000:1000 /home/user/scripts
COPY --chown=1000:1000 scripts/run-napcat.sh /home/user/scripts/run-napcat.sh
COPY --chown=1000:1000 scripts/wait-sync-ready.sh /home/user/scripts/wait-sync-ready.sh
RUN chmod +x /home/user/scripts/run-napcat.sh
RUN chmod +x /home/user/scripts/wait-sync-ready.sh

# Env and ports
ENV DISPLAY=:1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    NAPCAT_FLAGS=""

# Optional: admin token for updating routes at runtime (used by Lua)
ENV ROUTE_ADMIN_TOKEN=""

# Control whether to start Gemini service (default: true)
ENV ENABLE_GEMINI=true

# Ensure OpenResty binaries present in PATH
ENV PATH=/usr/local/openresty/bin:$PATH

EXPOSE 7860

# Run as UID 1000
USER 1000
CMD ["supervisord", "-c", "/home/user/supervisord.conf"]
