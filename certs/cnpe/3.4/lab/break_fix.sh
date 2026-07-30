# 3.4 Using Policy Engines and Admission Controllers for Governance

## Motivación y Gobierno Declarativo en Kubernetes

El gobierno de plataforma en Kubernetes se asegura mediante **Admission Webhooks** y motores de políticas declarativos como **Kyverno** y **OPA/Gatekeeper** (Open Policy Agent).

---

## 1. Admission Controllers y Webhooks

1. **MutatingAdmissionWebhook**: Modifica o enriquece campos en el objeto solicitado (ej: inyectar etiquetas obligatorias o sidecars) antes de guardar en `etcd`.
2. **ValidatingAdmissionWebhook**: Evalúa la spec final del objeto y valida si cumple con las políticas. Si viola una regla, rechaza la solicitud del API Server con HTTP 400.

---

## 2. Kyverno (Kubernetes Native Policy Management)

Kyverno utiliza CRDs nativos en lugar de lenguajes complejos de política:

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

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kyverno Policy Engine Docs — https://kyverno.io/docs/
- OPA Gatekeeper Documentation — https://open-policy-agent.github.io/gatekeeper/website/docs/