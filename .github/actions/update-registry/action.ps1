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

$query = "topic:battlescribe-data+org:BSData"
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
    Get-Content $_ -Raw | ConvertFrom-Yaml
}

$registryRepoNames = $regEntries.location.github | Where-Object { $_ }

$unregisteredRepos = $repositories | Where-Object {
    $_.full_name -notin $registryRepoNames
}
foreach ($repo in $unregisteredRepos) {
    $filepath = "$regEntriesDir/$($repo.name.ToLowerInvariant()).catpkg.yml"
    Write-Verbose "Creating $filepath"
    $yaml = [ordered]@{
        'location' = [ordered]@{
            'github' = $repo.full_name
        }
    }
    ConvertTo-Yaml $yaml -OutFile $filepath
}
return @($unregisteredRepos | Select-Object name, full_name, html_url)
