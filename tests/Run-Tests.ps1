#Requires -Version 5.1
# SPDX-License-Identifier: MIT
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'AntigravityProxy.psm1') -Force -DisableNameChecking
$script:passed = 0
$script:failed = 0

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw ('Expected [{0}], got [{1}]' -f $Expected, $Actual) }
}
function Assert-True($Value) { if (-not $Value) { throw 'Expected true.' } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '*') {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw ('Unexpected error: ' + $_.Exception.Message) }
        return
    }
    throw 'Expected an exception.'
}
function Run-Test([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host ('PASS ' + $Name) } catch {
        $script:failed++; Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

$fixtureName = 'antigravity-launcher-tests-' + [guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoot = Join-Path $tempBase $fixtureName
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$configPath = Join-Path $fixtureRoot 'config.json'
$endpoint = New-LocalProxyEndpoint -Port 10809
$envNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
$originalEnvironment = @{}
foreach ($name in $envNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    Run-Test 'IPv4 loopback and wildcard normalization' {
        Assert-Equal $endpoint.Url 'http://127.0.0.1:10809'
        Assert-Equal (New-LocalProxyEndpoint -ProxyHost '0.0.0.0' -Port 7890).Host '127.0.0.1'
        Assert-Equal (New-LocalProxyEndpoint -ProxyHost 'localhost' -Port 7890).Host '127.0.0.1'
    }
    Run-Test 'IPv6 loopback URL is bracketed' {
        Assert-Equal (New-LocalProxyEndpoint -ProxyHost '::' -Port 7890).Url 'http://[::1]:7890'
        Assert-Equal (New-LocalProxyEndpoint -ProxyHost '[::1]' -Port 7890).Host '::1'
    }
    Run-Test 'External proxy addresses and invalid ports are rejected' {
        Assert-Throws { New-LocalProxyEndpoint -ProxyHost '192.0.2.1' -Port 80 }
        Assert-Throws { New-LocalProxyEndpoint -ProxyHost 'example.invalid' -Port 80 }
        Assert-Throws { New-LocalProxyEndpoint -Port 0 }
        Assert-Throws { New-LocalProxyEndpoint -Port 65536 }
    }
    Run-Test 'Xray mixed inbound selected; SOCKS and external listeners ignored' {
        '{"inbounds":[{"protocol":"socks","port":10808},{"protocol":"mixed","listen":"127.0.0.1","port":10809},{"protocol":"http","listen":"192.0.2.1","port":9999}]}' | Set-Content -LiteralPath $configPath -Encoding UTF8
        $found = @(Read-V2rayProxyEndpoint -ConfigPath $configPath)
        Assert-Equal $found.Count 1
        Assert-Equal $found[0].Port 10809
    }
    Run-Test 'Sing-box listen_port and IPv6 wildcard supported' {
        '{"inbounds":[{"type":"mixed","listen":"::","listen_port":10809}]}' | Set-Content -LiteralPath $configPath -Encoding UTF8
        Assert-Equal (Read-V2rayProxyEndpoint -ConfigPath $configPath).Url 'http://[::1]:10809'
    }
    Run-Test 'Missing properties and invalid ports produce no candidates' {
        '{"inbounds":[{},{"protocol":"http","port":"bad"},{"protocol":"http","port":65536}]}' | Set-Content -LiteralPath $configPath -Encoding UTF8
        Assert-Equal @(Read-V2rayProxyEndpoint -ConfigPath $configPath).Count 0
        '{}' | Set-Content -LiteralPath $configPath -Encoding UTF8
        Assert-Equal @(Read-V2rayProxyEndpoint -ConfigPath $configPath).Count 0
    }
    Run-Test 'Malformed config error does not echo private content' {
        'PRIVATE-SENTINEL-invalid-json' | Set-Content -LiteralPath $configPath -Encoding UTF8
        Assert-Throws { Read-V2rayProxyEndpoint -ConfigPath $configPath } 'Cannot parse v2rayN runtime config*'
    }
    $unicodeLabel = [string][char]0x6D4B + [char]0x8BD5
    $v2rayFixture = Join-Path $fixtureRoot ('proxy fixture [1] ' + $unicodeLabel)
    [void][IO.Directory]::CreateDirectory((Join-Path $v2rayFixture 'binConfigs'))
    $runtimePath = Join-Path $v2rayFixture 'binConfigs\config.json'
    Run-Test 'Runtime detection accepts spaces, brackets, and Unicode paths' {
        '{"inbounds":[{"protocol":"mixed","listen":"127.0.0.1","port":10809}]}' | Set-Content -LiteralPath $runtimePath -Encoding UTF8
        Assert-Equal (Find-V2rayProxyEndpoint -V2rayNPath $v2rayFixture).Port 10809
    }
    Run-Test 'Ambiguous proxy configuration requires explicit selection' {
        '{"inbounds":[{"protocol":"mixed","port":10809},{"protocol":"http","port":10810}]}' | Set-Content -LiteralPath $runtimePath -Encoding UTF8
        Assert-Throws { Find-V2rayProxyEndpoint -V2rayNPath $v2rayFixture } 'Multiple HTTP/mixed proxies*'
    }
    Run-Test 'Pure SOCKS proxy is not silently treated as HTTP' {
        '{"inbounds":[{"protocol":"socks","port":10808}]}' | Set-Content -LiteralPath $runtimePath -Encoding UTF8
        Assert-Throws { Find-V2rayProxyEndpoint -V2rayNPath $v2rayFixture } 'No local HTTP/mixed proxy*'
    }
    $exeFixture = Join-Path $v2rayFixture 'Antigravity.exe'
    [IO.File]::WriteAllText($exeFixture, '')
    Run-Test 'Explicit application path is literal and must be an expected executable' {
        Assert-Equal (Find-AntigravityExecutable -AntigravityPath $exeFixture) $exeFixture
        $otherExe = Join-Path $fixtureRoot 'other.exe'
        [IO.File]::WriteAllText($otherExe, '')
        Assert-Throws { Find-AntigravityExecutable -AntigravityPath $otherExe } '*must point to Antigravity.exe*'
        Assert-Throws { Find-AntigravityExecutable -AntigravityPath $fixtureRoot }
    }
    Run-Test 'Environment restored after success, overriding stale bypass rules' {
        [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://old.invalid:9', 'Process')
        [Environment]::SetEnvironmentVariable('NO_PROXY', '*', 'Process')
        $capture = Invoke-WithProxyEnvironment -Endpoint $endpoint -Action {
            [pscustomobject]@{ Http = $env:HTTP_PROXY; Https = $env:HTTPS_PROXY; All = $env:ALL_PROXY; Bypass = $env:NO_PROXY }
        }
        Assert-Equal $capture.Http $endpoint.Url
        Assert-Equal $capture.Https $endpoint.Url
        Assert-Equal $capture.All $endpoint.Url
        Assert-Equal $capture.Bypass 'localhost,127.0.0.1,::1'
        Assert-Equal $env:HTTP_PROXY 'http://old.invalid:9'
        Assert-Equal $env:NO_PROXY '*'
    }
    Run-Test 'Environment restored when launch action throws' {
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', [System.Management.Automation.Language.NullString]::Value, 'Process')
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process'))
        Assert-Throws { Invoke-WithProxyEnvironment -Endpoint $endpoint -Action { throw 'simulated launch failure' } } 'simulated launch failure'
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process'))
        Assert-Equal $env:HTTP_PROXY 'http://old.invalid:9'
    }
    Run-Test 'Absent environment remains absent after successful launch action' {
        [Environment]::SetEnvironmentVariable('ALL_PROXY', [System.Management.Automation.Language.NullString]::Value, 'Process')
        Invoke-WithProxyEnvironment -Endpoint $endpoint -Action { Assert-Equal $env:ALL_PROXY 'http://127.0.0.1:10809' }
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable('ALL_PROXY', 'Process'))
    }
    $enginePath = (Get-Process -Id $PID).Path
    Run-Test 'Real child process inherits proxy environment; caller variables remain accessible' {
        $childScript = Join-Path $fixtureRoot 'child check.ps1'
        '[pscustomobject]@{Http=$env:HTTP_PROXY;Https=$env:HTTPS_PROXY;All=$env:ALL_PROXY;Bypass=$env:NO_PROXY} | ConvertTo-Json -Compress' | Set-Content -LiteralPath $childScript -Encoding ASCII
        $childOutput = Invoke-WithProxyEnvironment -Endpoint $endpoint -Action {
            & $enginePath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childScript
            if ($LASTEXITCODE -ne 0) { throw 'Child process failed.' }
        }
        $childEnvironment = ($childOutput -join '') | ConvertFrom-Json
        Assert-Equal $childEnvironment.Http $endpoint.Url
        Assert-Equal $childEnvironment.Https $endpoint.Url
        Assert-Equal $childEnvironment.All $endpoint.Url
        Assert-Equal $childEnvironment.Bypass 'localhost,127.0.0.1,::1'
        Assert-Equal $env:HTTP_PROXY 'http://old.invalid:9'
    }
    Run-Test 'Electron gets two arguments including loopback bypass' {
        $arguments = @(Get-AntigravityProxyArguments -Endpoint $endpoint)
        Assert-Equal $arguments.Count 2
        Assert-Equal $arguments[0] '--proxy-server=http://127.0.0.1:10809'
        Assert-Equal $arguments[1] '--proxy-bypass-list=localhost;127.0.0.1;[::1]'
    }
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $localEndpoint = New-LocalProxyEndpoint -Port $listener.LocalEndpoint.Port
    try {
        Run-Test 'Open local port is reachable' { Assert-True (Test-ProxyTcpPort -Endpoint $localEndpoint) }
        Run-Test 'DryRun works in a subprocess without executing the application fixture' {
            $entryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-Antigravity.ps1'
            $output = & $enginePath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entryScript -ProxyPort $localEndpoint.Port -AntigravityPath $exeFixture -DryRun
            Assert-Equal $LASTEXITCODE 0
            Assert-True (($output -join "`n") -like '*Finished without launching or closing Antigravity.*')
        }
        Run-Test 'Real entry script decodes each forwarded argument separately' {
            $savedCarrier = [Environment]::GetEnvironmentVariable('ANTIGRAVITY_PROXY_ARGS_JSON','Process')
            try {
                [Environment]::SetEnvironmentVariable('ANTIGRAVITY_PROXY_ARGS_JSON','["antigravity://callback?code=test&state=x%20y","a b","quote\"value","tail\\","","unicode","literal%TEMP%"]','Process')
                $entryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-Antigravity.ps1'
                $output = & $enginePath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entryScript -ProxyPort $localEndpoint.Port -AntigravityPath $exeFixture -DryRun
                Assert-Equal $LASTEXITCODE 0
                Assert-True (($output -join "`n") -like '*Forwarded argument count: 7*')
            } finally {
                if ($null -eq $savedCarrier) { $savedCarrier = [System.Management.Automation.Language.NullString]::Value }
                [Environment]::SetEnvironmentVariable('ANTIGRAVITY_PROXY_ARGS_JSON',$savedCarrier,'Process')
            }
        }
    } finally { $listener.Stop() }
    Run-Test 'Closed local port is rejected' { Assert-True (-not (Test-ProxyTcpPort -Endpoint $localEndpoint -TimeoutMs 500)) }
    Run-Test 'HTTPS check cannot falsely succeed through a closed proxy; TLS settings restored' {
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        $result = Test-ProxyHttps -Endpoint $localEndpoint -Uri 'https://example.invalid/' -TimeoutSeconds 1
        Assert-True (-not $result.Reachable)
        Assert-Equal ([Net.ServicePointManager]::SecurityProtocol) $previousTls
    }
} finally {
    foreach ($name in $envNames) {
        if ($null -eq $originalEnvironment[$name]) {
            [Environment]::SetEnvironmentVariable($name, [System.Management.Automation.Language.NullString]::Value, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
        }
    }
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedFixture) -eq $fixtureName) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    } else { throw 'Refusing to clean an unexpected fixture directory.' }
}
Write-Host ('Results: {0} passed, {1} failed. PowerShell {2}' -f $script:passed, $script:failed, $PSVersionTable.PSVersion)
if ($script:failed -gt 0) { exit 1 }
exit 0
