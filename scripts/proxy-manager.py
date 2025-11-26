#!/usr/bin/env python3
"""代理管理工具

用于启动、停止和检查SOCKS5代理服务状态。
通过supervisorctl控制Gost进程，并管理代理启用状态文件。
"""

import os
import subprocess
import sys
from typing import Optional


PROXY_ENABLED_FILE = "/home/user/.proxy-enabled"
SUPERVISOR_SOCKET = "unix:///home/user/supervisord.sock"


def is_proxy_enabled() -> bool:
    """检查代理是否启用（通过状态文件）"""
    return os.path.exists(PROXY_ENABLED_FILE)


def get_proxy_service_status() -> Optional[str]:
    """获取proxy服务的运行状态
    
    Returns:
        str: "RUNNING", "STOPPED", "STARTING", "FATAL" 等，或 None（如果查询失败）
    """
    try:
        result = subprocess.run(
            ["supervisorctl", "-c", "/home/user/supervisord.conf", "status", "proxy"],
            capture_output=True,
            text=True,
            timeout=5
        )
        # 输出格式: "proxy  RUNNING   pid 1234, uptime 0:01:23"
        if result.returncode == 0:
            parts = result.stdout.strip().split()
            if len(parts) >= 2:
                return parts[1]  # RUNNING, STOPPED, etc.
        return None
    except Exception as e:
        print(f"Failed to get proxy status: {e}", file=sys.stderr)
        return None


def start_proxy() -> bool:
    """启动代理服务
    
    1. 创建代理启用标记文件
    2. 通过supervisorctl启动proxy进程
    
    Returns:
        bool: 启动是否成功
    """
    try:
        # 创建启用标记
        with open(PROXY_ENABLED_FILE, "w") as f:
            f.write("enabled")
        print(f"✓ Created proxy enabled marker: {PROXY_ENABLED_FILE}")
        
        # 启动supervisor服务
        result = subprocess.run(
            ["supervisorctl", "-c", "/home/user/supervisord.conf", "start", "proxy"],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0 or "already started" in result.stdout.lower():
            print("✓ Proxy service started successfully")
            return True
        else:
            print(f"✗ Failed to start proxy: {result.stderr}", file=sys.stderr)
            return False
            
    except Exception as e:
        print(f"✗ Error starting proxy: {e}", file=sys.stderr)
        return False


def stop_proxy() -> bool:
    """停止代理服务
    
    1. 删除代理启用标记文件
    2. 通过supervisorctl停止proxy进程
    
    Returns:
        bool: 停止是否成功
    """
    try:
        # 删除启用标记
        if os.path.exists(PROXY_ENABLED_FILE):
            os.remove(PROXY_ENABLED_FILE)
            print(f"✓ Removed proxy enabled marker: {PROXY_ENABLED_FILE}")
        
        # 停止supervisor服务
        result = subprocess.run(
            ["supervisorctl", "-c", "/home/user/supervisord.conf", "stop", "proxy"],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0 or "not running" in result.stdout.lower():
            print("✓ Proxy service stopped successfully")
            return True
        else:
            print(f"✗ Failed to stop proxy: {result.stderr}", file=sys.stderr)
            return False
            
    except Exception as e:
        print(f"✗ Error stopping proxy: {e}", file=sys.stderr)
        return False


def restart_qq() -> bool:
    """重启NapCat服务
    
    Returns:
        bool: 重启是否成功
    """
    try:
        result = subprocess.run(
            ["supervisorctl", "-c", "/home/user/supervisord.conf", "restart", "napcat"],
            capture_output=True,
            text=True,
            timeout=15
        )
        
        if result.returncode == 0:
            print("✓ NapCat service restarted successfully")
            return True
        else:
            print(f"✗ Failed to restart NapCat: {result.stderr}", file=sys.stderr)
            return False
            
    except Exception as e:
        print(f"✗ Error restarting NapCat: {e}", file=sys.stderr)
        return False


def main():
    """命令行入口"""
    if len(sys.argv) < 2:
        print("Usage: proxy-manager.py {start|stop|status|restart-qq}")
        sys.exit(1)
    
    command = sys.argv[1].lower()
    
    if command == "start":
        success = start_proxy()
        sys.exit(0 if success else 1)
    
    elif command == "stop":
        success = stop_proxy()
        sys.exit(0 if success else 1)
    
    elif command == "status":
        enabled = is_proxy_enabled()
        status = get_proxy_service_status()
        
        print(f"Proxy enabled: {enabled}")
        print(f"Proxy service status: {status or 'UNKNOWN'}")
        sys.exit(0)
    
    elif command == "restart-qq":
        success = restart_qq()
        sys.exit(0 if success else 1)
    
    else:
        print(f"Unknown command: {command}")
        print("Usage: proxy-manager.py {start|stop|status|restart-qq}")
        sys.exit(1)


if __name__ == "__main__":
    main()
