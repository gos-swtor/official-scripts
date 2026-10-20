# GoS Script Package Format

The catalog uses schema **1**. Package manifests use schema **3** and declare the minimum Core API revision.
Each package has a README beside its immutable version folders:

```text
catalog.json
packages/operative/
  README.md
  1.0.0/
    gos-script.json
    live/operative.lua
    common/operative/medicine.lua
    common/operative/lethality.lua
```

## Catalog

`catalog.json` names the official repository, `gos-swtor/scripts`. Each package
declares its unique ID, display name, description, kind, latest version, and
selectable versions. Each version names its manifest path and changelog.

Core resolves the pushed `main` commit and reads the catalog, manifests, and
files at that exact commit SHA. Refresh does not include unpushed work or pull
requests. This release model does not require ZIP assets, tags, or catalog signatures.

## Manifest

`gos-script.json` contains:

- `schema`: `3`.
- `requires_core_api`: a positive integer; this initial release requires revision `1`. Core checks the script and its dependencies before downloading files.
- `id`, `name`, `version`, `kind`, and `description`: package identity and display metadata.
- `entry`: the owned `live/...` entry for scripts; null for libraries.
- `dependencies`: official package IDs mapped to exact versions.
- `files`: every owned install path with its lowercase SHA-256 and byte count.

Package IDs are lowercase kebab-case. Versions use stable tokens such as `1.0.0`.
A file has one package owner. Shared modules live in `gos-common`, and consumers
pin that exact package version rather than bundling another copy. Core rejects
conflicting ownership or dependency versions and verifies downloaded file hashes.

Keep `.gitattributes` (`* -text`) in this repository. Package bytes must survive
Git staging and checkout unchanged; line-ending conversion would invalidate their hashes.

## Installable roots

Allowed roots are `live/`, `common/`, `sprites/`, `fonts/`, and `sounds/`.
Runtime cache, simulations, development tools, logs, fixtures, temporary files,
and reverse-engineering notes are not package payloads. Package-defined installers,
executables, DLLs, symlinks, junctions, absolute paths, and parent traversal are forbidden.

## Release model

Development continues in `GoS-SWTOR/scripts`. Release snapshots are exported from
an explicit committed source revision into this repository and validated before
publication. Published version folders never change; fixes receive a new version.
The root and package READMEs describe the current release, while catalog changelogs
preserve version-specific notes. Unpublished local candidates archived in `.staging/`
are ignored and are not selectable public versions.
