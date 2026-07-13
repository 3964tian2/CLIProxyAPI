Set WshShell = CreateObject("WScript.Shell")
workDir = "D:\program\CPA"
launcher = "D:\program\CPA\maintenance\launch_cpa.ps1"
WshShell.CurrentDirectory = workDir
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & launcher & """ -WorkDir """ & workDir & """"
WshShell.Run command, 0, False
Set WshShell = Nothing
