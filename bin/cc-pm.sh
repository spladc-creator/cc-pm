#!/bin/bash
# cc-pm.sh — Claude Code 包管理器
# 管理跨项目的 Agent 和 Skill 配置共享
# 用法: ./cc-pm.sh <command> [args...] [--type agent|skill]

set -euo pipefail
shopt -s nullglob

# 从脚本位置推导路径（全部解析为绝对路径）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================== 路径检测（三级策略） ====================

# Registry：agents 和 skills 的存储目录
detect_registry() {
  # 1. 环境变量优先
  if [[ -n "${CC_PM_REGISTRY:-}" ]] && [[ -d "$CC_PM_REGISTRY" ]]; then
    cd "$CC_PM_REGISTRY" && pwd && return
  fi
  # 2. 脚本旁的 prompts/ 目录（兼容现有布局）
  if [[ -d "$SCRIPT_DIR/../prompts" ]]; then
    cd "$SCRIPT_DIR/../prompts" && pwd && return
  fi
  # 3. 默认：~/.cc-pm/registry/
  local default="$HOME/.cc-pm/registry"
  mkdir -p "$default/agents" "$default/skills"
  echo "$default"
}

# BASE_DIR：项目所在的根目录
detect_base() {
  # 1. 环境变量优先
  if [[ -n "${CC_PM_BASE:-}" ]] && [[ -d "$CC_PM_BASE" ]]; then
    cd "$CC_PM_BASE" && pwd && return
  fi
  # 2. 向上查找 .cc-pm-base 标记文件
  local dir="$(pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.cc-pm-base" ]]; then echo "$dir"; return; fi
    dir="$(dirname "$dir")"
  done
  # 3. 回退：脚本的上两级目录（兼容现有布局）
  cd "$SCRIPT_DIR/../.." && pwd
}

# 动态计算相对路径（用于 symlink）
compute_relpath() {
  python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$1" "$2"
}

BASE_DIR="$(detect_base)"
PROMPTS_DIR="$(detect_registry)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[info]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ==================== 类型配置 ====================

# 解析 --type 参数，默认 agent
parse_type() {
  local type="agent"
  for arg in "$@"; do
    case "$arg" in
      --type=*) type="${arg#--type=}" ;;
      --type)   ;; # 下一个参数是值，在 parse_args 中处理
      agent|skill) type="$arg" ;;
    esac
  done
  # 也检查 --type skill 这种形式
  local i=0
  for arg in "$@"; do
    i=$((i + 1))
    if [[ "$arg" == "--type" ]] && [[ $i -lt $# ]]; then
      shift $i
      type="$1"
      break
    fi
  done
  echo "$type"
}

# 根据类型设置变量
# 输出: registry_path target_subdir item_type
configure_type() {
  local type="$1"
  case "$type" in
    agent)
      echo "$PROMPTS_DIR/agents"
      echo "agents"
      echo "file"
      ;;
    skill)
      echo "$PROMPTS_DIR/skills"
      echo "skills"
      echo "dir"
      ;;
    *)
      error "未知类型: $type（支持: agent, skill）"
      ;;
  esac
}

# 解析名称（加后缀）
resolve_name() {
  local name="$1"
  local item_type="$2"
  case "$item_type" in
    file) # agent: 加 .md
      if [[ "$name" == *.md ]]; then echo "$name"; else echo "${name}.md"; fi ;;
    dir)  # skill: 加 .skill
      if [[ "$name" == *.skill ]]; then echo "$name"; else echo "${name}.skill"; fi ;;
  esac
}

# 获取项目的 .claude/<subdir> 目录
target_dir() {
  local project="$1"
  local subdir="$2"
  local dir="$BASE_DIR/$project/.claude/$subdir"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
  echo "$dir"
}

