' Run a PowerShell script WITHOUT a window.
' A scheduled task whose action is powershell.exe flashes a console for a split
' second even with -WindowStyle Hidden: conhost creates the window BEFORE
' PowerShell can apply the style, and once every 15 minutes that flash is
' noticeable. WScript.Shell.Run with mode 0 creates no window at all.
'   wscript.exe harness-hidden.vbs "<path to .ps1>" [arguments]
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
