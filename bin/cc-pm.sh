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

# ==================== 元数据解析 ====================

# 从文件的 YAML frontmatter 中提取指定字段
# 用法: parse_frontmatter <file> <field>
# 返回字段值（单行），多行字段返回第一行
parse_frontmatter() {
  local file="$1" field="$2"
  sed -n "/^---$/,/^---$/p" "$file" 2>/dev/null | grep "^${field}:" | head -1 | sed "s/^${field}: *//" | cut -c1-60
}

# 获取 agent/skill 的一行摘要
# 格式: name v版本 作者: xxx
meta_summary() {
  local file="$1"
  local name ver author desc
  name="$(parse_frontmatter "$file" "name")"
  ver="$(parse_frontmatter "$file" "version")"
  author="$(parse_frontmatter "$file" "author")"
  desc="$(parse_frontmatter "$file" "description")"
  # description 可能很长且含 \n，截取第一个实际句子
  desc="$(echo "$desc" | sed 's/\\n.*//' | cut -c1-40)"
  local parts=""
  [[ -n "$ver" ]] && parts="v${ver}"
  [[ -n "$author" ]] && parts="${parts:+$parts }by ${author}"
  [[ -n "$desc" ]] && parts="${parts:+$parts — }${desc}"
  echo "${parts}"
}

# ==================== 远程基础设施 ====================

REGISTRY_REPO_URL="https://github.com/spladc-creator/cc-pm-registry.git"
REGISTRY_RAW_BASE="https://raw.githubusercontent.com/spladc-creator/cc-pm-registry/main"
CACHE_DIR="${HOME}/.cc-pm/cache"
REGISTRY_REPO_DEFAULT="${HOME}/.cc-pm/registry-repo"

# 定位本地 registry-repo checkout
find_registry_repo() {
  if [[ -n "${CC_PM_REGISTRY_REPO:-}" ]] && [[ -d "$CC_PM_REGISTRY_REPO/.git" ]]; then
    echo "$CC_PM_REGISTRY_REPO"
    return
  fi
  if [[ -d "$REGISTRY_REPO_DEFAULT/.git" ]]; then
    echo "$REGISTRY_REPO_DEFAULT"
    return
  fi
  info "cloning registry repo..." >&2
  git clone --depth 1 "$REGISTRY_REPO_URL" "$REGISTRY_REPO_DEFAULT" 2>/dev/null
  echo "$REGISTRY_REPO_DEFAULT"
}

# 下载远程 index.json 到缓存（5 分钟 TTL）
fetch_remote_index() {
  mkdir -p "$CACHE_DIR"
  local cache_file="$CACHE_DIR/index.json"
  # TTL 检查（300 秒）
  if [[ -f "$cache_file" ]]; then
    local age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    if [[ $age -lt 300 ]]; then
      echo "$cache_file"
      return
    fi
  fi
  curl -fsSL "$REGISTRY_RAW_BASE/index.json" -o "$cache_file" 2>/dev/null || \
    error "failed to fetch remote index"
  echo "$cache_file"
}

# 计算文件 SHA-256
compute_checksum() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# 更新 index.json 中的包条目
update_index() {
  local index_file="$1"
  local pkg_name="$2"
  local pkg_type="$3"
  local version="$4"
  local author="$5"
  local description="$6"
  python3 -c "
import json, sys
with open('$index_file', 'r') as f:
    data = json.load(f)
ts = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
if '$pkg_name' not in data['packages']:
    data['packages']['$pkg_name'] = {'type': '$pkg_type', 'latest': '$version', 'versions': {}}
pkg = data['packages']['$pkg_name']
pkg['latest'] = '$version'
pkg['versions']['$version'] = {'author': '$author', 'description': '$description', 'published': ts}
data['updated'] = ts
with open('$index_file', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"
}

# 从 index.json 查询包信息
query_index() {
  local index_file="$1"
  local pkg_name="$2"
  local field="${3:-}"
  python3 -c "
import json, sys
with open('$index_file', 'r') as f:
    data = json.load(f)
pkg = data['packages'].get('$pkg_name')
if not pkg:
    sys.exit(1)
if '$field':
    print(pkg.get('$field', ''))
else:
    print(json.dumps(pkg))
"
}

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
# 输出: registry_path target_subdir internal_file
configure_type() {
  local type="$1"
  case "$type" in
    agent)
      echo "$PROMPTS_DIR/agents"
      echo "agents"
      echo "agent.md"
      ;;
    skill)
      echo "$PROMPTS_DIR/skills"
      echo "skills"
      echo "skill.md"
      ;;
    *)
      error "unknown type: $type (agent, skill)"
      ;;
  esac
}

