# cc-pm

Claude Code Agent & Skill 包管理器。管理跨项目的配置共享和远程分发。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/spladc-creator/cc-pm/main/bin/install.sh | bash
source ~/.zshrc
```

## 命令

| 命令 | 说明 |
|------|------|
| `install <name>[@version] <project>` | 安装到项目 |
| `uninstall <name> <project>` | 卸载 |
| `list [project]` | 列出已安装 |
| `doctor` | 健康检查 |
| `deps <name>` | 查看依赖 |
| `search <keyword>` | 搜索本地 registry |
| `publish <name>` | 发布到远程 |
| `pull <name>[@version]` | 从远程拉取 |
| `remote-search <keyword>` | 搜索远程 registry |

## 远程包仓库

https://github.com/spladc-creator/cc-pm-registry
