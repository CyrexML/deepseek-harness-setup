#!/usr/bin/env bash
# Веб-интерфейс на переднем плане — точка входа для launcher'а с Windows.
#
# Существует ради одной вещи: у неё НЕТ аргументов и в её пути НЕТ пробелов.
# `Start-Process` из PowerShell склеивает массив аргументов через пробел, не
# расставляя кавычек, поэтому `bash -lc "DSH_WEB_FOREGROUND=1 ... start-web.sh ~"`
# доезжал до bash разорванным: команда обрывалась на первом пробеле, остальное
# уходило в $0/$1. Строка без пробелов эту ловушку снимает.
export DSH_WEB_FOREGROUND=1
# Через `bash`, а не напрямую: бит исполнения у start-web.sh может
# не пережить свежий клон репозитория, и запуск падал бы с Permission denied.
exec bash "$HOME/Harness_AI/scripts/start-web.sh" "$HOME/Harness_AI"
