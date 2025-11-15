"""LFS 核心操作

职责：
- 计算文件哈希值
- 判断文件是否需要使用 LFS
- 将大文件转换为指针文件并上传
- 从指针文件恢复实际文件
- 扫描和处理所有 LFS 文件
"""

from __future__ import annotations

import hashlib
import os
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, List, Callable, Dict, Any

from sync.core.pointer import PointerFile, is_pointer_file, read_pointer, write_pointer, validate_pointer
from sync.core.release_api import GitHubReleaseAPI
from sync.core.manifest import Manifest
from sync.utils.logging import log, err


def sanitize_filename(filename: str) -> str:
    """清理文件名，移除或替换特殊字符
    
    GitHub Release asset 名称不允许某些字符，需要预先清理
    
    Args:
        filename: 原始文件名
    
    Returns:
        清理后的文件名
    """
    import re
    # 替换空格为下划线
    filename = filename.replace(' ', '_')
    # 替换括号为下划线
    filename = filename.replace('(', '_').replace(')', '_')
    # 移除连续的下划线
    filename = re.sub(r'_+', '_', filename)
    # 只保留字母、数字、点、短横线、下划线
    filename = re.sub(r'[^a-zA-Z0-9._-]', '_', filename)
    return filename


def calculate_file_hash(file_path: str, algorithm: str = "sha256") -> str:
    """计算文件哈希值（分块读取，避免内存溢出）
    
    Args:
        file_path: 文件路径
        algorithm: 哈希算法（默认 sha256）
    
    Returns:
        哈希值字符串，格式：algorithm:hexdigest
    """
    hasher = hashlib.new(algorithm)
    with open(file_path, 'rb') as f:
        while chunk := f.read(8192):
            hasher.update(chunk)
    return f"{algorithm}:{hasher.hexdigest()}"


def should_use_lfs(file_path: str, threshold: int) -> bool:
    """判断文件是否应该使用 LFS
    
    Args:
        file_path: 文件路径
        threshold: 大小阈值（字节）
    
    Returns:
        如果文件存在且大小超过阈值，返回 True
    """
    if not os.path.isfile(file_path):
        return False
    
    try:
        size = os.path.getsize(file_path)
        return size > threshold
    except OSError:
        return False


