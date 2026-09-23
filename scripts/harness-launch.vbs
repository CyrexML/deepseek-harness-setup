' Start the launcher without a console window. The Harness AI shortcut points
' here (wscript //B) rather than at powershell.exe: powershell -WindowStyle Hidden
' still flashes a window, while WScript.Shell.Run with mode 0 shows none.
' All the logic lives in harness-start.ps1 (-Hidden: it waits for the
' power.request signal file from the web Power buttons, or for a second click on
' the shortcut instead of Enter in a console).
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""F:\Harness_AI\run\harness-start.ps1"" -Hidden", 0, False
