' Запуск лончера без консольного окна. Ярлык «Harness AI» указывает сюда
' (wscript //B), а не на powershell.exe: у powershell -WindowStyle Hidden окно
' всё равно мелькает, WScript.Shell.Run с режимом 0 не показывает его вовсе.
' Вся логика — в harness-start.ps1 (-Hidden: ждёт файл-сигнал power.request
' от кнопок Power в вебе или второй клик по ярлыку вместо Enter в консоли).
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""F:\Harness_AI\run\harness-start.ps1"" -Hidden", 0, False