def convert_to_lfs(
    file_path: str,
    api: GitHubReleaseAPI,
    manifest: Manifest,
    release_tag: str,
    progress_callback: Optional[Callable[[str, int, int], None]] = None
) -> bool:
    """将大文件转换为 LFS 指针文件
    
    流程：
    1. 计算文件哈希
    2. 上传到 Release
    3. 创建指针文件
    4. 更新 manifest
    5. 删除原文件
    
    Args:
        file_path: 文件路径（绝对路径）
        api: GitHub Release API 客户端
        manifest: Manifest 管理器
        release_tag: Release 标签
        progress_callback: 进度回调 (file_path, uploaded, total)
    
    Returns:
        成功返回 True
    """
    try:
        # 1. 计算哈希
        log(f"Calculating hash for {file_path}...")
        file_hash = calculate_file_hash(file_path)
        file_size = os.path.getsize(file_path)
        filename = os.path.basename(file_path)
        
        # 2. 生成 asset 名称（清理特殊字符）
        hash_prefix = file_hash.split(':')[1][:12]  # 取前12位
        clean_filename = sanitize_filename(filename)
        asset_name = f"{hash_prefix}-{clean_filename}"
        
        # 3. 检查是否已上传
        release = api.get_or_create_release(release_tag)
        existing_asset = api.get_asset_by_name(release, asset_name)
        
        actual_asset_name = asset_name  # 默认使用清理后的名称
        
        if not existing_asset:
            # 4. 上传到 Release
            log(f"Uploading {filename} to Release...")
            
            def upload_progress(uploaded: int, total: int):
                if progress_callback:
                    progress_callback(file_path, uploaded, total)
            
            uploaded_asset = api.upload_asset(release, file_path, asset_name, upload_progress)
            # 使用 API 返回的实际名称（GitHub 可能进一步修改）
            actual_asset_name = uploaded_asset.get("name", asset_name)
            log(f"Uploaded as: {actual_asset_name}")
        else:
            actual_asset_name = existing_asset.get("name", asset_name)
            log(f"Asset already exists: {actual_asset_name}")
        
        # 5. 创建指针文件（使用实际的 asset 名称）
        pointer = PointerFile(
            version=1,
            hash=file_hash,
            size=file_size,
            filename=filename,
            release_tag=release_tag,
            asset_name=actual_asset_name  # 使用实际名称
        )
        
        pointer_path = file_path + ".pointer"
        write_pointer(pointer_path, pointer)
        
        # 6. 从 Git 索引中移除大文件（如果已被追踪）
        from sync.core import git_ops
        rel_path = os.path.relpath(file_path, manifest.hist_dir)
        try:
            # 检查文件是否被 Git 追踪
            result = git_ops.run(
                ["git", "ls-files", rel_path],
                cwd=manifest.hist_dir,
                check=False
            )
            if result.stdout.strip():
                # 文件已被追踪，从索引中移除（但保留工作区文件）
                git_ops.run(
                    ["git", "rm", "--cached", rel_path],
                    cwd=manifest.hist_dir,
                    check=False
                )
                log(f"Removed {rel_path} from Git index (file kept locally)")
        except Exception as e:
            err(f"Failed to remove from Git index: {e}")
        
        # 7. 更新 manifest（使用实际名称）
        # 文件路径相对于 hist_dir
        rel_path = os.path.relpath(file_path, manifest.hist_dir)
        manifest.add_version(rel_path, file_hash, actual_asset_name, file_size)
        manifest.save()
        
        # 7. 将原文件添加到 Git exclude（不删除！保留供程序访问）
        from sync.core.blacklist import ensure_git_info_exclude
        exclude_path = os.path.relpath(file_path, manifest.hist_dir)
        ensure_git_info_exclude(manifest.hist_dir, [exclude_path])
        
        log(f"✓ Converted to LFS: {filename} (file kept, pointer created)")
        
        return True
    except Exception as e:
        err(f"Failed to convert {file_path} to LFS: {e}")
        return False


def restore_from_lfs(
    pointer_path: str,
    api: GitHubReleaseAPI,
    manifest: Manifest,
    verify_hash: bool = True,
    progress_callback: Optional[Callable[[str, int, int], None]] = None
) -> bool:
    """从 LFS 指针文件恢复实际文件
    
    流程：
    1. 读取指针文件
    2. 从 Release 下载文件
    3. 验证哈希（可选）
    4. 替换指针文件为实际文件
    
    Args:
        pointer_path: 指针文件路径
        api: GitHub Release API 客户端
        manifest: Manifest 管理器
        verify_hash: 是否验证哈希
        progress_callback: 进度回调
    
    Returns:
        成功返回 True
    """
    try:
        # 1. 读取指针
        pointer = read_pointer(pointer_path)
        if not pointer or not validate_pointer(pointer):
            err(f"Invalid pointer file: {pointer_path}")
            return False
        
        # 2. 获取 Release
        release = api.get_release(pointer.release_tag)
        if not release:
            err(f"Release not found: {pointer.release_tag}")
            return False
        
        # 3. 查找 asset（尝试当前版本和历史版本）
        asset = api.get_asset_by_name(release, pointer.asset_name)
        
        if not asset:
            # 尝试从 manifest 获取历史版本
            rel_path = os.path.relpath(pointer_path[:-8], manifest.hist_dir)  # 移除 .pointer
            versions = manifest.get_all_versions(rel_path)
            
            for version in versions:
                asset = api.get_asset_by_name(release, version.asset_name)
                if asset:
                    log(f"Using fallback version: {version.asset_name}")
                    pointer.asset_name = version.asset_name
                    pointer.hash = version.hash
                    pointer.size = version.size
                    break
            
            if not asset:
                err(f"Asset not found in Release: {pointer.asset_name}")
                return False
        
        # 4. 下载文件
        temp_path = pointer_path + ".tmp"
        
        def download_progress(downloaded: int, total: int):
            if progress_callback:
                progress_callback(pointer_path, downloaded, total)
        
        api.download_asset(asset, temp_path, download_progress)
        
        # 5. 验证哈希
        if verify_hash:
            downloaded_hash = calculate_file_hash(temp_path)
            if downloaded_hash != pointer.hash:
                os.remove(temp_path)
                err(f"Hash mismatch for {pointer.filename}: expected {pointer.hash}, got {downloaded_hash}")
                return False
        
        # 6. 保存实际文件（不删除指针文件，两者共存）
        actual_path = pointer_path[:-8] if pointer_path.endswith('.pointer') else pointer_path
        
        # 如果实际文件已存在，检查哈希是否匹配
        if os.path.exists(actual_path):
            existing_hash = calculate_file_hash(actual_path)
            if existing_hash == pointer.hash:
                log(f"File already exists with correct hash, skipping: {pointer.filename}")
                os.remove(temp_path)
                return True
        
        # 移动临时文件到实际位置
        shutil.move(temp_path, actual_path)
        
        # 保留指针文件（不删除！）
        # 将实际文件添加到 Git exclude
        from sync.core.blacklist import ensure_git_info_exclude
        exclude_path = os.path.relpath(actual_path, manifest.hist_dir)
        ensure_git_info_exclude(manifest.hist_dir, [exclude_path])
        
        log(f"✓ Restored from LFS: {pointer.filename} (pointer kept)")
        return True
    except Exception as e:
        err(f"Failed to restore {pointer_path} from LFS: {e}")
        # 清理临时文件
        temp_path = pointer_path + ".tmp"
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass
        return False


