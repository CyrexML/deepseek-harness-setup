#!/usr/bin/env bash
# Write the current Windows host address into .dsh/config.json.
# Needed while WSL networking runs in NAT mode: the gateway address changes on
# every WSL restart, so a constant cannot be written into the config. In mirrored
# mode the script is unnecessary - 127.0.0.1 is enough there.
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
