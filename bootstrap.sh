#!/usr/bin/env bash

# Bootstrap script for creating new infrastructure applications
# Usage: ./bootstrap.sh [app-name] [options] OR ./bootstrap.sh (interactive mode)

set -eu

# Default values
APP_NAME=""
NAMESPACE=""
CHART_NAME=""
CHART_URL=""
CHART_VERSION=""
SYNC_PHASE="applications"
PROJECT="infrastructure"
SERVER_SIDE_APPLY="true"
# Default values - change these to point to your fork if customizing the pattern
VALUES_URL="https://github.com/arturo-builds-infra/argocd-applicationset-pattern"
VALUES_REVISION="HEAD"
INTERACTIVE_MODE=false
CREATE_PRE=false
CREATE_POST=false
CREATE_OVERRIDES=false

# Sync Policy defaults
SYNC_POLICY_PRUNE="true"
SYNC_POLICY_SELF_HEAL="true"

# Deployment defaults
DEPLOYMENT_ENVIRONMENTS=""

# Catppuccin Mocha colors
readonly RED='\033[38;2;243;139;168m'     # Pink
readonly GREEN='\033[38;2;166;227;161m'   # Green
readonly YELLOW='\033[38;2;249;226;175m'  # Yellow
readonly BLUE='\033[38;2;137;180;250m'    # Blue
readonly CYAN='\033[38;2;148;226;213m'    # Teal
readonly MAUVE='\033[38;2;203;166;247m'   # Mauve
readonly NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}${1}${NC}"
}

print_success() {
    echo -e "${GREEN}${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}${1}${NC}"
}

print_error() {
    echo -e "${RED}${1}${NC}"
}

print_prompt() {
    echo -e "${MAUVE}${1}${NC}"
}

# Function to show usage
show_usage() {
    cat << 'EOF'
Usage: bootstrap.sh [app-name] [options]
   OR: bootstrap.sh (interactive mode)

Creates a new infrastructure application with all required template files.

Arguments:
  app-name                Name of the application (optional - will prompt if not provided)

Options:
  --namespace <n>         Target namespace (default: same as app-name)
  --chart-name <n>        Helm chart name (default: same as app-name)
  --chart-url <url>       Helm chart repository URL (required)
  --chart-version <ver>   Helm chart version (required)
  --sync-phase <phase>    Sync phase: bootstrap, infrastructure, platform, applications (default: applications)
  --project <n>           ArgoCD project (default: infrastructure)
  --no-server-side-apply  Disable server-side apply (default: enabled)
  --values-url <url>      Values repository URL (default: current repo)
  --values-revision <rev> Values repository revision (default: HEAD)
  --no-prune              Disable prune in sync policy (default: enabled)
  --no-self-heal          Disable self-heal in sync policy (default: enabled)
  --environments <list>   Comma-separated list of environments (e.g., dev,test)
  --create-pre            Create pre.yaml.tpl file
  --create-post           Create post.yaml.tpl file  
  --create-overrides      Create overrides.yaml file
  --help                  Show this help message

Examples:
  # Interactive mode
  ./bootstrap.sh

  # Command line mode
  ./bootstrap.sh external-secrets \
    --chart-url https://charts.external-secrets.io \
    --chart-version 0.17.0 \
    --create-post

  # With restricted environments
  ./bootstrap.sh new-service \
    --chart-url https://charts.example.com \
    --chart-version 1.0.0 \
    --environments dev,test \
    --sync-phase platform
EOF
}

# Function to prompt for user input
prompt_input() {
    local prompt_text="${1}"
    local default_value="${2:-}"
    local variable_name="${3}"
    local value=""

    if [[ -n "${default_value}" ]]; then
        read -e -r -p $'\001\033[38;2;203;166;247m\002'"${prompt_text} [${default_value}]: "$'\001\033[0m\002' value
    else
        read -e -r -p $'\001\033[38;2;203;166;247m\002'"${prompt_text}: "$'\001\033[0m\002' value
    fi

    if [[ -z "${value}" && -n "${default_value}" ]]; then
        value="${default_value}"
    fi

    # Use indirect assignment to set the variable
    printf -v "${variable_name}" '%s' "${value}"
}

# Function to prompt for yes/no
prompt_yes_no() {
    local prompt_text="${1}"
    local default_value="${2:-n}"
    local response=""

    while true; do
        if [[ "${default_value}" == "y" ]]; then
            read -e -r -p $'\001\033[38;2;203;166;247m\002'"${prompt_text} [Y/n]: "$'\001\033[0m\002' response
        else
            read -e -r -p $'\001\033[38;2;203;166;247m\002'"${prompt_text} [y/N]: "$'\001\033[0m\002' response
        fi

        response="${response,,}" # Convert to lowercase

        if [[ -z "${response}" ]]; then
            response="${default_value}"
        fi

        case "${response}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                print_warning "Please answer yes or no (y/n)"
                ;;
        esac
    done
}

