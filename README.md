# ArgoCD ApplicationSet Pattern

A practical pattern for managing Helm-based infrastructure applications across multiple Kubernetes clusters using ArgoCD ApplicationSets.

**Part of the ArgoCD ApplicationSet Pattern:**
- **This repository**: Application pattern and architecture
- Container image repository: [argocd-gomplate](https://github.com/arturo-builds-infra/argocd-gomplate)
- ArgoCD configuration repository: [argocd-config](https://github.com/arturo-builds-infra/argocd-config)

## Table of Contents

- [Why This Pattern](#why-this-pattern)
  - [How It Works](#how-it-works)
  - [Trade-offs](#trade-offs)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Basic Usage](#basic-usage)
- [Repository Structure](#repository-structure)
- [Creating Applications](#creating-applications)
  - [Using the Bootstrap Script](#using-the-bootstrap-script)
  - [Manual Creation](#manual-creation)
- [Configuration](#configuration)
  - [Application Configuration](#application-configuration)
  - [Sync Phases](#sync-phases)
  - [Environment Variables](#environment-variables)
  - [Template Files](#template-files)
- [Plugin Configuration](#plugin-configuration)
- [Migrating from Helm](#migrating-from-helm)
- [Troubleshooting](#troubleshooting)
  - [Template Rendering](#template-rendering)
  - [Application Status](#application-status)
  - [Common Issues](#common-issues)
- [License](#license)

## Why This Pattern

This pattern solves several common problems when managing applications with ArgoCD:

**Dependency Management:** Applications often need resources created before deployment - secrets, namespaces, or other prerequisites. This pattern uses pre/post hooks to handle dependencies without requiring separate applications or complex tooling.

**Directory Scaffolding:** Instead of duplicating directory structures across environments or clusters, this uses a single application definition with templating. One `config.yaml` and one set of templates deploys everywhere.

**Templating Without the Overhead:** Tools like Helmfile and Kustomize work, but they add complexity. ArgoCD supports custom plugins, so this pattern uses a simple gomplate-based plugin that handles the specific use cases needed - environment-specific values, pre/post resources, and Helm chart rendering - without the extra layers.

**Lightweight and Reusable:** No heavy frameworks or complex abstractions. Just ArgoCD, Helm, and gomplate for templating. Easy to understand, easy to modify, easy to reuse across projects.

### How It Works

**Single ApplicationSet per Cluster:** The pattern creates one ApplicationSet per cluster using a cluster generator. Each ApplicationSet is named `cluster-core-CLUSTERNAME` and manages all applications for that cluster.

**Automatic Application Discovery:** The ApplicationSet scans the repository for `config.yaml` files and automatically generates child Applications for each one that matches the deployment criteria.

**Sync Wave Ordering:** Applications are deployed in the correct order using sync waves automatically assigned based on their `syncPhase` configuration (bootstrap → infrastructure → platform → applications).

**Environment Filtering:** Applications can be restricted to specific environments using the `deployment.environments` configuration, allowing fine-grained control over where applications deploy.

**Benefits:**
- Reduced complexity with fewer ApplicationSets to manage
- Consistent deployment order across all clusters
- Cleaner ArgoCD UI with one ApplicationSet per cluster
- Easier troubleshooting and debugging
- Automated sync with self-healing enabled by default

### Trade-offs

**Plugin Dependency:** This pattern requires a custom ArgoCD plugin, which means you cannot use ArgoCD's built-in repository credential management for Helm charts. The plugin runs in a sidecar container and needs its own access to private registries.

**Workaround:** Create a `.dockerconfigjson` secret with registry credentials and mount it to the plugin sidecar. See the [container image repository](https://github.com/arturo-builds-infra/argocd-gomplate) and [ArgoCD configuration repository](https://github.com/arturo-builds-infra/argocd-config) for configuration details.

**Debugging Complexity:** When things do not work as expected, debugging requires checking multiple layers (ApplicationSet → Application → Plugin → Helm). Plugin-specific issues require checking the ArgoCD repo-server logs, which adds an extra troubleshooting step compared to native ArgoCD features.

**Learning Curve:** If you are unfamiliar with gomplate templating or ArgoCD plugins, there is a small learning curve. However, the examples and bootstrap script help mitigate this.

## Quick Start

### Prerequisites

- ArgoCD installed in your cluster
- Cluster secrets registered in ArgoCD with required labels
- Custom argocd-gomplate-plugin configured (see [Plugin Configuration](#plugin-configuration))

### Basic Usage

1. Clone this repository:
   ```bash
   git clone https://github.com/arturo-builds-infra/argocd-applicationset-pattern
   cd argocd-applicationset-pattern
   ```

2. Update the ApplicationSet configuration:
   ```bash
   # Edit applicationset.yaml
   # The repo URLs point to this repository by default
   # If you fork this repo, update repoURL to point to your fork
   ```

3. Apply the ApplicationSet:
   ```bash
   kubectl apply -f applicationset.yaml
   ```

4. Create a new application:
   ```bash
   ./bootstrap.sh my-app \
     --chart-url https://charts.example.com \
     --chart-version 1.0.0
   ```

5. Commit and push:
   ```bash
   git add applications/my-app
   git commit -m "Add my-app"
   git push
   ```

The ApplicationSet will automatically detect the new application and deploy it to matching clusters.

## Repository Structure

```
.
├── applicationset.yaml         # Creates one ApplicationSet per cluster
├── bootstrap.sh                # Script to scaffold new applications
├── helm_to_argocd_migration.sh # Migrate existing Helm releases
└── applications/
    ├── application.yaml.tpl    # Global application template
    └── <app-name>/
        ├── config.yaml         # Application configuration
        ├── values.yaml.tpl     # Helm values template (required)
        ├── pre.yaml.tpl        # Pre-deployment resources (optional)
        ├── post.yaml.tpl       # Post-deployment resources (optional)
        └── overrides.yaml      # Environment overrides (optional)
```

## Creating Applications

### Using the Bootstrap Script

Interactive mode:
```bash
./bootstrap.sh
```

Command line mode:
```bash
./bootstrap.sh external-secrets \
  --chart-url https://charts.external-secrets.io \
  --chart-version 0.17.0 \
  --sync-phase infrastructure \
  --create-post
```

### Manual Creation

Create `applications/my-app/config.yaml`:
```yaml
argocd:
  project: infrastructure
  serverSideApply: true
  syncPhase: applications

application:
  name: my-app
  namespace: my-app
  chartName: my-chart
  chartURL: https://charts.example.com
  revision: 1.0.0
  valuesURL: https://github.com/arturo-builds-infra/argocd-applicationset-pattern
  valuesRevision: HEAD
```

Create `applications/my-app/values.yaml.tpl`:
```yaml
replicaCount: 2

env:
  AWS_REGION: "{{ .Env.ARGOCD_ENV_AWS_REGION }}"
  CLUSTER_NAME: "{{ .Env.ARGOCD_ENV_CLUSTER_ALIAS }}"
```

## Configuration

### Application Configuration

Each application requires a `config.yaml`:

```yaml
argocd:
  project: infrastructure          # ArgoCD project
  serverSideApply: true            # Enable server-side apply
  syncPhase: applications          # Deployment phase
  syncPolicy:                      # Optional overrides
    prune: true
    selfHeal: true

deployment:                        # Optional environment filter
  environments:
    - dev
    - prod

application:
  name: app-name
  namespace: app-namespace
  chartName: helm-chart
  chartURL: https://charts.example.com
  revision: 1.0.0
  valuesURL: https://github.com/arturo-builds-infra/argocd-applicationset-pattern
  valuesRevision: HEAD
```

### Sync Phases

Applications deploy in order using sync waves:

| Phase | Sync Wave | Purpose |
|-------|-----------|---------|
| bootstrap | 0 | Foundation resources |
| infrastructure | 10 | Core infrastructure services |
| platform | 20 | Platform-level services |
| applications | 30 | Application workloads |

### Environment Variables

Environment variables are passed from the ApplicationSet to each Application's plugin configuration. The ApplicationSet uses the cluster generator to iterate over registered clusters and exposes their labels as variables.

**Where variables come from:**
- Cluster labels are defined when registering a cluster secret in ArgoCD (e.g., `kubectl label secret <cluster-secret> -n argocd environment=prod`)
- The ApplicationSet accesses these labels via `{{ .metadata.labels.labelName }}`
- These are then passed as environment variables to the plugin in each generated Application

**Note:** The cluster labels shown below are based on specific use cases and can be completely customized to fit your needs.

Available in templates:

| Variable | Description | Example | Source |
|----------|-------------|---------|--------|
| `ARGOCD_ENV_ENVIRONMENT` | Environment | `prod` | `{{ .metadata.labels.environment }}` cluster label |
| `ARGOCD_ENV_AWS_ACCOUNT` | AWS account ID | `123456789012` | `{{ .metadata.labels.awsAccount }}` cluster label |
| `ARGOCD_ENV_AWS_REGION` | AWS region | `us-west-2` | `{{ .metadata.labels.awsRegion }}` cluster label |
| `ARGOCD_ENV_CLUSTER_ALIAS` | Cluster name | `banks-meowster` | `{{ .metadata.labels.alias }}` cluster label |
| `ARGOCD_APP_NAME` | Application name | `external-secrets` | Application config.yaml |
| `ARGOCD_APP_NAMESPACE` | Target namespace | `external-secrets` | Application config.yaml |

To customize or add variables:
1. Add labels to your cluster secret: `kubectl label secret my-cluster -n argocd yourLabel=yourValue`
2. Reference those labels in `applicationset.yaml` under `template.spec.source.plugin.env`:
   ```yaml
   - name: YOUR_VARIABLE
     value: "{{ .metadata.labels.yourLabel }}"
   ```
3. Use in templates as `{{ .Env.ARGOCD_ENV_YOUR_VARIABLE }}`

### Template Files

#### values.yaml.tpl (Required)

Main Helm values template:

```yaml
replicaCount: 2

image:
  repository: myapp
  tag: "{{ .Env.ARGOCD_ENV_HELM_CHART_VERSION }}"

env:
  AWS_REGION: "{{ .Env.ARGOCD_ENV_AWS_REGION }}"
  CLUSTER_NAME: "{{ .Env.ARGOCD_ENV_CLUSTER_ALIAS }}"
```

#### pre.yaml.tpl (Optional)

Resources deployed before Helm chart:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Env.ARGOCD_APP_NAMESPACE }}
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
```

#### post.yaml.tpl (Optional)

Resources deployed after Helm chart:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: post-config
  namespace: {{ .Env.ARGOCD_APP_NAMESPACE }}
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/sync-wave: "0"
data:
  status: "deployed"
```

#### overrides.yaml (Optional)

Environment-specific configuration:

```yaml
dev:
  values:
    replicaCount: 1

prod:
  values:
    replicaCount: 3
```

Use in templates:

```yaml
{{- $env := (ds "env") -}}
{{- $overrides := (index $env (default "dev" .Env.ARGOCD_ENV_ENVIRONMENT)).values -}}

replicaCount: {{ $overrides.replicaCount | conv.Default 2 }}
```

## Plugin Configuration

This pattern requires a custom ArgoCD plugin configuration. The plugin uses a container image with Helm, gomplate, and kubectl to process templates.

**Container image repository:** [argocd-gomplate](https://github.com/arturo-builds-infra/argocd-gomplate)

**ArgoCD configuration repository:** [argocd-config](https://github.com/arturo-builds-infra/argocd-config)

The plugin is configured as a sidecar container in the ArgoCD repo-server deployment. See the [argocd-config](https://github.com/arturo-builds-infra/argocd-config) repository for complete setup instructions and plugin configuration.

The plugin:
- Processes `.tpl` files with gomplate
- Supports both OCI and HTTPS Helm repositories
- Loads environment-specific overrides
- Renders Helm templates with processed values
- Concatenates pre, helm, and post manifests

## Migrating from Helm

Use the included migration script to transfer Helm releases to ArgoCD:

```bash
./helm_to_argocd_migration.sh <release-name> <namespace> [argocd-app-name]
```

Example:

```bash
./helm_to_argocd_migration.sh external-secrets kube-system external-secrets
```

The script:
- Removes Helm ownership annotations
- Adds ArgoCD tracking labels
- Deletes Helm release secrets
- Prepares resources for ArgoCD adoption

After migration, sync the ArgoCD application:

```bash
argocd app sync <app-name> --apply-out-of-sync-only
```

## Troubleshooting

### Template Rendering

Test templates locally:

```bash
export ARGOCD_ENV_CLUSTER_ALIAS="test"
export ARGOCD_ENV_AWS_REGION="us-west-2"
export ARGOCD_APP_NAME="my-app"
export ARGOCD_APP_NAMESPACE="my-app"

gomplate -d env=overrides.yaml -f values.yaml.tpl
```

### Application Status

Check application health:

```bash
argocd app get <app-name>
kubectl get applications -n argocd
```

### Common Issues

**Application not deploying:**
- Verify cluster labels match ApplicationSet selector
- Check environment filter in `config.yaml`
- Ensure `values.yaml.tpl` exists

**Template errors:**
- Validate gomplate syntax
- Check environment variable availability
- Test template rendering locally

**Sync failures:**
- Review ArgoCD application logs
- Verify Helm chart URL and version
- Check namespace permissions

**Plugin issues:**
- Check ArgoCD repo-server logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server`
- Verify plugin configuration and environment variables
- Ensure plugin has access to required registries

## License

Apache 2.0
