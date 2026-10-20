# Agent Instructions — Official Script Library

This repository is the release/distribution side of GoS:SWTOR Lua scripts.

In this local checkout, read `.staging/SCRIPT_LIBRARY_AGENT_HANDOFF.md` when
present before backend/release work. That ignored document is an internal
handoff, not public package content. Its canonical source is the development
repository's `docs/SCRIPT_LIBRARY_AGENT_HANDOFF.md`.
The initial release version is `1.0.0`. The previous checkout, including
its Git history and ignored evidence, is preserved in a separate sibling archive.
Do not refresh or publish packages as a side effect of unrelated Core work.

## Source Of Truth

- Development source lives in the separate `GoS-SWTOR` repository under
  `scripts/live`, `scripts/common`, `scripts/sim`, and `scripts/dev`.
- `packages/*` here are exported production snapshots, not normal development
  files. Do not hand-edit package Lua to fix behavior.
- Make Lua changes in `GoS-SWTOR`, validate them there, commit the intended
  source revision, then regenerate this repository with
  `scripts/dev/export_official_script_library.ps1`.
- The exporter must use an explicit committed source revision. Never substitute
  dirty working-tree Lua into production packages.

## Private Maintainer Tooling

- Python scripts and bytecode are private development tools. Never track or
  publish them in this repository; keep their source in `GoS-SWTOR`.
- Local Python copies may remain ignored for maintainer use. Run the canonical
  `GoS-SWTOR/scripts/dev/validate_official_script_library.py` against this
  checkout when validating an official candidate.

## Publication Is User-Controlled

- Staging or validating a package is not permission to publish it.
- Never commit, tag, push, create a GitHub release, upload release assets, or
  update a production catalog unless the user explicitly asks for that
  production publication action in the current task.
- When publication is explicitly requested, review the exact package/version,
  source revision, generated diff, manifest ownership, and validation results
  before committing.
- Do not publish unrelated regenerated packages as a side effect of releasing
  one requested package.

## Identity Boundary

- The intended remote is `github.com/gos-swtor/scripts`.
- Never use the `lyustra` Git identity, GitHub account, token, SSH key, or
  remote namespace to publish this repository.
- `gos-swtor` is reserved for this official scripts repository and the public
  `gos-swtor/gos-swtor.github.io` API website. Private `GoS-SWTOR` development
  remains under `lyustra`.
- Before a scripts push, temporarily activate `gos-swtor` with GitHub CLI. Run
  the guard, push, then restore `lyustra` as the private-development default.
- Run the private development tool `scripts/dev/verify_official_git_identity.ps1`
  with `-RepositoryRoot` pointing at this checkout before every explicitly
  requested push. Maintainer tools are not shipped in this repository.
- The guard requires the active GitHub CLI account to resolve to `gos-swtor`.
- Use repository-local official `user.name`/`user.email`; do not alter global
  Git identity merely for this repository.

## Current Exclusions

- The standalone `stealth-detector` package is excluded by user request on 2026-10-19.
- The public `tools/` directory is excluded; identity verification stays private.

- `combat-event-labels` was removed from the initial release at the user's request on 2026-10-05. Do not re-add it as a side effect of another release.
- `sentinel` is incomplete and is not an official package.
- `telekinetic-burst` is outdated and is not an official package.
- Do not add either to the catalog/package map without explicit user approval
  that it is production-ready.
