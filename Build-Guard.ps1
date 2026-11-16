#Requires -Version 5.1
# SPDX-License-Identifier: MIT
# Build the windowless entry-maintenance host with the system .NET Framework.
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Build with Windows PowerShell 5.1.' }
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
try {
    $parameters = New-Object CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable = $true
    $parameters.GenerateInMemory = $false
    $parameters.OutputAssembly = [IO.Path]::GetFullPath($OutputPath)
    $parameters.CompilerOptions = '/target:winexe /optimize'
    foreach ($assembly in @('System.dll','System.Core.dll')) { [void]$parameters.ReferencedAssemblies.Add($assembly) }
    $result = $provider.CompileAssemblyFromSource($parameters, [string[]]@([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GuardLauncher.cs'))))
    $errors = @($result.Errors | Where-Object { -not $_.IsWarning })
    if ($errors.Count -gt 0) { throw ('Guard compilation failed: ' + (($errors | ForEach-Object { $_.ErrorText }) -join '; ')) }
} finally { $provider.Dispose() }
