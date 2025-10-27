FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# 基础依赖：git/python/node/构建工具 + ffmpeg + supervisor + NapCat 运行�?RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg bash \
    git \
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

# 安装 Node.js LTS（AstrBot 依赖�?RUN apt-get update && apt-get install -y curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# 为无 root 运行准备：创建工作目录并赋予 UID 1000（无需创建用户名，避免 UID 冲突�?RUN mkdir -p /home/user && chown -R 1000:1000 /home/user
ENV HOME=/home/user \
    VIRTUAL_ENV=/home/user/.venv \
    PATH=/home/user/.venv/bin:/home/user/.local/bin:$PATH
WORKDIR /home/user

# 预创�?X11 socket 目录（非 root 运行 Xvfb 需要）
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# 克隆 AstrBot 源码
RUN git clone https://github.com/AstrBotDevs/AstrBot.git /home/user/AstrBot && \
    chown -R 1000:1000 /home/user/AstrBot

# 预下�?AstrBot WebUI 静态资源，避免运行时网络下载失�?RUN mkdir -p /home/user/AstrBot/data && chown -R 1000:1000 /home/user/AstrBot/data


# 安装 Python 依赖（使�?venv 避免 PEP 668�?RUN python3 -m venv "$VIRTUAL_ENV" && \
    "$VIRTUAL_ENV/bin/pip" install --no-cache-dir --upgrade pip uv && \
    uv pip install -r /home/user/AstrBot/requirements.txt --no-cache-dir && \
    "$VIRTUAL_ENV/bin/pip" install --no-cache-dir socksio pilk && \
    chown -R 1000:1000 "$VIRTUAL_ENV"

# 下载并解�?NapCat AppImage（构建期解压避免运行�?FUSE 需求）
ADD --chown=1000:1000 https://github.com/NapNeko/NapCatAppImageBuild/releases/download/v4.8.124/QQ-40990_NapCat-v4.8.124-amd64.AppImage /home/user/QQ.AppImage
RUN chmod +x /home/user/QQ.AppImage && \
    /home/user/QQ.AppImage --appimage-extract && \
    mv squashfs-root /home/user/napcat && \
    rm /home/user/QQ.AppImage && \
    chown -R 1000:1000 /home/user/napcat

# Supervisor 配置与日志目�?RUN mkdir -p /home/user/logs && chown -R 1000:1000 /home/user/logs
COPY --chown=1000:1000 supervisor/supervisord.conf /home/user/supervisord.conf
RUN mkdir -p /home/user/nginx && chown -R 1000:1000 /home/user/nginx
# NapCat ��������Ŀ¼�� AppImage��ȷ�������ڿ��� extract-and-run��
RUN mkdir -p /app/.config/QQ /app/napcat/config && chown -R 1000:1000 /app
ADD --chown=1000:1000 https://github.com/NapNeko/NapCatAppImageBuild/releases/download/v4.8.124/QQ-40990_NapCat-v4.8.124-amd64.AppImage /home/user/QQ.AppImage
RUN chmod +x /home/user/QQ.AppImage

# ���нű�
RUN mkdir -p /home/user/scripts && chown -R 1000:1000 /home/user/scripts
COPY --chown=1000:1000 scripts/run-napcat.sh /home/user/scripts/run-napcat.sh
RUN chmod +x /home/user/scripts/run-napcat.sh
COPY --chown=1000:1000 nginx/nginx.conf /home/user/nginx/nginx.conf
RUN mkdir -p \
      /home/user/nginx/tmp/body \
      /home/user/nginx/tmp/proxy \
      /home/user/nginx/tmp/fastcgi \
      /home/user/nginx/tmp/uwsgi \
      /home/user/nginx/tmp/scgi \
    && chown -R 1000:1000 /home/user/nginx

# 环境变量与端�?ENV DISPLAY=:1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    NAPCAT_FLAGS=""

EXPOSE 7860

# �?UID 1000 运行所有进程（�?supervisord 管理�?USER 1000
CMD ["supervisord", "-c", "/home/user/supervisord.conf"]

