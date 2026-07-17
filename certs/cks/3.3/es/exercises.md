# Ejercicios guiados: Restrict access to Kubernetes API (CKS 3.3)

> Fuente de referencia: [CNCF CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf). Requisitos: acceso `sudo` al control plane (kubeadm) y `kubectl` configurado como admin del cluster.

---

## Ejercicio 1: Auditar la configuración actual del API server

1. Conectate al nodo control-plane y localizá el manifiesto estático del API server:

   ```bash
   sudo ls /etc/kubernetes/manifests/
   sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

2. Identificá en la sección `spec.containers[0].command` los siguientes flags (si no aparecen explícitamente, anotá cuál es su valor por defecto según la versión de Kubernetes instalada):
   - `--anonymous-auth`
   - `--insecure-port`
   - `--authorization-mode`
   - `--enable-admission-plugins`

3. Confirmá el estado real (no solo el manifiesto) inspeccionando el proceso en ejecución:

   ```bash
   ps -ef | grep kube-apiserver | grep -oE -- '--authorization-mode=[^ ]*|--anonymous-auth=[^ ]*'
   ```

4. Listá los métodos de autenticación habilitados revisando también si existe un webhook de autenticación o un archivo de tokens estáticos configurado:

   ```bash
   sudo grep -E 'authentication-token-webhook|token-auth-file|oidc-issuer-url|client-ca-file' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

**Preguntas de comprensión:**
- ¿Por qué es más confiable revisar `ps -ef` que solo leer el YAML del manifiesto?
- Si `--authorization-mode` incluye `AlwaysAllow`, ¿qué implicancia de seguridad tiene esto sin importar qué RBAC esté definido?

---

## Ejercicio 2: Deshabilitar anonymous access e insecure port

1. Probá el acceso anónimo actual contra el API server usando `curl` sin credenciales:

   ```bash
   curl -k https://localhost:6443/api/v1/namespaces --max-time 3
   ```

2. Observá el código de respuesta HTTP. Si obtenés una respuesta con datos (o un `403` con detalle de objetos), el anonymous access está activo pero sin permisos (o con permisos mínimos vía RBAC).

3. Editá el manifiesto estático del API server para forzar el rechazo de autenticación anónima:

   ```bash
   sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Agregá o modificá la línea del comando:

   ```yaml
   - --anonymous-auth=false
   ```

4. Guardá el archivo. El kubelet detecta el cambio y reinicia automáticamente el pod estático `kube-apiserver`. Verificá que vuelva a estar `Running`:

   ```bash
   watch "sudo crictl ps | grep kube-apiserver"
   ```

5. Repetí el `curl` del paso 1 y confirmá que ahora la conexión es rechazada por falta de autenticación.

**Preguntas de comprensión:**
- ¿Qué diferencia hay entre deshabilitar `anonymous-auth` y simplemente no crear un `RoleBinding` para el usuario `system:anonymous`?
- ¿Por qué editar un manifiesto estático en `/etc/kubernetes/manifests/` no requiere un `kubectl apply` ni un `systemctl restart`?

---

## Ejercicio 3: Restringir acceso con RBAC y validar con `kubectl auth can-i`

1. Creá un namespace y una `ServiceAccount` de prueba:

   ```bash
   kubectl create namespace restricted-api
   kubectl create serviceaccount viewer-sa -n restricted-api
   ```

2. Definí un `Role` que solo permita `get` y `list` sobre `pods`:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-viewer
     namespace: restricted-api
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list"]
   EOF
   ```

3. Enlazá el `Role` a la `ServiceAccount` con un `RoleBinding`:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: pod-viewer-binding
     namespace: restricted-api
   subjects:
   - kind: ServiceAccount
     name: viewer-sa
     namespace: restricted-api
   roleRef:
     kind: Role
     name: pod-viewer
     apiGroup: rbac.authorization.k8s.io
   EOF
   ```

4. Verificá los permisos efectivos usando impersonation, sin necesidad de extraer el token:

   ```bash
   kubectl auth can-i list pods \
     --as=system:serviceaccount:restricted-api:viewer-sa -n restricted-api

   kubectl auth can-i delete pods \
     --as=system:serviceaccount:restricted-api:viewer-sa -n restricted-api

   kubectl auth can-i list secrets \
     --as=system:serviceaccount:restricted-api:viewer-sa -n restricted-api
   ```

**Preguntas de comprensión:**
- ¿Por qué `kubectl auth can-i --as` es preferible a extraer manualmente el token de la `ServiceAccount` y probar con `curl`?
- Si esta `ServiceAccount` necesitara acceder a `pods` en todos los namespaces, ¿qué objeto de RBAC habría que usar en lugar de `Role`/`RoleBinding`?

---

## Ejercicio 4: Restringir el acceso de los kubelets con NodeRestriction

1. Confirmá que el admission controller `NodeRestriction` está habilitado en el API server:

   ```bash
   sudo grep 'enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

2. Identificá las credenciales que usa un kubelet para autenticarse (grupo `system:nodes`):

   ```bash
   sudo cat /etc/kubernetes/kubelet.conf | grep -A2 'client-certificate'
   openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject
   ```

   Confirmá que el `subject` contiene `O=system:nodes` y `CN=system:node:<nombre-del-nodo>`.

3. Intentá, desde el nodo, simular una modificación indebida: usar las credenciales del kubelet para intentar hacer `label` a otro nodo distinto del propio (esto debe fallar por `NodeRestriction`):

   ```bash
   kubectl --kubeconfig=/etc/kubernetes/kubelet.conf label node <otro-nodo> test=intento
   ```

