function Get-BsdataGalleryCatpkg {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [string]$IndexPath,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$GallerySettings
  )
  $entries = Get-ChildItem $IndexPath *.catpkg.yml | Sort-Object Name

  $caches = $entries | Where-Object { $null -ne $_.cache -and $null -ne $_.cache.catpkg } | Select-Object -ExpandProperty cache
  $galleryJsonContent = [ordered]@{
    '$schema'           = 'https://raw.githubusercontent.com/BSData/schemas/master/src/catpkg.schema.json'
    name                = $GallerySettings.name
    description         = $GallerySettings.description
    battleScribeVersion = (@($caches.catpkg).battleScribeVersion | Sort-Object -Bottom 1) -as [string]
  } + $GallerySettings.urls + @{
    repositories = @($caches | ForEach-Object {
        $_.catpkg.archived = $_.repo.archived -eq $true
        $_.catpkg
      })
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

# Get an object that contains details about GitHub API call
function Get-GHApiUpdatedResult {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [string]$Endpoint,

    [Parameter()]
    [string]$ApiBaseUrl = "https://api.github.com",

    [Parameter()]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$LastModified,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$MaximumRetryCount = 3,

    [Parameter()]
    [int]$RetryIntervalSec = 5
  )
  
  # get object from API, but only if newer than what we've got already
  try {
    $apiArgs = @{
      Uri                     = $ApiBaseUrl.TrimEnd('/') + '/' + $Endpoint.TrimStart('/')
      ResponseHeadersVariable = 'respHeaders'
      StatusCodeVariable      = 'httpStatus'
      SkipHttpErrorCheck      = $true
      Headers                 = & {
        $requestHeaders = @{ }
        if ($Token) {
          $requestHeaders['Authorization'] = "token $Token"
        }
        if ($LastModified) {
          $requestHeaders['If-Modified-Since'] = $LastModified
        }
        return $requestHeaders
      }
    }
    # we have to employ custom retry logic because Invoke-RestMethod retries HTTP 304 NotModified
    $attempts = 0
    do {
      $time = Measure-Command {
        $apiResult = Invoke-RestMethod @apiArgs
        $apiResult | Out-Null # to avoid PSUseDeclaredVarsMoreThanAssignments, Justification: scriptblock is executed in current scope
      }
      Write-Verbose ("Request finished in {0:c}" -f $time)
      # repeat until 3rd attempt or success (200 or 304 is success)
      $repeat = ++$attempts -lt $MaximumRetryCount -and $httpStatus -notin @(200, 304)
      if ($repeat) {
        Write-Verbose "Retrying request in $RetryIntervalSec sec"
        Start-Sleep -Seconds $RetryIntervalSec
      }
    } while ($repeat)
  }
  catch {
    # exception during request
    Write-Error -Exception $_.Exception
    return [ordered]@{
      apiRequestError = [ordered]@{
        exception = $_.Exception.Message
      }
    }
  }
  if ($httpStatus -eq [System.Net.HttpStatusCode]::NotModified) {
    # not modified
    Write-Verbose "Up to date: $Endpoint"
    return [ordered]@{ apiUpToDate = $true }
  }
  if ($httpStatus -ne [System.Net.HttpStatusCode]::OK) {
    # error received
    Write-Warning "GET $Endpoint failed with HTTP $([int]$httpStatus) $($httpStatus -as [System.Net.HttpStatusCode])"
    $apiResult | ConvertTo-Json | Write-Warning
    return [ordered]@{
      apiResponseError = [ordered]@{
        code = $httpStatus -as [int]
      }
    }
  }
  # status code 200 OK
  Write-Verbose "Changed: $Endpoint"
  # prepare result object with release data: headers and content
  $result = [ordered]@{ }
  $lastModified = $respHeaders.'Last-Modified' -as [string]
  if ($lastModified) {
    $result.apiHeaders = @{
      LastModified = $lastModified
    }
  }
  $result.apiResult = $apiResult
  return $result
}

