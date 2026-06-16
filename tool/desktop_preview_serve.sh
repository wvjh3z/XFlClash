#!/usr/bin/env bash
# DEV-ONLY：在 headless Linux 上把桌面预览 app 渲染到浏览器（Xvfb + x11vnc + noVNC）。
# 不进正常构建链，仅手动跑。依赖：xvfb / x11vnc / websockify / novnc + 已构建的 bundle。
set -u

DISPLAY_NUM=99
SCREEN="1920x1080x24"
VNC_PORT=5900
WEB_PORT=6080
VNC_PASS="${VNC_PASS:-88888888}"
APP="build/linux/x64/debug/bundle/FlClash"

cd "$(dirname "$0")/.." || exit 2

echo "[preview] 清理旧进程…"
pkill -f "Xvfb :$DISPLAY_NUM" 2>/dev/null
pkill -f "x11vnc.*:$DISPLAY_NUM" 2>/dev/null
pkill -f "websockify.*$WEB_PORT" 2>/dev/null
pkill -f "bundle/FlClash" 2>/dev/null
sleep 1

if [ ! -x "$APP" ]; then
  echo "[preview] ✗ 找不到产物 $APP，请先 flutter build linux --debug -t lib/xboard/dev/desktop_preview_main.dart"
  exit 2
fi

echo "[preview] 启动 Xvfb :$DISPLAY_NUM ($SCREEN)…"
setsid Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" -ac >/tmp/xvfb.log 2>&1 &
sleep 2

export DISPLAY=":$DISPLAY_NUM"
export NO_AT_BRIDGE=1
export GTK_A11Y=none

echo "[preview] 启动预览 app…"
setsid "$APP" >/tmp/previewapp.log 2>&1 &
sleep 4

mkdir -p "$HOME/.vnc"
x11vnc -storepasswd "$VNC_PASS" "$HOME/.vnc/preview_passwd" >/dev/null 2>&1

echo "[preview] 启动 x11vnc（端口 $VNC_PORT，带密码）…"
setsid x11vnc -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" -rfbauth "$HOME/.vnc/preview_passwd" \
  -forever -shared -noxdamage -wait 20 >/tmp/x11vnc.log 2>&1 &
sleep 2

echo "[preview] 启动 noVNC（web 端口 $WEB_PORT）…"
echo "[preview] ====> 浏览器打开： http://<服务器IP>:$WEB_PORT/vnc.html  （VNC 密码：$VNC_PASS）"
setsid websockify --web=/usr/share/novnc "$WEB_PORT" "localhost:$VNC_PORT" >/tmp/websockify.log 2>&1 &
sleep 2
echo "[preview] ✓ 全部启动（已脱离终端，守护运行）。停止用： tool/desktop_preview_stop.sh"
