#!/usr/bin/env pwsh
#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#

[CmdletBinding()]
param(
    [switch]
    $Clean,

    [switch]
    $Bootstrap,

    [switch]
    $Test,

    [switch]
    $NoBuild,

    [switch]
    $Deploy,

    [string]
    $CoreToolsDir,

    [string]
    $Configuration = "Debug",

    [string]
    $BuildNumber = '0',

    [switch]
    $AddSBOM,

    [string]
    $SBOMUtilSASUrl,

    [string]
    [ValidateSet("7.2", "7.4")]
    $WorkerVersion
)

#Requires -Version 7.0

Import-Module "$PSScriptRoot/tools/helper.psm1" -Force

$PowerShellVersion = $null
$TargetFramework = $null
$DefaultPSWorkerVersion = '7.4'

if (-not $workerVersion)
{
    Write-Log "Worker version not specified. Setting workerVersion to '$DefaultPSWorkerVersion'"
    $workerVersion = $DefaultPSWorkerVersion
}

$PowerShellVersion = $WorkerVersion
Write-Log "Build worker version: $PowerShellVersion"

# Set target framework for 7.2 to net6.0 and for 7.4 to net7.0
$TargetFramework = ($PowerShellVersion -eq "7.2") ? 'net6.0' : 'net7.0'
Write-Log "Target framework: $TargetFramework"

function Get-FunctionsCoreToolsDir {
    if ($CoreToolsDir) {
        $CoreToolsDir
    } else {
        $funcPath = (Get-Command func).Source
        if (-not $funcPath) {
            throw 'Cannot find "func" command. Please install Azure Functions Core Tools: ' +
                  'see https://github.com/Azure/azure-functions-core-tools#installing for instructions'
        }

        # func may be just a symbolic link, so we need to follow it until we find the true location
        while ((((Get-Item $funcPath).Attributes) -band 'ReparsePoint') -ne 0) {
            $funcPath = (Get-Item $funcPath).Target
        }

        $funcParentDir = Split-Path -Path $funcPath -Parent

        if (-not (Test-Path -Path $funcParentDir/workers/powershell -PathType Container)) {
            throw 'Cannot find Azure Function Core Tools installation directory. ' +
                  'Please provide the path in the CoreToolsDir parameter.'
        }

        $funcParentDir
    }
}

function Install-SBOMUtil
{
    if ([string]::IsNullOrEmpty($SBOMUtilSASUrl))
    {
        throw "The `$SBOMUtilSASUrl parameter cannot be null or empty when specifying the `$AddSBOM switch"
    }

    $MANIFESTOOLNAME = "ManifestTool"
    Write-Log "Installing $MANIFESTOOLNAME..."

    $MANIFESTOOL_DIRECTORY = Join-Path $PSScriptRoot $MANIFESTOOLNAME
    Remove-Item -Recurse -Force $MANIFESTOOL_DIRECTORY -ErrorAction Ignore

    Invoke-RestMethod -Uri $SBOMUtilSASUrl -OutFile "$MANIFESTOOL_DIRECTORY.zip"
    Expand-Archive "$MANIFESTOOL_DIRECTORY.zip" -DestinationPath $MANIFESTOOL_DIRECTORY

    $dllName = "Microsoft.ManifestTool.dll"
    $manifestToolPath = "$MANIFESTOOL_DIRECTORY/$dllName"

    if (-not (Test-Path $manifestToolPath))
    {
        throw "$MANIFESTOOL_DIRECTORY does not contain '$dllName'"
    }

    Write-Log 'Done.'

    return $manifestToolPath
}

