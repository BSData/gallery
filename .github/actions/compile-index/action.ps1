#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

Import-Module $PSScriptRoot/lib/GitHubActionsCore
Import-Module $PSScriptRoot/lib/powershell-yaml

# set this after above imports so the imports aren't verbose
$VerbosePreference = 'Continue'

# function to build hashtable from pipeline, selecting string keys for objects
function ConvertTo-HashTable {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param (
    [Parameter(ValueFromPipeline)]
    [object] $InputObject,
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [string] $Key,
    [Parameter()]
    [switch] $Ordered
  )
  begin {
    $out = if ($Ordered) { [ordered]@{ } } else { @{ } }
  }
  process {
    $out[$Key] = $InputObject
  }
  end {
    $out
  }
}

# this function returns an escaped name that will be accepted as github release asset name
# NOTE keep in sync with https://developer.github.com/v3/repos/releases/#upload-a-release-asset
#      and https://github.com/BSData/publish-catpkg/blob/05e00b9215c65be226ff24346c31acab4fa037c7/action.ps1#L59-L72
function Get-EscapedAssetName {
  param (
    [Parameter(Mandatory, Position = 0)]
    [string] $Name
  )
  # according to https://developer.github.com/v3/repos/releases/#upload-a-release-asset
  # GitHub renames asset filenames that have special characters, non-alphanumeric characters, and leading or trailing periods.
  # Let's do that ourselves first so we know exact filename before upload.
  # 1. replace any group of non a-z, digit, hyphen or underscore chars with a single period
  $periodsOnly = $Name -creplace '[^a-zA-Z0-9\-_]+', '.'
  # 2. remove any leading or trailing period
  return $periodsOnly.Trim('.')
}

# get latest release info as a ready-to-save hashtable
function Get-LatestReleaseInfo {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [string] $Repository,
    [Parameter()]
    [System.Collections.IDictionary] $SavedRelease,
    [Parameter()]
    [string] $Token
  )
  $owner, $repoName = $Repository -split '/'
  $requestHeaders = @{ }
  if ($Token) {
    $requestHeaders['Authorization'] = "token $Token"
  }
  $savedHeaders = $SavedRelease.'api-response-headers'
  if ($savedHeaders.'Last-Modified') {
    $requestHeaders['If-Modified-Since'] = $savedHeaders.'Last-Modified'
  }
  # ETags, turns out, change all the time in github api (at least for latest releases)
  # if ($savedHeaders.'ETag') {
  #   $requestHeaders['If-None-Match'] = $savedHeaders.'ETag'
  # }
  # get latest release object from API, but only if newer than what we've got already
  $latestParams = @{
    Uri                     = "https://api.github.com/repos/$Repository/releases/latest"
    Headers                 = $requestHeaders
    ResponseHeadersVariable = 'releaseResponseHeaders'
    StatusCodeVariable      = 'latestReleaseStatusCode'
    SkipHttpErrorCheck      = $true
    Verbose                 = $true
  }
  try {
    # we have to employ custom retry logic because Invoke-RestMethod retries HTTP 304 NotModified
    $attempts = 0
    $retryInterval = 5
    do {
      if ($attempts -gt 0) {
        Write-Verbose "Retrying request in $retryInterval sec"
        Start-Sleep -Seconds $retryInterval
      }
      $time = Measure-Command {
        $latestRelease = Invoke-RestMethod @latestParams
        $latestRelease | Out-Null # to avoid PSUseDeclaredVarsMoreThanAssignments, Justification: scriptblock is executed in current scope
      }
      Write-Verbose ("Request finished in {0:c}" -f $time)
      # repeat until 3rd attempt or success (200 or 304 is success)
    } while (++$attempts -lt 3 -and $latestReleaseStatusCode -notin @(200, 304))
  }
  catch {
    # exception during request
    Write-Error -Exception $_.Exception
    return [ordered]@{
      'api-response-error' = [ordered]@{
        'exception' = $_.Exception.Message
      }
    }
  }
  if ($latestReleaseStatusCode -eq [System.Net.HttpStatusCode]::NotModified) {
    # not modified
    Write-Verbose "Up to date: $Repository"
    return $SavedRelease
  }
  if ($latestReleaseStatusCode -ne [System.Net.HttpStatusCode]::OK) {
    # error received
    Write-Warning "Latest release request failed with HTTP $([int]$latestReleaseStatusCode) $($latestReleaseStatusCode -as [System.Net.HttpStatusCode])"
    $latestRelease | ConvertTo-Json | Write-Warning
    return [ordered]@{
      'api-response-error' = [ordered]@{
        'code' = $latestReleaseStatusCode -as [int]
      }
    }
  }
  # status code 200 OK
  Write-Verbose "Latest release changed: $Repository"
  # prepare result object with release data: headers and content
  $resultHeaders = [ordered]@{ }
  if ($releaseResponseHeaders.'Last-Modified') {
    $resultHeaders.'Last-Modified' = $releaseResponseHeaders.'Last-Modified' -as [string]
  }
  # if ($releaseResponseHeaders.ETag) {
  #   $resultHeaders.'ETag' = $releaseResponseHeaders.ETag -as [string]
  # }
  $result = [ordered]@{ }
  if ($resultHeaders.Count -gt 0) {
    $result['api-response-headers'] = $resultHeaders
  }
  $result['api-response-content'] = $latestRelease | Select-Object 'tag_name', 'name', 'published_at'
  # get content of the new catpkg.json
  $assetName = Get-EscapedAssetName "$repoName.catpkg.json"
  $getIndexParams = @{
    Uri                = "https://github.com/$Repository/releases/latest/download/$assetName"
    StatusCodeVariable = 'catpkgStatusCode'
    SkipHttpErrorCheck = $true
    # retry 3 times (4 attempts) every 15 seconds. This is mostly so that when a new release
    # is created, the publish-catpkg action will take approx. 1 minute until assets are uploaded.
    RetryIntervalSec   = 15
    MaximumRetryCount  = 3
    Verbose            = $true
  }
  try {
    $time = Measure-Command {
      $catpkgJson = Invoke-RestMethod @getIndexParams
      $catpkgJson | Out-Null # to avoid PSUseDeclaredVarsMoreThanAssignments, Justification: scriptblock is executed in current scope
    }
    Write-Verbose ("Request finished in {0:c}" -f $time)
  }
  catch {
    # exception during request
    Write-Error -Exception $_.Exception
    $result['index-response-error'] = [ordered]@{
      'exception' = $_.Exception.Message
    }
    return $result
  }
  if ($catpkgStatusCode -eq [System.Net.HttpStatusCode]::OK) {
    # currently needed because of a couple of fields like battleScribeVersion:
    $result['index'] = $catpkgJson | Select-Object * -ExcludeProperty '$schema', 'repositoryFiles'
  }
  else {
    # error received
    Write-Warning "catpkg.json request failed with HTTP $([int]$catpkgStatusCode) $($catpkgStatusCode -as [System.Net.HttpStatusCode])"
    $catpkgJson | ConvertTo-Json | Write-Warning
    $result['index-response-error'] = [ordered]@{
      'code' = $catpkgStatusCode -as [int]
    }
  }
  return $result
}

