# 3.4 Using Policy Engines and Admission Controllers for Governance

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El gobierno de plataforma en Kubernetes se implementa mediante **Admission Webhooks** (Mutating y Validating Admission Controllers) y motores de política declarativos como **Kyverno** y **OPA/Gatekeeper** (Open Policy Agent).

---

## 1. Admission Controllers y Webhooks en Kubernetes

1. **MutatingAdmissionWebhook**: Modifica o inyecta campos en el objeto solicitado (ej: inyectar sidecars, agregar labels automáticos) antes de la persistencia en `etcd`.
2. **ValidatingAdmissionWebhook**: Revisa la spec final del objeto y valida si cumple con las políticas. Si no cumple, rechaza la solicitud del API Server con un mensaje de error HTTP 400.

---

## 2. Motores de Políticas Declarativos (Kyverno vs OPA Gatekeeper)

### Kyverno (Kubernetes Native Policy Management)
Kyverno utiliza recursos personalizados de Kubernetes (CRDs) en lugar de lenguajes de política complejos como Rego.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  rules:
  - name: validate-image-tag
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "El uso del tag 'latest' está prohibido en producción."
      pattern:
        spec:
          containers:
          - image: "!*:latest"
```

### OPA/Gatekeeper (Open Policy Agent)
Usa la Constraint Framework con `ConstraintTemplate` escritas en lenguaje **Rego**.

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kyverno Policy Engine Docs — https://kyverno.io/docs/
- OPA Gatekeeper Documentation — https://open-policy-agent.github.io/gatekeeper/website/docs/