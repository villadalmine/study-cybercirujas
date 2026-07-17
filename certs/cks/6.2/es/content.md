# Detectar amenazas dentro de infraestructura física, apps, redes, datos, usuarios y workloads

## Introducción

Hasta este punto del dominio *Monitoring, Logging and Runtime Security* nos enfocamos en **prevención** (hardening, admission control, network policies). Este tema cubre la otra mitad del problema: **detección** — asumir que un control preventivo va a fallar en algún momento y construir la capacidad de notarlo mientras ocurre o inmediatamente después.

En un clúster de Kubernetes, una amenaza puede manifestarse en superficies muy distintas:

| Superficie | Ejemplo de amenaza | Fuente de señal principal |
|---|---|---|
| Infraestructura física / nodos | Acceso SSH no autorizado a un worker node, modificación de `/etc/kubernetes/` | `auditd`, logs de host, Falco |
| Apps | Un contenedor de aplicación ejecuta un binario que no forma parte de su imagen | Falco (syscalls) |
| Redes | Conexión saliente a un pool de cryptomining, escaneo de puertos interno | Falco (`fd.*`), Cilium/Hubble |
| Datos | Lectura de `/var/lib/etcd` por un proceso que no es `etcd`, acceso a un Secret montado por un proceso inesperado | Falco, auditd |
| Usuarios | Un usuario sin RBAC para `exec` intenta abrir una shell en un pod, creación de un `ClusterRoleBinding` fuera de horario | Kubernetes audit log |
| Workloads | Container drift: un pod escribe y ejecuta un binario nuevo en runtime | Falco |

La herramienta central del programa CKS para esto es **Falco** (proyecto graduado de CNCF), que analiza syscalls en tiempo real vía eBPF (o el módulo de kernel legacy) y las evalúa contra un motor de reglas declarativas. La complementan el **audit log de la API de Kubernetes** (para la superficie "usuarios") y herramientas eBPF alternativas como **Tetragon** y **Tracee**.

## Falco: arquitectura y anatomía de una regla

Falco tiene tres piezas:

1. **Driver de captura**: `modern_ebpf` (default en instalaciones recientes), `ebpf` (probe eBPF clásico) o `kmod` (módulo de kernel). Capturan cada syscall del host.
2. **Motor de reglas** (`libsinsp`): enriquece cada evento con contexto de Kubernetes y contenedores (namespace, pod, imagen) y lo evalúa contra las reglas cargadas.
3. **Outputs**: stdout, archivo, gRPC, o vía **Falcosidekick** hacia Slack, un SIEM, Prometheus, etc.

Instalación típica vía Helm:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set collectors.kubernetes.enabled=true
```

Una regla tiene siempre esta forma (`rule`, `desc`, `condition`, `output`, `priority`):

```yaml
- rule: Unexpected outbound connection destination
  desc: >
    Detecta un contenedor conectándose a un puerto que no está en la
    whitelist de la aplicación (posible C2 o exfiltración).
  condition: >
    outbound and container
    and not fd.sport in (allowed_outbound_ports)
  output: >
    Conexión saliente no esperada (user=%user.name command=%proc.cmdline
    connection=%fd.name container=%container.name image=%container.image.repository)
  priority: WARNING
  tags: [network, mitre_exfiltration]
```

`condition` usa los **filter fields** de Falco (`proc.*`, `fd.*`, `container.*`, `k8s.*`, `user.*`) combinados con macros y listas reutilizables (`macro`, `list`). El resultado de una alerta se puede consumir como JSON:

```json
{
  "output": "07:14:22.123456789: Warning Conexión saliente no esperada (user=root command=curl container=web-app image=registry/web-app)",
  "priority": "Warning",
  "rule": "Unexpected outbound connection destination",
  "time": "2026-07-17T07:14:22.123456789Z",
  "output_fields": {
    "container.image.repository": "registry/web-app",
    "container.name": "web-app",
    "fd.name": "203.0.113.77:4444",
    "k8s.ns.name": "prod",
    "k8s.pod.name": "web-app-7f9c6d8b95-x2kpl",
    "proc.cmdline": "curl 203.0.113.77:4444",
    "user.name": "root"
  }
}
```

Con este vocabulario, recorremos las seis superficies del objetivo del examen.

## 1. Infraestructura física / nodos

A este nivel la detección corre por fuera del scheduler de Kubernetes: es monitoreo de host. Herramientas típicas: `auditd` (Linux audit framework) apuntando a los archivos sensibles del control plane, y Falco corriendo también contra el host (no solo contenedores) para capturar cambios en binarios del sistema.

Regla de `auditd` para detectar modificaciones a la configuración del kubelet o manifests estáticos:

```bash
# /etc/audit/rules.d/k8s-node.rules
-w /etc/kubernetes/ -p wa -k k8s_config_change
-w /var/lib/kubelet/config.yaml -p wa -k kubelet_config_change
-w /etc/kubernetes/pki/ -p wa -k k8s_pki_change
```

Verificación:

```bash
$ sudo ausearch -k k8s_config_change --start recent
type=PATH msg=audit(1752741262.331:501): item=0 name="/etc/kubernetes/manifests/kube-apiserver.yaml" ...
type=SYSCALL msg=audit(1752741262.331:501): ... exe="/usr/bin/vim" key="k8s_config_change"
```

Un cambio no planificado a un static pod manifest del control plane —fuera de una ventana de mantenimiento— es una señal de alta severidad: puede ser un intento de inyectar un contenedor privilegiado en el plano de control.

## 2. Aplicaciones

Acá el objetivo es detectar cuando un proceso dentro de un contenedor de aplicación hace algo que su imagen no debería hacer nunca — el caso clásico es una shell interactiva ganada por explotación de una vulnerabilidad de la app (RCE).

```yaml
- rule: Unexpected shell in application container
  desc: Detecta una shell interactiva dentro de un contenedor de aplicación.
  condition: >
    spawned_process and container
    and proc.name in (shell_binaries)
    and container.image.repository != "registry/debug-tools"
  output: >
    Shell inesperada en contenedor de app (user=%user.name shell=%proc.name
    parent=%proc.pname container=%container.name pod=%k8s.pod.name
    image=%container.image.repository)
  priority: CRITICAL
  tags: [application, shell, mitre_execution]