# 解析包名（目录名，无后缀）
resolve_name() {
  local name="$1"
  # 去掉可能残留的后缀
  name="${name%.md}"
  name="${name%.skill}"
  echo "$name"
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

# ==================== version ====================

# 从名称中提取版本号（name@version → name + version）
parse_version() {
  local input="$1"
  if [[ "$input" == *@* ]]; then
    echo "${input%%@*}"  # name
    echo "${input##*@}"  # version
  else
    echo "$input"
    echo ""              # 无版本指定
  fi
}

# TODO(human): 实现版本解析策略
# 输入: registry_dir, item_name, requested_version, item_type
# 输出: 解析后的源文件路径（stdout）
# 当 requested_version 为空时返回最新版本
# 当 requested_version 非空时返回精确匹配
resolve_version() {
  local registry_dir="$1"
  local item_name="$2"
  local req_ver="$3"
  local internal_file="$4"
  local pkg_dir="$registry_dir/$item_name"
  local source="$pkg_dir/$internal_file"

  # 无版本请求，直接返回源路径
  if [[ -z "$req_ver" ]]; then
    echo "$source"
    return 0
  fi

  # 策略 B: frontmatter 校验
  local actual_ver
  actual_ver="$(parse_frontmatter "$source" "version")"

  if [[ -z "$actual_ver" ]]; then
    error "$item_name has no version field in frontmatter"
  fi

  if [[ "$actual_ver" != "$req_ver" ]]; then
    error "version mismatch: requested $req_ver, got $actual_ver ($item_name)"
  fi

  echo "$source"
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
  [[ ${#args[@]} -lt 2 ]] && { echo "用法: $0 install <name>[@version] <project> [--type agent|skill]"; exit 1; }
  local raw_name="${args[0]}"
  local project="${args[1]}"

  # 解析 name@version
  local name req_ver
  name="$(parse_version "$raw_name" | head -1)"
  req_ver="$(parse_version "$raw_name" | tail -1)"

  local conf
  conf="$(configure_type "$type")"
  local registry target_subdir internal_file
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"
  internal_file="$(echo "$conf" | sed -n '3p')"

  local item_name
  item_name="$(resolve_name "$name")"
  local source
  source="$(resolve_version "$registry" "$item_name" "$req_ver" "$internal_file")"
  # target: symlink 文件名保持 .md 后缀（Claude Code 加载 .claude/agents/*.md）
  local target_ext="$([[ "$type" == "agent" ]] && echo ".md" || echo "")"
  local target
  target="$(target_dir "$project" "$target_subdir")/${item_name}${target_ext}"

  # 检查源
  [[ -f "$source" ]] || error "registry 中不存在: $item_name (expected: $source)"

  # 检查项目
  [[ -d "$BASE_DIR/$project" ]] || error "项目不存在: $project"

  # 检查是否已安装
  if [[ -e "$target" ]] || [[ -L "$target" ]]; then
    if [[ -L "$target" ]]; then
      local current
      current="$(readlink "$target")"
      if [[ "$current" == *"$item_name"* ]]; then
        warn "$item_name already installed in $project"
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
  local registry target_subdir internal_file
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"
  internal_file="$(echo "$conf" | sed -n '3p')"

  local item_name
  item_name="$(resolve_name "$name")"
  local target_ext="$([[ "$type" == "agent" ]] && echo ".md" || echo "")"
  local target
  target="$(target_dir "$project" "$target_subdir")/${item_name}${target_ext}"

  [[ -L "$target" ]] || {
    if [[ -e "$target" ]]; then
      error "$item_name is a physical file, not a symlink"
    else
      error "$item_name not installed in $project"
    fi
  }

  rm "$target"
  info "uninstalled $item_name from $project"

  # 检查是否还有其他项目链接到同一个源
  local other_links
  other_links="$(find "$BASE_DIR" -path "*/node_modules" -prune -o -path "*/.claude/${target_subdir}/${item_name}*" -type l -print 2>/dev/null)"

  if [[ -z "$other_links" ]]; then
    local pkg_dir="$registry/$item_name"
    rm -rf "$pkg_dir"
    info "no other deps, removed source: $item_name"
  else
    local count
    count="$(echo "$other_links" | wc -l | tr -d ' ')"
    info "$count project(s) still depend on $item_name, source kept"
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

  local conf
  conf="$(configure_type "$type")"
  local registry target_subdir internal_file
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"
  internal_file="$(echo "$conf" | sed -n '3p')"

  if [[ -z "$project" ]]; then
    echo "Registry ${type}s:"
    echo "-------------------------"
    for d in "$registry"/*/; do
      [[ -d "$d" ]] || continue
      local pkg_file="$d${internal_file}"
      [[ -f "$pkg_file" ]] || continue
      local n
      n="$(basename "$d")"
      local summary
      summary="$(meta_summary "$pkg_file")"
      printf "  %-35s %s\n" "$n" "${summary:-no description}"
    done
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
  done < <(find "$BASE_DIR" -path "*/node_modules" -prune -o \( -path "*/.claude/agents/*.md" -o -path "*/.claude/skills/*" \) -type l -print 2>/dev/null)

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
  local target_subdir
  registry="$(echo "$conf" | head -1)"
  target_subdir="$(echo "$conf" | sed -n '2p')"

  local item_name
  item_name="$(resolve_name "$name")"

  echo "deps for $item_name:"
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
  done < <(find "$BASE_DIR" -path "*/node_modules" -prune -o -path "*/.claude/${target_subdir}/${item_name}*" -type l -print 2>/dev/null)

  if [[ $found -eq 0 ]]; then
    warn "no projects depend on $item_name"
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
  local registry internal_file
  registry="$(echo "$conf" | head -1)"
  internal_file="$(echo "$conf" | sed -n '3p')"

  echo "search '$keyword' (${type}):"
  echo "-------------------------"

  local found=0
  for d in "$registry"/*/; do
    [[ -d "$d" ]] || continue
    local pkg_file="$d${internal_file}"
    [[ -f "$pkg_file" ]] || continue
    local n
    n="$(basename "$d")"
    if echo "$n" | grep -qi "$keyword" || { grep -qi "$keyword" "$pkg_file" 2>/dev/null && true; }; then
      local summary
      summary="$(meta_summary "$pkg_file")"
      printf "  %-35s %s\n" "$n" "${summary:-no description}"
      found=$((found + 1))
    fi
  done

  if [[ $found -eq 0 ]]; then
    warn "no match for '$keyword'"
  fi
}

# ==================== usage ====================
usage() {
  cat <<EOF
Claude Code 包管理器 — 管理跨项目的 Agent 和 Skill 配置

用法: $(basename "$0") <command> [args...] [--type agent|skill]

命令:
  install        <name>[@version] <project>  安装到项目（支持版本指定）
  uninstall      <name> <project>            卸载
  list           [project]                   列出已安装 / registry 内容
  doctor                                    全局健康检查
  deps           <name>                      查看依赖关系
  search         <keyword>                   搜索本地 registry
  publish        <name> [--type agent|skill] 发布到远程 registry
  pull           <name>[@version]            从远程拉取到本地
  remote-search  <keyword>                   搜索远程 registry

类型（--type，默认 agent）:
  agent   管理 .claude/agents/ 中的 agent 配置（文件级链接）
  skill   管理 .claude/skills/ 中的 skill 配置（目录级链接）

配置（三级检测，优先级从高到低）:
  CC_PM_BASE       项目根目录（默认: 脚本上两级 / .cc-pm-base 标记文件）
  CC_PM_REGISTRY   registry 路径（默认: 脚本旁 prompts/ 或 ~/.cc-pm/registry/）

示例:
  $(basename "$0") install deep-organizer 育儿与家庭互动
  $(basename "$0") install deep-organizer@2.0 育儿与家庭互动   # 指定版本
  $(basename "$0") list
  $(basename "$0") list 女儿学习辅导 --type skill
  $(basename "$0") doctor
  $(basename "$0") deps report-generator

registry:
  agents: $PROMPTS_DIR/agents/
  skills: $PROMPTS_DIR/skills/
base:     $BASE_DIR
EOF
}

# ==================== publish ====================
cmd_publish() {
  local type
  type="$(parse_type "$@")"
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  [[ ${#args[@]} -lt 1 ]] && { echo "usage: $0 publish <name> [--type agent|skill]"; exit 1; }
  local name="${args[0]}"

  local conf
  conf="$(configure_type "$type")"
  local registry internal_file
  registry="$(echo "$conf" | head -1)"
  internal_file="$(echo "$conf" | sed -n '3p')"

  local item_name
  item_name="$(resolve_name "$name")"
  local source="$registry/$item_name/$internal_file"
  [[ -f "$source" ]] || error "not found in local registry: $item_name"

  local version author description
  version="$(parse_frontmatter "$source" "version")"
  author="$(parse_frontmatter "$source" "author")"
  description="$(parse_frontmatter "$source" "description" | sed 's/\\n.*//' | cut -c1-80)"
  [[ -n "$version" ]] || error "$item_name has no version in frontmatter"

  local repo_dir
  repo_dir="$(find_registry_repo)"
  local type_dir="$([[ "$type" == "agent" ]] && echo "agents" || echo "skills")"
  local target_dir="$repo_dir/$type_dir/$item_name/$version"
  mkdir -p "$target_dir"

  # 复制文件
  if [[ "$type" == "agent" ]]; then
    cp "$source" "$target_dir/agent.md"
  else
    cp -r "$registry/$item_name/"* "$target_dir/"
  fi

  # 校验和
  compute_checksum "$target_dir/$internal_file" > "$target_dir/checksum.sha256"

  # 更新 index
  update_index "$repo_dir/index.json" "$item_name" "$type" "$version" "${author:-unknown}" "${description:-}"

  # git commit + push
  cd "$repo_dir"
  git add -A
  git commit -m "publish $item_name $version" || warn "no changes to commit"
  git push
  info "published $item_name $version → $REGISTRY_REPO_URL"
}

# ==================== pull ====================
cmd_pull() {
  local type
  type="$(parse_type "$@")"
  local args=()
  for arg in "$@"; do
    case "$arg" in --type*|agent|skill) ;; *) args+=("$arg") ;; esac
  done
  [[ ${#args[@]} -lt 1 ]] && { echo "usage: $0 pull <name>[@version] [--type agent|skill]"; exit 1; }
  local raw_name="${args[0]}"

  local name req_ver
  name="$(parse_version "$raw_name" | head -1)"
  req_ver="$(parse_version "$raw_name" | tail -1)"

  # 获取远程索引
  local index_file
  index_file="$(fetch_remote_index)"

  # 查询包信息
  local pkg_info
  pkg_info="$(query_index "$index_file" "$name")" || error "package '$name' not found in remote index"

  # 确定类型和版本
  local pkg_type
  pkg_type="$(python3 -c "import json; print(json.loads('''$pkg_info''')['type'])")"
  [[ -n "$type" ]] || type="$pkg_type"

  local conf
  conf="$(configure_type "$type")"
  local internal_file
  internal_file="$(echo "$conf" | sed -n '3p')"

  # 确定版本
  if [[ -z "$req_ver" ]]; then
    req_ver="$(python3 -c "import json; print(json.loads('''$pkg_info''')['latest'])")"
  fi

  local type_dir="$([[ "$type" == "agent" ]] && echo "agents" || echo "skills")"
  local cache_pkg_dir="$CACHE_DIR/$type_dir/$name/$req_ver"
  mkdir -p "$cache_pkg_dir"

  # 下载文件
  local remote_base="$REGISTRY_RAW_BASE/$type_dir/$name/$req_ver"
  info "downloading $name $req_ver..."
  curl -fsSL "$remote_base/$internal_file" -o "$cache_pkg_dir/$internal_file" || \
    error "download failed: $name $req_ver"
  curl -fsSL "$remote_base/checksum.sha256" -o "$cache_pkg_dir/checksum.sha256" 2>/dev/null || true

  # 校验
  if [[ -f "$cache_pkg_dir/checksum.sha256" ]]; then
    local expected actual
    expected="$(cat "$cache_pkg_dir/checksum.sha256" | cut -d' ' -f1)"
    actual="$(compute_checksum "$cache_pkg_dir/$internal_file")"
    if [[ "$expected" != "$actual" ]]; then
      rm -rf "$cache_pkg_dir"
      error "checksum mismatch! download may be corrupted"
    fi
    info "checksum verified"
  fi

  # 复制到本地 registry
  local local_registry
  local_registry="$(echo "$conf" | head -1)"
  local pkg_dir="$local_registry/$name"
  mkdir -p "$pkg_dir"
  cp "$cache_pkg_dir/$internal_file" "$pkg_dir/$internal_file"
  info "pulled $name $req_ver to local registry"
  info "now run: $(basename "$0") install $name <project>"
}

# ==================== remote-search ====================
cmd_remote_search() {
  local keyword="${1:-}"
  [[ -z "$keyword" ]] && { echo "usage: $0 remote-search <keyword>"; exit 1; }

  local index_file
  index_file="$(fetch_remote_index)"

  python3 -c "
import json, sys
with open('$index_file', 'r') as f:
    data = json.load(f)
found = 0
for name, pkg in data['packages'].items():
    desc = pkg.get('versions', {}).get(pkg.get('latest', ''), {}).get('description', '')
    author = pkg.get('versions', {}).get(pkg.get('latest', ''), {}).get('author', '')
    if '$keyword'.lower() in name.lower() or '$keyword'.lower() in desc.lower() or '$keyword'.lower() in author.lower():
        print(f\"  {name:35s} {pkg['type']:6s} {pkg.get('latest',''):4s} by {author:10s} — {desc[:40]}\")
        found += 1
if found == 0:
    print('  no matches')
"
}

# ==================== main ====================
case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  list)      shift; cmd_list "$@" ;;
  doctor)    cmd_doctor ;;
  deps)      shift; cmd_deps "$@" ;;
  search)    shift; cmd_search "$@" ;;
  publish)   shift; cmd_publish "$@" ;;
  pull)      shift; cmd_pull "$@" ;;
  remote-search|rsearch) shift; cmd_remote_search "$@" ;;
  -h|--help|help) usage ;;
  *)         usage ;;
esac
