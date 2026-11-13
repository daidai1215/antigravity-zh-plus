Option Explicit

Dim fso, shell, scriptDir, psScript, sysRoot, psExe, cmd, i, arg
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "launch-hans.ps1")

If Not fso.FileExists(psScript) Then
    MsgBox "Missing launch-hans.ps1 in: " & scriptDir, vbCritical, "Antigravity-Hans"
    WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
sysRoot = shell.ExpandEnvironmentStrings("%SystemRoot%")
psExe = fso.BuildPath(sysRoot, "System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(psExe) Then
    psExe = "powershell.exe"
End If

cmd = """" & psExe & """ -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & psScript & """"

For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    Select Case LCase(arg)
        Case "-watch", "-attachonly", "-syncshortcuts", "-enableautoguard", "-disableautoguard", "-stopall"
            cmd = cmd & " " & arg
        Case Else
            WScript.Quit 2
    End Select
Next

shell.CurrentDirectory = scriptDir
shell.Run cmd, 0, False