# Function to run interactive prompts
run_interactive_mode() {
    print_info "Interactive Application Bootstrap"
    echo

    # Required fields
    while [[ -z "${APP_NAME}" ]]; do
        prompt_input "Application name (required)" "" "APP_NAME"
        if [[ -z "${APP_NAME}" ]]; then
            print_warning "Application name is required"
        fi
    done

    prompt_input "Target namespace" "${APP_NAME}" "NAMESPACE"
    prompt_input "Helm chart name" "${APP_NAME}" "CHART_NAME"

    while [[ -z "${CHART_URL}" ]]; do
        prompt_input "Helm chart repository URL (required)" "" "CHART_URL"
        if [[ -z "${CHART_URL}" ]]; then
            print_warning "Chart URL is required"
        fi
    done

    while [[ -z "${CHART_VERSION}" ]]; do
        prompt_input "Helm chart version (required)" "" "CHART_VERSION"
        if [[ -z "${CHART_VERSION}" ]]; then
            print_warning "Chart version is required"
        fi
    done

    # Optional fields
    prompt_input "Sync phase (bootstrap/infrastructure/platform/applications)" "${SYNC_PHASE}" "SYNC_PHASE"
    prompt_input "ArgoCD project" "${PROJECT}" "PROJECT"

    if prompt_yes_no "Enable server-side apply?" "y"; then
        SERVER_SIDE_APPLY="true"
    else
        SERVER_SIDE_APPLY="false"
    fi

    prompt_input "Values repository URL" "${VALUES_URL}" "VALUES_URL"
    prompt_input "Values repository revision" "${VALUES_REVISION}" "VALUES_REVISION"

    # Sync Policy Configuration
    echo
    print_info "Sync Policy Configuration:"
    
    if prompt_yes_no "Enable prune (remove resources not in git)?" "y"; then
        SYNC_POLICY_PRUNE="true"
    else
        SYNC_POLICY_PRUNE="false"
    fi
    
    if prompt_yes_no "Enable self-heal (auto-correct drift)?" "y"; then
        SYNC_POLICY_SELF_HEAL="true"
    else
        SYNC_POLICY_SELF_HEAL="false"
    fi

    # Deployment Configuration
    echo
    print_info "Deployment Configuration:"
    if prompt_yes_no "Restrict to specific environments?" "n"; then
        prompt_input "Environment list (comma-separated, e.g., dev,test)" "" "DEPLOYMENT_ENVIRONMENTS"
    fi

    # Optional files
    echo
    print_info "Optional files (can be created later if needed):"
    if prompt_yes_no "Create pre.yaml.tpl (pre-deployment resources)?" "n"; then
        CREATE_PRE=true
    fi

    if prompt_yes_no "Create post.yaml.tpl (post-deployment resources)?" "n"; then
        CREATE_POST=true
    fi

    if prompt_yes_no "Create overrides.yaml (environment-specific config)?" "n"; then
        CREATE_OVERRIDES=true
    fi

    echo
}

