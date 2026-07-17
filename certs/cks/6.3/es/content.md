# 6.3 Investigate and identify phases of attack and bad actors within the environment

## Contexto

Este tema (dominio *Monitoring, Logging and Runtime Security* del curriculum CKS) evalúa la capacidad de **reconstruir el timeline de un ataque** en un clúster Kubernetes: qué pasos siguió el atacante, qué componentes tocó, y cómo aislar al actor detrás de la actividad maliciosa. No se trata de prevención (eso son otros dominios: RBAC, Pod Security, Network Policies) sino de **investigación forense post-hoc y en tiempo real**, combinando evidencia de varias capas: API server (audit logs), runtime de contenedores (Falco/eBPF, `crictl`), nodo (kubelet, `auditd`, syslog) y red (CNI, NetworkPolicy, service mesh).

En el examen esto se traduce típicamente en: dado un pod o nodo con comportamiento sospechoso, usar `kubectl`, `crictl`, audit logs y/o alertas de Falco para determinar **qué se ejecutó, quién lo autorizó, desde dónde y qué tocó después**.

## Marco de referencia: fases de ataque

Kubernetes no tiene un "kill chain" propio en el curriculum, pero conviene mapear la investigación contra un modelo conocido para no perder pasos. El estándar de facto es **MITRE ATT&CK for Containers** (matriz específica, subconjunto de ATT&CK Enterprise), que agrupa las mismas tácticas del kill chain clásico adaptadas a contenedores/K8s:

| Táctica MITRE ATT&CK | Ejemplo concreto en Kubernetes |
|---|---|
| **Initial Access** | Imagen de contenedor vulnerable/maliciosa, API server expuesto sin autenticación, credencial de kubeconfig filtrada, RCE en una app dentro de un pod |
| **Execution** | `kubectl exec` a un pod, `exec` remoto vía RCE de la app, container escape que ejecuta comandos en el nodo |
| **Persistence** | CronJob malicioso, DaemonSet en `kube-system`, ServiceAccount con token de larga duración, webhook admission malicioso |
| **Privilege Escalation** | Pod con `privileged: true` o `hostPID`/`hostPath`, abuso de RBAC (`bind`, `escalate`, `impersonate`), montar el socket del CRI (`/var/run/docker.sock`) |
| **Defense Evasion** | Borrar logs del pod, deshabilitar Falco, correr procesos con nombres legítimos, usar namespaces poco monitoreados |
| **Credential Access** | Leer `/var/run/secrets/kubernetes.io/serviceaccount/token`, montar `Secrets` ajenos, acceso a `etcd` sin cifrar |
| **Discovery** | `kubectl get pods -A`, `kubectl auth can-i --list`, enumerar el API server desde dentro del pod |
| **Lateral Movement** | Usar el token de ServiceAccount robado contra el API server, pivotar a otro namespace, moverse nodo a nodo vía SSH con credenciales encontradas |
| **Collection / Exfiltration** | Volcar `Secrets`/`ConfigMaps`, copiar datos vía `kubectl cp`, tráfico saliente no controlado por NetworkPolicy |
| **Impact** | Cryptomining, borrado de recursos, ransomware sobre volúmenes persistentes, DoS al API server |

Referencia oficial: [MITRE ATT&CK for Containers](https://attack.mitre.org/matrices/enterprise/containers/).

## Fuentes de evidencia

### 1. Kubernetes audit logs (API server)

Registran **todas** las requests al API server: quién (`user`), qué verbo (`verb`), sobre qué recurso, con qué resultado. Es la fuente #1 para reconstruir "quién hizo qué".

Ejemplo de política de auditoría mínima orientada a investigación (`audit-policy.yaml`):

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Capturar exec/attach a pods en el nivel más detallado
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]
  # Cambios en Secrets, sin loguear el body (evita duplicar credenciales en logs)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  # Todo lo demás, a nivel Metadata
  - level: Metadata
```

Flags en el `kube-apiserver`:

```
--audit-policy-file=/etc/kubernetes/audit-policy.yaml
--audit-log-path=/var/log/kubernetes/audit.log
--audit-log-maxage=30
--audit-log-maxbackup=10
--audit-log-maxsize=100
```

Consulta típica con `jq` para encontrar quién ejecutó `exec` en un namespace sospechoso:

```bash
jq -r 'select(.verb=="create" and (.objectRef.resource=="pods" and .objectRef.subresource=="exec"))
  | "\(.requestReceivedTimestamp) user=\(.user.username) ns=\(.objectRef.namespace) pod=\(.objectRef.name)"' \
  /var/log/kubernetes/audit.log
