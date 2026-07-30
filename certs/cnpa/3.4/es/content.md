# 3.4 Incident Response and Remediation in Platform Engineering

## Motivación y Diagnóstico de Incidentes

Diagnóstico y solución metódica de incidentes a nivel de Pod, Nodo y Kubelet durante fallas de producción.

---

## 1. Comandos de Diagnóstico

```bash
# Inspeccionar los logs del Kubelet
$ journalctl -u kubelet -n 100 --no-pager

# Inspeccionar el estado de los contenedores vía crictl
$ crictl ps -a
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes Debugging Tasks — https://kubernetes.io/docs/tasks/debug/