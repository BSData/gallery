# gallery
Gallery to browse all BattleScribe data sources (repositories), track and index them automatically.

The gallery can be visually browsed at [gallery.bsdata.net](https://gallery.bsdata.net/).

## Usage

### BattleScribe

This distribution channel works easily on BattleScribe for PCs and Android, slightly more complicated on iOS.

To try out this new data distribution system with BattleScribe, you need to copy the following URL:

> `https://github.com/BSData/gallery/releases/latest/download/bsdata.catpkg-gallery.json`

and paste it into an **Add repository source** field. Depending on your device:

- Desktop
  
  ![instruction to add repo source on desktop](docs/images/desktop-add-repo-source.png)

- Android
  
  ![instruction to add repo source on Android](docs/images/android-add-repo-source.png)

- iOS
You have to manipulate the repositories.xml file, which BattleScribe uses to fetch repository data. It can be found by opening the Files app and navigating to BattleScribe > settings > repositories.xml. repositorySourceUrl holds a URL that needs to be replaced by the URL given above. This way BattleScribe will no longer be able to read from the original repository, but this one instead.

## Adding new repository

To add a new data repository to this distribution system:

- first, setup your repository as instructed in https://github.com/BSData/catalogue-development/wiki/Help:-Hosting-repositories
- add a new file within registry/entries path: https://github.com/BSData/gallery/tree/master/registry/entries
- open PR

e.g. for a repository like https://github.com/BSData/skw9k create a file `skw9k.catpkg.yml` with the following content:

```yaml
location:
  github: BSData/skw9k
```
