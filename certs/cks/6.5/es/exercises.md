# CKS 6.5 — Use Kubernetes audit logs to monitor access

> Fuente de referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf) · [Kubernetes docs — Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)

Los ejercicios asumen un cluster tipo `kubeadm` donde el `kube-apiserver` corre como static pod (`/etc/kubernetes/manifests/kube-apiserver.yaml`). Ejecutalos como `root` o con `sudo` en el control plane.

---

## Ejercicio 1 — Habilitar audit logging con backend de archivo (log backend)

1. Creá el directorio donde va a vivir la audit policy y los logs:

   ```bash
   sudo mkdir -p /etc/kubernetes/audit
   sudo mkdir -p /var/log/kubernetes/audit
   ```

2. Escribí una policy mínima que audite todo a nivel `Metadata`:

   ```bash
   cat <<EOF | sudo tee /etc/kubernetes/audit/audit-policy.yaml
   apiVersion: audit.k8s.io/v1
   kind: Policy
   rules:
   - level: Metadata
   EOF
   ```

3. Editá el manifest del `kube-apiserver` para agregar los flags de auditing:

   ```bash
   sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Agregá bajo `spec.containers[0].command`:

   ```yaml
   - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
   - --audit-log-path=/var/log/kubernetes/audit/audit.log
   - --audit-log-maxage=7
   - --audit-log-maxbackup=3
   - --audit-log-maxsize=100
   ```

4. Montá ambos paths (policy y directorio de logs) como `hostPath` en `volumes` y `volumeMounts` del mismo pod:

   ```yaml
   volumeMounts:
   - name: audit-policy
     mountPath: /etc/kubernetes/audit/audit-policy.yaml
     readOnly: true
   - name: audit-log
     mountPath: /var/log/kubernetes/audit
   volumes:
   - name: audit-policy
     hostPath:
       path: /etc/kubernetes/audit/audit-policy.yaml
       type: File
   - name: audit-log
     hostPath:
       path: /var/log/kubernetes/audit
       type: DirectoryOrCreate
   ```

5. Guardá el archivo. El kubelet detecta el cambio del static pod y reinicia el `kube-apiserver` automáticamente. Esperá a que vuelva a estar `Running`:

   ```bash
   sudo crictl ps | grep kube-apiserver
   ```

6. Generá tráfico y confirmá que se están escribiendo eventos:

   ```bash
   kubectl get pods -A
   sudo tail -n 5 /var/log/kubernetes/audit/audit.log
   ```

**Preguntas de comprobación:**
1. ¿Qué pasa si el `kube-apiserver` no arranca después de editar el manifest? ¿Cómo lo debuggeás sin `kubectl` (porque el API server puede estar caído)?
2. ¿Por qué es necesario montar `audit-policy.yaml` como `hostPath` de tipo `File` (y no `Directory`) dentro del pod estático?
3. ¿Qué controla `--audit-log-maxsize` y qué pasa cuando se supera ese valor?

---

## Ejercicio 2 — Diseñar una audit policy granular (niveles y reglas por recurso)

1. Los niveles de auditing, de menor a mayor detalle, son: `None`, `Metadata`, `Request`, `RequestResponse`. Reescribí la policy para que:
   - No audite nada del recurso `events` (genera ruido).
   - Audite a nivel `RequestResponse` todo lo referido a `secrets` y `configmaps`.
   - Audite a nivel `Metadata` los `pods` en el verbo `exec` (para detectar accesos interactivos).
   - Audite a nivel `Metadata` el resto de los requests por default.

   ```bash
   cat <<EOF | sudo tee /etc/kubernetes/audit/audit-policy.yaml
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages:
     - RequestReceived
   rules:
   - level: None
     resources:
     - group: ""
       resources: ["events"]

   - level: RequestResponse
     resources:
     - group: ""
       resources: ["secrets", "configmaps"]

   - level: Metadata
     resources:
     - group: ""
       resources: ["pods"]
       subresources: ["exec", "attach"]

   - level: Metadata
   EOF
   ```

2. Aplicá el cambio (no hace falta tocar el manifest del apiserver, la policy ya está referenciada). El kubelet no recarga en caliente el archivo referenciado por `--audit-policy-file`, así que forzá el reinicio moviendo temporalmente el manifest:

   ```bash
   sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
   sleep 5
   sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```

3. Verificá que las reglas están activas leyendo un secret y haciendo `exec` en un pod:

   ```bash
   kubectl create secret generic demo --from-literal=k=v
   kubectl get secret demo -o yaml
   kubectl run nginx --image=nginx --restart=Never
   kubectl exec nginx -- ls /
   ```

4. Filtrá el log para confirmar que `secrets` quedó con `responseObject` (nivel `RequestResponse`) y que `events` no aparece:

   ```bash
   sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log | tail -n 1 | jq .
   sudo grep '"resource":"events"' /var/log/kubernetes/audit/audit.log | wc -l
   ```

**Preguntas de comprobación:**
1. ¿Por qué el orden de las reglas en la policy es importante? ¿Qué regla gana si un request matchea con más de una?
2. ¿Qué diferencia hay entre auditar `pods` con `subresources: ["exec"]` y auditar `pods` sin especificar `subresources`?
3. ¿Qué riesgo de seguridad y de performance/almacenamiento tiene usar `RequestResponse` en `secrets`?
4. ¿Qué significa `omitStages: ["RequestReceived"]` y por qué suele configurarse así en la mayoría de los clusters?

---

## Ejercicio 3 — Backend webhook: enviar audit events a un receptor externo

1. Creá un archivo de configuración de webhook apuntando a un endpoint HTTP (simulado localmente con `netcat` o un pod receptor real):

   ```bash
   cat <<EOF | sudo tee /etc/kubernetes/audit/webhook-config.yaml
   apiVersion: v1
   kind: Config
   clusters:
   - name: audit-webhook
     cluster:
       server: https://audit-sink.example.com/audit
   contexts:
   - context:
       cluster: audit-webhook
       user: ""
     name: audit-webhook-context
   current-context: audit-webhook-context
   EOF
   ```

2. Agregá los flags de webhook al manifest del `kube-apiserver`, en paralelo al backend de log (se pueden usar ambos backends a la vez):

   ```yaml
   - --audit-webhook-config-file=/etc/kubernetes/audit/webhook-config.yaml
   - --audit-webhook-initial-backoff=5s
   ```

3. Montá `webhook-config.yaml` con un `hostPath` igual que hiciste con la policy en el Ejercicio 1.

4. Guardá y esperá el reinicio del static pod. Confirmá en los logs del contenedor que no hay errores de conexión al webhook:

   ```bash
   sudo crictl logs $(sudo crictl ps --name kube-apiserver -q) 2>&1 | grep -i webhook
   ```

**Preguntas de comprobación:**
1. ¿Cuál es la diferencia principal entre el backend `log` y el backend `webhook` en términos de dónde queda la responsabilidad de persistir y rotar los eventos?
2. Si el endpoint del webhook está caído, ¿el `kube-apiserver` deja de responder requests de los clientes? ¿Por qué el modo `batch` (default) es relevante acá?
3. ¿Qué ventaja de seguridad tiene enviar los audit logs a un sistema externo (SIEM) en vez de dejarlos solo en el nodo del control plane?

---

## Ejercicio 4 — Analizar audit logs para detectar actividad sospechosa

1. Generá algunos eventos "sospechosos" a propósito: un usuario intentando listar `secrets` sin permiso, y un `exec` a un pod:

   ```bash
   kubectl create serviceaccount limited
   kubectl create rolebinding limited-view --clusterrole=view --serviceaccount=default:limited
   kubectl auth can-i list secrets --as=system:serviceaccount:default:limited
   kubectl exec nginx -- whoami
   ```

2. Con `jq`, extraé todos los eventos que resultaron en `Forbidden` (código HTTP 403):

   ```bash
   sudo cat /var/log/kubernetes/audit/audit.log \
     | jq 'select(.responseStatus.code == 403)'
   ```

3. Extraé todos los eventos de `exec` en pods, mostrando usuario, namespace y pod:

   ```bash
   sudo cat /var/log/kubernetes/audit/audit.log \
     | jq 'select(.objectRef.subresource == "exec") | {user: .user.username, namespace: .objectRef.namespace, pod: .objectRef.name, time: .requestReceivedTimestamp}'
   ```

4. Contá cuántos requests hizo cada `user.username` distinto (útil para detectar una cuenta comprometida generando tráfico anómalo):

   ```bash
   sudo cat /var/log/kubernetes/audit/audit.log \
     | jq -r '.user.username' | sort | uniq -c | sort -rn
   ```

**Preguntas de comprobación:**
1. ¿Qué campo del evento de audit te dice si el request fue autorizado o rechazado, y qué otro campo te dice por qué (motivo del `Forbidden`)?
2. Si necesitás correlacionar un `exec` sospechoso con la imagen del pod y el nodo donde corría, ¿esa información está en el audit log del `kube-apiserver`, o hace falta otra fuente (por ejemplo logs del kubelet o runtime)?
3. ¿Por qué el audit log por sí solo no reemplaza una herramienta de runtime security (como Falco) para detectar, por ejemplo, ejecución de un binario malicioso *dentro* del container?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

### Ejercicio 1
1. Si el `kube-apiserver` no levanta, revisá los logs del contenedor directamente vía el runtime del nodo (`crictl ps -a`, `crictl logs <container-id>`), ya que `kubectl logs` depende del propio API server que está caído. También podés inspeccionar `journalctl -u kubelet` para ver si el kubelet reporta errores creando el static pod (por ejemplo, un YAML mal formado o un path de `hostPath` inexistente).
2. Porque `hostPath` con `type: File` valida que el path exista y sea un archivo regular en el momento de crear el pod, evitando que Kubernetes lo trate como si fuera (o cree) un directorio. Usar `Directory` ahí apuntaría a la ruta equivocada o fallaría el mount.
3. `--audit-log-maxsize` define el tamaño máximo en megabytes de un archivo de audit log antes de rotarlo. Al superarse, se rota el archivo (comprimido o renombrado según implementación) y se empieza a escribir uno nuevo; junto con `--audit-log-maxbackup` y `--audit-log-maxage` controla cuántos backups y por cuántos días se retienen.

### Ejercicio 2
1. Las reglas se evalúan en orden y se aplica la **primera que matchea**; el resto se ignoran para ese request. Por eso las reglas más específicas (`secrets`, `pods/exec`) deben ir antes que la regla general (`level: Metadata` sin filtros) que actúa como catch-all al final.
2. Sin `subresources`, la regla audita cualquier operación sobre `pods` (get, list, create, delete, etc.) al nivel indicado. Con `subresources: ["exec"]`, solo audita el subrecurso `exec` (y en el ejemplo también `attach`), dejando el resto de las operaciones sobre pods cubiertas por otra regla (en este caso, la regla `Metadata` general).
3. `RequestResponse` en `secrets` graba el body completo del request y de la response, lo que significa que **el valor de los secrets queda persistido en texto plano dentro del audit log**. Esto es un riesgo de seguridad serio (el audit log se vuelve un objetivo de alto valor) y además incrementa mucho el tamaño de los logs. En la práctica, para `secrets` suele preferirse `Metadata` (para saber quién accedió, cuándo y a qué) y no `RequestResponse`.
4. `RequestReceived` es la etapa que se audita apenas el API server recibe el request, antes de procesarlo. Omitirla evita duplicar cada operación (que ya queda registrada en las etapas `ResponseStarted`/`ResponseComplete`/`Panic`) y reduce el volumen de eventos casi a la mitad sin perder información útil.

### Ejercicio 3
1. Con el backend `log`, Kubernetes escribe los eventos a un archivo local en el nodo del control plane, y sos vos quien gestiona rotación, retención y envío a otro lado. Con el backend `webhook`, el `kube-apiserver` envía cada evento (o lote de eventos) vía HTTP POST a un endpoint externo, delegando la persistencia, indexación y retención a ese sistema receptor (por ejemplo un SIEM o un colector de logs).
2. El `kube-apiserver` sigue respondiendo requests normalmente; el envío de audit events al webhook es asíncrono y no bloquea el path de servicio de la API (salvo que se configure explícitamente en modo `blocking`, que no es el default). El modo `batch` (default) agrupa eventos y los reintenta con backoff, así que caídas temporales del endpoint no afectan la disponibilidad del cluster, aunque sí pueden causar pérdida de eventos si el buffer se llena.
3. Centralizar los audit logs en un SIEM externo permite correlacionar actividad del cluster con otras fuentes (red, IAM, otros clusters), preservar los logs si el nodo del control plane se ve comprometido (evitando que un atacante los borre para cubrir sus huellas), y aplicar alertas/detección en tiempo real sobre el stream de eventos.

### Ejercicio 4
1. `responseStatus.code` indica el código HTTP resultante (403 = Forbidden). El campo `annotations["authorization.k8s.io/decision"]` (junto con `annotations["authorization.k8s.io/reason"]`) indica la decisión del autorizador y el motivo textual del rechazo.
2. Esa información (imagen, nodo) generalmente **no** está en el audit log del `kube-apiserver`: el evento de `exec` solo confirma que el usuario X pidió ejecutar un comando en el pod Y del namespace Z, pero no loguea el contenido del stream de exec ni detalles del contenedor en runtime. Para eso hay que cruzar con `kubectl describe pod` (imagen, nodeName) o logs del kubelet/container runtime en el nodo correspondiente.
3. El audit log solo ve **llamadas a la API de Kubernetes** (create, exec, delete, etc.), no la actividad *dentro* del container una vez que el proceso está corriendo. Un binario malicioso ejecutado dentro de un container que ya tenía acceso legítimo no genera ningún nuevo evento de API después del `exec` inicial. Herramientas como Falco monitorean syscalls a nivel de kernel/runtime y sí pueden detectar esa actividad post-exec.

</details>