# get latest release info as a ready-to-save hashtable
function Get-UpdatedCache {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [string] $Repository,

    [Parameter()]
    [System.Collections.IDictionary] $Cache,

    [Parameter()]
    [string] $Token
  )

  # prepare result object
  $result = [ordered]@{
    repo          = [ordered]@{}
    latestRelease = [ordered]@{}
    catpkg        = [ordered]@{}
  }

  # check repository - if changed, check archived flag
  $apiRepoArgs = @{
    Endpoint     = "/repos/$Repository"
    LastModified = $Cache.repo.apiHeaders.LastModified
    Token        = $Token
  }
  $apiRepo = Get-GHApiUpdatedResult @apiRepoArgs
  if ($apiRepo.apiUpToDate) {
    $result.repo = $Cache.repo
  }
  elseif (-not $apiRepo.apiResult) {
    # error
    $result.repo = $apiRepo
  }
  elseif ($apiRepo.apiResult.archived -ne $Cache.repo.properties.archived) {
    # archived value changed
    if ($apiRepo.apiResult.archived) {
      # only if repo is archived, save the LastModified header, so we only update the entry after it's unarchived
      $result.repo.apiHeaders = $apiRepo.apiHeaders
    }
    $result.repo.properties = $apiRepo.apiResult | Select-Object 'archived'
  }

  # check latest release - if changed, get catpk.json
  $apiLatestReleaseArgs = @{
    Endpoint     = "/repos/$Repository/releases/latest"
    LastModified = $Cache.latestRelease.apiHeaders.LastModified
    Token        = $Token
  }
  $apiLatestRelease = Get-GHApiUpdatedResult @apiLatestReleaseArgs
  if ($apiLatestRelease.apiUpToDate) {
    # latest release not changed, catpkg update not necessary
    $result.latestRelease = $Cache.latestRelease
    $result.catpkg = $Cache.catpkg
    return $result
  }
  elseif (-not $apiLatestRelease.apiResult) {
    # no apiResult means an error
    $result.latestRelease = $apiLatestRelease
    return $result
  }
  else {
    # latest release changed
    $result.latestRelease.apiHeaders = $apiLatestRelease.apiHeaders
    $result.latestRelease.properties = $apiLatestRelease.apiResult | Select-Object 'tag_name', 'name', 'published_at'
  }

  # # # # # # # # # # # # # # # # # # # # # # # # # # # #
  # Get catpkg.json from the latest release
  # # # # # # # # # # # # # # # # # # # # # # # # # # # #

  # get content of the new catpkg.json
  try {
    $getIndexParams = @{
      Uri                = & {
        $repoName = ($Repository -split '/')[1]
        $assetName = Get-EscapedAssetName "$repoName.catpkg.json"
        $catpkgAsset = $apiLatestRelease.apiResult.assets | Where-Object name -Match '\.catpkg\.json$' | Select-Object -First 1
        $fallbackUri = "https://github.com/$Repository/releases/latest/download/$assetName"
        return $catpkgAsset.browser_download_url ?? $fallbackUri
      }
      StatusCodeVariable = 'catpkgStatusCode'
      SkipHttpErrorCheck = $true
      # retry twice, max 15s per repo. Dropping from gallery isn't critical if we update every hour.
      RetryIntervalSec   = 5
      MaximumRetryCount  = 2
    }
    $time = Measure-Command {
      $catpkgJson = Invoke-RestMethod @getIndexParams
      $catpkgJson | Out-Null # to avoid PSUseDeclaredVarsMoreThanAssignments, Justification: scriptblock is executed in current scope
    }
    Write-Verbose ("Request finished in {0:c}" -f $time)
  }
  catch {
    # exception during request
    Write-Error -Exception $_.Exception
    $result.catpkg.apiRequestError = [ordered]@{
      'exception' = $_.Exception.Message
    }
    return $result
  }
  if ($catpkgStatusCode -ne [System.Net.HttpStatusCode]::OK) {
    # error received
    Write-Warning "catpkg.json request failed with HTTP $([int]$catpkgStatusCode) $($catpkgStatusCode -as [System.Net.HttpStatusCode])"
    $catpkgJson | ConvertTo-Json | Write-Warning
    $result.catpkg.apiResponseError = [ordered]@{
      'code' = $catpkgStatusCode -as [int]
    }
    return $result
  }
  $result.catpkg.properties = $catpkgJson | Select-Object * -ExcludeProperty '$schema', 'repositoryFiles'
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
    Write-Host ("-> Processing: " + $_.name) -ForegroundColor Cyan
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
    Write-Verbose "Updating index cache."
    $cache = Get-UpdatedCache $repository -Cache $index.cache -Token $Token -ErrorAction:Continue

    Write-Verbose "Saving updated cache."
    $index.cache = $cache
    $indexYmlPath = (Join-Path $IndexPath $_.name)
    $index | ConvertTo-Yaml | Set-Content $indexYmlPath -Force
    Write-Verbose "Entry updated."

    return $index
  }
}

Export-ModuleMember Update-BsdataGalleryIndex, Get-BsdataGalleryCatpkg