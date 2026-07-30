# 2.3 Diagnosing and Remediating Platform Issue and Incident Scenarios

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

La resolución rápida de incidentes (*Incident Response & Remediation*) en entornos de producción exige dominar las metodologías de diagnóstico, el análisis de causas raíz (*RCA*) y el uso de herramientas CLI como `kubectl`, `crictl` y métricas del sistema operativo.

---

## 1. Patrones y Diagnóstico de Fallas Comunes en Pods

| Estado del Pod | Causa Raíz Probable | Comando de Diagnóstico Principal |
|---|---|---|
| `CrashLoopBackOff` | Error en código de la app, falta de variable de entorno o falla de archivo de config | `kubectl logs <pod> --previous` |
| `ImagePullBackOff` | Tag inexistente, falta de `imagePullSecrets` o rate limit del registry | `kubectl describe pod <pod>` (sección Events) |
| `OOMKilled` | El proceso excedió el límite de memoria del contenedor (cgroups) | `kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}'` |
| `Pending` | Recursos insuficientes en el clúster, `NodeSelector`/`Taints` desalineados | `kubectl get events -n <ns> --sort-by='.lastTimestamp'` |

---

## 2. Diagnóstico a Nivel de Nodo y CNI

Cuando un nodo pasa a estado `NotReady`:
1. **Inspección del Kubelet**:
   ```bash
   journalctl -u kubelet -n 100 --no-pager
   ```
2. **Estado del Container Runtime (containerd / CRI-O)**:
   ```bash
   crictl ps
   crictl info
   ```
3. **Presión de Almacenamiento/Memoria**:
   ```bash
   kubectl describe node <node-name> | grep -i pressure
   ```

---

## 3. Playbooks de Remedación Declarativa

- **Reiniciar cargas de trabajo**: `kubectl rollout restart deployment/<name>`
- **Escalado de emergencia**: `kubectl scale deployment/<name> --replicas=0 && kubectl scale deployment/<name> --replicas=3`

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Troubleshooting Docs — https://kubernetes.io/docs/tasks/debug/debug-application/
- Containerd Diagnostics with crictl — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/