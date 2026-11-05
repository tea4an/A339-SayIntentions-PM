' Speedy Copilot A339 edition : runs a PowerShell script with no window at all.
' run_hidden.vbs <script.ps1> [arguments...]   (the bridge and the listener leave by themselves with X-Plane)
Dim args, i, cmd
Set args = WScript.Arguments
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & args(0) & """"
For i = 1 To args.Count - 1
    cmd = cmd & " " & args(i)
Next
CreateObject("WScript.Shell").Run cmd, 0, False