function Deploy-PowerShellWorker {
    $ErrorActionPreference = 'Stop'

    $powerShellWorkerDir = "$(Get-FunctionsCoreToolsDir)/workers/powershell/$PowerShellVersion"

    if (-not (Test-Path $powerShellWorkerDir))
    {
        Write-Log "Creating directory: '$powerShellWorkerDir'"
        New-Item -Path $powerShellWorkerDir -ItemType Directory -Force | Out-Null
    }

    Write-Log "Deploying worker to $powerShellWorkerDir..."

    if (-not $IsWindows) {
        sudo chmod -R a+w $powerShellWorkerDir
    }

    Remove-Item -Path $powerShellWorkerDir/* -Recurse -Force
    Copy-Item -Path "./src/bin/$Configuration/$TargetFramework/publish/*" `
        -Destination $powerShellWorkerDir -Recurse -Force

    Write-Log "Deployed worker to $powerShellWorkerDir"
}

# Bootstrap step
if ($Bootstrap.IsPresent) {
    Write-Log "Validate and install missing prerequisits for building ..."
    Install-Dotnet

    if (-not (Get-Module -Name PSDepend -ListAvailable)) {
        Write-Log -Warning "Module 'PSDepend' is missing. Installing 'PSDepend' ..."
        Install-Module -Name PSDepend -Scope CurrentUser -Force
    }
    if (-not (Get-Module -Name platyPS -ListAvailable)) {
        Write-Log -Warning "Module 'platyPS' is missing. Installing 'platyPS' ..."
        Install-Module -Name platyPS -Scope CurrentUser -Force
    }
}

# Clean step
if ($Clean.IsPresent) {
    Push-Location $PSScriptRoot
    git clean -fdX
    Pop-Location
}

# Common step required by both build and test
Find-Dotnet

# Build step
if (!$NoBuild.IsPresent) {
    if (-not (Get-Module -Name PSDepend -ListAvailable)) {
        throw "Cannot find the 'PSDepend' module. Please specify '-Bootstrap' to install build dependencies."
    }

    # Generate C# files for resources
    Start-ResGen

    # Generate csharp code from protobuf if needed
    New-gRPCAutoGenCode

    $requirements = "$PSScriptRoot/src/requirements.psd1"
    $modules = Import-PowerShellDataFile $requirements

    Write-Log "Install modules that are bundled with PowerShell Language worker, including"
    foreach ($entry in $modules.GetEnumerator()) {
        Write-Log -Indent "$($entry.Name) $($entry.Value.Version)"
    }

    Invoke-PSDepend -Path $requirements -Force

    Write-Log "Deleting fullclr folder from PackageManagement module if the folder exists ..."
    Get-Item "$PSScriptRoot/src/Modules/PackageManagement/1.1.7.0/fullclr" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    dotnet publish -c $Configuration "/p:BuildNumber=$BuildNumber" $PSScriptRoot

    if ($AddSBOM)
    {
        # Install manifest tool
        $manifestTool = Install-SBOMUtil
        Write-Log "manifestTool: $manifestTool "

        # Generate manifest
        $buildPath = "$PSScriptRoot/src/bin/$Configuration/$TargetFramework/publish"
        $telemetryFilePath = Join-Path $PSScriptRoot ((New-Guid).Guid + ".json")
        $packageName = "Microsoft.Azure.Functions.PowerShellWorker.nuspec"

        # Delete the manifest folder if it exists
        $manifestFolderPath = Join-Path $buildPath "_manifest"
        if (Test-Path $manifestFolderPath)
        {
            Remove-Item $manifestFolderPath -Recurse -Force -ErrorAction Ignore
        }

        Write-Log "Running: dotnet $manifestTool generate -BuildDropPath $buildPath -BuildComponentPath $buildPath -Verbosity Information -t $telemetryFilePath"
        & { dotnet $manifestTool generate -BuildDropPath $buildPath -BuildComponentPath $buildPath -Verbosity Information -t $telemetryFilePath -PackageName $packageName }
    }

    dotnet pack -c $Configuration "/p:BuildNumber=$BuildNumber" "$PSScriptRoot/package"
}

# Test step
if ($Test.IsPresent) {
    dotnet test "$PSScriptRoot/test/Unit"
    if ($LASTEXITCODE -ne 0) { throw "xunit tests failed." }
}

if ($Deploy.IsPresent) {
    Deploy-PowerShellWorker
}
