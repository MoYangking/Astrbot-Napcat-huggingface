FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

# 基础依赖：git/python/node/构建工具 + ffmpeg + supervisor + NapCat 运行库
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg bash \
    git \
    python3 python3-pip python3-dev \
    build-essential libffi-dev libssl-dev \
    ffmpeg \
    supervisor \
    xvfb libfuse2 \
    libglib2.0-0 libnspr4 libnss3 libatk1.0-0 libatspi2.0-0 \
    libgtk-3-0 libgdk-pixbuf2.0-0 libpango-1.0-0 libcairo2 \
    libx11-6 libx11-xcb1 libxext6 libxrender1 libxi6 libxrandr2 \
    libxcomposite1 libxdamage1 libxkbcommon0 libxfixes3 \
    libxcb1 libxcb-render0 libxcb-shm0 \
    libdrm2 libgbm1 \
    libxss1 libxtst6 libasound2 \
    libsecret-1-0 libnotify4 libdbus-1-3 libgl1 \
 && rm -rf /var/lib/apt/lists/*

# 安装 Node.js LTS（AstrBot 依赖）
RUN apt-get update && apt-get install -y curl gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# 为无 root 用户准备（HF Spaces 默认 uid=1000）
RUN useradd -m -u 1000 -s /bin/bash user
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH
WORKDIR /home/user

# 预创建 X11 socket 目录（非 root 运行 Xvfb 需要）
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# 克隆 AstrBot 源码
RUN git clone https://github.com/AstrBotDevs/AstrBot.git /home/user/AstrBot && \
    chown -R user:user /home/user/AstrBot

# 安装 Python 依赖（参考 AstrBot docker 文件使用 uv）
RUN python3 -m pip install --no-cache-dir --upgrade pip uv && \
    uv pip install -r /home/user/AstrBot/requirements.txt --no-cache-dir --system && \
    uv pip install socksio uv pilk --no-cache-dir --system

# 下载并解压 NapCat AppImage（构建期解压避免运行期 FUSE 需求）
ADD --chown=user:user https://github.com/NapNeko/NapCatAppImageBuild/releases/download/v4.8.124/QQ-40990_NapCat-v4.8.124-amd64.AppImage /home/user/QQ.AppImage
RUN chmod +x /home/user/QQ.AppImage && \
    /home/user/QQ.AppImage --appimage-extract && \
    mv squashfs-root /home/user/napcat && \
    rm /home/user/QQ.AppImage && \
    chown -R user:user /home/user/napcat

# Supervisor 配置与日志目录
RUN mkdir -p /home/user/logs && chown -R user:user /home/user/logs
COPY --chown=user:user supervisor/supervisord.conf /home/user/supervisord.conf

# 环境变量与端口
ENV DISPLAY=:1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    NAPCAT_FLAGS=""

EXPOSE 6099 6185 6186

# 以无 root 账户运行所有进程（由 supervisord 管理）
USER user
CMD ["supervisord", "-c", "/home/user/supervisord.conf"]
