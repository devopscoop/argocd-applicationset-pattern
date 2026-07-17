# AGENTS.md

Instructions for AI coding agents working in this repo.

## Package manifests

This repo ships a `Brewfile` (macOS: `brew bundle`) and a `pkglist.txt` (Arch Linux) that install every local CLI tool the repo uses. Keep them in sync with the code:

- When you add a tool, script, or a new external command inside an existing script, add the package to BOTH files, with a comment noting what uses it.
- When a tool stops being used, remove it from both files.
- Verify package names before adding them: `brew info <formula>` for Homebrew, and the official repos/AUR for Arch. Names differ between ecosystems (e.g. kubectl is Homebrew `kubernetes-cli` but Arch `kubectl`; gomplate is Arch's AUR `gomplate-bin`). If a package is AUR-only, note that in pkglist.txt's header instructions.
- Only workstation tools belong in the manifests — software that runs inside the cluster (ArgoCD, the gomplate sidecar plugin) does not.
- Update the "Install required packages" section in README.md if the tool list changes.
