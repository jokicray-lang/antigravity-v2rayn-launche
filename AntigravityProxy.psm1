# SPDX-License-Identifier: MIT
Set-StrictMode -Version 2.0

function Get-OptionalProperty {
    param($InputObject, [string]$Name)
    if ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]) {
        return $InputObject.$Name
    }
}

function New-LocalProxyEndpoint {
    [CmdletBinding()]
    param(
        [string]$ProxyHost = '127.0.0.1',
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )
    $address = $ProxyHost.Trim().Trim('[', ']')
    switch ($address) {
        'localhost' { $address = '127.0.0.1' }
        '0.0.0.0'   { $address = '127.0.0.1' }
        '::'        { $address = '::1' }
    }
    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($address, [ref]$parsedAddress) -or
        -not [Net.IPAddress]::IsLoopback($parsedAddress)) {
        throw 'Only local loopback HTTP/mixed proxies are supported.'
    }
    $address = $parsedAddress.ToString()
    $uriHost = $address
    if ($address.Contains(':')) { $uriHost = '[' + $address + ']' }
    [pscustomobject]@{ Host = $address; Port = $Port; Url = "http://${uriHost}:$Port" }
}

function Read-V2rayProxyEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Never echo config contents: they can contain subscription credentials.
        throw 'Cannot parse v2rayN runtime config. Specify -ProxyPort explicitly.'
    }
    foreach ($inbound in @(Get-OptionalProperty $config 'inbounds')) {
        $protocol = Get-OptionalProperty $inbound 'protocol'
        if (-not $protocol) { $protocol = Get-OptionalProperty $inbound 'type' }
        if ($protocol -notin @('http', 'mixed')) { continue }
        $portValue = Get-OptionalProperty $inbound 'port'
        if (-not $portValue) { $portValue = Get-OptionalProperty $inbound 'listen_port' }
        $listen = Get-OptionalProperty $inbound 'listen'
        if (-not $listen) { $listen = '127.0.0.1' }
        $portNumber = 0
        if (-not [int]::TryParse([string]$portValue, [ref]$portNumber) -or
            $portNumber -lt 1 -or $portNumber -gt 65535) { continue }
        try { New-LocalProxyEndpoint -ProxyHost $listen -Port $portNumber } catch { continue }
    }
}

function Find-V2rayProxyEndpoint {
    [CmdletBinding()]
    param([string]$V2rayNPath, [switch]$All)
    $roots = @()
    if ($V2rayNPath) {
        $resolved = (Resolve-Path -LiteralPath $V2rayNPath -ErrorAction Stop).ProviderPath
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { $resolved = Split-Path -Parent $resolved }
        $roots = @($resolved)
    } else {
        foreach ($process in @(Get-Process -Name 'v2rayN' -ErrorAction SilentlyContinue)) {
            try { if ($process.Path) { $roots += Split-Path -Parent $process.Path } } catch {}
        }
        if ($roots.Count -eq 0) {
            foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA)) {
                if ($base) { $roots += Join-Path $base 'v2rayN' }
            }
            if ($env:USERPROFILE) { $roots += Join-Path $env:USERPROFILE 'scoop\apps\v2rayn\current' }
        }
    }
    $endpoints = @(
        foreach ($root in @($roots | Select-Object -Unique)) {
            # Read the runtime protocol, not the sometimes misleading GUI label.
            Read-V2rayProxyEndpoint -ConfigPath (Join-Path $root 'binConfigs\config.json')
        }
    )
    $endpoints = @($endpoints | Sort-Object Url -Unique)
    if ($All) { return $endpoints }
    if ($endpoints.Count -eq 0) {
        throw 'No local HTTP/mixed proxy found. Start v2rayN, or specify -ProxyPort and optionally -V2rayNPath.'
    }
    if ($endpoints.Count -gt 1) {
        throw 'Multiple HTTP/mixed proxies found. Specify the intended -ProxyPort explicitly.'
    }
    return $endpoints[0]
}

