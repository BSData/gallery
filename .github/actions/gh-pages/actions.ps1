#!/usr/bin/env pwsh

[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [string] $IndexPath,

  [Parameter(Mandatory)]
  [string] $DataPath,

  [Parameter(Mandatory)]
  [string] $GalleryJsonPath,

  [Parameter(Mandatory)]
  [string] $Token
)

#Requires -Version 7
#Requires -Module powershell-yaml

$caches = Get-ChildItem $IndexPath *.catpkg.yml

foreach ($file in $caches) {
    $yml = Get-Content $file -Raw | ConvertFrom-Yaml -Ordered
    $repository = $yml.location.github
    if (!$yml.cache.catpkg.properties) {
        Write-Verbose "$repository skipped - no catpkg cache data."
        continue
    }
    $props = $yml.cache.catpkg.properties
    $repoBasePath = "$DataPath/$repository"
    # escape version in path?
    $versionPath = "$repoBasePath/$($props.version)"
    # get or create directory for gh-pages data for the repo for this release
    $versionDir = New-Item $versionPath -ItemType Directory -Force
    $catpkgPath = "$versionDir/catpkg.json"
    $catpkg = Get-Item $catpkgPath -ErrorAction:SilentlyContinue
    if ($catpkg) {
        # compare 
    }
    # download
}