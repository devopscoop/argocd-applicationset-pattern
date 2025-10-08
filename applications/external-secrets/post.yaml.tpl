apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets
  annotations:
    argocd.argoproj.io/hook: PostSync
  labels:
    app.kubernetes.io/instance: {{ .Env.ARGOCD_APP_NAME }}
spec:
  provider:
    aws:
      service: SecretsManager
      region: {{ .Env.ARGOCD_ENV_AWS_REGION }}
      auth:
        jwt:
          serviceAccountRef:
            name: {{ .Env.ARGOCD_APP_NAME }}
            namespace: {{ .Env.ARGOCD_ENV_APPLICATION_NAMESPACE }}