```

Salida:

```
2026-07-15T03:14:07Z user=system:serviceaccount:default:build-bot ns=default pod=web-7d9f8
2026-07-15T03:14:22Z user=system:serviceaccount:default:build-bot ns=kube-system pod=coredns-6f4
```

Un ServiceAccount llamado `build-bot` haciendo `exec` en `kube-system` a las 3 AM es un IOC (*indicator of compromise*) claro: fuera de su patrón normal de uso y con movimiento lateral hacia un namespace privilegiado.

Referencia: [Auditing – Kubernetes docs](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/).

### 2. Falco / eBPF (runtime)

Falco detecta comportamiento anómalo a nivel de syscall en tiempo real: ideal para identificar la **fase de ejecución** del ataque (shell dentro de un contenedor, escritura en binarios del sistema, conexiones salientes no esperadas).

Alerta típica de Falco ante un shell interactivo dentro de un contenedor:

```
03:14:07.123456789: Warning A shell was spawned in a container with an attached terminal
(user=root user_loginuid=-1 k8s.ns=default k8s.pod=web-7d9f8 container=a1b2c3d4e5f6
shell=bash parent=runc cmdline=bash -i terminal=34816 container_id=a1b2c3d4e5f6
image=myregistry/web:1.2.3)
```

Regla custom para detectar el patrón "exfiltración vía curl a un host externo desde un pod que nunca hace requests salientes":

```yaml
- rule: Unexpected outbound connection from web pod
  desc: web-7d9f8 no debería iniciar conexiones salientes
  condition: >
    outbound and container and k8s.ns.name="default" and
    k8s.pod.name startswith "web-" and
    not fd.sip in (allowed_egress_ips)
  output: >
    Conexión saliente no autorizada (pod=%k8s.pod.name comando=%proc.cmdline
    destino=%fd.rip:%fd.rport)
  priority: CRITICAL
```

Referencia: [Falco – Default rules & writing rules](https://falco.org/docs/rules/).

### 3. Container runtime (containerd / CRI-O vía `crictl`)

Cuando hay que inspeccionar un contenedor comprometido a nivel de nodo (sin depender del API server, por si el atacante ya escaló privilegios):

```bash
# Listar contenedores en el nodo, incluyendo los detenidos
crictl ps -a

# Inspeccionar el contenedor sospechoso: imagen, comando, mounts, env
crictl inspect a1b2c3d4e5f6 | jq '.status.image, .status.mounts, .info.runtimeSpec.process.env'

# Ver logs crudos del contenedor (independiente de kubectl logs)
crictl logs a1b2c3d4e5f6

# Ver el árbol de procesos dentro del namespace del contenedor
crictl inspect -o go-template --template '{{.info.pid}}' a1b2c3d4e5f6
ps --forest -o pid,ppid,cmd -g $(crictl inspect --output json a1b2c3d4e5f6 | jq '.info.pid')
```

Esto es clave porque `kubectl logs`/`kubectl exec` dependen del API server y del kubelet: si el atacante los manipuló o el pod ya fue eliminado, `crictl` en el nodo suele preservar más evidencia.

### 4. Logs del nodo

```bash
journalctl -u kubelet --since "2026-07-15 03:00" --until "2026-07-15 03:30"
journalctl -u containerd --since "2026-07-15 03:00"
ausearch -k exec_container   # si auditd está configurado con reglas sobre runc/containerd-shim
```

### 5. Red (CNI / NetworkPolicy / conntrack)

```bash
# Conexiones activas en el nodo asociadas al namespace del pod
nsenter -t <PID_del_contenedor> -n netstat -tnp

# Registros de flujo si el CNI plugin los expone (ej. Cilium)
cilium monitor --related-to <endpoint-id>
```

## Caso práctico: investigar un pod con criptominería

**Señal inicial:** Falco reporta uso anómalo de CPU + spawn de proceso `xmrig` dentro de un pod.

```
04:02:11.998: Critical Cryptomining process detected
(k8s.ns=prod k8s.pod=frontend-6b8c9 command=xmrig -o pool.minexmr.com:4444 -u 4Ab3...)
```

**Paso 1 — Confirmar el alcance con `kubectl`:**

```bash
kubectl -n prod get pod frontend-6b8c9 -o wide
kubectl -n prod describe pod frontend-6b8c9
```

Se revisa `image`, `serviceAccountName`, `nodeName` y eventos recientes (`Events:` al final del `describe`) para ver si hubo un `Pulled`/`Created` reciente que no corresponde a un deploy legítimo (indicaría que el atacante reemplazó la imagen o inyectó un contenedor efímero).

**Paso 2 — Auditar cómo entró:**

```bash
jq -r --arg pod "frontend-6b8c9" \
  'select(.objectRef.name==$pod) | "\(.requestReceivedTimestamp) \(.user.username) \(.verb) \(.objectRef.resource)"' \
  /var/log/kubernetes/audit.log
