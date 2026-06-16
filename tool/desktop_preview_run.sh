#!/usr/bin/env bash
# DEV-ONLY：热重载版桌面预览。flutter run（GTK Linux）跑在 Xvfb 上，x11vnc + noVNC 推到浏览器。
# 改完 UI 代码 → tool/desktop_preview_reload.sh（热重载）/ desktop_preview_reload.sh -R（热重启）。
set -u

DISPLAY_NUM=99
SCREEN="1920x1080x24"
VNC_PORT=5900
WEB_PORT=6080
VNC_PASS="${VNC_PASS:-88888888}"
PIDFILE=/tmp/flutter_preview.pid
TARGET=lib/xboard/dev/desktop_preview_main.dart

cd "$(dirname "$0")/.." || exit 2

# 1. 确保 Xvfb 在跑
if ! pgrep -f "Xvfb :$DISPLAY_NUM" >/dev/null; then
  echo "[preview] 启动 Xvfb :$DISPLAY_NUM ($SCREEN)…"
  setsid Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" -ac >/tmp/xvfb.log 2>&1 &
  sleep 2
fi
export DISPLAY=":$DISPLAY_NUM"
export NO_AT_BRIDGE=1
export GTK_A11Y=none

# 2. 确保 x11vnc 在跑
if ! pgrep -f "x11vnc.*:$DISPLAY_NUM" >/dev/null; then
  mkdir -p "$HOME/.vnc"
  x11vnc -storepasswd "$VNC_PASS" "$HOME/.vnc/preview_passwd" >/dev/null 2>&1
  echo "[preview] 启动 x11vnc…"
  setsid x11vnc -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" -rfbauth "$HOME/.vnc/preview_passwd" \
    -forever -shared -noxdamage -wait 20 >/tmp/x11vnc.log 2>&1 &
  sleep 2
fi

# 3. 确保 noVNC/websockify 在跑
if ! pgrep -f "websockify.*$WEB_PORT" >/dev/null; then
  echo "[preview] 启动 noVNC（web 端口 $WEB_PORT）…"
  setsid websockify --web=/usr/share/novnc "$WEB_PORT" "localhost:$VNC_PORT" >/tmp/websockify.log 2>&1 &
  sleep 2
fi

# 4. 杀掉旧的 flutter run / app，启动新的 flutter run（热重载）
echo "[preview] 停止旧 flutter run / app…"
[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
pkill -f "flutter_tools.*run" 2>/dev/null
pkill -f "bundle/FlClash" 2>/dev/null
sleep 2

echo "[preview] 启动 flutter run（热重载模式）…"
setsid flutter run -d linux -t "$TARGET" --pid-file="$PIDFILE" \
  >/tmp/flutter_run.log 2>&1 &
echo "[preview] flutter 正在编译启动（首次约 30-60s）。日志：/tmp/flutter_run.log"
echo "[preview] ====> 浏览器： http://<服务器IP>:$WEB_PORT/vnc.html  （密码：$VNC_PASS）"
echo "[preview] 热重载： tool/desktop_preview_reload.sh   热重启： tool/desktop_preview_reload.sh -R"