```

Si la aplicación es, por ejemplo, un servidor Node.js que jamás debería invocar `/bin/sh`, cualquier match de esta regla es indicador casi directo de una explotación exitosa.

## 3. Redes

Falco ve la syscall `connect()`/`accept()` y expone campos `fd.sip`, `fd.sport`, `fd.rip`, `fd.rport`. Esto permite detectar tanto **escaneo de puertos interno** (muchas conexiones fallidas a puertos distintos desde un mismo pod) como **conexiones a destinos de C2/cryptomining conocidos**.

```yaml
- rule: Outbound connection to cryptomining port
  desc: Puerto asociado a pools de mining conocidos (Stratum, XMRig, etc.).
  condition: >
    outbound and container
    and fd.rport in (3333, 4444, 5555, 7777, 8333, 14444)
  output: >
    Posible tráfico de cryptomining (container=%container.name
    pod=%k8s.pod.name dest=%fd.rip:%fd.rport)
  priority: CRITICAL
  tags: [network, mitre_command_and_control]
```

Para observabilidad L3-L7 más rica (identidad de servicio, verbos HTTP, DNS), el CNI **Cilium** con **Hubble** permite ver y exportar cada flow, incluyendo los denegados por `NetworkPolicy`:

```bash
$ hubble observe --verdict DROPPED --namespace prod
Jul 17 07:15:03.221: prod/web-app-7f9c6d8b95-x2kpl:52344 -> prod/db-0:5432 policy-verdict:DROPPED (DENIED by policy allow-web-to-api)
```

Un `DROPPED` inesperado de un pod hacia otro con el que nunca debería hablar es tan valioso como una alerta de Falco: confirma que la `NetworkPolicy` está funcionando *y* que alguien intentó moverse lateralmente.

## 4. Datos

Foco en accesos anómalos a datos sensibles: el datastore de **etcd**, volúmenes de **Secrets** montados, y archivos de credenciales en el filesystem del nodo.

```yaml
- rule: Unexpected process accessing etcd data
  desc: Un proceso distinto de etcd está leyendo su directorio de datos.
  condition: >
    open_read and fd.directory = /var/lib/etcd
    and not proc.name = "etcd"
  output: >
    Acceso inesperado a datos de etcd (proc=%proc.name user=%user.name
    file=%fd.name)
  priority: CRITICAL
  tags: [data, mitre_collection]

- rule: Read of Secret volume by unexpected process
  desc: Lectura de un Secret montado por un proceso fuera del entrypoint del contenedor.
  condition: >
    open_read and container
    and fd.name startswith /var/run/secrets/kubernetes.io
    and not proc.name in (container_entrypoint_procs)
  output: >
    Lectura sospechosa de Secret (proc=%proc.name pod=%k8s.pod.name
    file=%fd.name)
  priority: WARNING
  tags: [data, secrets]
```

Recordar: como `etcd` no cifra por defecto (a menos que se configure *encryption at rest*), cualquier acceso directo a sus archivos en disco expone Secrets en texto plano — de ahí la severidad `CRITICAL`.

## 5. Usuarios

Esta superficie se apoya en el **audit log de la API server** (`--audit-log-path`, `--audit-policy-file`), no en Falco, porque la amenaza ocurre a nivel de llamada a la API, no de syscall en un nodo.

Evento de audit log mostrando un usuario ejecutando `kubectl exec` sobre un pod de producción:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/prod/pods/web-app-7f9c6d8b95-x2kpl/exec?command=%2Fbin%2Fsh&stdin=true&tty=true",
  "verb": "create",
  "user": { "username": "dev-carla", "groups": ["system:authenticated"] },
  "sourceIPs": ["203.0.113.55"],
  "objectRef": { "resource": "pods", "subresource": "exec", "namespace": "prod", "name": "web-app-7f9c6d8b95-x2kpl" },
  "responseStatus": { "code": 101 }
}
```

