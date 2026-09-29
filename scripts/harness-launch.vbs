' Start the launcher without a console window. The Harness AI shortcut points
' here (wscript //B) rather than at powershell.exe: powershell -WindowStyle Hidden
' still flashes a window, while WScript.Shell.Run with mode 0 shows none.
' All the logic lives in harness-start.ps1 (-Hidden: it waits for the
' power.request signal file from the web Power buttons, or for a second click on
' the shortcut instead of Enter in a console).
' The author's F: used to be baked in here, and nothing substituted it at install
' time: on any other drive the shortcut started nothing and said nothing. This
' file sits next to harness-start.ps1, so it can find it without being told.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
runDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & runDir & "\harness-start.ps1"" -Hidden", 0, False
