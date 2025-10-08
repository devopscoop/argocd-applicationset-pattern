{{- $currentEnv := env.Getenv "ARGOCD_ENV_ENVIRONMENT" -}}
{{- range file.Walk "." }}
  {{- if not (file.IsDir .) }}
    {{- $filename := filepath.Base . }}
    {{- if eq $filename "config.yaml" }}
      {{- $config := file.Read . | yaml }}
      {{- $argocd := index $config "argocd" | default (dict) }}
      {{- $application := index $config "application" | default (dict) }}
      {{- $syncPhase := index $argocd "syncPhase" | default "" }}
      
      {{- $shouldDeploy := true }}
      {{- $deployment := index $config "deployment" }}
      {{- if $deployment }}
        {{- $deploymentKeys := keys $deployment }}
        {{- $hasEnv := false }}
        {{- range $key := $deploymentKeys }}
          {{- if eq $key "environments" }}
            {{- $hasEnv = true }}
          {{- end }}
        {{- end }}
        {{- if $hasEnv }}
          {{- $envs := index $deployment "environments" }}
          {{- $foundEnv := false }}
          {{- range $env := $envs }}
            {{- if eq $env $currentEnv }}
              {{- $foundEnv = true }}
            {{- end }}
          {{- end }}
          {{- $shouldDeploy = $foundEnv }}
        {{- end }}
      {{- end }}
      
      {{- if $shouldDeploy }}
        {{- $syncPolicy := index $argocd "syncPolicy" | default (dict) }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: "{{ index $application "name" }}"
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    app.kubernetes.io/managed-by: applicationset
    argocd.argoproj.io/application-set-name: cluster-core-applications
    type: application
    appName: "{{ index $application "name" }}"
    syncPhase: "{{ $syncPhase }}"
    environment: "{{ $currentEnv }}"
    cluster: "{{ env.Getenv "ARGOCD_ENV_CLUSTER_ALIAS" }}"
  annotations:
    {{- if eq $syncPhase "bootstrap" }}
    argocd.argoproj.io/sync-wave: "0"
    {{- else if eq $syncPhase "infrastructure" }}
    argocd.argoproj.io/sync-wave: "10"
    {{- else if eq $syncPhase "platform" }}
    argocd.argoproj.io/sync-wave: "20"
    {{- else if eq $syncPhase "applications" }}
    argocd.argoproj.io/sync-wave: "30"
    {{- end }}
spec:
  project: "{{ index $argocd "project" }}"
  source:
    repoURL: "{{ index $application "valuesURL" }}"
    targetRevision: "{{ index $application "valuesRevision" }}"
    path: "applications/{{ index $application "name" }}"
    plugin:
      name: argocd-gomplate
      env:
        - name: HELM_CHART_URL
          value: "{{ index $application "chartURL" }}"
        - name: HELM_CHART_NAME
          value: "{{ index $application "chartName" }}"
        - name: HELM_CHART_VERSION
          value: "{{ index $application "revision" }}"
        - name: ENVIRONMENT
          value: "{{ $currentEnv }}"
        - name: AWS_ACCOUNT
          value: "{{ env.Getenv "ARGOCD_ENV_AWS_ACCOUNT" }}"
        - name: AWS_REGION
          value: "{{ env.Getenv "ARGOCD_ENV_AWS_REGION" }}"
        - name: CLUSTER_ALIAS
          value: "{{ env.Getenv "ARGOCD_ENV_CLUSTER_ALIAS" }}"
        - name: APPLICATION_NAMESPACE
          value: "{{ index $application "namespace" }}"
  destination:
    server: "{{ env.Getenv "ARGOCD_ENV_DESTINATION_SERVER" }}"
    namespace: "{{ index $application "namespace" }}"
  syncPolicy:
    {{- $pruneValue := false }}
    {{- $selfHealValue := false }}
    {{- if ne (index $syncPolicy "prune") nil }}
      {{- $pruneValue = index $syncPolicy "prune" }}
    {{- else }}
      {{- $pruneValue = true }}
    {{- end }}
    {{- if ne (index $syncPolicy "selfHeal") nil }}
      {{- $selfHealValue = index $syncPolicy "selfHeal" }}
    {{- else }}
      {{- $selfHealValue = true }}
    {{- end }}
    {{- if or $pruneValue $selfHealValue }}
    automated:
      prune: {{ $pruneValue }}
      selfHeal: {{ $selfHealValue }}
    {{- end }}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply={{ index $argocd "serverSideApply" | default true }}
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 1m
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
