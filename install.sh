#!/usr/bin/env bash
# ClawNook — One-command installer
# Usage: curl -fsSL https://raw.githubusercontent.com/cintia09/clawnook/main/install.sh | bash
set -euo pipefail

# ── i18n: detect system language ──
_LANG="en"
case "${LANG:-}${LC_ALL:-}${LANGUAGE:-}" in zh*) _LANG="zh" ;; esac
_m() { if [ "$_LANG" = "zh" ]; then echo "$1"; else echo "$2"; fi; }

INSTALLER_COMMIT="${INSTALLER_COMMIT:-}"

fetch_remote_installer(){
  local url="$1"
  local out_file="$2"
  curl -fsSL --connect-timeout 8 --max-time 25 --retry 2 --retry-delay 1 "$url" -o "$out_file"
}

fetch_imageonly_script(){
  local out_file="$1"
  local api_url="https://api.github.com/repos/cintia09/clawnook/commits/main"
  local sha=""

  if [ -n "$INSTALLER_COMMIT" ]; then
    _m "[INFO] 正在获取安装脚本（固定提交 ${INSTALLER_COMMIT}）..." "[INFO] Fetching installer (pinned commit ${INSTALLER_COMMIT})..." >&2
    if fetch_remote_installer "https://raw.githubusercontent.com/cintia09/clawnook/${INSTALLER_COMMIT}/install-imageonly.sh" "$out_file"; then
      return 0
    fi
  fi

  _m "[INFO] 正在查询最新提交..." "[INFO] Querying latest commit..." >&2
  sha="$(curl -fsSL --connect-timeout 8 --max-time 15 "$api_url" 2>/dev/null | awk -F'"' '/"sha"/ {print $4; exit}' || true)"
  if [ -n "$sha" ]; then
    _m "[INFO] 正在获取安装脚本（提交 ${sha}）..." "[INFO] Fetching installer (commit ${sha})..." >&2
    if fetch_remote_installer "https://raw.githubusercontent.com/cintia09/clawnook/${sha}/install-imageonly.sh" "$out_file"; then
      return 0
    fi
  fi

  _m "[INFO] 回退获取 main 分支安装脚本..." "[INFO] Falling back to main branch installer..." >&2
  fetch_remote_installer "https://raw.githubusercontent.com/cintia09/clawnook/main/install-imageonly.sh?ts=$(date +%s)" "$out_file"
}

run_imageonly_installer(){
  local target_dir tmp_root tmp_script
  target_dir="${TARGET_DIR:-$(pwd)}"

  tmp_root="${TMPDIR:-/tmp}"
  tmp_root="${tmp_root%/}"
  tmp_script="$(mktemp "${tmp_root}/openclaw-imageonly.XXXXXX")"
  if fetch_imageonly_script "$tmp_script"; then
    chmod +x "$tmp_script"
    if [ -r /dev/tty ] && [ -w /dev/tty ] && [ ! -t 0 ]; then
      _m "⚡ 检测到 curl|bash，切换为交互向导（通过 /dev/tty）..." "⚡ Detected curl|bash, switching to interactive wizard (via /dev/tty)..."
      exec env TARGET_DIR="$target_dir" FORCE_TTY_INTERACTIVE=1 bash "$tmp_script"
    fi
    exec env TARGET_DIR="$target_dir" bash "$tmp_script"
  fi

  if [ -f "$target_dir/install-imageonly.sh" ]; then
    _m "⚠️ 远端安装脚本下载失败，回退使用当前目录 install-imageonly.sh" "⚠️ Remote installer download failed, falling back to local install-imageonly.sh" >&2
    chmod +x "$target_dir/install-imageonly.sh" || true
    exec env TARGET_DIR="$target_dir" bash "$target_dir/install-imageonly.sh"
  fi

  if [ -f "$target_dir/clawnook/install-imageonly.sh" ]; then
    _m "⚠️ 远端安装脚本下载失败，回退使用本地仓库 clawnook/install-imageonly.sh" "⚠️ Remote installer download failed, falling back to local repo clawnook/install-imageonly.sh" >&2
    chmod +x "$target_dir/clawnook/install-imageonly.sh" || true
    exec env TARGET_DIR="$target_dir" bash "$target_dir/clawnook/install-imageonly.sh"
  fi

  _m "⚠️ 无法下载 ImageOnly 安装脚本，请稍后重试。" "⚠️ Failed to download ImageOnly installer, please try again later." >&2
  exit 1
}

echo "🐾 ClawNook Installer"
echo "========================="
_m "ImageOnly 是当前唯一安装路径。" "ImageOnly is the only installation method."
echo ""

run_imageonly_installer
