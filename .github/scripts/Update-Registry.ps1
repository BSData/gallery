[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [string] $RegistryPath,

  [Parameter()]
  [string] $Token
)

#Requires -Version 7
#Requires -Module powershell-yaml

$parentOrgName = 'BSData'

$query = "topic:battlescribe-data+org:$parentOrgName"
$apiRepoSearchArgs = @{
  Method        = 'GET'
  Uri           = "https://api.github.com/search/repositories?q=$query"
  FollowRelLink = $true
  Headers       = @{
    Accept = 'application/vnd.github.v3+json'
  }
}
if ($Token) {
  $apiRepoSearchArgs.Headers['Authorization'] = "token $token"
}
$apiRepoSearchResult = Invoke-RestMethod @apiRepoSearchArgs
$repositories = @($apiRepoSearchResult.items | Sort-Object full_name)

$regSettings = Get-Item "$RegistryPath/settings.yml" | Get-Content -Raw | ConvertFrom-Yaml
$regEntriesSubpath = $regSettings.registrations.path
$regEntriesDir = Get-Item "$RegistryPath/$regEntriesSubpath"
$regEntries = Get-ChildItem $regEntriesDir *.catpkg.yml | ForEach-Object {
  $yml = Get-Content $_ -Raw | ConvertFrom-Yaml
  return @{ content = $yml; file = $_ }
}
# add registry entries for BSData repos not yet registered
$registryRepoNames = $regEntries.content.location.github | Where-Object { $_ }
$reposMissingFromRegistry = $repositories | Where-Object {
  $_.full_name -notin $registryRepoNames
}
foreach ($repo in $reposMissingFromRegistry) {
  $filepath = "$regEntriesDir/$($repo.name.ToLowerInvariant()).catpkg.yml"
  Write-Verbose "Creating $filepath"
  $yaml = [ordered]@{
    'location' = [ordered]@{
      'github' = $repo.full_name
    }
  }
  ConvertTo-Yaml $yaml -OutFile $filepath
}
# del registry entries for repositories no longer reachable
$orgRepoNames = $repositories.full_name
$reposNoLongerExisting = $regEntries | Where-Object {
  $reponame = $_.content.location.github
  if ($reponame -in $orgRepoNames) {
    # we've got it in API response, so it surely exists
    return $false
  }
  if ($reponame -match "^$parentOrgName/" -and $reponame -notin $orgRepoNames) {
    # we've not got it in API response and it's from requested org,
    # so it doesn't meet search criteria (e.g. no 'battlescribe-data' topic)
    $_.del_reason = "not found in org repos query results"
    return $true
  }
  # ping repo is available
  $apiRepoGetArgs = @{
    Uri                = "https://api.github.com/repos/$reponame"
    StatusCodeVariable = 'status'
    SkipHttpErrorCheck = $true
    Headers            = ($Token ? @{ Authorization = "token $Token" } : @{})
  }
  $null = Invoke-RestMethod @apiRepoGetArgs
  $notFound = $status -eq 404
  if ($notFound) {
    $_.del_reason = "repository not found (404)"
  }
  return $notFound
}
foreach ($repo in $reposNoLongerExisting) {
  $filepath = $repo.file
  $reason = $repo.del_reason
  Write-Verbose "Deleting $filepath (reason: $reason)"
  Remove-Item $filepath -Force
}
return @{
  count = @($reposMissingFromRegistry).Count + @($reposNoLongerExisting).Count
  add   = @($reposMissingFromRegistry | Select-Object name, full_name, html_url)
  del   = @($reposNoLongerExisting | ForEach-Object {
      $reponame = $_.content.location.github
      return @{
        name      = ($reponame -split '/')[0]
        full_name = $reponame
        html_url  = "https://github.com/$reponame"
        reason    = $_.del_reason
      }
    })
}
