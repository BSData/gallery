[CmdletBinding()]
param (
  [Parameter()]
  [string[]] $Entries,

  [Parameter()]
  [string] $RegistryPath = (Get-Item "./registry"),

  [Parameter()]
  [string] $Token
)

$Entries = $Entries -replace '\\', '/'
Import-Module powershell-yaml -Verbose:$false -ErrorAction:Ignore
|| Install-Module powershell-yaml -RequiredVersion 0.4.2 -Force -Verbose:$false

if ($env:GITHUB_ACTIONS -ne 'true') {
  function LogDebug($Message) {
    Write-Verbose $Message
  }
  function LogWarning($Message, $File) {
    Write-Warning "$File`: $Message"
  }
  function LogError($Message, $File) {
    Write-Error "$File`: $Message"
  }
  function FormatFileRef($props, $msg) {
    $file = $props['file']
    $line = $props['line']
    $col = $props['col']
    $value = ''
    if ($file) {
      $position = $line ? $col ? "($line,$col)" : "($line)" : '';
      $value += "${file}${position}: "
    }
    return $value + $message
  }
}
else {
  function LogDebug($Message) {
    Write-ActionDebug $Message
  }
  function LogWarning($Message, $File) {
    Write-ActionWarning $Message $File
  }
  function LogError($Message, $File) {
    Write-ActionError $Message $File
  }
}

# read registry settings
$settings = Get-Content (Join-Path $RegistryPath settings.yml) -Raw | ConvertFrom-Yaml
$entriesDir = Join-Path $RegistryPath $settings.registrations.path

# process registry entries
Get-ChildItem $entriesDir *.catpkg.yml | Sort-Object Name | ForEach-Object {
  if ($Entries -and [System.IO.Path]::GetRelativePath('.', "$_").Replace('\', '/') -notin $Entries) {
    LogDebug "$_ skipped because it wasn't whitelisted to check."
  }
  $file = $_
  $entry = Get-Content $file -Raw | ConvertFrom-Yaml -Ordered
  $repo = $entry.location.github
  if (-not $repo) {
    LogError "Entry must have a location.github property." $file
    return
  }
  if ($repo -notmatch '^[^\s\/]+\/[^\s\/]+$') {
    LogError "GitHub repository name must be formatted as 'owner/name', e.g. BSData/gallery." $file
    return
  }
  $owner, $reponame = $repo -split '/'
  $apiUrl = "https://api.github.com/repos/$owner/$reponame"
  $apiRepoArgs = @{
    Uri = $apiUrl
    StatusCodeVariable = 'status'
    SkipHttpErrorCheck = $true
    Headers = @{
      # preview api for 'topics'
      Accept = 'application/vnd.github.mercy-preview+json'
    } + ($Token ? @{ Authorization = "token $Token" } : @{} )
  }
  $apiRepo = Invoke-RestMethod @apiRepoArgs
  if ($status -ne 200) {
    if ($status -eq 404) {
      LogError "GitHub repository couldn't be reached at $apiUrl - it doesn't exist or is private." $file
      return
    }
    LogError "Fetching $repo failed with HTTP $status." $file
    return
  }
  if ('battlescribe-data' -notin $apiRepo.topics) {
    LogWarning "$repo doesn't have a 'battlescribe-data' topic added." $file
  }
  $getWorkflowsArgs = @{
    Uri = "$apiUrl/contents/.github/workflows"
    StatusCodeVariable = 'status'
    SkipHttpErrorCheck = $true
    Headers = ($Token ? @{ Authorization = "token $Token" } : @{} )
  }
  $workflows = Invoke-RestMethod @getWorkflowsArgs
  $addWorkflowsSuggestion = @"
Consider adding necessary workflows by adding a comment with first line like:
> ``/template-workflows-pr $repo``
"@
  if ($status -ne 200) {
    LogWarning "Fetching $repo workflows failed with HTTP $status. $addWorkflowsSuggestion" $file
  }
  $existingWorkflows = @(($workflows | Where-Object { $_.type -eq 'file' }).name)
  $missingWorkflows = @(
    'ci.yml',
    # 'chatops.yml',
    'publish-catpkg.yml'
  ) | Where-Object { $_ -notin $existingWorkflows }
  if ($missingWorkflows) {
    LogWarning "$repo is missing workflows: $($missingWorkflows -join ', '). $addWorkflowsSuggestion" $file
  }
}