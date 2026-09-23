#!/usr/bin/env bash
# Подставляет актуальный адрес Windows-хоста в .dsh/config.json.
# Нужен, пока сеть WSL работает в режиме NAT: адрес шлюза меняется при
# каждом перезапуске WSL, поэтому константу в конфиг вписывать нельзя
# (§7.3 decision-01). В зеркальном режиме (§7.2) скрипт не нужен —
# там достаточно 127.0.0.1.
set -euo pipefail
cfg="$(dirname "$0")/../../.dsh/config.json"
gw="$(ip route show default | awk '{print $3}')"
python3 - "$cfg" "$gw" <<'PY'
import json, sys, re
path, gw = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
p = cfg["models"]["providers"]["qwen-local"]
p["baseUrl"] = re.sub(r"//[^:/]+:", f"//{gw}:", p["baseUrl"])
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"baseUrl -> {p['baseUrl']}")
PY
