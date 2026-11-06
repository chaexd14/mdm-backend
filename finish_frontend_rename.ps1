$ErrorActionPreference = 'Stop'
$mdmSource = [IO.Path]::GetFullPath('E:\kiosk-dashboard')
$mdmDestination = [IO.Path]::GetFullPath('E:\mdm-frontend')
$mdmLog = 'E:\mdm-backend\tmp\frontend-rename.log'
if ($mdmSource -ne 'E:\kiosk-dashboard' -or $mdmDestination -ne 'E:\mdm-frontend') {
    throw 'Unexpected rename paths'
}
$mdmDeadline = [DateTime]::UtcNow.AddMinutes(30)
[IO.File]::WriteAllText($mdmLog, "Waiting for Windows folder locks to be released.`r`n")
while ([DateTime]::UtcNow -lt $mdmDeadline) {
    if (Test-Path -LiteralPath $mdmDestination) {
        if (Test-Path -LiteralPath $mdmSource) {
            [IO.File]::AppendAllText($mdmLog, "Stopped: destination already exists; no files overwritten.`r`n")
            exit 1
        }
        break
    }
    if (-not (Test-Path -LiteralPath $mdmSource)) {
        [IO.File]::AppendAllText($mdmLog, "Stopped: source does not exist.`r`n")
        exit 1
    }
    $mdmResolvedSource = (Resolve-Path -LiteralPath $mdmSource).Path
    $mdmSourceItem = Get-Item -LiteralPath $mdmResolvedSource
    if ($mdmResolvedSource -ne 'E:\kiosk-dashboard' -or ($mdmSourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Source is not the expected ordinary folder'
    }
    try {
        Rename-Item -LiteralPath $mdmSource -NewName 'mdm-frontend' -ErrorAction Stop
        break
    } catch [IO.IOException] {
        Start-Sleep -Milliseconds 1000
    }
}
if ((Test-Path -LiteralPath $mdmSource) -or -not (Test-Path -LiteralPath $mdmDestination)) {
    [IO.File]::AppendAllText($mdmLog, "Timed out: close Codex and rerun this script.`r`n")
    exit 1
}
$mdmBackendReadme = 'E:\mdm-backend\README.md'
[IO.File]::WriteAllText($mdmBackendReadme, [IO.File]::ReadAllText($mdmBackendReadme).Replace('E:/kiosk-dashboard', 'E:/mdm-frontend'))
$mdmFrontendReadme = 'E:\mdm-frontend\README.md'
$mdmText = [IO.File]::ReadAllText($mdmFrontendReadme).Replace('# MDM dashboard frontend', '# MDM web frontend')
$mdmText = $mdmText.Replace('```powershell' + "`n" + 'npm install', '```powershell' + "`n" + 'cd E:\mdm-frontend' + "`n" + 'npm install')
[IO.File]::WriteAllText($mdmFrontendReadme, $mdmText)
[IO.File]::AppendAllText($mdmLog, "SUCCESS: renamed E:\kiosk-dashboard to E:\mdm-frontend; documentation updated.`r`n")
