# Contributing to BSData Gallery

Thank you for your interest in contributing to the BSData Gallery!

## Adding a New Repository

The most common contribution is adding a new BattleScribe data repository to the gallery.

### Prerequisites

Your repository must:

- Be publicly accessible on GitHub
- Have the `battlescribe-data` topic added
- Have a published release with a `.catpkg.json` asset
- Follow the setup guide at [BSData catalogue development wiki](https://github.com/BSData/catalogue-development/wiki/Help:-Hosting-repositories)

### Steps

1. **Fork** this repository
2. **Create** a new file in `registry/entries/` named `<your-repo-name>.catpkg.yml`
3. **Add** the following content:

   ```yaml
   location:
     github: <owner>/<repo-name>
   ```

   For example, for `https://github.com/BSData/wh40k-10e`:

   ```yaml
   location:
     github: BSData/wh40k-10e
   ```

4. **Open a pull request** — CI will automatically validate your entry

### Naming Convention

- The filename should match your repository name in lowercase
- Use the `.catpkg.yml` extension
- Example: `my-game-system.catpkg.yml`

## Repositories in the BSData Organization

Repositories under the [BSData](https://github.com/BSData) organization with the `battlescribe-data` topic are automatically discovered and added by a daily workflow. You typically don't need to manually add these.

## Reporting Issues

If you notice problems with the gallery (missing repositories, broken data, etc.), please [open an issue](https://github.com/BSData/gallery/issues/new).

## Development

The gallery uses PowerShell scripts and GitHub Actions:

- **Validation**: `.github/scripts/Validate-Registry.ps1`
- **Registry updates**: `.github/scripts/Update-Registry.ps1`
- **Index compilation**: `.github/scripts/Update-IndexCache.ps1` + `lib/BsdataGallery` module

### Running Locally

Scripts require PowerShell 7+ and the `powershell-yaml` module:

```pwsh
Install-Module powershell-yaml -Force
```
