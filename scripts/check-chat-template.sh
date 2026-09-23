#!/usr/bin/env bash
# Проверка, реплеит ли живой llama-server reasoning прошлых шагов в промпт
# (шаг 1 аудита контекста 2026-09-12). Шлёт в /apply-template историю из двух
# assistant-сообщений с reasoning_content поверх tool-цикла и смотрит, попали ли
# маркеры в отрендеренный промпт. Ожидание с qwen3.8-agent.jinja: оба ОТСУТСТВУЮТ.
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
out=$(curl -sf --max-time 10 "$URL/apply-template" -H 'Content-Type: application/json' -d "$body") || { echo "сервер не отвечает на $URL"; exit 2; }
one=$(grep -c "MARKER-THINK-ONE" <<<"$out"); two=$(grep -c "MARKER-THINK-TWO" <<<"$out")
echo "reasoning шага 1 в промпте: $([ "$one" = 0 ] && echo нет || echo ДА);  шага 2 (последний): $([ "$two" = 0 ] && echo нет || echo ДА)"
if [ "$one" = 0 ]; then echo "OK: история без reasoning (qwen3.8-agent.jinja активен)"; else echo "стоковый шаблон: reasoning всех шагов хода реплеится"; exit 1; fi
