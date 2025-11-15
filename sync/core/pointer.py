"""LFS 指针文件处理

职责：
- 判断文件是否为指针文件
- 读取和解析指针文件内容
- 创建和写入指针文件
- 验证指针文件格式
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Optional

from sync.utils.logging import log, err


@dataclass
class PointerFile:
    """LFS 指针文件数据结构"""
    version: int
    hash: str  # sha256:abc123...
    size: int
    filename: str
    release_tag: str
    asset_name: str
    
    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "type": "lfs-pointer",
            "hash": self.hash,
            "size": self.size,
            "filename": self.filename,
            "release_tag": self.release_tag,
            "asset_name": self.asset_name
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> PointerFile:
        return cls(
            version=data.get("version", 1),
            hash=data["hash"],
            size=data["size"],
            filename=data["filename"],
            release_tag=data["release_tag"],
            asset_name=data["asset_name"]
        )


def is_pointer_file(path: str) -> bool:
    """判断文件是否为 LFS 指针文件
    
    检查：
    1. 文件名以 .pointer 结尾，或
    2. 文件很小（<1KB）且包含 lfs-pointer 标记
    """
    if not os.path.isfile(path):
        return False
    
    # 快速检查：文件名
    if path.endswith('.pointer'):
        return True
    
    # 大小检查：指针文件应该很小
    try:
        if os.path.getsize(path) > 2048:  # 2KB
            return False
    except OSError:
        return False
    
    # 内容检查：尝试解析 JSON
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            # 快速检查是否包含关键字
            if 'lfs-pointer' not in content:
                return False
            data = json.loads(content)
            return data.get("type") == "lfs-pointer"
    except (json.JSONDecodeError, OSError, KeyError, UnicodeDecodeError):
        return False


def read_pointer(path: str) -> Optional[PointerFile]:
    """读取指针文件内容
    
    返回：
    - PointerFile 对象，如果成功
    - None，如果失败或不是指针文件
    """
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            data = json.load(f)
        
        # 验证数据类型
        if not isinstance(data, dict):
            err(f"Pointer file is not a dict: {path}")
            return None
        
        if data.get("type") != "lfs-pointer":
            return None
        
        return PointerFile.from_dict(data)
    except (json.JSONDecodeError, OSError, KeyError, UnicodeDecodeError, TypeError) as e:
        err(f"Failed to read pointer file {path}: {e}")
        return None


def write_pointer(path: str, pointer: PointerFile) -> bool:
    """写入指针文件
    
    Args:
        path: 指针文件路径（原文件位置）
        pointer: PointerFile 对象
    
    Returns:
        成功返回 True，失败返回 False
    """
    try:
        # 确保父目录存在
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        
        # 写入 JSON
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(pointer.to_dict(), f, indent=2, ensure_ascii=False)
        
        log(f"✓ Pointer file created: {path}")
        return True
    except OSError as e:
        err(f"Failed to write pointer file {path}: {e}")
        return False


def get_real_path_from_pointer(pointer_path: str) -> str:
    """从指针文件路径获取实际文件路径
    
    如果指针文件名为 xxx.pointer，返回 xxx
    否则返回原路径
    """
    if pointer_path.endswith('.pointer'):
        return pointer_path[:-8]  # 移除 .pointer 后缀
    return pointer_path


def validate_pointer(pointer: PointerFile) -> bool:
    """验证指针文件数据完整性
    
    检查：
    - 哈希值格式正确
    - 文件大小 > 0
    - 必要字段非空
    """
    if not pointer.hash or not pointer.hash.startswith('sha256:'):
        return False
    
    if pointer.size <= 0:
        return False
    
    if not pointer.filename or not pointer.asset_name:
        return False
    
    if not pointer.release_tag:
        return False
    
    return True