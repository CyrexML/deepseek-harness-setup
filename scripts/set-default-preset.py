#!/usr/bin/env python3
"""Точечно выставить agent-presets.default в $DSH_HOME/settings.yaml.

Это то же поле, которое пишет кнопка «Set as default» в интерфейсе
(packages/client/ui-agent-preset/README.md: «the default write ... targets the
`agent-presets` settings namespace's `default` field, which is what the host
resolves at creation»). YAML не переписывается целиком — правится одна строка,
остальной документ сохраняется как есть.
"""
import sys, os, re

path, value = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8').read().splitlines(keepends=True) if os.path.exists(path) else []

start = None
for i, l in enumerate(lines):
    if re.match(r'^agent-presets:\s*$', l):
        start = i
        break

old = None
if start is None:
    if lines and not lines[-1].endswith('\n'):
        lines.append('\n')
    lines += ['agent-presets:\n', f'  default: {value}\n']
else:
    j = start + 1
    done = False
    while j < len(lines) and (lines[j].startswith((' ', '\t')) or not lines[j].strip()):
        m = re.match(r'^(\s+)default:\s*(.*?)\s*$', lines[j])
        if m:
            old = m.group(2)
            lines[j] = f'{m.group(1)}default: {value}\n'
            done = True
            break
        j += 1
    if not done:
        lines.insert(start + 1, f'  default: {value}\n')

open(path, 'w', encoding='utf-8').write(''.join(lines))
print(f"agent-presets.default: {old or '(не был задан)'} -> {value}")
