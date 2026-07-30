# 4.3 Vulnerability Scanning and Continuous Risk Assessment

## Motivación y Evaluación Continua de Riesgos

El escaneo de vulnerabilidades continuo (**Continuous Vulnerability Scanning**) en imágenes de contenedor (Trivy/Grype) y el monitoreo de runtime a nivel de kernel (Falco).

---

## 1. Escaneo en Registro y CI/CD con Trivy

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 myregistry.io/app:v1.0
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Trivy Docs — https://trivy.dev/