#!/usr/bin/env bash
###############################################################################
# XFlClash hooks setup
#
# 一次性配置 git 把 hooks 路径指向 .githooks/(默认 .git/hooks/ 不进 git).
# 让 .githooks/commit-msg 对所有 clone 仓库的开发者生效.
#
# 用法(在 XFlClash 仓库根目录执行):
#     bash tool/setup-hooks.sh
#
# 关联: conventions §2.4 / spec xboard-mvp-form-b W0.6 / README 首次签出步骤
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "[setup-hooks] ✗ 当前目录不是 git 仓库: ${REPO_ROOT}" >&2
    exit 1
fi

HOOKS_DIR="${REPO_ROOT}/.githooks"
if [[ ! -d "${HOOKS_DIR}" ]]; then
    echo "[setup-hooks] ✗ 找不到 .githooks/ 目录: ${HOOKS_DIR}" >&2
    echo "                请先在 XFlClash 仓库根目录跑此脚本." >&2
    exit 1
fi

echo "[setup-hooks] chmod +x .githooks/*"
chmod +x "${HOOKS_DIR}"/* || true

echo "[setup-hooks] git config core.hooksPath .githooks"
git config core.hooksPath .githooks

echo ""
echo "[setup-hooks] ✓ 配置完成. 已激活以下 hooks:"
ls -la "${HOOKS_DIR}/"

echo ""
echo "[setup-hooks] 验证 commit-msg 拦截:"
echo "    git commit -m 'invalid message'       # 应被拒"
echo "    git commit -m '[xfork] chore: test'   # 应通过"
