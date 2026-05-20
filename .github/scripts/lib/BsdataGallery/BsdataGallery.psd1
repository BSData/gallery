@{
    RootModule        = 'BsdataGallery.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'BSData'
    Description       = 'PowerShell module for BSData Gallery index operations'
    PowerShellVersion = '7.0'
    RequiredModules   = @('powershell-yaml')
    FunctionsToExport = @(
        'Update-BsdataGalleryIndex'
        'Get-BsdataGalleryCatpkg'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
