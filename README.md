# cc-pm

Claude Code 包管理器 — 通过软链接管理跨项目的 Agent 和 Skill 配置。

## 它解决什么问题

在 Claude Code 中，Agent 和 Skill 配置以文件形式存在项目的 `.claude/` 目录下。当多个项目需要共享同一套配置时，手动复制会导致版本不一致。

cc-pm 用**符号链接**替代复制——源文件统一维护，各项目通过链接引用，改一处全局生效。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/spladc-creator/cc-pm/main/bin/install.sh | bash
```

指定你的 monorepo 根目录：

```bash
curl -fsSL https://raw.githubusercontent.com/spladc-creator/cc-pm/main/bin/install.sh | bash -s -- --base /path/to/monorepo
```

安装完成后：

1. 重新加载 shell：`source ~/.zshrc`
2. 在 monorepo 根目录创建标记文件：`cd /path/to/monorepo && touch .cc-pm-base`
3. 开始使用：`cc-pm.sh list`

## 使用方法

### 命令

| 命令 | 说明 |
|------|------|
| `cc-pm.sh install <name> <project>` | 安装到项目（创建软链接） |
| `cc-pm.sh uninstall <name> <project>` | 卸载 |
| `cc-pm.sh list [project]` | 列出已安装 / registry 内容 |
| `cc-pm.sh doctor` | 全局健康检查 |
| `cc-pm.sh deps <name>` | 查看依赖关系 |
| `cc-pm.sh search <keyword>` | 搜索 registry |

### 类型

通过 `--type` 指定，默认 `agent`。

| 类型 | 说明 | 目标目录 |
|------|------|----------|
| Agent | 单文件配置（`.md`） | `.claude/agents/` |
| Skill | 目录配置（`.skill/`） | `.claude/skills/` |

### 示例

```bash
# 安装 agent
cc-pm.sh install deep-organizer my-project

# 安装 skill
cc-pm.sh install cc-pm my-project --type skill

# 查看
cc-pm.sh list my-project --type skill
cc-pm.sh doctor
cc-pm.sh search deep
```

## 路径检测

cc-pm 使用三级策略定位路径，无需硬编码：

| 优先级 | BASE_DIR（项目根） | Registry（存储位置） |
|--------|-------------------|---------------------|
| 1 | `CC_PM_BASE` 环境变量 | `CC_PM_REGISTRY` 环境变量 |
| 2 | `.cc-pm-base` 标记文件 | 脚本旁 `prompts/` 目录 |
| 3 | 脚本上两级目录 | `~/.cc-pm/registry/` |

## 创建自己的 Agent / Skill

### Agent 格式

在 `prompts/agents/` 下创建 `.md` 文件：

```yaml
---
name: my-agent
description: 一句话描述
tools: Glob, Grep, Read
model: sonnet
---

Agent 系统提示词正文...
```

### Skill 格式

在 `prompts/skills/` 下创建 `.skill` 目录：

```
my-skill.skill/
  skill.md       # 必须存在
  hooks/         # 可选，包含 hook 脚本
```

skill.md：

```yaml
---
name: my-skill
description: 一句话描述
location: project
---

技能说明正文...
```

## 卸载 cc-pm

```bash
rm -rf ~/.cc-pm
# 然后手动移除 shell profile 中的相关行
```

## License

MIT
