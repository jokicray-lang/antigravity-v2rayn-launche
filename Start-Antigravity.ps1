#Requires -Version 5.1
# SPDX-License-Identifier: MIT
# Select a reachable proxy and launch or forward Antigravity requests with that proxy.
<#
.SYNOPSIS
Launch Antigravity using a local v2rayN HTTP/mixed proxy.
.DESCRIPTION
Detects the running v2rayN runtime config. Sets process-only proxy variables and
Electron proxy flags, keeping local callbacks direct. Existing apps must be quit
first. Diagnose and DryRun do not launch or close Antigravity.
.EXAMPLE
.\Start-Antigravity.ps1 -ProxyPort 10809
.EXAMPLE
.\Start-Antigravity.ps1 -Diagnose -CheckNetwork
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 65535)][int]$ProxyPort = 0,
    [string]$ProxyHost = '127.0.0.1',
    [string]$V2rayNPath,
    [string]$AntigravityPath,
    [switch]$Diagnose,
    [switch]$CheckNetwork,
    [switch]$DryRun,
    [string[]]$AppArguments = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This launcher supports Windows only.'
    }
    Import-Module (Join-Path $PSScriptRoot 'AntigravityProxy.psm1') -Force -DisableNameChecking
    Write-Host 'Antigravity automatic proxy launcher 2.0.1'
    $installedConfigPath = Join-Path $PSScriptRoot 'launcher-config.json'
    if (Test-Path -LiteralPath $installedConfigPath) {
        $installedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
        if (-not $AntigravityPath -and (Test-Path -LiteralPath $installedConfig.AntigravityPath -PathType Leaf)) { $AntigravityPath = $installedConfig.AntigravityPath }
    }
    $carrier = [Environment]::GetEnvironmentVariable('ANTIGRAVITY_PROXY_ARGS_JSON', 'Process')
    if ($carrier) {
        if (-not $carrier.TrimStart().StartsWith('[')) { throw 'Invalid argument carrier.' }
        $decodedArguments = ConvertFrom-Json -InputObject $carrier
        # Windows PowerShell 5.1 emits a JSON array as one pipeline item.
        $AppArguments = @(foreach ($argument in $decodedArguments) { [string]$argument })
        [Environment]::SetEnvironmentVariable('ANTIGRAVITY_PROXY_ARGS_JSON', [System.Management.Automation.Language.NullString]::Value, 'Process')
    }
    if ($ProxyPort -gt 0) {
        $candidates = @(New-LocalProxyEndpoint -ProxyHost $ProxyHost -Port $ProxyPort)
        Write-Host 'Proxy source: explicit port'
    } else {
        if ($PSBoundParameters.ContainsKey('ProxyHost')) {
            throw '-ProxyHost requires an explicit -ProxyPort.'
        }
        $candidates = @(Get-LocalProxyCandidates -V2rayNPath $V2rayNPath)
        Write-Host 'Proxy sources: Windows settings, v2rayN, environment, common local ports'
    }
    try { $endpoint = Find-WorkingProxyEndpoint -Candidates $candidates -LocalOnly:$DryRun } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 3 }
    Write-Host ('Proxy: ' + $endpoint.Url)
    if ($DryRun) { Write-Host 'Proxy check: TCP only (preview)' } else { Write-Host 'Proxy check: HTTPS response received through the selected proxy' }

    $exe = Find-AntigravityExecutable -AntigravityPath $AntigravityPath
    $launchArguments = @(Get-AntigravityProxyArguments -Endpoint $endpoint)
    Write-Host ('Application: ' + $exe)
    Write-Host ('Arguments: ' + ($launchArguments -join ' '))

    if ($Diagnose -or $DryRun) {
        Write-Host ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
        Write-Host 'Child environment: HTTP_PROXY / HTTPS_PROXY / ALL_PROXY = the proxy above'
        Write-Host 'Child NO_PROXY: localhost,127.0.0.1,::1'
        Write-Host ('Forwarded argument count: ' + $AppArguments.Count)
    }
    if ($CheckNetwork) {
        $networkOk = $true
        foreach ($target in @(
            'https://accounts.google.com/.well-known/openid-configuration'
            'https://oauth2.googleapis.com/token'
            'https://daily-cloudcode-pa.googleapis.com/'
        )) {
            $result = Test-ProxyHttps -Endpoint $endpoint -Uri $target
            if ($result.Reachable) {
                Write-Host ('HTTPS response: {0} (HTTP {1}; sign-in not tested)' -f $result.Host, $result.StatusCode)
            } else {
                $networkOk = $false
                Write-Host ('HTTPS check failed: {0} ({1}, HTTP {2})' -f $result.Host, $result.Detail, $result.StatusCode) -ForegroundColor Yellow
            }
        }
        if (-not $networkOk) { exit 4 }
    }
    if ($Diagnose -or $DryRun) {
        Write-Host 'Finished without launching or closing Antigravity.'
        exit 0
    }

    # Preserve callbacks/open-file requests even when Electron is already running.
    $sessionId = (Get-Process -Id $PID).SessionId
    $running = @(Get-Process -Name 'Antigravity', 'Antigravity IDE' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId })
    if ($running.Count -gt 0) {
        Write-Host 'An existing instance will receive this request. A new proxy environment takes effect after that instance fully exits.'
    }
    $allArguments = @($launchArguments) + @($AppArguments)
    $argumentLine = (@($allArguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $started = Invoke-WithProxyEnvironment -Endpoint $endpoint -Action {
        Start-Process -FilePath $exe -ArgumentList $argumentLine -PassThru -ErrorAction Stop
    }
    Write-Host ('Started Antigravity (PID {0}). The calling shell environment was restored.' -f $started.Id)
    Write-Host 'Complete Google sign-in if requested. The external browser must also be able to reach Google.'
    Write-Host 'A successful process launch does not prove that the UI or authentication has recovered.'
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
