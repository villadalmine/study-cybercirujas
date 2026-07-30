# 3.5 Integrating Security Scanning and Compliance Checks into Deployment Pipelines

## Motivación y Shift-Left Security

Shift-Left Security en la plataforma implica integrar el escaneo continuo de vulnerabilidades (**Vulnerability Scanning**), el análisis estático de manifiestos IaC y las reglas de seguridad runtime en los pipelines de CI/CD antes del despliegue en producción.

---

## 1. Escaneo Estático y de Imágenes (Trivy & Falco)

- **Trivy (Aqua Security)**: Escaneo estático de vulnerabilidades en imágenes y manifiestos de Kubernetes.
- **Falco (CNCF Graduated)**: Detección de anomalías y amenazas en tiempo real a nivel de kernel utilizando eBPF.

```bash
# Escaneo de vulnerabilidades en imágenes bloqueando en CVEs CRITICAL/HIGH
trivy image --severity HIGH,CRITICAL --exit-code 1 myregistry.io/app:v1.0
```

Regla declarativa de Falco para detectar shells lanzadas dentro de contenedores:

```yaml
- rule: Terminal shell in container
  desc: A shell was spawned inside a running container
  condition: >
    spawned_process and container and
    shell_procs and not user_known_shell_activities
  output: >
    Shell spawned in container (user=%user.name container_id=%container.id
    image=%container.image.repository)
  priority: WARNING
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Trivy Security Scanner — https://trivy.dev/
- Falco Runtime Security — https://falco.org/docs/