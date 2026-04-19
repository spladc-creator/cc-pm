#!/bin/bash
# cc-pm 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/<user>/cc-pm/main/bin/install.sh | bash
#       curl -fsSL ... | bash -s -- --base /path/to/monorepo
#       curl -fsSL ... | bash -s -- --dir ~/my-cc-pm
set -euo pipefail

# ==================== 配置 ====================
REPO_URL="https://github.com/spladc-creator/cc-pm.git"
INSTALL_DIR="${CC_PM_HOME:-$HOME/.cc-pm}"
BASE_DIR=""
PROFILE_FILES=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile")

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "${CYAN}[→]${NC} $*"; }

# ==================== 参数解析 ====================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)  INSTALL_DIR="$2"; shift 2 ;;
    --base) BASE_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ==================== 安装 ====================
step "安装目录: $INSTALL_DIR"

# Clone 或更新
if [[ -d "$INSTALL_DIR/.git" ]]; then
  step "检测到已有安装，更新中..."
  (cd "$INSTALL_DIR" && git pull --ff-only) || {
    warn "git pull 失败，保留现有版本"
  }
else
  if [[ -d "$INSTALL_DIR" ]]; then
    warn "$INSTALL_DIR 已存在且非 git 仓库，跳过 clone"
  else
    step "克隆仓库..."
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
fi

# 设置权限
chmod +x "$INSTALL_DIR/bin/cc-pm.sh" 2>/dev/null || true
info "cc-pm.sh 已就位"

# ==================== 环境变量 ====================
# 查找用户的 shell profile
find_profile() {
  for f in "${PROFILE_FILES[@]}"; do
    [[ -f "$f" ]] && echo "$f" && return
  done
  echo ""
}

# 检查某行是否已存在于 profile 中
profile_has() {
  local file="$1" pattern="$2"
  grep -qF "$pattern" "$file" 2>/dev/null
}

PROFILE="$(find_profile)"

if [[ -n "$PROFILE" ]]; then
  step "配置 $PROFILE"

  # PATH
  if ! profile_has "$PROFILE" 'cc-pm/bin'; then
    echo "" >> "$PROFILE"
    echo "# cc-pm: Claude Code 包管理器" >> "$PROFILE"
    echo "export PATH=\"$INSTALL_DIR/bin:\$PATH\"" >> "$PROFILE"
    info "PATH 已添加"
  else
    info "PATH 已存在，跳过"
  fi

  # CC_PM_REGISTRY
  if ! profile_has "$PROFILE" 'CC_PM_REGISTRY'; then
    echo "export CC_PM_REGISTRY=\"$INSTALL_DIR/prompts\"" >> "$PROFILE"
    info "CC_PM_REGISTRY 已设置"
  else
    info "CC_PM_REGISTRY 已存在，跳过"
  fi
else
  warn "未找到 shell profile 文件，请手动添加以下内容:"
  echo ""
  echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\""
  echo "  export CC_PM_REGISTRY=\"$INSTALL_DIR/prompts\""
fi

# CC_PM_BASE（如果通过 --base 指定）
if [[ -n "$BASE_DIR" ]] && [[ -d "$BASE_DIR" ]]; then
  if ! [[ -f "$BASE_DIR/.cc-pm-base" ]]; then
    touch "$BASE_DIR/.cc-pm-base"
    info ".cc-pm-base 标记文件已创建: $BASE_DIR"
  fi
fi

# ==================== 完成 ====================
echo ""
echo "=========================================="
info "安装完成！"
echo "=========================================="
echo ""
echo "接下来："
echo ""
echo "  1. 重新加载 shell："
echo "     source $PROFILE"
echo ""
echo "  2. 在你的 monorepo 根目录创建标记文件："
echo "     cd /path/to/your/monorepo"
echo "     touch .cc-pm-base"
echo ""
echo "  3. 开始使用："
echo "     cc-pm.sh list"
echo "     cc-pm.sh install <skill-name> <project> --type skill"
echo ""

if [[ -n "$BASE_DIR" ]]; then
  info "BASE_DIR 已标记: $BASE_DIR"
fi
