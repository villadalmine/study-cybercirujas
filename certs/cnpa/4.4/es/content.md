# 4.4 Cryptographic Identity Management and Secret Storage

## Motivación y Gestión de Secretos con HashiCorp Vault / External Secrets Operator

Gestión dinámica y segura de secretos utilizando **HashiCorp Vault** e inyección mediante **External Secrets Operator (ESO)**.

---

## 1. External Secrets Operator (ExternalSecret CRD)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-secret-external
  namespace: platform-prod
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: db-secret
    creationPolicy: Owner
  data:
  - secretKey: password
    remoteRef:
      key: secret/data/db
      property: password
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- External Secrets Operator Docs — https://external-secrets.io/
- HashiCorp Vault — https://www.vaultproject.io/