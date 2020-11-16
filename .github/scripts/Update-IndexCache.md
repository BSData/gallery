# Compile BSData gallery index entries

Compile current index and registry into a new up-to-date index.

prerequisites:
- registry of listed repositories/orgs
- an index containing latest release details
  (index is split across multiple files, one for every "active" repo/pkg)

1. Combine registry with index (add, update, remove index entries)
2. For every index entry:
  a. ask for 'latest' release from API (with 'If-Modified-Since' using Last-Updated details if available)
      - if API returns 302 Not Modified, entry is up-to-date
      - if API returns 404 Not Found (no release), set noRelease to true
      - otherwise, entry requires update
  b. update index entry with info from the API response:
    - tag name
    - release name
    - release date
    - Last-Updated and ETag headers from GitHub API
  c. if tag name was the same, end processing this entry
  d. if noRelease == true, end processing this entry
  e. download index.catpkg.json - if failed, set noIndexJson to true
  f. save necessary details from json to index entry

inputs:
  token:
    description: GitHub auth token to authorize GitHub API requests
    required: false
    default: ${{ github.token }}
  registry-path:
    description: Path where registry files are available.
    required: false
    default: ./registry
  index-path:
    description: Path where index entries are available.
    required: false
    default: ./index
  gallery-json-path:
    description: |
      File path where gallery JSON index should be saved. If left empty (default), 
      the file will not be produced.
    required: false