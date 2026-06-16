#!/usr/bin/env bash
# 触发【真实 app】热重载（默认 SIGUSR1=hot reload；加 -R 用 SIGUSR2=hot restart）。
# 配合 tool/desktop_realapp_run.sh 使用。
PIDFILE=/tmp/flutter_realapp.pid
SIG=USR1
LABEL="热重载 (hot reload)"
[ "${1:-}" = "-R" ] && { SIG=USR2; LABEL="热重启 (hot restart)"; }

if [ ! -f "$PIDFILE" ]; then
  echo "[reload] ✗ 找不到 $PIDFILE，flutter run 没在跑？先 tool/desktop_realapp_run.sh"
  exit 1
fi
PID="$(cat "$PIDFILE")"
if ! kill -0 "$PID" 2>/dev/null; then
  echo "[reload] ✗ 进程 $PID 不存在，flutter run 可能已退出。先 tool/desktop_realapp_run.sh"
  exit 1
fi
kill -"$SIG" "$PID" && echo "[reload] ✓ 已触发 $LABEL（pid=$PID）。约 1-3s 后 VNC 画面刷新。"
