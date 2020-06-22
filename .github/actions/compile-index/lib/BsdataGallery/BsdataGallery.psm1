function Get-BsdataGalleryCatpkg {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [string]$IndexPath,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$GallerySettings
  )
  $entries = Get-ChildItem $IndexPath *.catpkg.yml | Sort-Object Name

  $entriesWithRelease = $entries | Where-Object { $null -ne $_.'latest-release' -and $null -ne $_.'latest-release'.catpkg }
  $catkpgs = @($entriesWithRelease.'latest-release'.catpkg)
  $galleryJsonContent = [ordered]@{
    '$schema'           = 'https://raw.githubusercontent.com/BSData/schemas/master/src/catpkg.schema.json'
    name                = $GallerySettings.name
    description         = $GallerySettings.description
    battleScribeVersion = ($catkpgs.battleScribeVersion | Sort-Object -Bottom 1) -as [string]
  } + $GallerySettings.urls + @{
    repositories = $catkpgs
  }
  return $galleryJsonContent
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
  # # # # # # # # # # # # # # # # # # # # # # # # # # # #
  # Get latest release API object
  # # # # # # # # # # # # # # # # # # # # # # # # # # # #

  # get latest release object from API, but only if newer than what we've got already
  try {
    $latestParams = @{
      Uri                     = "https://api.github.com/repos/$Repository/releases/latest"
      ResponseHeadersVariable = 'releaseResponseHeaders'
      StatusCodeVariable      = 'latestReleaseStatusCode'
      SkipHttpErrorCheck      = $true
      Headers                 = & {
        $requestHeaders = @{ }
        if ($Token) {
          $requestHeaders['Authorization'] = "token $Token"
        }
        $savedLastModified = $SavedRelease.'api-response-headers'.'Last-Modified'
        if ($savedLastModified) {
          $requestHeaders['If-Modified-Since'] = $savedLastModified
        }
        return $requestHeaders
      }
    }
    # we have to employ custom retry logic because Invoke-RestMethod retries HTTP 304 NotModified
    $attempts = 0
    do {
      $time = Measure-Command {
        $latestRelease = Invoke-RestMethod @latestParams
        $latestRelease | Out-Null # to avoid PSUseDeclaredVarsMoreThanAssignments, Justification: scriptblock is executed in current scope
      }
      Write-Verbose ("Request finished in {0:c}" -f $time)
      # repeat until 3rd attempt or success (200 or 304 is success)
      $repeat = ++$attempts -lt 3 -and $latestReleaseStatusCode -notin @(200, 304)
      if ($repeat) {
        $retryInterval = 5
        Write-Verbose "Retrying request in $retryInterval sec"
        Start-Sleep -Seconds $retryInterval
      }
    } while ($repeat)
  }
  catch {
    # exception during request
    Write-Error -Exception $_.Exception
    return [ordered]@{
      'api-request-error' = [ordered]@{
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
  $result = [ordered]@{ }
  $lastModified = $releaseResponseHeaders.'Last-Modified' -as [string]
  if ($lastModified) {
    $result['api-response-headers'] = @{
      'Last-Modified' = $lastModified
    }
  }
  $result['api-response-content'] = $latestRelease | Select-Object 'tag_name', 'name', 'published_at'

  # # # # # # # # # # # # # # # # # # # # # # # # # # # #
  # Get catpkg.json from the latest release
  # # # # # # # # # # # # # # # # # # # # # # # # # # # #

  # get content of the new catpkg.json
  $repoName = ($Repository -split '/')[1]
  $assetName = Get-EscapedAssetName "$repoName.catpkg.json"
  $catpkgAsset = $latestRelease.assets | Where-Object name -Match '\.catpkg\.json$' | Select-Object -First 1
  $catpkgAssetUri = $catpkgAsset.browser_download_url ?? "https://github.com/$Repository/releases/latest/download/$assetName"
  $getIndexParams = @{
    Uri                = $catpkgAssetUri
    StatusCodeVariable = 'catpkgStatusCode'
    SkipHttpErrorCheck = $true
    # retry 3 times (4 attempts) every 15 seconds. This is mostly so that when a new release
    # is created, the publish-catpkg action will take approx. 1 minute until assets are uploaded.
    RetryIntervalSec   = 15
    MaximumRetryCount  = 3
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
    $result['catpkg-request-error'] = [ordered]@{
      'exception' = $_.Exception.Message
    }
    return $result
  }
  if ($catpkgStatusCode -eq [System.Net.HttpStatusCode]::OK) {
    # currently needed because of a couple of fields like battleScribeVersion:
    $result['catpkg'] = $catpkgJson | Select-Object * -ExcludeProperty '$schema', 'repositoryFiles'
  }
  else {
    # error received
    Write-Warning "catpkg.json request failed with HTTP $([int]$catpkgStatusCode) $($catpkgStatusCode -as [System.Net.HttpStatusCode])"
    $catpkgJson | ConvertTo-Json | Write-Warning
    $result['catpkg-response-error'] = [ordered]@{
      'code' = $catpkgStatusCode -as [int]
    }
  }
  return $result
}

function Update-BsdataGalleryIndex {
  [CmdletBinding()]
  param (
    # Path to registry entries directory (registrations)
    [Parameter(Mandatory)]
    [string]
    $RegistrationsPath,

    # Path to index entries directory
    [Parameter(Mandatory)]
    [string]
    $IndexPath,
    
    [Parameter(Mandatory)]
    [string]$Token
  )
  
  # read registry entries
  $registry = [ordered]@{ }
  Get-ChildItem $RegistrationsPath *.catpkg.yml | Sort-Object Name | ForEach-Object {
    $registry[$_.Name] = @{
      name         = $_.Name
      registryFile = $_
      # if there's an index file, set it
      indexFile    = Get-ChildItem $IndexPath $_.Name
    }
  }
  # remove index files no longer in registry
  Get-ChildItem $IndexPath *.catpkg.yml
  | Where-Object { -not $registry[$_.Name] }
  | Remove-Item

  # process all entries
  return $registry.Values | ForEach-Object {
    Write-Host ("-> Processing: " + $_.name)
    $registration = Get-Content $_.registryFile -Raw | ConvertFrom-Yaml -Ordered
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
    Write-Verbose "Getting latest release info."
    $latestRelease = Get-LatestReleaseInfo $repository -SavedRelease $index.'latest-release' -Token $Token -ErrorAction:Continue
    if ($latestRelease -ne $index.'latest-release') {
      Write-Verbose "Saving latest release info."
      $index.'latest-release' = $latestRelease
      $indexYmlPath = (Join-Path $IndexPath $_.name)
      $index | ConvertTo-Yaml | Set-Content $indexYmlPath -Force
      Write-Host "Entry updated." -ForegroundColor Cyan
    }
    return $index
  }
}

Export-ModuleMember Update-BsdataGalleryIndex, Get-BsdataGalleryCatpkg