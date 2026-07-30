# 3.5 Integrating Security Scanning and Compliance Checks into Deployment Pipelines

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

Shift-Left Security en la plataforma implica integrar escaneo continuo de vulnerabilidades (**Vulnerability Scanning**), análisis estático de manifiestos (**IaC Security**) y verificación de compliance en los pipelines de integración y despliegue continuo (CI/CD).

---

## 1. Escaneo de Imágenes y Manifiestos IaC (Trivy / Grype / Checkov)

- **Trivy (Aqua Security)**: Escáner de seguridad integral para imágenes de contenedores, archivos de configuración (Kubernetes, Helm, Terraform) y dependencias.
- **Checkov**: Escaneo estático de manifiestos IaC enfocado en configuraciones erróneas de seguridad.

```bash
# Escaneo de vulnerabilidades en imagen de contenedor bloqueando en CVEs CRITICAL/HIGH
trivy image --severity HIGH,CRITICAL --exit-code 1 myregistry.io/app:v1.0

# Escaneo de manifiestos Kubernetes locales antes del commit
trivy config ./deploy/k8s/
```

---

## 2. Ingesta de Alertas de Seguridad Runtime (Falco)

**Falco** (CNCF Graduated) es el motor de detección de amenazas en tiempo real para Kubernetes basado en eBPF que analiza llamadas al sistema del kernel.

```yaml
# Regla de Falco para detectar exec dentro de contenedores en producción
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