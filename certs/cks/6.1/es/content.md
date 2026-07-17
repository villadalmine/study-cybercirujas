# 6.1 Perform Behavioral Analytics to Detect Malicious Activities

## Contexto

El **behavioral analytics** (análisis de comportamiento) es la práctica de observar la actividad en runtime de procesos, contenedores y el propio cluster —syscalls, conexiones de red, accesos a archivos, llamadas a la API de Kubernetes— para detectar patrones que se desvían de lo esperado. A diferencia del scanning estático (imágenes, manifiestos), acá el foco está en **qué pasa mientras el workload corre**.

En el examen CKS, este dominio se resuelve casi siempre con **Falco** (proyecto graduado de CNCF), aunque el curriculum también menciona el uso de **audit logs de Kubernetes** y herramientas de **process/syscall monitoring** en general (ej. Tracee, sysdig). La idea central es: definir una "baseline" de comportamiento normal y generar alertas cuando algo se sale de esa baseline (shell inesperado en un container, escritura en `/etc`, conexión saliente a un puerto raro, escalada de privilegios, etc.).

## Falco: arquitectura básica

Falco captura eventos del kernel (syscalls) y los evalúa contra un conjunto de reglas escritas en YAML. Dos formas de captura:

- **Kernel module** (`falco-driver`, legacy, vía `insmod`)
- **eBPF probe** (`falco-bpf`), más común hoy y sin necesidad de compilar un módulo de kernel
- **Modern eBPF** (`modern_bpf`), usa CO-RE, no requiere headers del kernel — es el default recomendado en versiones recientes

Instalación típica en un nodo (fuera del cluster, como DaemonSet, o vía Helm):

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_bpf
```

Falco corre como **DaemonSet** para tener visibilidad de todos los nodos. Los eventos se emiten a stdout, a un log file, o vía **Falco Sidekick** a Slack, webhooks, un SIEM, etc.

## Reglas de Falco

Una regla combina una **condition** (expresión sobre campos de syscall/kernel event), una **output** (mensaje formateado) y una **priority**.

Ejemplo — reglas incluidas por default en `falco_rules.yaml`:

```yaml
- rule: Terminal shell in container
  desc: A shell was used as the entrypoint/exec point into a container with an attached terminal.
  condition: >
    spawned_process and container
    and shell_procs and proc.tty != 0
    and container_entrypoint
  output: >
    A shell was spawned in a container with an attached terminal
    (user=%user.name user_loginuid=%user.loginuid %container.info
    shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline terminal=%proc.tty container_id=%container.id image=%container.image.repository)
  priority: NOTICE
  tags: [container, shell, mitre_execution]
```

Salida real cuando alguien hace `kubectl exec -it` con `bash`:

```
17:42:31.123456789: Notice A shell was spawned in a container with an attached terminal
(user=root user_loginuid=-1 container_id=3f2a9b1c8e4d image=nginx shell=bash parent=runc cmdline=bash terminal=34816)
k8s.ns=default k8s.pod=nginx-7d4b8f8c9-abcde container=3f2a9b1c8e4d
```

### Regla custom: escritura en directorio sensible

```yaml
- rule: Write below etc
  desc: An attempt to write to /etc directory
  condition: >
    (open_write and container and
     fd.name startswith /etc)
  output: >
    File below /etc opened for writing (user=%user.name command=%proc.cmdline
    file=%fd.name container_id=%container.id image=%container.image.repository)
  priority: WARNING
  tags: [filesystem, container]
```

### Regla custom: conexión saliente inesperada

```yaml
- rule: Unexpected outbound connection to non-standard port
  desc: Detect outbound connection from container to a port outside allowed range
  condition: >
    outbound and container
    and not fd.sport in (allowed_outbound_ports)
  output: >
    Unexpected outbound connection (command=%proc.cmdline connection=%fd.name
    container_id=%container.id image=%container.image.repository)
  priority: WARNING
  tags: [network]

- list: allowed_outbound_ports
  items: [80, 443, 53]
