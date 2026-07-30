# 3.5 CI/CD Relationship Fundamentals and Integration

## Motivación e Integración CI/CD en Kubernetes

Integrar los procesos de **Integración Continua (CI)** y **Entrega Continua (CD)** es fundamental para garantizar que el código enviado por los desarrolladores pase automáticamente por fases de validación, compilación de imágenes de contenedor, análisis de vulnerabilidades y reconciliación declarativa en el clúster de producción.

---

## 1. Separación de Responsabilidades entre CI y CD

- **Fase de CI (Continuous Integration)**: Responsable de ejecutar pruebas unitarias, linters, construir artefactos de imagen en el OCI Registry y actualizar los manifiestos de la aplicación en el repositorio de Git.
- **Fase de CD (Continuous Delivery)**: Responsable de detectar los cambios en Git (GitOps) y aplicarlos de forma segura en el clúster de Kubernetes mediante controladores in-cluster como Argo CD o Flux, garantizando auto-remediación y rollback automático si la aplicación falla.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- GitOps & CI/CD Best Practices — https://opengitops.dev/