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

function GetIndexHashHashtable {
  return Get-ChildItem $IndexPath *.catpkg.yml
  | Get-FileHash -Algorithm SHA256
  | ForEach-Object -Begin { $out = @{} } -Process {
    $out[$_.Path] = $_.Hash
  } -End { Write-Output $out }
}

# save current index files' SHA
$originalSha = GetIndexHashHashtable

# update index
$registryArgs = @{
  RegistrationsPath = Join-Path $RegistryPath $settings.registrations.path
  IndexPath         = $IndexPath
  Token             = $Token
}
$null = Update-BsdataGalleryIndex @registryArgs

# find index files with changed SHA
$updatedSha = GetIndexHashHashtable

$changedIndexPaths = $originalSha.Keys + $updatedSha.Keys
| Select-Object -Unique
| ForEach-Object {
  if ($originalSha[$_] -ne $updatedSha[$_]) {
    $relative = [System.IO.Path]::GetRelativePath($IndexPath, $_)
    Write-Output $relative
  }
}

# update gallery-catpkg.json
$galleryCatpkgArgs = @{
  IndexPath       = $IndexPath
  GallerySettings = $settings.gallery
}
Get-BsdataGalleryCatpkg @galleryCatpkgArgs
| ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii
| Set-Content $GalleryJsonPath -Force

Write-Output @{
  'changed_index_paths' = @($changedIndexPaths)
}