#!/usr/bin/env bash
# Check whether the live llama-server replays the reasoning of past steps into
# the prompt. Sends a history of two assistant messages carrying reasoning_content
# to /apply-template and looks for the markers in the rendered prompt. With the
# stand's template both must be ABSENT.
set -u
URL="${DSH_LLAMA_BASE_URL:-http://$(ip route show default | awk '{print $3}'):8080/v1}"
URL="${URL%/v1}"
body='{"messages":[
 {"role":"user","content":"do the task"},
 {"role":"assistant","content":"","reasoning_content":"MARKER-THINK-ONE","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]},
 {"role":"tool","tool_call_id":"c1","content":"file.txt"},
 {"role":"assistant","content":"","reasoning_content":"MARKER-THINK-TWO","tool_calls":[{"id":"c2","type":"function","function":{"name":"read","arguments":"{\"file_path\":\"file.txt\"}"}}]},
 {"role":"tool","tool_call_id":"c2","content":"hello"}],
 "tools":[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}},
          {"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"file_path":{"type":"string"}}}}}]}'
out=$(curl -sf --max-time 10 "$URL/apply-template" -H 'Content-Type: application/json' -d "$body") || { echo "the server does not answer on $URL"; exit 2; }
one=$(grep -c "MARKER-THINK-ONE" <<<"$out"); two=$(grep -c "MARKER-THINK-TWO" <<<"$out")
echo "step 1 reasoning in the prompt: $([ "$one" = 0 ] && echo no || echo YES);  step 2 (last): $([ "$two" = 0 ] && echo no || echo YES)"
if [ "$one" = 0 ]; then echo "OK: history without reasoning (the stand template is active)"; else echo "stock template: the reasoning of every step is replayed"; exit 1; fi
