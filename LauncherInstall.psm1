# SPDX-License-Identifier: MIT
# Back up, redirect, repair and restore per-user shortcuts and registry values.
Set-StrictMode -Version 2.0

function Read-LauncherState([string]$Directory) {
    $path = Join-Path $Directory 'install-state.json'
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
}
function Save-LauncherState($State) {
    $path = Join-Path $State.Directory 'install-state.json'
    $text = $State | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($path + '.tmp', $text, (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
}
function New-LauncherState([string]$Directory, [string]$Application) {
    [pscustomobject]@{ Version='2.0.0'; Installed=$true; Directory=$Directory; Application=$Application; Shortcuts=@(); Registry=@(); CreatedKeys=@() }
}
function Get-LauncherMutexName([string]$Directory, [string]$Role = 'Install') {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Directory.ToLowerInvariant()))).Replace('-','').Substring(0,20) } finally { $sha.Dispose() }
    return ('Local\AntigravityProxy' + $Role + $hash)
}
function Convert-LauncherCommand([string]$Command, [string]$Application, [string]$Dispatcher) {
    if ($Command -notmatch '^\s*(?:"(?<exe>[^"]+)"|(?<exe>\S+))(?<tail>.*)$') { return }
    $exe = [Environment]::ExpandEnvironmentVariables($Matches.exe)
    $tail = $Matches.tail
    if (-not [string]::Equals($exe, $Application, [StringComparison]::OrdinalIgnoreCase)) { return }
    return ('"' + $Dispatcher + '"' + $tail)
}
function Get-LauncherShortcutPaths([string]$Application, [string]$Directory) {
    $dispatcher = Join-Path $Directory 'ProxyLauncher.exe'
    $roots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup'))
    if ($env:APPDATA) { $roots += Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar' }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($root in @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
            try {
                $link = $shell.CreateShortcut($file.FullName)
                if ($link.TargetPath -ieq $Application -or $link.TargetPath -ieq $dispatcher) { $file.FullName }
            } catch { Write-Verbose 'Could not inspect a shortcut.' }
        }
    }
}
function Set-LauncherShortcut($State, [string]$Path) {
    $dispatcher = Join-Path $State.Directory 'ProxyLauncher.exe'
    $shell = New-Object -ComObject WScript.Shell
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $link = $shell.CreateShortcut($Path)
    if ($exists -and $link.TargetPath -ieq $dispatcher) { return }
    if ($exists -and $link.TargetPath -ine $State.Application) { return }
    $record = @($State.Shortcuts | Where-Object { $_.Path -ieq $Path } | Select-Object -First 1)
    if ($record.Count -eq 0) {
        $backup = Join-Path $State.Directory ('backup\' + [guid]::NewGuid().ToString('N') + '.lnk')
        if ($exists) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup)); Copy-Item -LiteralPath $Path -Destination $backup }
        $record = [pscustomobject]@{ Path=$Path; Existed=$exists; Backup=$backup; Arguments=[string]$link.Arguments }
        $State.Shortcuts = @($State.Shortcuts) + @($record)
        Save-LauncherState $State
    } else { $record = $record[0] }
    # Preserve original flags, URI placeholders, working directory and icon.
    if (-not $exists) { $link.Arguments = $record.Arguments }
    $record.Arguments = [string]$link.Arguments
    Save-LauncherState $State
    $link.TargetPath = $dispatcher
    if (-not $link.IconLocation) { $link.IconLocation = $State.Application + ',0' }
    if (-not $link.WorkingDirectory) { $link.WorkingDirectory = Split-Path -Parent $State.Application }
    $link.Save()
}
function Set-TrackedRegistryValue($State, [string]$Key, [string]$Name, [string]$Value) {
    $record = @($State.Registry | Where-Object { $_.Key -eq $Key -and $_.Name -eq $Name } | Select-Object -First 1)
    $keyObject = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Key)
    $exists = $false; $oldValue = $null; $oldKind = 'String'
    try {
        if ($keyObject) {
            $exists = $Name -in $keyObject.GetValueNames()
            if ($exists) {
                $oldValue = $keyObject.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $oldKind = [string]$keyObject.GetValueKind($Name)
                if ([string]$oldValue -ceq $Value) { return }
            }
        }
    } finally { if ($keyObject) { $keyObject.Close() } }
    if ($record.Count -eq 0) {
        $record = [pscustomobject]@{ Key=$Key; Name=$Name; Existed=$exists; OriginalValue=$oldValue; OriginalKind=$oldKind; InstalledValue=$Value }
        $State.Registry = @($State.Registry) + @($record)
    } else { $record[0].InstalledValue = $Value }
    $prefix = ''
    foreach ($component in $Key.Split('\')) {
        if ($prefix) { $prefix += '\' }; $prefix += $component
        $existingKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($prefix)
        if ($existingKey) { $existingKey.Close() } elseif ($prefix -notin $State.CreatedKeys) { $State.CreatedKeys = @($State.CreatedKeys) + $prefix }
    }
    Save-LauncherState $State
    $keyObject = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Key)
    try { $keyObject.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String) } finally { $keyObject.Close() }
}
function Repair-LauncherEntries($State) {
    if (-not $State.Installed) { return }
    $dispatcher = Join-Path $State.Directory 'ProxyLauncher.exe'
    foreach ($path in @(Get-LauncherShortcutPaths $State.Application $State.Directory)) { Set-LauncherShortcut $State $path }
    foreach ($record in @($State.Shortcuts)) {
        if (-not (Test-Path -LiteralPath $record.Path)) { Set-LauncherShortcut $State $record.Path }
    }
    $protocolKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('antigravity\shell\open\command')
    try { $command = if ($protocolKey) { [string]$protocolKey.GetValue('') } else { '' } } finally { if ($protocolKey) { $protocolKey.Close() } }
    $redirected = Convert-LauncherCommand $command $State.Application $dispatcher
    if ($redirected) { Set-TrackedRegistryValue $State 'Software\Classes\antigravity\shell\open\command' '' $redirected }
    foreach ($runPath in @('Software\Microsoft\Windows\CurrentVersion\Run','Software\Microsoft\Windows\CurrentVersion\RunOnce')) {
        $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath)
        try {
            if ($runKey) {
                foreach ($name in $runKey.GetValueNames()) {
                    $redirected = Convert-LauncherCommand ([string]$runKey.GetValue($name)) $State.Application $dispatcher
                    if ($redirected) { Set-TrackedRegistryValue $State $runPath $name $redirected }
                }
            }
        } finally { if ($runKey) { $runKey.Close() } }
    }
}
function Restore-LauncherEntries($State) {
    # Mark inactive first: the guard checks this flag under the same mutex.
    $State.Installed = $false
    Save-LauncherState $State
    $dispatcher = Join-Path $State.Directory 'ProxyLauncher.exe'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($record in @($State.Shortcuts)) {
        if (Test-Path -LiteralPath $record.Path) {
            $link = $shell.CreateShortcut($record.Path)
            if ($link.TargetPath -ine $dispatcher -or $link.Arguments -cne $record.Arguments) { Write-Warning ('Preserving a separately changed shortcut: ' + $record.Path); continue }
        }
        if ($record.Existed) { Copy-Item -LiteralPath $record.Backup -Destination $record.Path -Force } elseif (Test-Path -LiteralPath $record.Path) { Remove-Item -LiteralPath $record.Path }
    }
    foreach ($record in @($State.Registry)) {
        $keyObject = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($record.Key, $true)
        try {
            if (-not $keyObject) { continue }
            if ([string]$keyObject.GetValue($record.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $record.InstalledValue) {
                Write-Warning ('Preserving a separately changed registry value: HKCU\' + $record.Key + '\' + $record.Name); continue
            }
            if ($record.Existed) { $keyObject.SetValue($record.Name, $record.OriginalValue, [Microsoft.Win32.RegistryValueKind]::$($record.OriginalKind)) } else { $keyObject.DeleteValue($record.Name, $false) }
        } finally { if ($keyObject) { $keyObject.Close() } }
    }
    foreach ($path in @($State.CreatedKeys | Sort-Object Length -Descending)) {
        $keyObject = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
        $empty = $false
        try { if ($keyObject) { $empty = $keyObject.ValueCount -eq 0 -and $keyObject.SubKeyCount -eq 0 } } finally { if ($keyObject) { $keyObject.Close() } }
        if ($empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($path, $false) }
    }
}

Export-ModuleMember -Function Read-LauncherState, Save-LauncherState, New-LauncherState, Get-LauncherMutexName, Convert-LauncherCommand, Get-LauncherShortcutPaths, Set-LauncherShortcut, Set-TrackedRegistryValue, Repair-LauncherEntries, Restore-LauncherEntries
