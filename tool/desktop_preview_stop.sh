#!/usr/bin/env bash
# 停止桌面预览全栈（Xvfb + app + x11vnc + noVNC）。
echo "[preview] 停止 noVNC / x11vnc / app / Xvfb …"
pkill -f "websockify.*6080" 2>/dev/null
pkill -f "x11vnc.*:99" 2>/dev/null
pkill -f "bundle/FlClash" 2>/dev/null
pkill -f "Xvfb :99" 2>/dev/null
echo "[preview] 已停止。"
