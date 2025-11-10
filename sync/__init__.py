"""Sync 包：本地到 GitHub 的自动同步工具集。

推荐直接运行：
  python -m sync         # 启动守护进程（全自动）

可选（调试）：
  python -m sync init    # 仅初始化并提交一次
  python -m sync status  # 打印状态 JSON
  python -m sync serve   # 启动最小 Web UI
"""