function Update-RegistryIndex {
  [CmdletBinding()]
  param (
    # Path to registry entries directory (registrations)
    [Parameter(Mandatory)]
    [string]
    $RegistrationsPath,
    # Path to index entries directory
    [Parameter(Mandatory)]
    [string]
    $IndexPath
  )
  
  # read registry entries
  $registry = Get-ChildItem $registrationsPath -Filter *.catpkg.yml | Sort-Object Name | ForEach-Object {
    return @{
      name         = $_.Name
      registryFile = $_
    }
  } | ConvertTo-HashTable -Key { $_.name } -Ordered
  # zip entries with existing index entries
  Get-ChildItem $indexPath *.catpkg.yml | ForEach-Object {
    $entry = $registry[$_.Name]
    if ($null -eq $entry) {
      $entry = @{ name = $_.Name }
      $registry[$_.Name] = $entry
    }
    $entry.indexFile = $_
  }

  # process all entries
  return $registry.Values | Sort-Object name | ForEach-Object {
    Write-Host ("-> Processing: " + $_.name)
    if (-not $_.registryFile) {
      Write-Verbose "Index entry not in registry, removing."
      Remove-Item $_.indexFile
      return
    }
    $registration = $_.registryFile | Get-Content -Raw | ConvertFrom-Yaml -Ordered
    if ($_.indexFile) {
      Write-Verbose "Reading index entry."
      $index = $_.indexFile | Get-Content -Raw | ConvertFrom-Yaml -Ordered
      # compare registry and index, if location differs, use registration thus forcing refresh
      $index = if ($index.location.github -ne $registration.location.github) { $registration } else { $index }
    }
    else {
      Write-Verbose "Reading registry entry."
      $index = $registration
    }
    $repository = $index.location.github
    $owner, $repoName = $repository -split '/'
    Write-Verbose "Getting latest release info."
    $latestRelease = Get-LatestReleaseInfo $repository -SavedRelease $index.'latest-release' -Token $token -ErrorAction:Continue
    if ($latestRelease -ne $index.'latest-release') {
      Write-Verbose "Saving latest release info."
      $index.'latest-release' = $latestRelease
      $indexYmlPath = (Join-Path $indexPath $_.name)
      $index | ConvertTo-Yaml | Set-Content $indexYmlPath -Force
      Write-Host "Entry updated." -ForegroundColor Cyan
    }
    return $index
  }
}

# read inputs
$registryPath = Get-ActionInput 'registry-path'
$indexPath = Get-ActionInput 'index-path'
$token = Get-ActionInput 'token'

# read settings
[string]$regSettingsPath = Join-Path $registryPath settings.yml
$settings = Get-Content $regSettingsPath -Raw | ConvertFrom-Yaml
$registrationsPath = Join-Path $registryPath $settings.registrations.path

$entries = Update-RegistryIndex -RegistrationsPath $registrationsPath -IndexPath $indexPath

$galleryJsonPath = Get-ActionInput 'gallery-json-path'
if (-not $galleryJsonPath) {
  Write-Host "Done, gallery json creation skipped (no path)." -ForegroundColor Green
  exit 0
}

$entriesWithRelease = $entries | Where-Object { $null -ne $_.'latest-release' -and $null -ne $_.'latest-release'.index }
$entryIndexes = @($entriesWithRelease.'latest-release'.index)
$galleryJsonContent = [ordered]@{
  '$schema'           = 'https://raw.githubusercontent.com/BSData/schemas/master/src/catpkg.schema.json'
  name                = $settings.gallery.name
  description         = $settings.gallery.description
  battleScribeVersion = ($entryIndexes.battleScribeVersion | Sort-Object -Bottom 1) -as [string]
} + $settings.gallery.urls + @{
  repositories = $entryIndexes
}

$galleryJsonContent | ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii | Set-Content $galleryJsonPath -Force
