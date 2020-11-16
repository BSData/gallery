#!/usr/bin/env pwsh

[CmdletBinding()]
param (
    # Path to the index cache directory (catpkg.yml files)
    [Parameter(Mandatory)]
    [string] $IndexPath,

    # Path to where the data is save to (catpkg.json and bsr files)
    [Parameter(Mandatory)]
    [string] $DataPath,

    # Base URL where the data is served from
    [Parameter(Mandatory)]
    [string] $DataBaseUrl,

    # Path to catpkg-gallery.json which will be saved with modifications to Data path
    [Parameter(Mandatory)]
    [string] $GalleryJsonPath,

    # Paths of index cache files which were updated and should be updated in Data path as well
    [Parameter()]
    [string[]] $ChangedIndexPath,

    # Authorization token for GitHub API endpoints
    [Parameter(Mandatory)]
    [string] $Token
)

#Requires -Version 7
#Requires -Module powershell-yaml

filter Update-DataEntry {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline)]
        [System.IO.FileInfo] $InputObject
    )
    $cacheFile = $InputObject
    $name = $cacheFile.Name.Replace(".catpkg.yml", "").ToLowerInvariant()
    $cacheYml = Get-Content $cacheFile -Raw | ConvertFrom-Yaml -Ordered
    $repository = $cacheYml.location.github
    Write-Verbose "$repository - processing..."
    if (!$cacheYml.cache.catpkg.properties) {
        Write-Verbose "$repository skipped - no catpkg cache data."
        return
    }
    $props = $cacheYml.cache.catpkg.properties
    # calculate hash of cache yaml file
    $cacheYmlSha = (Get-FileHash "$cacheFile" -Algorithm SHA256).Hash
    # get or create directory for gh-pages data for the repo latest data
    $repoBasePath = New-Item "$DataPath/$name/latest" -ItemType Directory -Force
    $cacheShaFilename = "cache.sha.txt"
    $catpkgFilename = "$name.catpkg.json"
    $bsrFilename = "$name.bsr"
    $catpkg = Get-Item "$repoBasePath/$catpkgFilename" -ErrorAction:SilentlyContinue
    if ($catpkg) {
        # read saved hash of last used cache yml file
        $savedSha = Get-Item "$repoBasePath/$cacheShaFilename" -ErrorAction:SilentlyContinue
        if ($cacheYmlSha -eq $savedSha) {
            Write-Verbose "$repository skipped - data index up-to-date with cache"
            return
        }
    }
    # update required
    # save cache hash
    Set-Content "$repoBasePath/$cacheShaFilename" $cacheYmlSha -NoNewline -Force
    # save catpkg.json
    try {
        $null = Invoke-WebRequest $props.repositoryUrl -OutFile "$repoBasePath/$catpkgFilename"
    } catch {
        # needed not to print 404 webpage in logs
        throw $_.Exception.Message
    }
    $catpkg = Get-Content "$repoBasePath/$catpkgFilename" -Raw | ConvertFrom-Json
    # save repo.bsr
    try {
        $null = Invoke-WebRequest $catpkg.repositoryBsrUrl -OutFile "$repoBasePath/$bsrFilename"
    } catch {
        # needed not to print 404 webpage in logs
        throw $_.Exception.Message
    }
    # patch up catpkg properties to direct to gallery dataindex urls
    . {
        # force name
        $catpkg.name = ($catpkg.name -eq $name) ? $catpkg.name : $name
        # update supported properties
        $catpkg.repositoryUrl = ([uri]"$DataBaseUrl/$name/latest/$catpkgFilename").AbsoluteUri
        $catpkg.repositoryBsrUrl = ([uri]"$DataBaseUrl/$name/latest/$bsrFilename").AbsoluteUri
        # remove unsupported properties
        $catpkg.PSObject.Properties.Remove('indexUrl')
        $catpkg.PSObject.Properties.Remove('repositoryGzipUrl')
        # save back to file
        $catpkg | ConvertTo-Json -Depth 10 | Set-Content "$repoBasePath/$catpkgFilename"
    }
    Write-Verbose "$repository - data updated."
}

$caches = Get-ChildItem $IndexPath *.catpkg.yml

Write-Verbose "Catpkg data - processing..."
$caches | Update-DataEntry
Write-Verbose "Catpkg data - updated."

# now let's patch and save catpkg-gallery.json
Write-Verbose "Gallery data - processing..."
$gallery = Get-Content $GalleryJsonPath -Raw | ConvertFrom-Json
$galleryFilename = "catpkg-gallery.json"
$gallery.repositorySourceUrl = ([uri]"$DataBaseUrl/$galleryFilename").AbsoluteUri
$archived = @($gallery.repositories | Where-Object { $_.archived -eq $true } | Select-Object -ExpandProperty githubUrl)
$gallery.repositories = @(
    Get-ChildItem $DataPath *.catpkg.json -Recurse
    | Sort-Object Name
    | ForEach-Object {
        $catpkg = Get-Content $_ -Raw | ConvertFrom-Json | Select-Object -ExcludeProperty '$schema', 'repositoryFiles'
        $catpkg.archived = $archived -contains $catpkg.githubUrl
        Write-Output $catpkg
    }
)
$gallery | ConvertTo-Json -Depth 10 | Set-Content "$DataPath/$galleryFilename"
Write-Verbose "Gallery data - updated."
