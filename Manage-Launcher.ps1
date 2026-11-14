#Requires -Version 5.1
# SPDX-License-Identifier: MIT
# Install the launcher, maintain matching entry points and restore original settings.
[CmdletBinding()]
param([string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'AntigravityProxyLauncher'), [string]$AntigravityPath, [switch]$Preview, [switch]$Repair, [switch]$Watch, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AntigravityProxy.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'LauncherInstall.psm1') -Force -DisableNameChecking
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$installApplying = $false

if ($Watch) {
    $singleton = New-Object Threading.Mutex($false, (Get-LauncherMutexName $InstallDirectory 'Watch'))
    $watchAcquired = $false
    try {
        try { $watchAcquired = $singleton.WaitOne(0) } catch [Threading.AbandonedMutexException] { $watchAcquired = $true }
        if (-not $watchAcquired) { exit 0 }
        while ($true) {
            $lock = New-Object Threading.Mutex($false, (Get-LauncherMutexName $InstallDirectory))
            $acquired = $false
            try {
                try { $acquired = $lock.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
                if ($acquired) {
                    $state = Read-LauncherState $InstallDirectory
                    if (-not $state -or -not $state.Installed) { break }
                    Repair-LauncherEntries $state
                }
            } catch {
                [IO.File]::WriteAllText((Join-Path $InstallDirectory 'guard-error.log'), $_.Exception.Message)
            } finally { if ($acquired) { $lock.ReleaseMutex() }; $lock.Dispose() }
            Start-Sleep -Seconds 30
        }
    } finally { if ($watchAcquired) { $singleton.ReleaseMutex() }; $singleton.Dispose() }
    exit 0
}

$lock = New-Object Threading.Mutex($false, (Get-LauncherMutexName $InstallDirectory))
$acquired = $false
try {
    try { $acquired = $lock.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Another install/repair is in progress.' }
    if ($Uninstall -or $Repair) {
        $state = Read-LauncherState $InstallDirectory
        if (-not $state) { throw 'No installation state found.' }
        if ($Uninstall) { Restore-LauncherEntries $state; Write-Host 'Original entries restored. The guard will exit within 30 seconds. Backups are retained.' } else { Repair-LauncherEntries $state; Write-Host 'Entries checked and repaired.' }
        exit 0
    }
    $exe = Find-AntigravityExecutable -AntigravityPath $AntigravityPath
    $dispatcher = Join-Path $InstallDirectory 'ProxyLauncher.exe'
    $paths = @(Get-LauncherShortcutPaths $exe $InstallDirectory)
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('Programs'))) {
        if ($folder -and (Test-Path -LiteralPath $folder)) {
            $defaultLink = Join-Path $folder 'Antigravity.lnk'
            if (-not (Test-Path -LiteralPath $defaultLink)) { $paths += $defaultLink }
        }
    }
    Write-Host ('Application: ' + $exe)
    Write-Host ('Launcher directory: ' + $InstallDirectory)
    foreach ($path in @($paths | Select-Object -Unique)) { Write-Host ('Shortcut: ' + $path) }
    Write-Host 'Matching antigravity:// and existing user autorun entries will use the launcher.'
    Write-Host 'A per-user login guard checks these entries every 30 seconds after app updates.'
    if ($Preview) { Write-Host 'Preview only. No changes made.'; exit 0 }

    [void][IO.Directory]::CreateDirectory($InstallDirectory)
    foreach ($name in @('AntigravityProxy.psm1','LauncherInstall.psm1','Start-Antigravity.ps1','Manage-Launcher.ps1','Build-Dispatcher.ps1','Dispatcher.cs','Launch.cmd','Install.cmd','Uninstall.cmd','README.md','LICENSE')) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $InstallDirectory $name
        if (-not [string]::Equals([IO.Path]::GetFullPath($source), $destination, [StringComparison]::OrdinalIgnoreCase)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
    }
    $buildPath = Join-Path $InstallDirectory ('ProxyLauncher.build-' + [guid]::NewGuid().ToString('N') + '.exe')
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $InstallDirectory 'Build-Dispatcher.ps1') -OutputPath $buildPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the local dispatcher.' }
    Move-Item -LiteralPath $buildPath -Destination $dispatcher -Force
    [IO.File]::WriteAllText((Join-Path $InstallDirectory 'launcher-config.json'), (@{AntigravityPath=$exe} | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
    $state = Read-LauncherState $InstallDirectory
    if (-not $state -or -not $state.Installed) { $state = New-LauncherState $InstallDirectory $exe }
    $state.Application = $exe
    Save-LauncherState $state
    $installApplying = $true
    foreach ($path in @($paths | Select-Object -Unique)) { Set-LauncherShortcut $state $path }
    Repair-LauncherEntries $state
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $guardArgs = @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $InstallDirectory 'Manage-Launcher.ps1'),'-Watch','-InstallDirectory',$InstallDirectory)
    $guardLine = (@($guardArgs | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    Set-TrackedRegistryValue $state 'Software\Microsoft\Windows\CurrentVersion\Run' 'AntigravityProxyLauncherGuard' ((ConvertTo-WindowsArgument $powerShell) + ' ' + $guardLine)
    Save-LauncherState $state
    Start-Process -FilePath $powerShell -ArgumentList $guardLine -WindowStyle Hidden
    Write-Host 'Installed. Fully quit Antigravity once, then use your usual shortcut. No application process was terminated.'
} catch {
    $failure = $_.Exception.Message
    if ($installApplying) {
        try { $rollback = Read-LauncherState $InstallDirectory; if ($rollback) { Restore-LauncherEntries $rollback }; Write-Host 'Installation entries rolled back.' } catch { Write-Host ('Rollback could not finish; retained backups: ' + $InstallDirectory) -ForegroundColor Yellow }
    }
    Write-Host ('ERROR: ' + $failure) -ForegroundColor Red
    exit 1
} finally { if ($acquired) { $lock.ReleaseMutex() }; $lock.Dispose() }
