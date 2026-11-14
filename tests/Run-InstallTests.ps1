#Requires -Version 5.1
# SPDX-License-Identifier: MIT
# Regression checks for shortcut/registry restoration and dispatcher argument forwarding.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'AntigravityProxy.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'LauncherInstall.psm1') -Force -DisableNameChecking
$script:passed = 0; $script:failed = 0
function Assert-Equal($Actual,$Expected) { if ($Actual -cne $Expected) { throw ('Expected [{0}], got [{1}]' -f $Expected,$Actual) } }
function Assert-True($Value) { if (-not $Value) { throw 'Expected true.' } }
function Run-Test([string]$Name,[scriptblock]$Action) { try { & $Action; $script:passed++; Write-Host ('PASS '+$Name) } catch { $script:failed++; Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) -ForegroundColor Red } }
$fixtureName = 'antigravity-install-tests-' + [guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$fixture = Join-Path $tempBase $fixtureName
[void][IO.Directory]::CreateDirectory($fixture)
$registryTestRoot = 'Software\AntigravityLauncherTest-'+[guid]::NewGuid().ToString('N')
$shell = New-Object -ComObject WScript.Shell
try {
    Run-Test 'System proxy parser honors protocol maps and local addresses only' {
        $endpoints = @(ConvertFrom-SystemProxy 'http=127.0.0.1:10809;https=[::1]:7890;socks=127.0.0.1:10808')
        Assert-Equal $endpoints.Count 2
        Assert-Equal $endpoints[0].Port 10809
        Assert-Equal $endpoints[1].Host '::1'
        Assert-Equal @(ConvertFrom-SystemProxy 'http://user:password@127.0.0.1:80').Count 0
        Assert-Equal @(ConvertFrom-SystemProxy 'http://192.0.2.1:80').Count 0
    }
    Run-Test 'Unusable candidates are skipped before selecting a working proxy' {
        $candidates = @((New-LocalProxyEndpoint -Port 7890),(New-LocalProxyEndpoint -Port 10809))
        $selected = Find-WorkingProxyEndpoint -Candidates $candidates -Probe { param($candidate) $candidate.Port -eq 10809 }
        Assert-Equal $selected.Port 10809
    }
    Run-Test 'Protocol and autorun arguments survive command redirection' {
        Assert-Equal (Convert-LauncherCommand '"C:\Apps\Antigravity.exe" --open-url "%1"' 'C:\Apps\Antigravity.exe' 'C:\Proxy Launcher\ProxyLauncher.exe') '"C:\Proxy Launcher\ProxyLauncher.exe" --open-url "%1"'
        Assert-True ($null -eq (Convert-LauncherCommand '"C:\Other.exe" "%1"' 'C:\Apps\Antigravity.exe' 'C:\Proxy.exe'))
    }
    $app = Join-Path $fixture 'Antigravity.exe'
    [IO.File]::WriteAllText($app,'')
    $stateRoot = Join-Path $fixture 'installed launcher'
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $state = New-LauncherState $stateRoot $app
    $linkPath = Join-Path $fixture 'original shortcut.lnk'
    $link = $shell.CreateShortcut($linkPath); $link.TargetPath=$app; $link.Arguments='--new-window "a b"'; $link.Description='Keep original metadata'; $link.Save()
    $originalHash = (Get-FileHash -LiteralPath $linkPath).Hash
    Run-Test 'Shortcut rewrites preserve arguments and retain one original backup' {
        Set-LauncherShortcut $state $linkPath
        Set-LauncherShortcut $state $linkPath
        Assert-Equal $state.Shortcuts.Count 1
        $rewritten = $shell.CreateShortcut($linkPath)
        Assert-Equal $rewritten.TargetPath (Join-Path $stateRoot 'ProxyLauncher.exe')
        Assert-Equal $rewritten.Arguments '--new-window "a b"'
        Assert-Equal $rewritten.Description 'Keep original metadata'
    }
    Run-Test 'Updater-reset shortcut is repaired without overwriting the original backup' {
        $link = $shell.CreateShortcut($linkPath); $link.TargetPath=$app; $link.Save()
        Set-LauncherShortcut $state $linkPath
        Assert-Equal (Get-FileHash -LiteralPath $state.Shortcuts[0].Backup).Hash $originalHash
        Assert-Equal ($shell.CreateShortcut($linkPath)).TargetPath (Join-Path $stateRoot 'ProxyLauncher.exe')
    }
    Run-Test 'Uninstall restores exact original shortcut bytes' {
        Restore-LauncherEntries $state
        Assert-Equal (Get-FileHash -LiteralPath $linkPath).Hash $originalHash
        Assert-Equal (Read-LauncherState $stateRoot).Installed $false
    }
    Run-Test 'New shortcut is removed on uninstall; other shortcuts are not touched' {
        $state = New-LauncherState $stateRoot $app
        $newLink = Join-Path $fixture 'created.lnk'
        Set-LauncherShortcut $state $newLink
        Restore-LauncherEntries $state
        Assert-True (-not (Test-Path -LiteralPath $newLink))
        Assert-True (Test-Path -LiteralPath $linkPath)
    }
    Run-Test 'Registry original data and value kind round-trip through saved manifest' {
        $testKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryTestRoot)
        $testKey.SetValue('handler','%LOCALAPPDATA%\original.exe',[Microsoft.Win32.RegistryValueKind]::ExpandString); $testKey.Close()
        $state = New-LauncherState $stateRoot $app
        Set-TrackedRegistryValue $state $registryTestRoot 'handler' 'C:\ProxyLauncher.exe'
        $state = Read-LauncherState $stateRoot
        Restore-LauncherEntries $state
        $testKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryTestRoot)
        try {
            Assert-Equal ([string]$testKey.GetValueKind('handler')) 'ExpandString'
            Assert-Equal $testKey.GetValue('handler',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) '%LOCALAPPDATA%\original.exe'
        } finally { $testKey.Close() }
    }
    Run-Test 'Registry values created by the installer are removed, sibling values retained' {
        $state = New-LauncherState $stateRoot $app
        Set-TrackedRegistryValue $state $registryTestRoot 'added' 'launcher'
        Restore-LauncherEntries $state
        $testKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryTestRoot)
        try { Assert-True ('added' -notin $testKey.GetValueNames()); Assert-True ('handler' -in $testKey.GetValueNames()) } finally { $testKey.Close() }
    }
    Run-Test 'Uninstall preserves registry data independently changed after installation' {
        $state = New-LauncherState $stateRoot $app
        Set-TrackedRegistryValue $state $registryTestRoot 'changed' 'launcher'
        $testKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryTestRoot,$true); $testKey.SetValue('changed','user-changed'); $testKey.Close()
        Restore-LauncherEntries $state -WarningAction SilentlyContinue
        $testKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryTestRoot)
        try { Assert-Equal $testKey.GetValue('changed') 'user-changed' } finally { $testKey.Close() }
    }
    Run-Test 'Built dispatcher round-trips URI, Unicode, quotes, empty and trailing-slash arguments' {
        $dispatchRoot = Join-Path $fixture ('dispatcher [' + [char]0x6D4B + ']')
        [void][IO.Directory]::CreateDirectory($dispatchRoot)
        $dispatchExe = Join-Path $dispatchRoot 'ProxyLauncher.exe'
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Build-Dispatcher.ps1') -OutputPath $dispatchExe
        Assert-Equal $LASTEXITCODE 0
        '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "received.json"), $env:ANTIGRAVITY_PROXY_ARGS_JSON, [Text.Encoding]::UTF8)' | Set-Content -LiteralPath (Join-Path $dispatchRoot 'Start-Antigravity.ps1') -Encoding ASCII
        $expected = @('antigravity://callback?code=test&state=x%20y','a b','quote"value','tail\','',([string][char]0x6D4B+[char]0x8BD5),'literal%TEMP%')
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$dispatchExe; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.Arguments = (@($expected | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
        $process = [Diagnostics.Process]::Start($start)
        try { if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'Fixture dispatcher timed out.' }; Assert-Equal $process.ExitCode 0 } finally { $process.Dispose() }
        $actual = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $dispatchRoot 'received.json') -Raw)
        Assert-Equal $actual.Count $expected.Count
        for ($i=0; $i -lt $expected.Count; $i++) { Assert-Equal $actual[$i] $expected[$i] }
    }
} finally {
    # Only delete the uniquely named fixture key created by this test run.
    if ($registryTestRoot -match '^Software\\AntigravityLauncherTest-[0-9a-f]{32}$') { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryTestRoot,$false) }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -eq $fixtureName) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host ('Results: {0} passed, {1} failed. PowerShell {2}' -f $script:passed,$script:failed,$PSVersionTable.PSVersion)
if ($script:failed -gt 0) { exit 1 }