function Find-AntigravityExecutable {
    [CmdletBinding()]
    param([string]$AntigravityPath)
    if ($AntigravityPath) {
        $resolved = (Resolve-Path -LiteralPath $AntigravityPath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
            [IO.Path]::GetFileName($resolved) -notin @('Antigravity.exe', 'Antigravity IDE.exe')) {
            throw '-AntigravityPath must point to Antigravity.exe or Antigravity IDE.exe.'
        }
        return $resolved
    }
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE\Antigravity IDE.exe'
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $candidates += Join-Path $base 'Antigravity\Antigravity.exe'
            $candidates += Join-Path $base 'Antigravity IDE\Antigravity IDE.exe'
        }
    }
    foreach ($registryPath in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue)) {
            if ((Get-OptionalProperty $entry 'DisplayName') -notmatch '(?i)^(Google\s+)?Antigravity') { continue }
            $icon = Get-OptionalProperty $entry 'DisplayIcon'
            if ($icon) {
                $icon = ([Environment]::ExpandEnvironmentVariables([string]$icon) -replace ',\s*-?\d+\s*$','').Trim().Trim('"')
                if ([IO.Path]::GetFileName($icon) -in @('Antigravity.exe','Antigravity IDE.exe')) { $candidates += $icon }
            }
            $location = Get-OptionalProperty $entry 'InstallLocation'
            if ($location) {
                $location = [Environment]::ExpandEnvironmentVariables([string]$location).Trim().Trim('"')
                $candidates += Join-Path $location 'Antigravity.exe'
                $candidates += Join-Path $location 'Antigravity IDE.exe'
            }
        }
    }
    foreach ($process in @(Get-Process -Name 'Antigravity', 'Antigravity IDE' -ErrorAction SilentlyContinue)) {
        try { if ($process.Path) { $candidates += $process.Path } } catch {}
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'Antigravity was not found. Specify -AntigravityPath with its full executable path.'
}

function Test-ProxyTcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint,
        [ValidateRange(100, 30000)][int]$TimeoutMs = 2000
    )
    $client = New-Object Net.Sockets.TcpClient
    $pending = $null
    try {
        $pending = $client.BeginConnect($Endpoint.Host, $Endpoint.Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($pending)
        return $client.Connected
    } catch { return $false } finally {
        $client.Close()
        if ($null -ne $pending) { $pending.AsyncWaitHandle.Close() }
    }
}

function Test-ProxyHttps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 10
    )
    $response = $null
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Proxy = New-Object Net.WebProxy($Endpoint.Url, $true)
        $request.Proxy.Credentials = $null
        $request.AllowAutoRedirect = $false
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.UserAgent = 'Antigravity-v2rayN-Launcher/1.0'
        try {
            $response = $request.GetResponse()
        } catch [Net.WebException] {
            $response = $_.Exception.Response
            if ($null -eq $response) {
                return [pscustomobject]@{ Host = $Uri.Host; Reachable = $false; StatusCode = $null; Detail = [string]$_.Exception.Status }
            }
        }
        $status = [int]$response.StatusCode
        # A 401/403/404/405 proves an HTTP response, not successful sign-in.
        $reachable = $status -ge 200 -and $status -lt 500 -and $status -ne 407
        [pscustomobject]@{ Host = $Uri.Host; Reachable = $reachable; StatusCode = $status; Detail = 'HTTP response only; authentication was not tested.' }
    } catch {
        [pscustomobject]@{ Host = $Uri.Host; Reachable = $false; StatusCode = $null; Detail = $_.Exception.GetType().Name }
    } finally {
        if ($null -ne $response) { $response.Close() }
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
    }
}

function Get-AntigravityProxyArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Endpoint)
    @(
        '--proxy-server=' + $Endpoint.Url
        '--proxy-bypass-list=localhost;127.0.0.1;[::1]'
    )
}