```

Validar sintaxis de reglas antes de desplegar:

```bash
falco --validate /etc/falco/rules.d/custom_rules.yaml
```

Listar los campos disponibles para condiciones (útil para escribir reglas propias):

```bash
falco --list=container
falco --list=fd
```

## Priorización y tuning (reducir falsos positivos)

En un cluster real, muchas reglas default disparan ruido (ej. herramientas de CI que hacen `exec` legítimo). El approach correcto en producción:

1. Correr Falco en modo *learning* / auditoría por un tiempo.
2. Usar `macro` y `list` para definir excepciones controladas (ej. imágenes o procesos permitidos).
3. Sobrescribir reglas del default (`falco_rules.yaml`) en `falco_rules.local.yaml`, nunca editando el archivo base.

```yaml
- macro: trusted_containers
  condition: (container.image.repository = "myregistry/ci-runner")

- rule: Terminal shell in container
  condition: >
    spawned_process and container
    and shell_procs and proc.tty != 0
    and container_entrypoint
    and not trusted_containers
```

Esto es exactamente el tipo de conocimiento que se evalúa en CKS: **no** desactivar la regla entera, sino acotar la excepción.

## Falcosidekick y respuesta a alertas

Falco por sí solo solo genera el evento. Para reaccionar (alertar, o incluso automatizar una respuesta como matar el pod), se usa **Falcosidekick**, que reenvía outputs a +50 destinos (Slack, Elasticsearch, Prometheus, webhook genérico) y opcionalmente **Falcosidekick-UI** para visualizarlas.

```bash
helm install falcosidekick falcosecurity/falcosidekick \
  --namespace falco \
  --set config.slack.webhookurl="https://hooks.slack.com/services/XXX"
```

## Kubernetes Audit Logs como fuente de behavioral analytics

Además del comportamiento a nivel de syscall, el **audit log de la API de Kubernetes** (visto en el dominio de Cluster Hardening) permite detectar comportamiento anómalo a nivel de control plane: creación repetida de pods con `hostPID`/`hostNetwork`, un ServiceAccount haciendo `list secrets` en todos los namespaces, RBAC bypass intentado, etc.

Ejemplo de policy de audit enfocada en detectar actividad sospechosa:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: RequestResponse
    verbs: ["create", "update", "patch"]
    resources:
      - group: ""
        resources: ["pods"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
```

Un análisis de comportamiento sobre este log (manual, con `jq`, o ingerido en un SIEM) permite detectar, por ejemplo, un `ServiceAccount` leyendo `secrets` fuera de su patrón habitual:

```bash
kubectl logs -n kube-system kube-apiserver-controlplane \
  | jq 'select(.verb=="get" and .objectRef.resource=="secrets")' \
  | jq '.user.username' | sort | uniq -c | sort -rn
```

## Otras herramientas mencionadas en el curriculum

- **Tracee** (Aqua Security): también basado en eBPF, detecta comportamiento sospechoso (rootkit techniques, container escapes) con reglas propias (signatures).
- **sysdig / sysdig inspect**: captura y explora syscalls en detalle (`sysdig -pc`), útil para investigar forense post-incidente, complementario a Falco (que es el motor de detección en tiempo real).

Ejemplo mínimo con `sysdig` para ver toda la actividad de proceso dentro de un container específico:

```bash
sysdig -pc -c spy_users container.id=3f2a9b1c8e4d
```

## Resumen de enfoque para el examen

1. Identificar que una syscall/comportamiento anómalo requiere una **regla de Falco** (no un NetworkPolicy ni un PSA).
2. Saber leer y **modificar** una regla YAML existente (agregar excepción vía macro, cambiar condition).
3. Saber **desplegar Falco como DaemonSet** y verificar que está generando output (`kubectl logs -n falco -l app.kubernetes.io/name=falco`).
4. Relacionar el audit log de la API con detección de actividad maliciosa a nivel de control plane (no solo a nivel de contenedor).

## Referencias

- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Falco — documentación oficial: https://falco.org/docs/
- Falco Rules reference: https://falco.org/docs/reference/rules/
- Falcosidekick: https://github.com/falcosecurity/falcosidekick
- Kubernetes Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Tracee (Aqua Security): https://aquasecurity.github.io/tracee/latest/
- sysdig: https://github.com/draios/sysdig