```

Si aparece un `patch`/`update` sobre el `Deployment` (no sobre el pod directamente) desde un usuario no habitual, el vector de acceso inicial fue una credencial comprometida (kubeconfig, CI/CD token) con permisos de escritura sobre `deployments`.

**Paso 3 — Identificar al "bad actor" (usuario/ServiceAccount origen):**

```bash
kubectl get rolebinding,clusterrolebinding -A -o json \
  | jq -r '.items[] | select(.subjects[]?.name=="ci-deployer") | .metadata.name + " -> " + .roleRef.name'
```

Se cruza el `username` del audit log con los `RoleBinding`/`ClusterRoleBinding` para ver **qué permisos tenía realmente** ese actor y si excedían lo esperado (indicio de escalación previa o de un rol demasiado amplio).

**Paso 4 — Contención (sin destruir evidencia):**

```bash
# Aislar el pod de la red sin borrarlo (para preservar el proceso corriendo)
kubectl label pod frontend-6b8c9 quarantine=true
kubectl apply -f deny-all-quarantine-netpol.yaml   # NetworkPolicy que selecciona label quarantine=true

# Cordonar el nodo para que no reciba más pods mientras se investiga
kubectl cordon <node-name>

# Snapshot del filesystem del contenedor antes de tocar nada más
crictl inspect a1b2c3d4e5f6 > /forensics/frontend-6b8c9-inspect.json
kubectl cp prod/frontend-6b8c9:/ /forensics/frontend-6b8c9-fs -c app
```

Nota: **no** se hace `kubectl delete pod` de entrada — eso destruye evidencia volátil (procesos en memoria, conexiones activas). Primero se aísla con NetworkPolicy/cordon, se captura evidencia, y recién después se remedia.

**Paso 5 — Trazar movimiento lateral posterior:**

```bash
jq -r --arg sa "system:serviceaccount:prod:frontend-sa" \
  'select(.user.username==$sa) | "\(.requestReceivedTimestamp) \(.verb) \(.objectRef.namespace // "-")/\(.objectRef.resource)"' \
  /var/log/kubernetes/audit.log | sort
```

Si el ServiceAccount montado en el pod (`frontend-sa`) empezó a hacer `list secrets` en otros namespaces después de la infección, confirma exfiltración de credenciales adicionales y da el alcance real del incidente (qué otros namespaces/recursos hay que tratar como comprometidos).

## Debugging con Ephemeral Containers (sin alterar el pod original)

Para inspeccionar un contenedor "distroless" (sin shell) sin modificar su imagen ni reiniciarlo:

```bash
kubectl debug -it frontend-6b8c9 --image=busybox --target=app -- sh
```

El contenedor efímero comparte los namespaces de proceso con `--target=app`, permitiendo ver `ps`, archivos abiertos (`/proc/<pid>/fd`), variables de entorno del proceso original, sin dejar rastro dentro de la imagen del contenedor investigado.

Referencia: [Ephemeral containers – Kubernetes docs](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/).

## Buenas prácticas para el examen

- Ante un escenario de "investigá qué pasó", el orden lógico suele ser: **audit log → identificar actor/verbo/recurso → Falco/eBPF para confirmar comportamiento en runtime → crictl/journalctl en el nodo para evidencia de bajo nivel**.
- Diferenciar claramente **Metadata vs RequestResponse** en la audit policy: `RequestResponse` es necesario para ver el *body* de un `exec` (comando ejecutado), pero es costoso — el examen puede pedir ajustar la policy para capturar solo lo necesario.
- Recordar que `kubectl logs --previous` recupera logs de un contenedor reiniciado (útil si el atacante forzó un crash/restart para borrar rastro).
- `kubectl get events --sort-by=.lastTimestamp -A` es la forma más rápida de ver actividad reciente en todo el clúster durante una investigación bajo presión de tiempo.
- No confundir esta tarea (investigación/forense) con **Falco como mecanismo de detección** (otro subtema del mismo dominio) ni con **hardening preventivo** (RBAC, PSA) — acá el foco es reconstruir el ataque ya ocurrido o en curso.

## Referencias

- [CNCF – CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)
- [Kubernetes – Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes – Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/)
- [Kubernetes – Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [Falco – Documentation](https://falco.org/docs/)
- [Falco – Default Rules](https://github.com/falcosecurity/rules/blob/main/rules/falco_rules.yaml)
- [MITRE ATT&CK for Containers](https://attack.mitre.org/matrices/enterprise/containers/)
- [crictl – Command line reference](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/)
- [CIS Benchmark for Kubernetes](https://www.cisecurity.org/benchmark/kubernetes)