function Invoke-WithProxyEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    # The child inherits these process-only values; finally restores the caller.
    $values = @{
        HTTP_PROXY = $Endpoint.Url
        HTTPS_PROXY = $Endpoint.Url
        ALL_PROXY = $Endpoint.Url
        NO_PROXY = 'localhost,127.0.0.1,::1'
    }
    $saved = @{}
    foreach ($name in $values.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process') }
        & $Action
    } finally {
        foreach ($name in $values.Keys) {
            # PowerShell 7.5+ distinguishes an empty value from an absent one.
            # NullString prevents the binder from converting null into "".
            if ($null -eq $saved[$name]) {
                [Environment]::SetEnvironmentVariable($name, [System.Management.Automation.Language.NullString]::Value, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
            }
        }
    }
}

function ConvertFrom-SystemProxy {
    param([string]$ProxyServer)
    foreach ($part in @($ProxyServer -split ';')) {
        $value = $part.Trim()
        if (-not $value) { continue }
        if ($value -match '^(?<scheme>[^=]+)=(?<address>.+)$') {
            if ($Matches.scheme -notin @('http','https')) { continue }
            $value = $Matches.address
        }
        if ($value -notmatch '^[a-z]+://') { $value = 'http://' + $value }
        $proxyUri = $null
        if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$proxyUri)) { continue }
        if ($proxyUri.Scheme -ne 'http' -or $proxyUri.UserInfo -or $proxyUri.Query -or $proxyUri.Fragment -or $proxyUri.AbsolutePath -ne '/') { continue }
        try { New-LocalProxyEndpoint -ProxyHost $proxyUri.Host -Port $proxyUri.Port } catch { continue }
    }
}

function Get-LocalProxyCandidates {
    param([string]$V2rayNPath)
    $candidates = @()
    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ((Get-OptionalProperty $settings 'ProxyEnable') -eq 1) {
        $candidates += @(ConvertFrom-SystemProxy (Get-OptionalProperty $settings 'ProxyServer'))
    }
    try { $candidates += @(Find-V2rayProxyEndpoint -V2rayNPath $V2rayNPath -All) } catch { Write-Verbose $_.Exception.Message }
    foreach ($variable in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')) {
        $candidates += @(ConvertFrom-SystemProxy ([Environment]::GetEnvironmentVariable($variable, 'Process')))
    }
    foreach ($port in @(7890,7897,7899,7891,10809,10808,10811,1080,8888,2080)) {
        $candidates += New-LocalProxyEndpoint -Port $port
    }
    $seen = @{}
    foreach ($candidate in $candidates) {
        if (-not $seen.ContainsKey($candidate.Url)) { $seen[$candidate.Url] = $true; $candidate }
    }
}

function Find-WorkingProxyEndpoint {
    [CmdletBinding()]
    param([object[]]$Candidates, [switch]$LocalOnly, [scriptblock]$Probe)
    foreach ($candidate in $Candidates) {
        if ($Probe) { $usable = & $Probe $candidate } else {
            $usable = Test-ProxyTcpPort -Endpoint $candidate -TimeoutMs 500
            if ($usable -and -not $LocalOnly) {
                $usable = (Test-ProxyHttps -Endpoint $candidate -Uri 'https://oauth2.googleapis.com/' -TimeoutSeconds 4).Reachable
            }
        }
        if ($usable) { return $candidate }
    }
    throw 'No usable local HTTP/mixed proxy found. Start your proxy client and check its node, routing, or port.'
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    # Quote for CreateProcess/CommandLineToArgvW, never for cmd.exe or Invoke-Expression.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
        } else { [void]$builder.Append(('\' * $slashes)) }
        [void]$builder.Append($character)
        $slashes = 0
    }
    [void]$builder.Append(('\' * ($slashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

Export-ModuleMember -Function New-LocalProxyEndpoint, Read-V2rayProxyEndpoint, Find-V2rayProxyEndpoint, Find-AntigravityExecutable, Test-ProxyTcpPort, Test-ProxyHttps, Get-AntigravityProxyArguments, Invoke-WithProxyEnvironment, ConvertFrom-SystemProxy, Get-LocalProxyCandidates, Find-WorkingProxyEndpoint, ConvertTo-WindowsArgument
