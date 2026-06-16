#!/usr/bin/env bash
# DEV-ONLY：热重载版【真实 app】（真账号登录 + 热重载）。
# flutter run 跑真实入口 lib/main.dart（真实 dart-define / 真实 API），渲染到 Xvfb :99，
# x11vnc + noVNC 推到浏览器。改完 UI → tool/desktop_realapp_reload.sh（热重载，秒刷新）。
#
# 与 desktop_realapp_vnc.sh（跑预编译产物、无热重载）的区别：本脚本用 flutter run，支持热重载。
# 与 desktop_preview_run.sh（mock 预览）的区别：本脚本跑真实入口 + 真实 dart-define，可真账号登录。
set -u

DISPLAY_NUM=99
WIN_W="${WIN_W:-1100}"
WIN_H="${WIN_H:-700}"
SCREEN="${WIN_W}x${WIN_H}x24"
VNC_PORT=5900
WEB_PORT=6080
VNC_PASS="${VNC_PASS:-88888888}"
PIDFILE=/tmp/flutter_realapp.pid
PREFS="$HOME/.local/share/com.follow.clash/shared_preferences.json"

cd "$(dirname "$0")/.." || exit 2

# 1. 把窗口初始尺寸写进真实 app 配置（避免动态 resize 黑屏；本机 Xvfb 软件 GL 限制）。
if [ -f "$PREFS" ]; then
  python3 - "$PREFS" "$WIN_W" "$WIN_H" <<'PY'
import json,sys
p,w,h=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
d=json.load(open(p)); cfg=json.loads(d['flutter.config'])
cfg['windowProps']={'width':w,'height':h,'top':None,'left':None}
d['flutter.config']=json.dumps(cfg,ensure_ascii=False)
json.dump(d,open(p,'w'),ensure_ascii=False)
print('[realrun] windowProps =', cfg['windowProps'])
PY
fi

# 2. 确保 Xvfb 在跑（尺寸贴合窗口，noVNC 无黑边）。
if ! pgrep -f "Xvfb :$DISPLAY_NUM" >/dev/null; then
  echo "[realrun] 启动 Xvfb :$DISPLAY_NUM ($SCREEN)…"
  setsid Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" -ac >/tmp/xvfb.log 2>&1 &
  sleep 2
fi
export DISPLAY=":$DISPLAY_NUM"
export NO_AT_BRIDGE=1
export GTK_A11Y=none

# 3. 确保 x11vnc 在跑。
if ! pgrep -f "x11vnc.*:$DISPLAY_NUM" >/dev/null; then
  mkdir -p "$HOME/.vnc"
  x11vnc -storepasswd "$VNC_PASS" "$HOME/.vnc/preview_passwd" >/dev/null 2>&1
  echo "[realrun] 启动 x11vnc（密码 $VNC_PASS）…"
  setsid x11vnc -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" -rfbauth "$HOME/.vnc/preview_passwd" \
    -forever -shared -noxdamage -wait 20 >/tmp/x11vnc.log 2>&1 &
  sleep 2
fi

# 4. 确保 noVNC/websockify 在跑。
if ! pgrep -f "websockify.*$WEB_PORT" >/dev/null; then
  echo "[realrun] 启动 noVNC（web 端口 $WEB_PORT）…"
  setsid websockify --web=/usr/share/novnc "$WEB_PORT" "localhost:$VNC_PORT" >/tmp/websockify.log 2>&1 &
  sleep 2
fi

# 5. 杀掉旧 flutter run / app，启动新的 flutter run（真实入口 + 真实 dart-define + 热重载）。
echo "[realrun] 停止旧 flutter run / app…"
[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
pkill -f "flutter_tools.*run" 2>/dev/null
pkill -f "bundle/FlClash" 2>/dev/null
sleep 2

echo "[realrun] 启动 flutter run（真实 app，热重载模式，首次编译约 60-120s）…"
setsid flutter run -d linux -t lib/main.dart --pid-file="$PIDFILE" \
  --dart-define-from-file=flavor_defines.json \
  --dart-define=XB_FORM_A=true \
  --dart-define=XB_PRODUCT_VERSION=0.0.1 \
  --dart-define=XB_BUILD_TAG="$(date +%Y%m%d%H%M)" \
  --dart-define=XB_BUILD_NUMBER=1 \
  >/tmp/flutter_realapp_run.log 2>&1 &

# 6. 后台守候：窗口出现后移到 0,0 填满屏（move 非 resize，安全）。
(
  for _ in $(seq 1 120); do
    WID=$(DISPLAY=":$DISPLAY_NUM" xdotool search --name "FlClash" 2>/dev/null | head -1)
    if [ -n "$WID" ]; then
      sleep 2
      DISPLAY=":$DISPLAY_NUM" xdotool windowmove "$WID" 0 0 2>/dev/null
      break
    fi
    sleep 2
  done
) &

echo "[realrun] 编译中… 日志：tail -f /tmp/flutter_realapp_run.log"
echo "[realrun] ====> 浏览器： http://<服务器IP>:$WEB_PORT/vnc.html?resize=scale&autoconnect=1  （密码：$VNC_PASS）"
echo "[realrun] 热重载： tool/desktop_realapp_reload.sh    热重启： tool/desktop_realapp_reload.sh -R"
