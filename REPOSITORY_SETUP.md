# Official Repository Setup

The official repository is `https://github.com/gos-swtor/scripts`, using the
`main` branch. The initial release is `1.0.0`; older development staging and
its Git history are archived separately.

Only an explicit user request authorizes an official commit or push. Use the
`gos-swtor` GitHub account and repository-local Git identity for the official
`https://github.com/gos-swtor/scripts` repository. Do not change global identity
or publish through the private development account.

Keep `.gitattributes` (`* -text`) so Git preserves manifest payload hashes.
The standalone Stealth Detector and public maintainer tools are excluded.

Before an authorized push, run the private guard from the GoS-SWTOR development
checkout, replacing the path below with this distribution checkout:

```powershell
gh auth switch --hostname github.com --user gos-swtor
.\scripts\dev\verify_official_git_identity.ps1 -RepositoryRoot '<distribution-checkout>'
```

After the official push, restore the private-development CLI account:

```powershell
gh auth switch --hostname github.com --user lyustra
```

The guard verifies the exact fetch and push destinations, local author, active
GitHub account and actual Git push credentials. It stays in the private
development repository and must not be copied into this public repository.
