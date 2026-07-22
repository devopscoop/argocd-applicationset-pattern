# Brewfile for argocd-applicationset-pattern
#
# Installs every CLI tool used or referenced by this repo.
# Usage: brew bundle

# argocd - ArgoCD CLI, used by helm_to_argocd_migration.sh and post-migration steps
brew "argocd"

# bash - bootstrap.sh and helm_to_argocd_migration.sh use `#!/usr/bin/env bash`
brew "bash"

# git - cloning and the Quick Start workflow
brew "git"

# gomplate - local template testing (the pattern's templating engine)
brew "gomplate"

# helm - required by helm_to_argocd_migration.sh
brew "helm"

# jq - JSON parsing in helm_to_argocd_migration.sh
brew "jq"

# kubectl - applying the ApplicationSet and cluster operations
brew "kubernetes-cli"
