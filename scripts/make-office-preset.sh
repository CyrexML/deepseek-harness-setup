#!/usr/bin/env bash
# Генерирует пресет «Local 64k + Office» из рабочего local-64k: та же композиция,
# но каталог skills (tool-skill) включён — для сессий с документами
# (.xlsx/.docx/.pptx/.univer): модель видит skills univer и грузит их сама.
# Модули .mjs не копируются — строки name: ./x.mjs переписываются на
# ../local-64k/x.mjs (относительный спецификатор, agent-presets/src/specifier.ts:45).
# Перезапускать после любой правки local-64k/agent.cordis.yml; DSH перечитывает
# пресеты при старте web.
set -euo pipefail
SRC="$HOME/.dsh/.agent-presets/local-64k"
DST="$HOME/.dsh/.agent-presets/local-64k-office"
mkdir -p "$DST"
python3 - "$SRC/agent.cordis.yml" "$DST/agent.cordis.yml" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
a = "- id: tool-skill\n  name: '@deepseek-ai/dsh-tool-skill'\n  disabled: true\n"
if s.count(a) != 1: sys.exit("tool-skill row not found in base preset — make-office-preset.sh needs re-targeting")
s = s.replace(a, "- id: tool-skill\n  name: '@deepseek-ai/dsh-tool-skill'\n  # Office-вариант: каталог skills (univer) включён.\n", 1)
s, n = re.subn(r"(name: )\./", r"\1../local-64k/", s)
head = ("# СГЕНЕРИРОВАНО scripts/make-office-preset.sh из ../local-64k/agent.cordis.yml —\n"
        "# НЕ ПРАВИТЬ РУКАМИ, правки делать в local-64k и перегенерировать.\n")
open(dst, "w").write(head + s)
print(f"office preset: {n} module rows → ../local-64k/, tool-skill enabled")
PY
cat > "$DST/preset.yml" <<'YML'
name: Local 64k + Office
description: То же, что Local 64k, плюс каталог skills univer для документов (.xlsx/.docx/.pptx/.univer). Сгенерировано scripts/make-office-preset.sh — не править руками.
order: 2
YML
echo "→ $DST"
