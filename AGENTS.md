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

## What this repo is

A GitOps configuration repo: YAML manifests, gomplate templates, and two bash
scripts. There is no application code, no build, no test suite, and no linter
config. "Deploying" means committing to the branch the ApplicationSet tracks
(`main`), so the way to check a change is to render it locally before pushing.

## Architecture: two rendering passes

The chain is longer than the file layout suggests. Read `applicationset.yaml`
and `applications/application.yaml.tpl` together — neither makes sense alone.

**Pass 1 — app-of-apps.** `applicationset.yaml` defines a *single*
ApplicationSet (`cluster-core-applications`) with a cluster generator. For each
registered cluster secret it emits one Application named
`cluster-core-<alias>`, pointed at the `applications/` directory through the
`argocd-gomplate` plugin. (The README's "one ApplicationSet per cluster" is
loose phrasing for this.)

**Pass 2 — child Applications.** Rendering `applications/` runs
`application.yaml.tpl`, which `file.Walk`s the directory, reads every
`config.yaml` it finds, and emits one Application manifest per config — with the
sync-wave annotation, the `argocd-gomplate` plugin block, and the chart
coordinates from that config. Each child Application then points at
`applications/<name>`, where the plugin renders `values.yaml.tpl`, runs `helm
template`, and concatenates `pre` + helm output + `post`.

Consequences worth internalizing:

- **Applications are discovered, never registered.** Adding a directory under
  `applications/` with a `config.yaml` and a `values.yaml.tpl` is the entire
  onboarding step. There is no index file to update.
- **`application.yaml.tpl` executes in the *parent* Application's context**
  (destination namespace `argocd`); `values.yaml.tpl` / `pre.yaml.tpl` /
  `post.yaml.tpl` execute in the *child's*. `ARGOCD_APP_*` variables therefore
  mean different things in the two layers.
- **Sync waves order child Applications inside the parent's sync**, not
  resources inside a chart.

## The plugin lives in another repo

`argocd-gomplate` (the sidecar image and its `plugin.yaml`) is at
<https://github.com/arturo-builds-infra/argocd-gomplate>; ArgoCD's own config is
at <https://github.com/arturo-builds-infra/argocd-config>. The logic that
decides *which* files get rendered, in what order, and how pre/helm/post are
concatenated is there, not here. You cannot reproduce the full pipeline locally
from this repo alone — only the individual gomplate renders. When rendering
behaves unexpectedly in-cluster, the repo-server sidecar logs are the source of
truth:

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c argocd-gomplate
```

## Environment variables: the `ARGOCD_ENV_` prefix rule

ArgoCD prefixes every plugin `env` entry with `ARGOCD_ENV_`. A variable declared
as `- name: AWS_REGION` is read in templates as `.Env.ARGOCD_ENV_AWS_REGION`.
Variables do **not** inherit down the chain automatically — each layer declares
its own list.

| Layer | Declared in | Passed |
|---|---|---|
| Parent | `applicationset.yaml` | `ENVIRONMENT`, `AWS_ACCOUNT`, `AWS_REGION`, `CLUSTER_ALIAS`, `DESTINATION_SERVER` (from cluster-secret labels) |
| Child | `applications/application.yaml.tpl` | `HELM_CHART_URL`, `HELM_CHART_NAME`, `HELM_CHART_VERSION`, `ENVIRONMENT`, `AWS_ACCOUNT`, `AWS_REGION`, `CLUSTER_ALIAS`, `APPLICATION_NAMESPACE` |

So **plumbing a new cluster label to an app template takes three edits**: label
the cluster secret, add the variable to `applicationset.yaml`'s plugin `env`,
then re-export it in `application.yaml.tpl`'s plugin `env` block. Skipping the
third leaves the value visible to the app-of-apps template and empty everywhere
else. Note `DESTINATION_SERVER` is deliberately parent-only, and the target
namespace reaches child templates as `ARGOCD_ENV_APPLICATION_NAMESPACE` (see
`applications/external-secrets/post.yaml.tpl`).

Missing variables render as empty strings rather than failing — `gomplate` is
called through `env.Getenv` / `.Env`, so a typo produces a silently malformed
manifest, not an error.

## Sync phases are hardcoded in four places

The phase → wave mapping (`bootstrap` 0, `infrastructure` 10, `platform` 20,
`applications` 30) is an `if/else` chain in `application.yaml.tpl`. Adding or
renaming a phase means updating all of: that chain, the validation regex in
`bootstrap.sh` (`validate_params`), the `--sync-phase` line in `show_usage`, and
the table in `README.md`. An unrecognized `syncPhase` produces an Application
with *no* sync-wave annotation instead of an error.

## Upstream URLs are hardcoded

`spec.template.spec.source.repoURL` in `applicationset.yaml`, `VALUES_URL` in
`bootstrap.sh`, and `application.valuesURL` in every `applications/*/config.yaml`
all point at `https://github.com/arturo-builds-infra/argocd-applicationset-pattern`.
A fork has to change all of them, including existing app configs.

## Config defaults

`config.yaml`'s `argocd.syncPolicy.prune` and `.selfHeal` both default to `true`
when absent (`application.yaml.tpl`), and `automated:` is omitted entirely when
both are false. `bootstrap.sh` mirrors this by writing the `syncPolicy:` block
only when a value is non-default, so a generated config with no `syncPolicy` key
is intentional, not incomplete.

## Local verification

There is nothing to run in CI beyond the Claude review workflows, so verify by
rendering.

Preview the child Applications the app-of-apps pass would generate (run from
`applications/`, because the template walks `.`):

```bash
cd applications
ARGOCD_ENV_ENVIRONMENT=prod \
ARGOCD_ENV_CLUSTER_ALIAS=test-cluster \
ARGOCD_ENV_AWS_ACCOUNT=123456789012 \
ARGOCD_ENV_AWS_REGION=us-west-2 \
ARGOCD_ENV_DESTINATION_SERVER=https://kubernetes.default.svc \
  gomplate -f application.yaml.tpl
```

Render a single application's values (drop `-d env=…` if there is no
`overrides.yaml`):

```bash
cd applications/<app>
ARGOCD_ENV_ENVIRONMENT=prod \
ARGOCD_ENV_AWS_ACCOUNT=123456789012 \
ARGOCD_ENV_AWS_REGION=us-west-2 \
ARGOCD_ENV_CLUSTER_ALIAS=test-cluster \
ARGOCD_APP_NAME=<app> \
ARGOCD_ENV_APPLICATION_NAMESPACE=<app> \
  gomplate -d env=overrides.yaml -f values.yaml.tpl
```

Then validate the YAML and, when the change affects chart output, the chart:

```bash
kubectl apply --dry-run=client -f applicationset.yaml
helm template <app> <chart> --repo <chartURL> --version <revision> -f /tmp/values.yaml
```

Scaffold a new application rather than hand-writing the directory:

```bash
./bootstrap.sh <name> --chart-url <url> --chart-version <ver> \
  --sync-phase infrastructure --create-post
```

`bootstrap.sh` refuses to overwrite an existing `applications/<name>` directory,
so re-scaffolding requires deleting it first.

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