# ==================== install ====================
cmd_install() {
  local type
  type="$(parse_type "$@")"
  # 过滤掉 --type 参数，取 name 和 project
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  [[ ${#args[@]} -lt 2 ]] && { echo "用法: $0 install <name> <project> [--type agent|skill]"; exit 1; }
  local name="${args[0]}"
  local project="${args[1]}"

  local conf
  conf="$(configure_type "$type")"
  local registry target_subdir item_type
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"
  item_type="$(echo "$conf" | sed -n '3p')"

  local item_name
  item_name="$(resolve_name "$name" "$item_type")"
  local source="$registry/$item_name"
  local target
  target="$(target_dir "$project" "$target_subdir")/$item_name"

  # 检查源
  case "$item_type" in
    file) [[ -f "$source" ]] || error "registry 中不存在: $item_name" ;;
    dir)  [[ -d "$source" ]] || error "registry 中不存在: $item_name" ;;
  esac

  # 检查项目
  [[ -d "$BASE_DIR/$project" ]] || error "项目不存在: $project"

  # 检查是否已安装
  if [[ -e "$target" ]] || [[ -L "$target" ]]; then
    if [[ -L "$target" ]]; then
      local current
      current="$(readlink "$target")"
      if [[ "$current" == *"$item_name" ]]; then
        warn "$item_name 已安装在 $project 中"
        return 0
      fi
    fi
    error "$target 已存在（非本工具管理的链接），请手动处理"
  fi

  # 动态计算相对路径
  local rel
  rel="$(compute_relpath "$source" "$(dirname "$target")")"
  ln -s "$rel" "$target"
  info "已安装 ${type}: $item_name → $project"
}

# ==================== uninstall ====================
cmd_uninstall() {
  local type
  type="$(parse_type "$@")"
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  [[ ${#args[@]} -lt 2 ]] && { echo "用法: $0 uninstall <name> <project> [--type agent|skill]"; exit 1; }
  local name="${args[0]}"
  local project="${args[1]}"

  local conf
  conf="$(configure_type "$type")"
  local registry target_subdir item_type
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"
  item_type="$(echo "$conf" | sed -n '3p')"

  local item_name
  item_name="$(resolve_name "$name" "$item_type")"
  local target
  target="$(target_dir "$project" "$target_subdir")/$item_name"

  [[ -L "$target" ]] || {
    if [[ -e "$target" ]]; then
      error "$item_name 是物理文件/目录，不是软链接，请手动处理"
    else
      error "$item_name 未安装在 $project 中"
    fi
  }

  rm "$target"
  info "已从 $project 卸载 $item_name"

  # 检查是否还有其他项目链接到同一个源
  local other_links
  other_links="$(find "$BASE_DIR" -path "*/node_modules" -prune -o -path "*/.claude/${target_subdir}/${item_name}" -type l -print 2>/dev/null)"

  if [[ -z "$other_links" ]]; then
    local source="$registry/$item_name"
    case "$item_type" in
      file) rm "$source" ;;
      dir)  rm -rf "$source" ;;
    esac
    info "无其他项目依赖，已删除源: ${registry_rel}/${item_name}"
  else
    local count
    count="$(echo "$other_links" | wc -l | tr -d ' ')"
    info "仍有 $count 个项目依赖此 ${type}，源文件保留"
  fi
}

# ==================== list ====================
cmd_list() {
  local type
  type="$(parse_type "$@")"
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  local project="${args[0]:-}"

  local conf
  conf="$(configure_type "$type")"
  local registry target_subdir
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"

  if [[ -z "$project" ]]; then
    echo "Registry 中的 ${type}:"
    echo "-------------------------"
    case "$type" in
      agent)
        for f in "$registry"/*.md; do
          [[ -f "$f" ]] || continue
          local n
          n="$(basename "$f")"
          local desc
          desc="$(head -5 "$f" | grep '^description:' | sed 's/description: *//' | cut -c1-50)" || true
          printf "  %-35s %s\n" "$n" "${desc:-无描述}"
        done
        ;;
      skill)
        for d in "$registry"/*.skill; do
          [[ -d "$d" ]] || continue
          local n
          n="$(basename "$d")"
          local desc=""
          if [[ -f "$d/skill.md" ]]; then
            desc="$(head -5 "$d/skill.md" | grep '^description:' | sed 's/description: *//' | cut -c1-50)" || true
          fi
          printf "  %-35s %s\n" "$n" "${desc:-无描述}"
        done
        ;;
    esac
    return 0
  fi

  local agents_path="$BASE_DIR/$project/.claude/$target_subdir"
  if [[ ! -d "$agents_path" ]]; then
    warn "$project 下没有 .claude/$target_subdir 目录"
    return 0
  fi

  echo "$project 已安装的 ${type}:"
  echo "-------------------------"
  for f in "$agents_path"/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    local n
    n="$(basename "$f")"
    if [[ -L "$f" ]]; then
      if [[ -e "$f" ]]; then
        printf "  %-35s → %s\n" "$n" "共享模板（有效）"
      else
        printf "  %-35s → %s [失效]\n" "$n" "$(readlink "$f")"
      fi
    else
      printf "  %-35s %s\n" "$n" "本地物理文件/目录"
    fi
  done
}

# ==================== doctor ====================
cmd_doctor() {
  local broken=0
  local total=0

  echo "全局健康检查:"
  echo "-------------------------"

  # 扫描 agents 和 skills 的软链接
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    total=$((total + 1))
    if [[ ! -e "$link" ]]; then
      echo -e "  ${RED}失效${NC}: $link → $(readlink "$link")"
      broken=$((broken + 1))
    fi
  done < <(find "$BASE_DIR" -path "*/node_modules" -prune -o \( -path "*/.claude/agents/*.md" -o -path "*/.claude/skills/*.skill" \) -type l -print 2>/dev/null)

  if [[ $total -eq 0 ]]; then
    info "未发现任何软链接"
  elif [[ $broken -eq 0 ]]; then
    info "全部 $total 个软链接正常"
  else
    echo "-------------------------"
    error "发现 $broken/$total 个失效链接"
  fi
}

