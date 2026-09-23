' Запуск PowerShell-скрипта БЕЗ окна.
' Задача планировщика с действием powershell.exe показывает окно консоли на
' долю секунды даже с -WindowStyle Hidden: окно создаёт conhost ДО того, как
' PowerShell успевает применить стиль. Раз в 15 минут это мигает на экране
' (жалоба 2026-09-23). WScript.Shell.Run с режимом 0 не создаёт окна вовсе.
'   wscript.exe harness-hidden.vbs "<путь к .ps1>" [аргументы]
Option Explicit
Dim shell, args, cmd, i
Set shell = CreateObject("WScript.Shell")
Set args = WScript.Arguments
If args.Count = 0 Then WScript.Quit 2
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & args(0) & """"
For i = 1 To args.Count - 1
  cmd = cmd & " " & args(i)
Next
shell.Run cmd, 0, False
