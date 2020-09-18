[CmdletBinding()]
param (
    [Parameter()]
    [string] $GitHubToken
)

if ($env:GITHUB_ACTIONS -eq 'true') {
    function Log ($message) {
        
    }
}
else {
    function Log ($message) {
        
    }
}