# ==================== deps ====================
cmd_deps() {
  local type
  type="$(parse_type "$@")"
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  [[ ${#args[@]} -lt 1 ]] && { echo "用法: $0 deps <name> [--type agent|skill]"; exit 1; }
  local name="${args[0]}"

  local conf
  conf="$(configure_type "$type")"
  local target_subdir item_type
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"
  item_type="$(echo "$conf" | sed -n '3p')"

  local item_name
  item_name="$(resolve_name "$name" "$item_type")"

  echo "依赖 $item_name 的项目:"
  echo "-------------------------"

  local found=0
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    local project
    project="$(echo "$link" | sed "s|$BASE_DIR/||" | cut -d'/' -f1)"
    local status="有效"
    [[ -e "$link" ]] || status="失效"
    printf "  %-25s %s\n" "$project" "$status"
    found=$((found + 1))
  done < <(find "$BASE_DIR" -path "*/node_modules" -prune -o -path "*/.claude/${target_subdir}/${item_name}" -type l -print 2>/dev/null)

  if [[ $found -eq 0 ]]; then
    warn "无项目依赖此 ${type}"
  fi
}

# ==================== search ====================
cmd_search() {
  local type
  type="$(parse_type "$@")"
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  [[ ${#args[@]} -lt 1 ]] && { echo "用法: $0 search <keyword> [--type agent|skill]"; exit 1; }
  local keyword="${args[0]}"

  local conf
  conf="$(configure_type "$type")"
  local registry
  registry="$(echo "$conf" | head -1)"

  echo "搜索 '$keyword' (${type}):"
  echo "-------------------------"

  local found=0
  case "$type" in
    agent)
      for f in "$registry"/*.md; do
        [[ -f "$f" ]] || continue
        local n
        n="$(basename "$f")"
        if echo "$n" | grep -qi "$keyword" || { grep -qi "$keyword" "$f" 2>/dev/null && true; }; then
          local desc
          desc="$(head -5 "$f" | grep '^description:' | sed 's/description: *//' | cut -c1-50)" || true
          printf "  %-35s %s\n" "$n" "${desc:-无描述}"
          found=$((found + 1))
        fi
      done
      ;;
    skill)
      for d in "$registry"/*.skill; do
        [[ -d "$d" ]] || continue
        local n
        n="$(basename "$d")"
        local content="$d/skill.md"
        if echo "$n" | grep -qi "$keyword" || { [[ -f "$content" ]] && { grep -qi "$keyword" "$content" 2>/dev/null || false; }; }; then
          local desc=""
          if [[ -f "$content" ]]; then
            desc="$(head -5 "$content" | grep '^description:' | sed 's/description: *//' | cut -c1-50)" || true
          fi
          printf "  %-35s %s\n" "$n" "${desc:-无描述}"
          found=$((found + 1))
        fi
      done
      ;;
  esac

  if [[ $found -eq 0 ]]; then
    warn "未找到匹配的 ${type}"
  fi
}

# ==================== usage ====================
usage() {
  cat <<EOF
Claude Code 包管理器 — 管理跨项目的 Agent 和 Skill 配置

用法: $(basename "$0") <command> [args...] [--type agent|skill]

命令:
  install   <name> <project>       安装到项目（创建软链接）
  uninstall <name> <project>       卸载（最后链接时同时删源文件）
  list      [project]              列出已安装 / registry 内容
  doctor                          全局健康检查（扫描 agents + skills）
  deps      <name>                 查看依赖关系
  search    <keyword>              搜索 registry

类型（--type，默认 agent）:
  agent   管理 .claude/agents/ 中的 agent 配置（文件级链接）
  skill   管理 .claude/skills/ 中的 skill 配置（目录级链接）

配置（三级检测，优先级从高到低）:
  CC_PM_BASE       项目根目录（默认: 脚本上两级 / .cc-pm-base 标记文件）
  CC_PM_REGISTRY   registry 路径（默认: 脚本旁 prompts/ 或 ~/.cc-pm/registry/）

示例:
  $(basename "$0") install deep-organizer 育儿与家庭互动
  $(basename "$0") install history-storytelling 育儿与家庭互动 --type skill
  $(basename "$0") list 女儿学习辅导 --type skill
  $(basename "$0") doctor
  $(basename "$0") deps report-generator

registry:
  agents: $PROMPTS_DIR/agents/
  skills: $PROMPTS_DIR/skills/
base:     $BASE_DIR
EOF
}

# ==================== main ====================
case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  list)      shift; cmd_list "$@" ;;
  doctor)    cmd_doctor ;;
  deps)      shift; cmd_deps "$@" ;;
  search)    shift; cmd_search "$@" ;;
  -h|--help|help) usage ;;
  *)         usage ;;
esac