def scan_pointer_files(directory: str) -> List[str]:
    """扫描目录中的所有指针文件
    
    Args:
        directory: 要扫描的目录
    
    Returns:
        指针文件路径列表
    """
    pointers = []
    for root, dirs, files in os.walk(directory):
        # 跳过 .git 目录
        if '.git' in root:
            continue
        
        for file in files:
            path = os.path.join(root, file)
            if is_pointer_file(path):
                pointers.append(path)
    
    return pointers


def scan_large_files(directory: str, threshold: int, excludes: List[str] = None) -> List[str]:
    """扫描目录中的大文件（未转换为 LFS 的）
    
    Args:
        directory: 要扫描的目录
        threshold: 大小阈值
        excludes: 排除的路径前缀列表
    
    Returns:
        大文件路径列表
    """
    excludes = excludes or []
    large_files = []
    
    for root, dirs, files in os.walk(directory):
        # 跳过 .git 和 .lfs 目录
        if '.git' in root or '.lfs' in root:
            continue
        
        # 检查是否在排除列表中
        rel_root = os.path.relpath(root, directory)
        if any(rel_root.startswith(ex) for ex in excludes):
            continue
        
        for file in files:
            # 跳过指针文件
            if file.endswith('.pointer'):
                continue
            
            path = os.path.join(root, file)
            if should_use_lfs(path, threshold):
                large_files.append(path)
    
    return large_files


def restore_all_lfs_files(
    directory: str,
    api: GitHubReleaseAPI,
    manifest: Manifest,
    max_workers: int = 3,
    progress_callback: Optional[Callable[[int, int], None]] = None
) -> Dict[str, bool]:
    """并发恢复所有 LFS 文件
    
    Args:
        directory: 目录
        api: GitHub Release API 客户端
        manifest: Manifest 管理器
        max_workers: 最大并发数
        progress_callback: 进度回调 (completed, total)
    
    Returns:
        文件路径 -> 是否成功的字典
    """
    pointers = scan_pointer_files(directory)
    if not pointers:
        log("No LFS pointer files found")
        return {}
    
    log(f"Found {len(pointers)} LFS pointer files, restoring...")
    
    results = {}
    completed = 0
    
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {
            executor.submit(restore_from_lfs, p, api, manifest): p 
            for p in pointers
        }
        
        for future in as_completed(futures):
            pointer_path = futures[future]
            try:
                success = future.result()
                results[pointer_path] = success
                completed += 1
                
                if progress_callback:
                    progress_callback(completed, len(pointers))
                
            except Exception as e:
                err(f"Error restoring {pointer_path}: {e}")
                results[pointer_path] = False
                completed += 1
                
                if progress_callback:
                    progress_callback(completed, len(pointers))
    
    success_count = sum(1 for v in results.values() if v)
    log(f"✓ Restored {success_count}/{len(pointers)} LFS files")
    
    return results