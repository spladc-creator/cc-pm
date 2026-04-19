---
name: cc-pm
description: Claude Code 包管理器技能。当用户提到"包管理器""软链接""安装agent/skill""卸载agent/skill"时激活，提供 cc-pm.sh 命令参考和操作引导。安装后自动配置关键词触发 hook。
location: project
---

# Claude Code 包管理器 (cc-pm)

## 适用场景

当用户需要管理跨项目的 Agent 或 Skill 配置时使用此技能。包括安装、卸载、查看、搜索等操作。

---

## 安装

### 首次安装（一键脚本）

```bash
curl -fsSL https://raw.githubusercontent.com/spladc/cc-pm/main/bin/install.sh | bash
```

指定 monorepo 根目录：

```bash
curl -fsSL https://raw.githubusercontent.com/spladc/cc-pm/main/bin/install.sh | bash -s -- --base /path/to/monorepo
```

安装完成后：

1. 重新加载 shell：`source ~/.zshrc`
2. 在 monorepo 根目录创建标记：`cd /path/to/monorepo && touch .cc-pm-base`
3. 开始使用：`cc-pm.sh list`

### 安装到项目（skill 方式）

```bash
cc-pm.sh install cc-pm <project> --type skill
```

---

## Setup（安装后必须执行）

此 skill 包含 hook 脚本，安装后需要配置 UserPromptSubmit hook 才能实现关键词自动触发。

**执行步骤：**

1. 确认 hook 脚本存在于当前项目的 skill 目录：
   ```
   .claude/skills/cc-pm.skill/hooks/cc-pm-context.py
   ```

2. 读取当前项目的 `.claude/settings.json`（如果没有则创建）

3. 将以下 hook 配置合并到 settings.json（保留已有配置，不要覆盖）：
   ```json
   {
     "hooks": {
       "UserPromptSubmit": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 .claude/skills/cc-pm.skill/hooks/cc-pm-context.py",
               "timeout": 10
             }
           ]
         }
       ]
     }
   }
   ```

4. 用 `echo '{"userMessage":"包管理器"}' | python3 .claude/skills/cc-pm.skill/hooks/cc-pm-context.py` 验证 hook 脚本正常工作

5. 告知用户：hook 已配置，新会话生效。用户也可以通过 `/hooks` 查看和确认。

---

## 命令参考

脚本路径：`../../共享模板/bin/cc-pm.sh`（相对于项目根目录）

路径检测（三级策略，优先级从高到低）：

| 优先级 | BASE_DIR（项目根） | Registry（agents/skills 存储） |
|--------|-------------------|-------------------------------|
| 1 | `CC_PM_BASE` 环境变量 | `CC_PM_REGISTRY` 环境变量 |
| 2 | 向上查找 `.cc-pm-base` 标记文件 | 脚本旁的 `prompts/` 目录 |
| 3 | 脚本上两级目录（回退） | `~/.cc-pm/registry/`（自动创建） |

| 命令 | 用法 | 说明 |
|------|------|------|
| `install` | `cc-pm.sh install <name> <project> [--type agent\|skill]` | 安装到项目（创建软链接） |
| `uninstall` | `cc-pm.sh uninstall <name> <project> [--type agent\|skill]` | 卸载（最后链接时同时删源文件） |
| `list` | `cc-pm.sh list [project] [--type agent\|skill]` | 列出已安装 / registry 内容 |
| `doctor` | `cc-pm.sh doctor` | 全局健康检查（扫描 agents + skills） |
| `deps` | `cc-pm.sh deps <name> [--type agent\|skill]` | 查看依赖关系 |
| `search` | `cc-pm.sh search <keyword> [--type agent\|skill]` | 搜索 registry |

---

## 类型区别

| 类型 | `--type` | 链接方式 | 目标目录 | 命名规则 |
|------|----------|----------|----------|----------|
| Agent | `agent`（默认） | 文件级软链接 | `.claude/agents/` | 自动加 `.md` 后缀 |
| Skill | `skill` | 目录级软链接 | `.claude/skills/` | 自动加 `.skill` 后缀 |

---

## 文件格式规范

### Agent（单文件）

`共享模板/prompts/agents/<name>.md`：

```yaml
---
name: agent-name
description: 一句话描述，用于 list 和搜索时展示
tools: Tool1, Tool2
model: sonnet
color: yellow
---

[Agent 系统提示词正文]
```

### Skill（目录）

`共享模板/prompts/skills/<name>.skill/skill.md`：

```yaml
---
name: skill-name
description: 一句话描述
location: project
---

[技能说明和指令正文]
```

---

## 典型操作

```bash
# 安装 agent
cc-pm.sh install deep-organizer 育儿与家庭互动

# 安装 skill
cc-pm.sh install history-storytelling 育儿与家庭互动 --type skill

# 查看某个项目
cc-pm.sh list 女儿学习辅导 --type skill

# 全局健康检查
cc-pm.sh doctor

# 搜索 registry
cc-pm.sh search deep
```

---

## 注意事项

1. **软链接机制**：安装不复制文件，创建相对路径符号链接，源文件修改全局生效
2. **安全卸载**：卸载时检查是否还有其他项目依赖，仅当无依赖时才删除源文件
3. **动态路径**：symlink 相对路径由 `python3 os.path.relpath` 动态计算，不硬编码，适配任意目录结构
4. **Hook 脚本**：`hooks/cc-pm-context.py` 使用 `os.path.realpath(__file__)` 动态定位 cc-pm.sh，无需硬编码路径，任何项目通用
5. **独立部署**：通过 `CC_PM_BASE` 和 `CC_PM_REGISTRY` 环境变量，脚本可部署在任意位置，无需 spladc.com 目录结构
