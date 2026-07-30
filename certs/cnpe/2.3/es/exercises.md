# 2.3 Diagnosing and Remediating Platform Issue and Incident Scenarios

## Motivación y Respuesta a Incidentes en la Plataforma

La resolución rápida y metódica de incidentes (**Incident Response & Remediation**) en plataformas cloud native requiere dominar las herramientas de diagnóstico a nivel de clúster, nodo y runtime de contenedor. Durante un incidente de producción, la prioridad del SRE/Platform Engineer es restaurar la disponibilidad del servicio minimizando el radio de impacto (*Blast Radius*) antes de iniciar el análisis de causa raíz (*Root Cause Analysis - RCA*).

---

## 1. Patrones de Falla Comunes en Cargas de Trabajo

| Estado del Pod | Causa Raíz Probable | Comando de Diagnóstico Principal | Acción de Remedación Inmediata |
|---|---|---|---|
| `CrashLoopBackOff` | Error de código, falta de archivo de configuración o secreto | `kubectl logs <pod> --previous` | Rollback a la versión anterior en Git / Deployment |
| `ImagePullBackOff` | Tag inexistente o falta de `imagePullSecrets` | `kubectl describe pod <pod>` (Events) | Corregir tag en Git o actualizar el Secret de Registry |
| `OOMKilled` | El contenedor superó su `limits.memory` (cgroups) | `kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}'` | Incrementar `limits.memory` o ajustar VPA |
| `Pending` | Falta de recursos en nodos o Taints/Affinity desalineados | `kubectl get events --sort-by='.lastTimestamp'` | Escalar nodos vía Autoscaler o corregir Tolerations |

---

## 2. Diagnóstico del Plano de Control y Nodos

Cuando un nodo pasa a estado `NotReady`:

### 2.1 Inspección del Demonio Kubelet
El demonio `kubelet` se encarga de la comunicación con el API Server y del ciclo de vida de los contenedores en el nodo.

```bash
# Inspeccionar los logs del servicio Kubelet en el nodo afectado
$ journalctl -u kubelet -n 100 --no-pager -f
```

### 2.2 Diagnóstico del Container Runtime (`crictl`)
Cuando el API Server no responde o los contenedores no inician, la herramienta CLI `crictl` interactúa directamente con el runtime del contenedor (containerd / CRI-O) a través de la API CRI (*Container Runtime Interface*).

```bash
# Listar contenedores activos directamente a nivel de runtime
$ crictl ps -a

# Inspeccionar logs del contenedor a nivel de runtime
$ crictl logs <container-id>
```

---

## 3. Playbooks de Remedación Declarativa

1. **Reiniciar Cargas de Trabajo (Rolling Restart)**:
   ```bash
   kubectl rollout restart deployment/platform-api -n platform-prod
   ```
2. **Escalado de Emergencia**:
   ```bash
   kubectl scale deployment/platform-api --replicas=10 -n platform-prod
   ```
3. **Drenado Seguro de Nodos Afectados**:
   ```bash
   kubectl drain node-az-a-2 --ignore-daemonsets --delete-emptydir-data
   ```

---

## Verificación de la Recuperación del Servicio

```bash
# Verificar que el rollout haya finalizado exitosamente
$ kubectl rollout status deployment/platform-api -n platform-prod --timeout=60s
deployment "platform-api" successfully rolled out
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Troubleshooting Tasks — https://kubernetes.io/docs/tasks/debug/
- crictl CLI Reference — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/