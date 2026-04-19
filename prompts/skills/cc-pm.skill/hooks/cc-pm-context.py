#!/usr/bin/env python3
"""UserPromptSubmit hook: detect cc-pm related keywords and inject help context.

This script lives inside cc-pm.skill/hooks/ and uses dynamic path resolution
to find cc-pm.sh regardless of which project the skill is installed in.
"""
import sys, json, subprocess, os

# Resolve real path through symlink
# Real location: 共享模板/prompts/skills/cc-pm.skill/hooks/
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CC_PM_PATH = os.path.normpath(os.path.join(SCRIPT_DIR, '..', '..', '..', '..', 'bin', 'cc-pm.sh'))

input_data = sys.stdin.read()
keywords = [
    '包管理器', '软链接', 'cc-pm', 'agent-pm',
    '安装agent', '安装skill', '卸载agent', '卸载skill',
]

if any(k in input_data for k in keywords):
    result = subprocess.run(
        [CC_PM_PATH, '--help'],
        capture_output=True, text=True
    )
    msg = '用户提到了包管理器相关内容，以下是 cc-pm.sh 帮助信息供参考：\n\n' + result.stdout
    print(json.dumps({'systemMessage': msg}))
else:
    print('{}')
