"""GitHub Release API 封装

职责：
- 获取或创建 Release
- 上传文件到 Release (asset)
- 下载 Release 中的文件
- 删除 Release 中的文件
- 列出所有 assets
"""

from __future__ import annotations

import os
import time
from typing import Optional, List, Dict, Any, Callable

try:
    import httpx
except ImportError:
    httpx = None

from sync.utils.logging import log, err, mask_token


class GitHubReleaseAPI:
    """GitHub Release API 客户端"""
    
    def __init__(self, repo: str, token: str, timeout: int = 300):
        """初始化 API 客户端
        
        Args:
            repo: 仓库名称，格式：owner/repo
            token: GitHub Personal Access Token
            timeout: 请求超时时间（秒）
        """
        if not httpx:
            raise RuntimeError("httpx not installed, required for LFS")
        
        self.repo = repo
        self.token = token
        self.timeout = timeout
        self.base_url = f"https://api.github.com/repos/{repo}"
        self.headers = {
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "AstrBot-Sync-LFS/1.0"
        }
    
    def _request(self, method: str, url: str, **kwargs) -> httpx.Response:
        """发送 HTTP 请求，带重试机制"""
        max_retries = 3
        for attempt in range(max_retries):
            try:
                with httpx.Client(timeout=self.timeout) as client:
                    resp = client.request(method, url, headers=self.headers, **kwargs)
                    resp.raise_for_status()
                    return resp
            except httpx.HTTPStatusError as e:
                if e.response.status_code == 404 and attempt == max_retries - 1:
                    raise
                if e.response.status_code >= 500 and attempt < max_retries - 1:
                    time.sleep(2 ** attempt)  # 指数退避
                    continue
                raise
            except httpx.RequestError as e:
                if attempt < max_retries - 1:
                    time.sleep(2 ** attempt)
                    continue
                raise
        raise RuntimeError("Max retries exceeded")
    
    def get_release(self, tag: str) -> Optional[Dict[str, Any]]:
        """获取指定 tag 的 Release
        
        Returns:
            Release 对象（dict），如果不存在返回 None
        """
        try:
            url = f"{self.base_url}/releases/tags/{tag}"
            resp = self._request("GET", url)
            return resp.json()
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            raise
    
    def create_release(self, tag: str, name: str, body: str = "") -> Dict[str, Any]:
        """创建新的 Release
        
        Args:
            tag: Release 标签
            name: Release 名称
            body: Release 描述
        
        Returns:
            创建的 Release 对象
        """
        url = f"{self.base_url}/releases"
        data = {
            "tag_name": tag,
            "name": name,
            "body": body or f"LFS storage for large files",
            "draft": False,
            "prerelease": False
        }
        resp = self._request("POST", url, json=data)
        log(f"✓ Created release: {tag}")
        return resp.json()
    
    def get_or_create_release(self, tag: str) -> Dict[str, Any]:
        """获取或创建 Release"""
        release = self.get_release(tag)
        if release:
            return release
        return self.create_release(tag, f"LFS Storage - {tag}")
    
    def list_assets(self, release: Dict[str, Any]) -> List[Dict[str, Any]]:
        """列出 Release 中的所有 assets"""
        url = release["assets_url"]
        resp = self._request("GET", url)
        return resp.json()
    
    def get_asset_by_name(self, release: Dict[str, Any], name: str) -> Optional[Dict[str, Any]]:
        """根据名称查找 asset"""
        assets = self.list_assets(release)
        for asset in assets:
            if asset["name"] == name:
                return asset
        return None
    
    def upload_asset(
        self, 
        release: Dict[str, Any], 
        file_path: str, 
        asset_name: str,
        progress_callback: Optional[Callable[[int, int], None]] = None
    ) -> Dict[str, Any]:
        """上传文件到 Release
        
        Args:
            release: Release 对象
            file_path: 本地文件路径
            asset_name: asset 名称
            progress_callback: 进度回调函数 (uploaded_bytes, total_bytes)
        
        Returns:
            上传的 asset 对象
        """
        # 检查是否已存在同名 asset
        existing = self.get_asset_by_name(release, asset_name)
        if existing:
            log(f"Asset {asset_name} already exists, deleting old version")
            self.delete_asset(existing)
        
        # 上传 URL
        upload_url = release["upload_url"].replace("{?name,label}", f"?name={asset_name}")
        
        # 读取文件
        file_size = os.path.getsize(file_path)
        log(f"Uploading {asset_name} ({file_size} bytes)...")
        
        with open(file_path, 'rb') as f:
            file_data = f.read()
        
        # 上传
        headers = self.headers.copy()
        headers["Content-Type"] = "application/octet-stream"
        
        with httpx.Client(timeout=self.timeout) as client:
            resp = client.post(upload_url, headers=headers, content=file_data)
            resp.raise_for_status()
        
        log(f"✓ Uploaded asset: {asset_name}")
        return resp.json()
    
    def download_asset(
        self,
        asset: Dict[str, Any],
        save_path: str,
        progress_callback: Optional[Callable[[int, int], None]] = None
    ) -> bool:
        """下载 asset 到本地文件
        
        Args:
            asset: asset 对象
            save_path: 保存路径
            progress_callback: 进度回调
        
        Returns:
            成功返回 True
        """
        # 使用 Release Asset 的 API 端点（asset["url"]），通过 PAT 鉴权下载二进制内容
        url = asset["url"]
        size = asset.get("size", 0)
        
        log(f"Downloading {asset.get('name', '<unknown>')} ({size} bytes)...")
        
        # 确保父目录存在
        parent = os.path.dirname(save_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        
        # 构造请求头：带上 Token，并在访问 API 端点时使用 octet-stream
        headers = self.headers.copy()
        # 对下载接口，期望拿到二进制流
        headers["Accept"] = "application/octet-stream"
        
        with httpx.Client(timeout=self.timeout, follow_redirects=True) as client:
            with client.stream("GET", url, headers=headers) as resp:
                resp.raise_for_status()
                downloaded = 0
                with open(save_path, "wb") as f:
                    for chunk in resp.iter_bytes(chunk_size=8192):
                        if not chunk:
                            continue
                        f.write(chunk)
                        downloaded += len(chunk)
                        if progress_callback:
                            progress_callback(downloaded, size)
        
        log(f"✓ Downloaded: {asset.get('name', '<unknown>')}")
        return True
    
    def delete_asset(self, asset: Dict[str, Any]) -> bool:
        """删除 Release 中的 asset
        
        Args:
            asset: asset 对象
        
        Returns:
            成功返回 True
        """
        url = asset["url"]
        try:
            self._request("DELETE", url)
            log(f"✓ Deleted asset: {asset['name']}")
            return True
        except Exception as e:
            err(f"Failed to delete asset {asset['name']}: {e}")
            return False
