"""简单日志工具：统一输出格式，并对敏感信息进行掩码。"""

import os
import sys
from datetime import datetime


def _now():
    return datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")


def log(msg: str):
    """标准输出日志（单行）。"""
    sys.stdout.write(f"[{_now()}] [sync] {msg}\n")
    sys.stdout.flush()


def err(msg: str):
    """标准错误日志（单行）。"""
    sys.stderr.write(f"[{_now()}] [sync] ERROR: {msg}\n")
    sys.stderr.flush()


def mask_token(s: str) -> str:
    """在日志中掩码 URL 中的 Token。

    识别类似 `https://user:token@github.com/...` 或 `https://x-access-token:token@github.com/...`，
    将 token 替换为 `***`。如果包含 `ghp_` 前缀的 Token，也会部分掩码。
    """
    if not s:
        return s
    # Mask patterns like https://x-access-token:TOKEN@github.com/...
    # or https://<user>:<token>@github.com/...
    try:
        if "@github.com" in s and ":" in s and "@" in s:
            prefix, rest = s.split("@", 1)
            if ":" in prefix:
                head, _ = prefix.rsplit(":", 1)
                return f"{head}:***@{rest}"
    except Exception:
        pass
    # Fallback: redact long ghp_ tokens if present
    return s.replace("ghp_", "ghp_***")
