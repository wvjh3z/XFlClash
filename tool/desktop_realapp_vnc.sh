#!/usr/bin/env bash
# DEV-ONLY：在 headless Linux 上把【真实 app】（真账号登录，可不连 VPN）渲染到浏览器。
# 与 desktop_preview_serve.sh（mock 预览）区别：这里跑的是真实构建产物 + 真实 API。
#
# 关键约束（实测）：本机 Xvfb 软件 GL 不能【动态 resize】窗口到 >680（必黑屏），
# 但【初始即大尺寸】创建窗口可正常渲染。所以：
#   1) 把窗口初始尺寸写进 shared_preferences（windowProps），让 app 启动即大窗；
#   2) Xvfb 屏幕设成与窗口同尺寸，窗口移到 0,0 填满，noVNC 里无黑边；
#   3) 绝不用 xdotool 动态 resize 窗口。
set -u

DISPLAY_NUM=99
WIN_W="${WIN_W:-1100}"
WIN_H="${WIN_H:-700}"
SCREEN="${WIN_W}x${WIN_H}x24"
VNC_PORT=5900
WEB_PORT=6080
VNC_PASS="${VNC_PASS:-88888888}"
APP="build/linux/x64/debug/bundle/FlClash"
PREFS="$HOME/.local/share/com.follow.clash/shared_preferences.json"

cd "$(dirname "$0")/.." || exit 2

if [ ! -x "$APP" ]; then
  echo "[realvnc] ✗ 找不到产物 $APP"
  echo "  先构建真实 app：flutter build linux --debug --dart-define-from-file=flavor_defines.json \\"
  echo "    --dart-define=XB_FORM_A=true --dart-define=XB_PRODUCT_VERSION=0.0.1 \\"
  echo "    --dart-define=XB_BUILD_TAG=\$(date +%Y%m%d%H%M) --dart-define=XB_BUILD_NUMBER=1"
  exit 2
fi

echo "[realvnc] 清理旧进程…"
pkill -f "bundle/FlClash" 2>/dev/null
pkill -f "websockify.*$WEB_PORT" 2>/dev/null
pkill -f "x11vnc.*:$DISPLAY_NUM" 2>/dev/null
pkill -f "Xvfb :$DISPLAY_NUM" 2>/dev/null
sleep 2

# 把窗口初始尺寸写进真实 app 配置（windowProps），避免动态 resize 黑屏。
if [ -f "$PREFS" ]; then
  echo "[realvnc] 写入初始窗口尺寸 ${WIN_W}x${WIN_H} 到 windowProps…"
  python3 - "$PREFS" "$WIN_W" "$WIN_H" <<'PY'
import json,sys
p,w,h=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
d=json.load(open(p))
cfg=json.loads(d['flutter.config'])
cfg['windowProps']={'width':w,'height':h,'top':None,'left':None}
d['flutter.config']=json.dumps(cfg,ensure_ascii=False)
json.dump(d,open(p,'w'),ensure_ascii=False)
print('  windowProps =', cfg['windowProps'])
PY
else
  echo "[realvnc] ⚠ 未找到 $PREFS（app 首次运行后会生成）；将用默认 680x580 启动。"
fi

echo "[realvnc] 启动 Xvfb :$DISPLAY_NUM ($SCREEN)…"
setsid Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" -ac >/tmp/xvfb.log 2>&1 &
sleep 2

export DISPLAY=":$DISPLAY_NUM"
export NO_AT_BRIDGE=1
export GTK_A11Y=none

mkdir -p "$HOME/.vnc"
x11vnc -storepasswd "$VNC_PASS" "$HOME/.vnc/preview_passwd" >/dev/null 2>&1
echo "[realvnc] 启动 x11vnc（端口 $VNC_PORT，密码 $VNC_PASS）…"
setsid x11vnc -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" -rfbauth "$HOME/.vnc/preview_passwd" \
  -forever -shared -noxdamage -wait 20 >/tmp/x11vnc.log 2>&1 &
sleep 2

echo "[realvnc] 启动 noVNC（web 端口 $WEB_PORT）…"
setsid websockify --web=/usr/share/novnc "$WEB_PORT" "localhost:$VNC_PORT" >/tmp/websockify.log 2>&1 &
sleep 2

echo "[realvnc] 启动真实 app…"
setsid "$APP" >/tmp/realapp.log 2>&1 &
sleep 14

# 窗口与屏同尺寸，居中可能溢出，强制移到 0,0 填满（move 不是 resize，安全）。
WID=$(xdotool search --name "FlClash" 2>/dev/null | head -1)
if [ -n "$WID" ]; then
  xdotool windowmove "$WID" 0 0 2>/dev/null
fi
sleep 1
echo "[realvnc] 窗口状态："
xwininfo -root -tree 2>/dev/null | grep -i flclash | head -2

echo "[realvnc] ✓ 就绪。浏览器打开："
echo "  http://<服务器IP>:$WEB_PORT/vnc.html?resize=scale&autoconnect=1   （密码：$VNC_PASS）"
echo "  日志：/tmp/realapp.log    停止：tool/desktop_preview_stop.sh"
