commonLabels:
  app.kubernetes.io/instance: "{{ .Env.ARGOCD_APP_NAME }}"

serviceAccount:
  annotations:
    # AWS-specific: EKS IAM role for service account
    eks.amazonaws.com/role-arn: "arn:aws:iam::{{ .Env.ARGOCD_ENV_AWS_ACCOUNT }}:role/external-secrets_{{ .Env.ARGOCD_ENV_CLUSTER_ALIAS }}"

webhook:
  timeoutSeconds: 30