4. Repetí la operación pero sobre el propio nodo del kubelet, que sí debería permitirse:

   ```bash
   kubectl --kubeconfig=/etc/kubernetes/kubelet.conf label node $(hostname) test=ok
   ```

**Preguntas de comprensión:**
- ¿Qué problema de seguridad previene específicamente `NodeRestriction` que RBAC por sí solo no cubriría (dado que todos los kubelets comparten el grupo `system:nodes`)?
- ¿Por qué el `CN` del certificado del kubelet debe seguir el patrón `system:node:<nombre>` para que `NodeRestriction` funcione correctamente?

---

## Ejercicio 5: Restringir el acceso de red al API server

1. Verificá en qué interfaz y puerto escucha el API server:

   ```bash
   sudo ss -tlnp | grep 6443
   ```

2. Revisá si existe una regla de firewall a nivel de host que limite qué IPs pueden alcanzar el puerto 6443 (por ejemplo con `nftables` o `iptables`):

   ```bash
   sudo iptables -L -n | grep 6443
   ```

3. Si el cluster corre en un proveedor cloud o con `firewalld`, restringí el acceso al puerto 6443 solo a las IPs de administración conocidas (ejemplo con `firewalld`):

   ```bash
   sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/24" port protocol="tcp" port="6443" accept'
   sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port protocol="tcp" port="6443" drop'
   sudo firewall-cmd --reload
   ```

4. Validá desde una máquina fuera del rango permitido que la conexión al puerto 6443 ahora es rechazada o se cuelga (timeout), mientras que desde una IP dentro del rango `10.0.0.0/24` sigue funcionando.

**Preguntas de comprensión:**
- ¿Por qué restringir el acceso de red al puerto 6443 es una capa de defensa complementaria (defense in depth) y no un reemplazo de RBAC/autenticación?
- Si el cluster usa un load balancer externo delante del API server, ¿en qué capa conviene aplicar esta restricción de IPs: en el load balancer, en el host, o en ambos? Justificá.

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
- `ps -ef` muestra los flags con los que el proceso realmente arrancó. El YAML del manifiesto puede haber sido editado después de que el kubelet ya levantó el pod (aunque el kubelet lo re-sincroniza), o puede haber flags con valores por defecto que no aparecen explícitos en el archivo pero sí se resuelven en tiempo de ejecución.
- `AlwaysAllow` hace que el authorizer apruebe cualquier request autenticado (o incluso anónimo, si `anonymous-auth` está activo) sin evaluar reglas de RBAC. Cualquier `Role`/`ClusterRole` definido queda sin efecto porque el authorizer nunca llega a consultarlos.

**Ejercicio 2**
- `anonymous-auth=false` rechaza la request en la etapa de **autenticación**: nunca se le asigna una identidad (`system:anonymous`), por lo que ni siquiera entra a la etapa de autorización. No crear un `RoleBinding` para `system:anonymous` deja que la request se autentique igual pero sea denegada en la etapa de **autorización** (RBAC) — sigue siendo autenticada, y si `authorization-mode` incluye `AlwaysAllow` o hay un binding heredado, podría igual tener acceso.
- Los pods estáticos (`static pods`) son gestionados directamente por el kubelet, que vigila el directorio `/etc/kubernetes/manifests/` (`--pod-manifest-path`) y recrea el pod automáticamente ante cualquier cambio en el archivo, sin pasar por el API server ni por `systemd`.

**Ejercicio 3**
- Impersonation evalúa el RBAC real que tendría esa identidad sin necesidad de manejar tokens, exponerlos en la shell history, ni depender de que el token no haya expirado. Es más seguro y más rápido para verificación.
- Se necesitaría un `ClusterRole` combinado con un `ClusterRoleBinding` (o un `RoleBinding` que referencia un `ClusterRole` si se quiere mantener el scope a un namespace, pero para *todos* los namespaces corresponde `ClusterRoleBinding`).

**Ejercicio 4**
- `NodeRestriction` impide que un kubelet modifique objetos `Node` o `Pod` que no le pertenecen (por ejemplo, el kubelet del nodo A no puede taintear/labelear el nodo B, ni modificar el status de pods que no corren en su propio nodo). Sin este admission controller, como todos los kubelets comparten el grupo `system:nodes`, un RBAC basado solo en ese grupo les daría permisos idénticos sobre *todos* los nodos y pods del cluster, no solo los propios.
- `NodeRestriction` usa el `CN` del certificado (`system:node:<nombre>`) para determinar a qué nodo pertenece la identidad y así aplicar la restricción "solo tu propio nodo". Si el `CN` no sigue ese patrón, el admission controller no puede identificar el nodo asociado y la restricción no se aplica correctamente.

**Ejercicio 5**
- La restricción de red reduce la superficie de ataque (defense in depth) impidiendo que un atacante siquiera *intente* autenticarse contra el API server desde una IP no autorizada, pero no reemplaza la autenticación/autorización: si un atacante compromete una máquina dentro del rango permitido, igual necesita credenciales válidas y los permisos RBAC correspondientes para hacer algo.
- Conviene aplicarla en **ambas** capas cuando sea posible: en el load balancer (o security group del cloud provider) para bloquear tráfico antes de que llegue a la red del cluster, y en el host como capa adicional en caso de que el load balancer esté mal configurado o el atacante tenga acceso a la red interna.

</details>