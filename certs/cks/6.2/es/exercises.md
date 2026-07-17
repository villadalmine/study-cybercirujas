# CKS 6.2 — Detectar amenazas en infraestructura física, apps, redes, datos, usuarios y workloads

> Referencia: [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

La herramienta central de este dominio es **Falco**, el runtime security agent de referencia en el ecosistema de Kubernetes (proyecto CNCF graduado). Falco intercepta syscalls a nivel de kernel y las evalúa contra un set de reglas para generar alertas. Complementariamente, el **audit log** del `kube-apiserver` permite detectar actividad sospechosa de usuarios a nivel de API. Los ejercicios siguientes cubren las seis superficies mencionadas en el curriculum agrupando *apps* y *workloads*, ya que en Kubernetes ambas se detectan con el mismo mecanismo (syscalls del contenedor).

En un clúster de examen (o `kind`/`minikube` local), Falco suele venir preinstalado como servicio systemd en el nodo o como DaemonSet. Los pasos verifican primero cuál es el caso antes de operar sobre él.

---

## Ejercicio 1: Amenazas a nivel de infraestructura física (host) — reglas default de Falco

1. Verificá si Falco corre como servicio del sistema operativo en el nodo:

   ```bash
   systemctl status falco
   ```

   Si no existe como servicio, verificá si corre como DaemonSet dentro del clúster:

   ```bash
   kubectl get daemonset -n falco
   ```

2. Revisá la ubicación del archivo de reglas por defecto:

   ```bash
   sudo cat /etc/falco/falco_rules.yaml | grep -A2 "rule: Terminal shell in container"
   ```

3. Seguí el stream de alertas en tiempo real (ajustá el comando según el modo de instalación):

   ```bash
   sudo journalctl -fu falco
   # o, si corre como DaemonSet:
   kubectl logs -n falco -l app=falco -f
   ```

4. Desde otra terminal, generá una alerta a nivel de host abriendo un shell interactivo dentro de cualquier Pod corriendo:

   ```bash
   kubectl run threat-test --image=nginx --restart=Never
   kubectl wait --for=condition=Ready pod/threat-test
   kubectl exec -it threat-test -- /bin/sh
   ```

5. Volvé a la terminal donde seguís el log de Falco y localizá la alerta `Terminal shell in container` (prioridad `Notice`). Identificá en el output los campos `user.name`, `container.id` y `proc.cmdline`.

**Preguntas de verificación:**
- ¿Por qué Falco detecta esta amenaza a nivel de syscall del kernel y no a nivel de API de Kubernetes?
- ¿Qué campo del alert usarías para correlacionar el evento con un Pod específico del clúster?

---

## Ejercicio 2: Amenazas en apps y workloads — contenedor privilegiado y escalado de privilegios

1. Desplegá un Pod privilegiado (comportamiento típico de un workload comprometido intentando escapar del contenedor):

   ```yaml
   # privileged-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: privileged-test
   spec:
     containers:
     - name: privileged-test
       image: nginx
       securityContext:
         privileged: true
   ```

   ```bash
   kubectl apply -f privileged-pod.yaml
   ```

2. Buscá en el log de Falco la alerta `Launch Privileged Container` (prioridad `Warning` o superior) y anotá el `output_fields` completo.

3. Dentro de ese mismo Pod, simulá un intento de acceso al filesystem del host (indicador típico de container escape):

   ```bash
   kubectl exec -it privileged-test -- sh -c "mount | grep -i overlay"
   kubectl exec -it privileged-test -- ls /proc/1/root
   ```

4. Revisá si se disparó la regla `Read/Write from/to any host directory in an unprivileged Pod` o similar, según la configuración de reglas activa.

5. Limpiá el recurso de prueba:

   ```bash
   kubectl delete pod privileged-test threat-test
   ```

**Preguntas de verificación:**
- ¿Qué campo de `securityContext` en el manifiesto del Pod fue la causa raíz de la alerta, y qué política admission (por ejemplo, Pod Security Admission `restricted`) la hubiese bloqueado antes de llegar a ejecutarse?
- ¿Por qué la detección en runtime (Falco) es un control complementario y no un reemplazo de la prevención en admisión?

---

## Ejercicio 3: Amenazas de red — conexión saliente anómala (indicador de cryptomining)

1. Creá una regla custom en `/etc/falco/rules.d/custom_rules.yaml` que detecte conexiones salientes a puertos típicos del protocolo Stratum (usado por mineros de criptomonedas):

   ```yaml
   - rule: Outbound Connection to Stratum Mining Port
     desc: Detecta una conexión saliente desde un contenedor a un puerto asociado al protocolo Stratum
     condition: >
       outbound and container and
       fd.sport in (3333, 4444, 5555, 7777, 8080, 14444)
     output: >
       Conexión sospechosa a puerto de minería (command=%proc.cmdline connection=%fd.name container=%container.name)
     priority: CRITICAL
     tags: [network, mitre_impact]
   ```

2. Recargá Falco para que tome la nueva regla:

   ```bash
   sudo systemctl restart falco
   # o, para DaemonSet:
   kubectl rollout restart daemonset/falco -n falco
   ```

3. Simulá la conexión sospechosa desde un Pod:

   ```bash
   kubectl run net-test --image=busybox --restart=Never -- sleep 3600
   kubectl exec -it net-test -- nc -w 2 example.com 3333
   ```

4. Confirmá que la alerta `Outbound Connection to Stratum Mining Port` aparece en el log con prioridad `Critical`.

5. Como control preventivo, redactá (no apliques todavía) un `NetworkPolicy` que hubiese evitado el tráfico saliente al puerto 3333, restringiendo `egress` solo a los puertos necesarios del namespace.

**Preguntas de verificación:**
- En la condición de la regla, ¿qué diferencia hay entre filtrar por `fd.sport` (puerto local/origen) y `fd.rport` (puerto remoto/destino), y cuál es más apropiado para este caso?
- ¿Por qué detectar esta amenaza con Falco no exime de aplicar `NetworkPolicy` como control preventivo?

---

## Ejercicio 4: Amenazas sobre datos — acceso no autorizado a archivos y Secrets sensibles

1. Agregá a tu archivo de reglas custom una regla que detecte lectura de material sensible del control plane desde dentro de un contenedor:

   ```yaml
   - rule: Sensitive File Read Inside Container
     desc: Detecta lectura de archivos sensibles (credenciales, PKI) desde un contenedor
     condition: >
       open_read and container and
       (fd.name startswith /etc/kubernetes/pki or fd.name = /etc/shadow)
     output: >
       Lectura de archivo sensible (file=%fd.name proc=%proc.cmdline container=%container.name user=%user.name)
     priority: WARNING
     tags: [filesystem, data]
   ```

2. Recargá Falco (mismo comando del ejercicio anterior).

3. Montá un Secret existente en un Pod de prueba y accedé a su contenido, simulando exfiltración de datos:

   ```bash
   kubectl create secret generic demo-secret --from-literal=api-key=super-secreto
   ```

   ```yaml
   # secret-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: secret-test
   spec:
     containers:
     - name: secret-test
       image: busybox
       command: ["sleep", "3600"]
       volumeMounts:
       - name: secret-vol
         mountPath: /etc/secret-data
     volumes:
     - name: secret-vol
       secret:
         secretName: demo-secret
   ```

   ```bash
   kubectl apply -f secret-pod.yaml
   kubectl exec -it secret-test -- cat /etc/secret-data/api-key
   ```

4. Verificá que Kubernetes **no** deja rastro de este acceso a nivel de API (los Secrets montados como volumen se leen del filesystem, no vía API), por lo que solo Falco —a nivel de syscall— detecta el acceso. Contrastá esto consultando el audit log:

   ```bash
   grep secret-test /var/log/kubernetes/audit/audit.log 2>/dev/null
   ```

5. Limpiá los recursos:

   ```bash
   kubectl delete pod secret-test
   kubectl delete secret demo-secret
   ```

**Preguntas de verificación:**
- ¿Por qué el acceso al Secret montado como archivo no queda registrado en el audit log de la API, y qué mecanismo sí lo detecta?
- ¿Qué otra fuente de amenaza a datos (además del filesystem) deberías cubrir con una regla equivalente si el Secret se consumiera como variable de entorno en lugar de volumen?

---

## Ejercicio 5: Amenazas de usuarios — actividad sospechosa vía audit log del kube-apiserver

1. Verificá que el audit log esté habilitado en el `kube-apiserver` y localizá su política:

   ```bash
   ps -ef | grep kube-apiserver | grep -o -- '--audit-policy-file=\S*'
   ps -ef | grep kube-apiserver | grep -o -- '--audit-log-path=\S*'
   ```

2. Inspeccioná la política de auditoría activa y confirmá que registra al menos el nivel `Metadata` para el subresource `pods/exec`:

   ```bash
   sudo cat /etc/kubernetes/audit-policy.yaml
   ```

3. Simulá actividad sospechosa de un usuario: múltiples `exec` interactivos a Pods en un período corto (patrón asociado a movimiento lateral):

   ```bash
   kubectl run audit-test --image=nginx --restart=Never
   kubectl wait --for=condition=Ready pod/audit-test
   kubectl exec -it audit-test -- whoami
   kubectl exec -it audit-test -- id
   ```

4. Filtrá el audit log buscando eventos del subresource `exec`, identificando usuario, `sourceIPs` y timestamp:

   ```bash
   sudo cat /var/log/kubernetes/audit/audit.log | \
     jq -c 'select(.objectRef.subresource=="exec")' | \
     jq -r '"\(.requestReceivedTimestamp) user=\(.user.username) sourceIPs=\(.sourceIPs) pod=\(.objectRef.name)"'
   ```

5. Contrastá esa actividad contra el `RoleBinding`/`ClusterRoleBinding` del usuario para determinar si el `exec` estaba dentro de su alcance autorizado:

   ```bash
   kubectl get rolebindings,clusterrolebindings -A -o json | \
     jq -r '.items[] | select(.subjects[]?.name=="<usuario-a-investigar>") | .metadata.name'
   ```

6. Limpiá el recurso de prueba:

   ```bash
   kubectl delete pod audit-test
   ```

**Preguntas de verificación:**
- ¿Qué nivel mínimo de audit policy (`None`, `Metadata`, `Request`, `RequestResponse`) es necesario para ver *quién* ejecutó el `exec`, sin necesariamente capturar los comandos escritos dentro de la sesión interactiva?
- Si un usuario sin `RoleBinding` para `pods/exec` aparece igual en el audit log con ese verbo, ¿qué indica eso sobre el estado de autorización del clúster?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
- Falco opera con un driver (kernel module o eBPF) que intercepta syscalls directamente en el kernel del host, por debajo de la capa de Kubernetes. Por eso detecta comportamiento *dentro* del contenedor (como abrir un shell) que la API de Kubernetes nunca ve, ya que `kubectl exec` es solo el canal de conexión: la actividad real ocurre a nivel de proceso/syscall en el nodo.
- El campo `container.id` (junto con `k8s.pod.name` si Falco tiene el plugin/metadata de Kubernetes habilitado) permite mapear la alerta al Pod específico del clúster.

**Ejercicio 2**
- El campo `securityContext.privileged: true` fue la causa raíz. Pod Security Admission con el nivel `restricted` (o incluso `baseline`) en el namespace hubiese rechazado el Pod en el momento de la creación, antes de que llegara a ejecutarse.
- La detección en runtime es complementaria porque cubre lo que la prevención no puede anticipar: imágenes comprometidas, binarios maliciosos ejecutados post-deploy, o vulnerabilidades explotadas en tiempo de ejecución que ningún control de admisión estático puede predecir. Prevención y detección son capas independientes de defensa en profundidad.

**Ejercicio 3**
- `fd.sport` es el puerto *local* (origen) de la conexión desde la perspectiva del proceso que la abre; `fd.rport` es el puerto *remoto* (destino). Para detectar una conexión saliente **hacia** un servicio de minería, lo correcto es filtrar por `fd.rport` (el puerto del servidor remoto de mining pool), no por `fd.sport`. La regla del ejercicio tiene ese error intencional para practicar la corrección: debería usar `fd.rport in (...)`.
- Porque Falco es detección, no prevención: genera la alerta después de que el paquete ya salió. `NetworkPolicy` bloquea el tráfico *antes* de que ocurra, reduciendo la superficie de ataque independientemente de si existe una regla de detección para ese patrón específico.

**Ejercicio 4**
- El acceso queda invisible en el audit log del `kube-apiserver` porque una vez que el Secret se monta como volumen, el kubelet ya materializó su contenido como un archivo en el filesystem del nodo (típicamente en `tmpfs`); leerlo con `cat` es una operación de filesystem local, no una llamada a la API de Kubernetes. Solo un agente que monitorea syscalls a nivel de host, como Falco, puede detectar ese acceso.
- Deberías cubrir la lectura de variables de entorno del proceso (por ejemplo vía `/proc/<pid>/environ`) con una regla que detecte `open_read` sobre esa ruta, ya que un Secret consumido como env var queda expuesto en el entorno del proceso y es legible por cualquiera con acceso al namespace de procesos del contenedor.

**Ejercicio 5**
- El nivel `Metadata` es suficiente para ver quién ejecutó el `exec` (usuario, timestamp, `sourceIPs`, Pod objetivo), porque registra el request y su metadata sin el body. Ver los comandos escritos dentro de la sesión interactiva de `exec` requeriría inspección adicional (por ejemplo, Falco con la regla de "Terminal shell in container" o un exec de auditoría a nivel de proceso), ya que el audit log de la API no captura el stream bidireccional de una sesión `exec` interactiva incluso con `RequestResponse`.
- Indica una brecha de autorización: el `RBAC` del clúster no está restringiendo correctamente ese verbo/subresource para ese usuario, lo cual es en sí mismo un hallazgo de seguridad — el acceso no autorizado a `pods/exec` debe cerrarse ajustando el `Role`/`ClusterRole` correspondiente.

</details>