Query rápida contra el audit log para detectar `exec`/`attach` en namespaces productivos por usuarios que no forman parte del equipo de guardia:

```bash
$ jq -r 'select(.objectRef.subresource=="exec") | "\(.requestReceivedTimestamp) \(.user.username) \(.objectRef.namespace)/\(.objectRef.name)"' audit.log
2026-07-17T07:14:59Z dev-carla prod/web-app-7f9c6d8b95-x2kpl
```

Otra señal de usuario de alto valor: creación de bindings de RBAC de alto privilegio fuera de un pipeline de GitOps conocido —

```bash
$ kubectl get events -A --field-selector reason=Created \
    -o jsonpath='{range .items[?(@.involvedObject.kind=="ClusterRoleBinding")]}{.involvedObject.name}{"\n"}{end}'
```

combinado con el `user.username` del audit log que hizo el `create`, permite atribuir un intento de *privilege escalation* a una identidad concreta.

## 6. Workloads

Acá el foco es el comportamiento del contenedor *en runtime*, comparado contra lo que su imagen debería hacer — el concepto de **immutability**: un contenedor bien construido no necesita escribir binarios nuevos ni escalar privilegios después de arrancar.

```yaml
- rule: Write below binary dir at runtime
  desc: >
    Un proceso escribe en un directorio de binarios del sistema dentro
    de un contenedor — típico de drop de malware o cryptominer.
  condition: >
    container and open_write
    and fd.name pmatch (/bin, /sbin, /usr/bin, /usr/sbin)
  output: >
    Escritura en directorio de binarios en runtime (proc=%proc.name
    file=%fd.name pod=%k8s.pod.name image=%container.image.repository)
  priority: CRITICAL
  tags: [workload, mitre_persistence]

- rule: Setuid or setgid call in container
  desc: Escalación de privilegios dentro de un contenedor vía setuid/setgid.
  condition: >
    container and (evt.type=setuid or evt.type=setgid)
    and not proc.name in (allowed_setuid_procs)
  output: >
    Llamada setuid/setgid sospechosa (proc=%proc.name pod=%k8s.pod.name
    uid=%evt.arg.uid)
  priority: WARNING
  tags: [workload, mitre_privilege_escalation]
```

**Escenario integrado** (así suele plantearse en el examen): un pod de imagen "clean" empieza a consumir CPU al 100%, Falco dispara `Write below binary dir at runtime` porque el atacante bajó un binario de minería a `/usr/bin`, y segundos después dispara `Outbound connection to cryptomining port` porque ese binario se conecta a un pool externo. La correlación de ambas alertas en la misma `k8s.pod.name` confirma cryptojacking con alta confianza, sin necesidad de ver el binario en sí.

## Herramientas alternativas / complementarias

| Herramienta | Mecanismo | Cuándo se usa en vez de (o junto a) Falco |
|---|---|---|
| **Falco** | eBPF / kmod, reglas YAML | Motor de referencia del CKS, cobertura syscall genérica |
| **Tetragon** (Cilium) | eBPF, políticas `TracingPolicy` en CRD | Cuando ya se usa Cilium como CNI y se quiere enforcement in-kernel (no solo alertar, sino bloquear) |
| **Tracee** (Aqua) | eBPF, `Rego`/OPA para reglas | Alternativa open source con foco en forensics y firmas de detección tipo MITRE ATT&CK |
| **auditd** | Kernel audit subsystem de Linux | Superficie de nodo/host, fuera del alcance de contenedores |
| **Kubernetes audit log** | API server | Única fuente para la superficie "usuarios" (llamadas a la API) |
| **Hubble / Cilium** | eBPF a nivel de red | Superficie de red con contexto L3-L7 e identidad de servicio |

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Falco — Documentación oficial: https://falco.org/docs/
- Falco — Reference de reglas y filter fields: https://falco.org/docs/reference/rules/supported-fields/
- Falco — Falcosidekick (outputs): https://github.com/falcosecurity/falcosidekick
- Kubernetes — Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — Audit policy examples: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/#audit-policy
- Cilium — Hubble Observability: https://docs.cilium.io/en/stable/observability/hubble/
- Tetragon — Documentación oficial: https://tetragon.io/docs/
- Tracee (Aqua Security) — Documentación oficial: https://aquasecurity.github.io/tracee/latest/
- Linux `auditd` — man pages: `man auditd`, `man auditctl`, `man ausearch`
- MITRE ATT&CK for Containers: https://attack.mitre.org/matrices/enterprise/containers/