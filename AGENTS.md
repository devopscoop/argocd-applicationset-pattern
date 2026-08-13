# AGENTS.md

Instructions for AI coding agents working in this repo. `CLAUDE.md` is a symlink
to this file — edit this one; do not replace the symlink.

## What this repo is

A GitOps content repo, not an application. There is no build, no test suite, and
no linter. The "program" is a set of templates that ArgoCD renders inside a
cluster via a custom `argocd-gomplate` plugin sidecar. Local verification means
rendering templates with `gomplate`; real verification only happens in a cluster.

## Architecture: two rendering passes

The non-obvious part of this repo is that `applications/` is rendered twice by
the same plugin, at two different levels:

```
applicationset.yaml            ← ArgoCD ApplicationSet, cluster generator,
                                 one Application per registered cluster secret
  └─ Application "cluster-core-<alias>", source path: applications/
       └─ plugin renders applications/application.yaml.tpl        ← PASS 1
            walks the tree, reads every applications/*/config.yaml,
            emits one ArgoCD Application per config.yaml
              └─ each child Application, source path: applications/<name>/
                   └─ plugin renders that directory                ← PASS 2
                        pre.yaml.tpl + `helm template` (values.yaml.tpl) + post.yaml.tpl
```

Consequences worth knowing before editing anything:

- **Two template languages that look identical.** `applicationset.yaml` is
  ArgoCD's own Go template (`goTemplate: true`), and its `{{ .metadata.labels.X }}`
  fields come from the *cluster secret*. Every `*.tpl` file is **gomplate**,
  runs in the plugin sidecar, and has no cluster access — its only input is
  environment variables (`{{ .Env.X }}` or `env.Getenv "X"`).
- **The `ARGOCD_ENV_` prefix rule.** ArgoCD prefixes every plugin `env` entry
  with `ARGOCD_ENV_` before the template sees it. The full chain for one
  variable is: cluster secret label → `applicationset.yaml` plugin env
  (`ENVIRONMENT`) → `ARGOCD_ENV_ENVIRONMENT` in `application.yaml.tpl` →
  re-exported into the child Application's plugin env → `ARGOCD_ENV_*` in that
  app's `values/pre/post` templates. Adding a variable in only one of those two
  files renders an empty string silently — no error.
- **Pass 1 runs with the working directory set to `applications/`**, which is
  why `file.Walk "."` finds the per-app `config.yaml` files.
- **Environment filtering and sync waves are decided in `application.yaml.tpl`,
  not by ArgoCD.** `deployment.environments` is compared against
  `ARGOCD_ENV_ENVIRONMENT` at render time; an excluded app produces no
  Application manifest at all. Sync phases map to waves there too:
  bootstrap 0, infrastructure 10, platform 20, applications 30.
- **Omitted `config.yaml` fields default to on**: `prune`, `selfHeal`, and
  `serverSideApply` all default to `true` in `application.yaml.tpl`. Only
  `config.yaml` and `values.yaml.tpl` are required per app; `pre.yaml.tpl`,
  `post.yaml.tpl`, and `overrides.yaml` are optional.

## Coupled edits

These changes are incomplete unless every listed file is touched:

| Change | Files that must change together |
|---|---|
| Add/rename a sync phase | `applications/application.yaml.tpl` (wave mapping), `bootstrap.sh` (validation regex + `--sync-phase` help), README sync-phase table |
| Add a template variable | `applicationset.yaml` (`plugin.env`), `applications/application.yaml.tpl` (`plugin.env` of the child Application), README variable table |
| Fork or move the repo | `repoURL` in `applicationset.yaml`, `VALUES_URL` default in `bootstrap.sh`, `valuesURL` in every `applications/*/config.yaml` |
| Add/remove a CLI tool | `Brewfile`, `pkglist.txt`, README "Install required packages" (see below) |

Note that the repo currently lives under `devopscoop` while every URL above
points at `github.com/arturo-builds-infra/argocd-applicationset-pattern`. Leave
that alone unless asked to change it — but change all three places at once.

Prefer `./bootstrap.sh` over hand-writing a new application directory; it
encodes the required fields and the defaults above.

## Commands

```bash
# Scaffold a new application (interactive with no args)
./bootstrap.sh my-app --chart-url https://charts.example.com --chart-version 1.0.0

# Render pass 2 — one app's Helm values (run from the app directory).
# Drop the -d flag if the app has no overrides.yaml.
ARGOCD_APP_NAME=my-app ARGOCD_ENV_ENVIRONMENT=prod ARGOCD_ENV_AWS_REGION=us-west-2 \
  gomplate -d env=overrides.yaml -f values.yaml.tpl

# Render pass 1 — the generated Application manifests (run from applications/).
# This is the closest thing to a test in this repo: run it after touching
# application.yaml.tpl or any config.yaml, and check that each app you expect
# appears, with the right sync wave.
ARGOCD_ENV_ENVIRONMENT=prod ARGOCD_ENV_CLUSTER_ALIAS=test \
ARGOCD_ENV_AWS_ACCOUNT=123456789012 ARGOCD_ENV_AWS_REGION=us-west-2 \
ARGOCD_ENV_DESTINATION_SERVER=https://kubernetes.default.svc \
  gomplate -f application.yaml.tpl

# Install the ApplicationSet
kubectl apply -f applicationset.yaml

# Plugin failures surface here, not in the Application events
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c argocd-gomplate
```

`helm_to_argocd_migration.sh` is interactive and mutates a live cluster
(strips Helm annotations, relabels resources, deletes Helm release secrets).
Do not run it to test a change — hand it to the user.

## Package manifests

This repo ships a `Brewfile` (macOS: `brew bundle`) and a `pkglist.txt` (Arch Linux) that install every local CLI tool the repo uses. Keep them in sync with the code:

- When you add a tool, script, or a new external command inside an existing script, add the package to BOTH files, with a comment noting what uses it.
- When a tool stops being used, remove it from both files.
- Verify package names before adding them: `brew info <formula>` for Homebrew, and the official repos/AUR for Arch. Names differ between ecosystems (e.g. kubectl is Homebrew `kubernetes-cli` but Arch `kubectl`; gomplate is Arch's AUR `gomplate-bin`). If a package is AUR-only, note that in pkglist.txt's header instructions.
- Only workstation tools belong in the manifests — software that runs inside the cluster (ArgoCD, the gomplate sidecar plugin) does not.
- Update the "Install required packages" section in README.md if the tool list changes.

## Conventions

- Commit messages follow Conventional Commits (`ci:`, `docs:`, `feat:`).
- The GitHub Actions workflows pin `anthropics/claude-code-action` and
  `actions/checkout` to full SHAs, and pin `--model claude-opus-5 --effort xhigh`.
  Keep the pins and the comments explaining the permission scopes if you touch
  `.github/workflows/`.