# Function to validate required parameters
validate_params() {
    if [[ -z "${APP_NAME}" ]]; then
        print_error "Application name is required"
        if [[ "${INTERACTIVE_MODE}" == false ]]; then
            show_usage
        fi
        exit 1
    fi

    if [[ -z "${CHART_URL}" ]]; then
        print_error "Chart URL is required"
        if [[ "${INTERACTIVE_MODE}" == false ]]; then
            show_usage
        fi
        exit 1
    fi

    if [[ -z "${CHART_VERSION}" ]]; then
        print_error "Chart version is required"
        if [[ "${INTERACTIVE_MODE}" == false ]]; then
            show_usage
        fi
        exit 1
    fi

    # Set defaults based on app name if not provided
    if [[ -z "${NAMESPACE}" ]]; then
        NAMESPACE="${APP_NAME}"
    fi

    if [[ -z "${CHART_NAME}" ]]; then
        CHART_NAME="${APP_NAME}"
    fi

    # Validate sync phase
    if [[ ! "${SYNC_PHASE}" =~ ^(bootstrap|infrastructure|platform|applications)$ ]]; then
        print_error "Invalid sync phase. Must be: bootstrap, infrastructure, platform, or applications"
        exit 1
    fi

    # Validate app name format
    if [[ ! "${APP_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        print_error "Invalid app name format. Must be lowercase alphanumeric with hyphens"
        exit 1
    fi
}

# Function to check if application already exists
check_existing_app() {
    if [[ -d "applications/${APP_NAME}" ]]; then
        print_error "Application '${APP_NAME}' already exists at applications/${APP_NAME}"
        exit 1
    fi
}

# Function to create directory structure
create_directory() {
    local app_dir="applications/${APP_NAME}"
    print_info "Creating directory: ${app_dir}"
    mkdir -p "${app_dir}"
}

# Function to generate config.yaml
generate_config() {
    local config_file="applications/${APP_NAME}/config.yaml"
    print_info "Generating config.yaml"
    
    cat > "${config_file}" << EOF
argocd:
  project: ${PROJECT}
  serverSideApply: ${SERVER_SIDE_APPLY}
  syncPhase: ${SYNC_PHASE}$(if [[ "${SYNC_POLICY_PRUNE}" != "true" || "${SYNC_POLICY_SELF_HEAL}" != "true" ]]; then echo "
  syncPolicy:"
if [[ "${SYNC_POLICY_PRUNE}" != "true" ]]; then echo "    prune: ${SYNC_POLICY_PRUNE}"; fi
if [[ "${SYNC_POLICY_SELF_HEAL}" != "true" ]]; then echo "    selfHeal: ${SYNC_POLICY_SELF_HEAL}"; fi
fi)$(if [[ -n "${DEPLOYMENT_ENVIRONMENTS}" ]]; then echo "

deployment:
  environments:"
IFS=',' read -ra ENV_ARRAY <<< "${DEPLOYMENT_ENVIRONMENTS}"
for env in "${ENV_ARRAY[@]}"; do
  echo "    - $(echo "$env" | xargs)"  # xargs trims whitespace
done
fi)

application:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  chartName: ${CHART_NAME}
  chartURL: ${CHART_URL}
  revision: ${CHART_VERSION}
  valuesURL: ${VALUES_URL}
  valuesRevision: ${VALUES_REVISION}
EOF
}

# Function to generate values.yaml.tpl
generate_values_template() {
    local values_file="applications/${APP_NAME}/values.yaml.tpl"
    print_info "Generating values.yaml.tpl"
    
    cat > "${values_file}" << 'EOF'
# Helm values template - customize for your specific chart
# This file is processed by gomplate with access to environment variables

# Add your chart-specific values here
# Refer to your chart's values.yaml for available configuration options

# Example: Using environment variables
# nameOverride: "{{ .Env.ARGOCD_APP_NAME }}-{{ .Env.ARGOCD_ENV_CLUSTER_ALIAS }}"

# Example: Environment-specific configuration  
# env:
#   AWS_REGION: "{{ .Env.ARGOCD_ENV_AWS_REGION }}"
#   CLUSTER_NAME: "{{ .Env.ARGOCD_ENV_CLUSTER_ALIAS }}"
#   ENVIRONMENT: "{{ .Env.ARGOCD_ENV_ENVIRONMENT }}"

# Example: Using overrides (if overrides.yaml exists)
# {{- $env := (ds "env") -}}
# {{- $overrides := (index $env (default "dev" .Env.ARGOCD_ENV_ENVIRONMENT)).values -}}
# 
# replicaCount: {{ $overrides.replicaCount | conv.Default 2 }}
EOF
}

# Function to generate pre.yaml.tpl (if requested)
generate_pre_template() {
    if [[ "${CREATE_PRE}" != true ]]; then
        return
    fi

    local pre_file="applications/${APP_NAME}/pre.yaml.tpl"
    print_info "Generating pre.yaml.tpl"
    
    cat > "${pre_file}" << 'EOF'
# Pre-deployment resources
# These resources are deployed before the main Helm chart
# Remove this file if not needed

# Example: Add your pre-deployment resources here
# apiVersion: v1
# kind: ConfigMap
# metadata:
#   name: "{{ .Env.ARGOCD_APP_NAME }}-pre-config"
#   namespace: "{{ .Env.ARGOCD_APP_NAMESPACE }}"
#   annotations:
#     argocd.argoproj.io/hook: PreSync
#     argocd.argoproj.io/sync-wave: "-1"
# data:
#   config.yaml: |
#     # Your pre-deployment configuration
EOF
}

# Function to generate post.yaml.tpl (if requested)
generate_post_template() {
    if [[ "${CREATE_POST}" != true ]]; then
        return
    fi

    local post_file="applications/${APP_NAME}/post.yaml.tpl"
    print_info "Generating post.yaml.tpl"
    
    cat > "${post_file}" << 'EOF'
# Post-deployment resources
# These resources are deployed after the main Helm chart
# Remove this file if not needed

# Example: Add your post-deployment resources here
# apiVersion: v1
# kind: ConfigMap
# metadata:
#   name: "{{ .Env.ARGOCD_APP_NAME }}-post-config"
#   namespace: "{{ .Env.ARGOCD_APP_NAMESPACE }}"
#   annotations:
#     argocd.argoproj.io/hook: PostSync
#     argocd.argoproj.io/sync-wave: "0"
# data:
#   status: "deployed"
#   cluster: "{{ .Env.ARGOCD_ENV_CLUSTER_ALIAS }}"
EOF
}

# Function to generate overrides.yaml (if requested)
generate_overrides_template() {
    if [[ "${CREATE_OVERRIDES}" != true ]]; then
        return
    fi

    local overrides_file="applications/${APP_NAME}/overrides.yaml"
    print_info "Generating overrides.yaml"
    
    cat > "${overrides_file}" << 'EOF'
# Environment-specific overrides
# Remove this file if you don't need environment-specific customization

test:
  values:
    # Add test environment specific values

dev:
  values:
    # Add dev environment specific values

staging:
  values:
    # Add staging environment specific values

prod:
  values:
    # Add prod environment specific values
EOF
}

# Function to show completion summary
show_completion_summary() {
    print_success "Application '${APP_NAME}' created successfully!"
    echo
    print_info "Files created:"
    echo "  applications/${APP_NAME}/"
    echo "  ├── config.yaml"

    if [[ "${CREATE_PRE}" == true ]]; then
        echo "  ├── pre.yaml.tpl"
    fi

    if [[ "${CREATE_POST}" == true ]]; then
        echo "  ├── post.yaml.tpl"
    fi

    if [[ "${CREATE_OVERRIDES}" == true ]]; then
        echo "  ├── overrides.yaml"
    fi

    echo "  └── values.yaml.tpl"
    echo
    print_info "Next steps:"
    echo "  1. Edit values.yaml.tpl with your chart-specific configuration"

    if [[ "${CREATE_PRE}" == false && "${CREATE_POST}" == false ]]; then
        echo "  2. Add pre.yaml.tpl or post.yaml.tpl if needed"
        echo "  3. Commit and push to deploy"
    else
        echo "  2. Customize any optional files you created"
        echo "  3. Commit and push to deploy"
    fi

    echo
    print_warning "Remember:"
    echo "  • Use 'valuesRevision: HEAD' for production"
    echo "  • Test changes in development before merging"
    echo "  • Follow JIRA-XXXX branch naming convention"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --namespace)
                NAMESPACE="${2}"
                shift 2
                ;;
            --chart-name)
                CHART_NAME="${2}"
                shift 2
                ;;
            --chart-url)
                CHART_URL="${2}"
                shift 2
                ;;
            --chart-version)
                CHART_VERSION="${2}"
                shift 2
                ;;
            --sync-phase)
                SYNC_PHASE="${2}"
                shift 2
                ;;
            --project)
                PROJECT="${2}"
                shift 2
                ;;
            --no-server-side-apply)
                SERVER_SIDE_APPLY="false"
                shift
                ;;
            --values-url)
                VALUES_URL="${2}"
                shift 2
                ;;
            --values-revision)
                VALUES_REVISION="${2}"
                shift 2
                ;;
            --no-prune)
                SYNC_POLICY_PRUNE="false"
                shift
                ;;
            --no-self-heal)
                SYNC_POLICY_SELF_HEAL="false"
                shift
                ;;
            --environments)
                DEPLOYMENT_ENVIRONMENTS="${2}"
                shift 2
                ;;
            --create-pre)
                CREATE_PRE=true
                shift
                ;;
            --create-post)
                CREATE_POST=true
                shift
                ;;
            --create-overrides)
                CREATE_OVERRIDES=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: ${1}"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "${APP_NAME}" ]]; then
                    APP_NAME="${1}"
                else
                    print_error "Unexpected argument: ${1}"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# Main execution
main() {
    print_info "Application Bootstrap"
    echo

    # Parse arguments first
    parse_args "$@"

    # If no arguments provided or missing required ones, run interactive mode
    if [[ $# -eq 0 ]] || [[ -z "${APP_NAME}" || -z "${CHART_URL}" || -z "${CHART_VERSION}" ]]; then
        INTERACTIVE_MODE=true
        run_interactive_mode
    fi
    
    validate_params
    check_existing_app
    create_directory
    generate_config
    generate_values_template
    generate_pre_template
    generate_post_template
    generate_overrides_template
    
    echo
    show_completion_summary
}

main "$@"
