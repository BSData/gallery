#!/usr/bin/env pwsh

[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [string]$RegistryPath,
  
  [Parameter(Mandatory)]
  [string]$IndexPath,

  [Parameter(Mandatory)]
  [string]$GalleryJsonPath,

  [Parameter(Mandatory)]
  [string]$Token
)

#Requires -Version 7
#Requires -Module powershell-yaml

Import-Module $PSScriptRoot/lib/BsdataGallery -Verbose:$false

# read settings
$settings = Get-Content (Join-Path $RegistryPath settings.yml) -Raw | ConvertFrom-Yaml

$registryArgs = @{
  RegistrationsPath = Join-Path $RegistryPath $settings.registrations.path
  IndexPath         = $IndexPath
  Token             = $Token
}
$null = Update-BsdataGalleryIndex @registryArgs

$galleryCatpkgArgs = @{
  IndexPath       = $IndexPath
  GallerySettings = $settings.gallery
}
Get-BsdataGalleryCatpkg @galleryCatpkgArgs
| ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii
| Set-Content $GalleryJsonPath -Force
