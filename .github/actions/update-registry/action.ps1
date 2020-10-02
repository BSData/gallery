[CmdletBinding()]
param (
  [Parameter(Mandatory)]
  [string] $RegistryPath,

  [Parameter()]
  [string] $Token
)

if (-not (Get-Module powershell-yaml -Verbose:$false)) {
  Install-Module powershell-yaml -RequiredVersion "0.4.1" -Force -Verbose:$false
}
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
  return @{ content = $yml; file = $_}
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
  if ($reponame -match "^$parentOrgName/" -and $reponame -notin $orgRepoNames) {
    return $true
  }
  # ping repo is available
  $null = Invoke-RestMethod "https://github.com/$reponame" -StatusCodeVariable status -SkipHttpErrorCheck
  return $status -eq 404
}
foreach ($repo in $reposNoLongerExisting) {
  $filepath = $repo.file
  Write-Verbose "Deleting $filepath"
  Remove-Item $filepath -Force
}
return @{
  count = @($reposMissingFromRegistry).Count + @($reposNoLongerExisting).Count
  add   = @($reposMissingFromRegistry | Select-Object name, full_name, html_url)
  del   = @($reposNoLongerExisting | ForEach-Object {
      return @{
        name      = ($_ -split '/')[0]
        full_name = $_
        html_url  = "https://github.com/$_"
      }
    })
}
