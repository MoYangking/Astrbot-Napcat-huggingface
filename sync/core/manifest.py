"""LFS Manifest 管理

职责：
- 加载和保存 manifest.json
- 记录文件版本历史
- 管理版本清理（保留最多 N 个版本）
- 提供版本查询接口
"""

from __future__ import annotations

import json
import os
import time
import threading
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, asdict

from sync.utils.logging import log, err


@dataclass
class FileVersion:
    """文件版本信息"""
    hash: str  # sha256:abc123...
    asset_name: str
    size: int
    timestamp: str  # ISO 8601 格式
    uploaded: bool = True
    
    def to_dict(self) -> dict:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: dict) -> FileVersion:
        return cls(**data)


@dataclass
class FileRecord:
    """文件记录（包含所有版本）"""
    current_hash: str
    versions: List[FileVersion]
    
    def to_dict(self) -> dict:
        return {
            "current_hash": self.current_hash,
            "versions": [v.to_dict() for v in self.versions]
        }
    
    @classmethod
    def from_dict(cls, data: dict) -> FileRecord:
        versions = [FileVersion.from_dict(v) for v in data.get("versions", [])]
        return cls(
            current_hash=data["current_hash"],
            versions=versions
        )


class Manifest:
    """LFS Manifest 管理器"""
    
    def __init__(self, hist_dir: str, release_tag: str = "large-files-v1"):
        """初始化 Manifest
        
        Args:
            hist_dir: Git 仓库目录
            release_tag: Release 标签
        """
        self.hist_dir = hist_dir
        self.release_tag = release_tag
        self.manifest_path = os.path.join(hist_dir, ".lfs", "manifest.json")
        self._lock = threading.Lock()
        self._data: Dict[str, Any] = {}
        self._load()
    
    def _load(self) -> None:
        """从文件加载 manifest"""
        if not os.path.exists(self.manifest_path):
            self._data = {
                "version": 2,
                "last_updated": self._current_time(),
                "release_tag": self.release_tag,
                "files": {}
            }
            return
        
        try:
            with open(self.manifest_path, 'r', encoding='utf-8') as f:
                self._data = json.load(f)
            log(f"Loaded manifest: {len(self._data.get('files', {}))} files")
        except (json.JSONDecodeError, OSError) as e:
            err(f"Failed to load manifest: {e}, using empty manifest")
            self._data = {
                "version": 2,
                "last_updated": self._current_time(),
                "release_tag": self.release_tag,
                "files": {}
            }
    
    def save(self) -> bool:
        """保存 manifest 到文件"""
        with self._lock:
            try:
                # 确保目录存在
                os.makedirs(os.path.dirname(self.manifest_path), exist_ok=True)
                
                # 更新时间戳
                self._data["last_updated"] = self._current_time()
                
                # 写入文件
                with open(self.manifest_path, 'w', encoding='utf-8') as f:
                    json.dump(self._data, f, indent=2, ensure_ascii=False)
                
                return True
            except OSError as e:
                err(f"Failed to save manifest: {e}")
                return False
    
    def get_file_record(self, file_path: str) -> Optional[FileRecord]:
        """获取文件记录
        
        Args:
            file_path: 文件路径（相对于 hist_dir）
        
        Returns:
            FileRecord 或 None
        """
        files = self._data.get("files", {})
        if file_path not in files:
            return None
        return FileRecord.from_dict(files[file_path])
    
    def add_version(
        self,
        file_path: str,
        hash_value: str,
        asset_name: str,
        size: int,
        set_as_current: bool = True
    ) -> None:
        """添加文件新版本
        
        Args:
            file_path: 文件路径（相对于 hist_dir）
            hash_value: 文件哈希值
            asset_name: Release asset 名称
            size: 文件大小
            set_as_current: 是否设为当前版本
        """
        with self._lock:
            files = self._data.setdefault("files", {})
            
            # 创建新版本
            new_version = FileVersion(
                hash=hash_value,
                asset_name=asset_name,
                size=size,
                timestamp=self._current_time(),
                uploaded=True
            )
            
            if file_path in files:
                # 更新现有记录
                record = FileRecord.from_dict(files[file_path])
                # 检查是否已存在相同哈希
                if not any(v.hash == hash_value for v in record.versions):
                    record.versions.append(new_version)
                if set_as_current:
                    record.current_hash = hash_value
                files[file_path] = record.to_dict()
            else:
                # 创建新记录
                record = FileRecord(
                    current_hash=hash_value,
                    versions=[new_version]
                )
                files[file_path] = record.to_dict()
            
            log(f"Added version for {file_path}: {hash_value[:16]}...")
    
    def get_current_version(self, file_path: str) -> Optional[FileVersion]:
        """获取文件当前版本"""
        record = self.get_file_record(file_path)
        if not record:
            return None
        
        for version in record.versions:
            if version.hash == record.current_hash:
                return version
        
        # 如果当前哈希对应的版本不存在，返回最新的
        if record.versions:
            return record.versions[-1]
        return None
    
    def get_all_versions(self, file_path: str) -> List[FileVersion]:
        """获取文件所有版本（按时间排序）"""
        record = self.get_file_record(file_path)
        if not record:
            return []
        return sorted(record.versions, key=lambda v: v.timestamp, reverse=True)
    
    def cleanup_old_versions(self, file_path: str, keep: int = 3) -> List[str]:
        """清理旧版本，保留最新 N 个
        
        Args:
            file_path: 文件路径
            keep: 保留的版本数
        
        Returns:
            需要删除的 asset 名称列表
        """
        with self._lock:
            record = self.get_file_record(file_path)
            if not record or len(record.versions) <= keep:
                return []
            
            # 按时间排序（新到旧）
            sorted_versions = sorted(
                record.versions,
                key=lambda v: v.timestamp,
                reverse=True
            )
            
            # 保留最新的 N 个
            to_keep = sorted_versions[:keep]
            to_remove = sorted_versions[keep:]
            
            # 更新记录
            record.versions = to_keep
            files = self._data.get("files", {})
            files[file_path] = record.to_dict()
            
            # 返回需要删除的 asset 名称
            removed_assets = [v.asset_name for v in to_remove]
            if removed_assets:
                log(f"Cleaned up {len(removed_assets)} old versions for {file_path}")
            return removed_assets
    
    def cleanup_all_old_versions(self, keep: int = 3) -> Dict[str, List[str]]:
        """清理所有文件的旧版本
        
        Returns:
            文件路径 -> 需要删除的 asset 列表
        """
        result = {}
        files = self._data.get("files", {})
        for file_path in files:
            removed = self.cleanup_old_versions(file_path, keep)
            if removed:
                result[file_path] = removed
        return result
    
    def list_all_files(self) -> List[str]:
        """列出所有被跟踪的文件"""
        return list(self._data.get("files", {}).keys())
    
    def remove_file(self, file_path: str) -> List[str]:
        """从 manifest 中移除文件
        
        Returns:
            需要删除的 asset 名称列表
        """
        with self._lock:
            record = self.get_file_record(file_path)
            if not record:
                return []
            
            # 获取所有 assets
            assets = [v.asset_name for v in record.versions]
            
            # 从 manifest 删除
            files = self._data.get("files", {})
            if file_path in files:
                del files[file_path]
                log(f"Removed file from manifest: {file_path}")
            
            return assets
    
    @staticmethod
    def _current_time() -> str:
        """获取当前时间（ISO 8601 格式）"""
        from datetime import datetime
        return datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")