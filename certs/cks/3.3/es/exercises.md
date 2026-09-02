# Tema 3.3 — Restringir el acceso a la API de Kubernetes (CKS v1.34)

> **Supuesto del entorno de laboratorio:** un clúster aprovisionado con `kubeadm`. Los componentes del plano de control corren como **static pods**, así que el manifiesto del `kube-apiserver` vive en `/etc/kubernetes/manifests/kube-apiserver.yaml`. Editar ese archivo hace que el kubelet reinicie el API server automáticamente (fijate en que el contenedor se recree). Ejecutá cada paso como `root` en el nodo del plano de control salvo que se indique lo contrario.
>
> **Nota de peligro:** un `kube-apiserver.yaml` malformado hace que el API server no arranque y `kubectl` deje de responder. Hacé siempre un backup con `cp` primero y sabé cómo recuperarte leyendo los logs del kubelet/contenedor.

---

## Ejercicio 1 — Deshabilitar la autenticación anónima

El API server trata cualquier petición que ningún autenticador acepte como el usuario anónimo `system:anonymous` del grupo `system:unauthenticated` **cuando `--anonymous-auth=true`**. En un clúster endurecido, o la deshabilitás por completo o la acotás únicamente a los endpoints de salud (Ejercicio 1b).

### Pasos

1. Confirmá la configuración actual en el API server en ejecución:

   ```bash
   ps -ef | grep kube-apiserver | grep -o 'anonymous-auth=[a-z]*'
   ```

   Si no imprime nada, el flag no está definido — y el **valor por defecto es `true`**.

2. Probá el acceso anónimo desde *fuera* de cualquier contexto de kubeconfig. Usá la dirección anunciada del API server:

   ```bash
   APISERVER=https://$(kubectl -n default get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'):6443
   curl -k $APISERVER/api/v1/namespaces/default/pods
   ```

   Esperado (auth anónima activada, pero RBAC deniega) — HTTP 403, fijate en el nombre de usuario:

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\" ...",
     "reason": "Forbidden",
     "code": 403
   }
   ```

3. Hacé un backup y editá el manifiesto:

   ```bash
   cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
   ```

   Agregá (o cambiá) el flag bajo `spec.containers[0].command`:

   ```yaml
       - --anonymous-auth=false
   ```

4. Esperá a que el pod del API server se recree y volvé a probar:

   ```bash
   crictl ps | grep kube-apiserver          # watch for a fresh container / new age
   curl -k $APISERVER/api/v1/namespaces/default/pods
   ```

   Esperado ahora — HTTP 401 (rechazado antes incluso de que corra la autorización):

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "Unauthorized",
     "reason": "Unauthorized",
     "code": 401
   }
   ```

> ❓ **Comprobá tu comprensión**
> 1. En el paso 2 la respuesta fue `403 Forbidden`, pero en el paso 4 pasó a ser `401 Unauthorized`. ¿Qué cambió en el pipeline de procesamiento de peticiones, y qué etapa produjo cada código?
> 2. ¿Por qué deshabilitar la auth anónima *no alcanza* por sí solo para decir "la API está blindada"? ¿Qué sigue gobernando lo que puede hacer una identidad autenticada?
> 3. Un compañero dice que `--anonymous-auth=false` rompió el health check de su balanceador de carga externo que pega a `/healthz`. ¿Por qué, y cuál es la solución moderna que evita rehabilitar el acceso anónimo indiscriminado?

---

## Ejercicio 1b — Acotar el acceso anónimo solo a los endpoints de salud (`AnonymousAuthConfigurableEndpoints`)

Desde la v1.32 la funcionalidad `AnonymousAuthConfigurableEndpoints` (habilitada por defecto en v1.34) te permite mantener el acceso anónimo **solo** para rutas no autenticadas específicas (`/healthz`, `/livez`, `/readyz`) mientras todo lo demás devuelve 401. Esta es la respuesta correcta en producción al problema del "se rompió la sonda de salud".

### Pasos

1. Creá un archivo `AuthenticationConfiguration` en el nodo del plano de control, por ejemplo `/etc/kubernetes/authn/anon.yaml`:

   ```yaml
   apiVersion: apiserver.config.k8s.io/v1beta1
   kind: AuthenticationConfiguration
   anonymous:
     enabled: true
     conditions:
     - path: /livez
     - path: /readyz
     - path: /healthz
   ```

2. Referencialo desde el manifiesto del API server y **quitá** el flag `--anonymous-auth` (son mutuamente excluyentes; definir ambos hace que el API server se niegue a arrancar):

   ```yaml
       - --authentication-config=/etc/kubernetes/authn/anon.yaml
   ```

3. Asegurate de que el archivo esté montado dentro del static pod. Agregá un volumen `hostPath` + `volumeMount` (los static pods no ven los archivos del host de otro modo):

   ```yaml
       volumeMounts:
       - name: authn-config
         mountPath: /etc/kubernetes/authn
         readOnly: true
   ...
     volumes:
     - name: authn-config
       hostPath:
         path: /etc/kubernetes/authn
         type: DirectoryOrCreate
   ```

4. Verificá el acotamiento después de que el API server reinicie:

   ```bash
   curl -k $APISERVER/healthz        # expect: ok
   curl -k $APISERVER/api/v1/nodes   # expect: 401 Unauthorized
   ```

> ❓ **Comprobá tu comprensión**
> 1. ¿Qué pasa al arrancar el API server si especificás **ambos**, `--anonymous-auth=true` y `--authentication-config` con un bloque `anonymous`?
> 2. ¿Por qué el archivo `AuthenticationConfiguration` necesita un montaje de volumen `hostPath`, mientras que el flag `--anonymous-auth` no necesitaba montar nada?

---

## Ejercicio 2 — Verificar que no haya un puerto de servicio inseguro

Históricamente el API server exponía un `--insecure-port` no autenticado (por defecto 8080). Este flag fue **eliminado por completo en v1.20**; en v1.34 no hay nada que deshabilitar, pero tenés que ser capaz de *demostrar* que el API server sirve únicamente sobre TLS en el 6443.

### Pasos

1. Confirmá que no existe ningún listener inseguro/en texto plano en localhost:

   ```bash
   ps -ef | grep kube-apiserver | grep -oE 'insecure-port=[0-9]+' || echo "no insecure-port flag (expected on v1.20+)"
   ```

2. Confirmá que el único listener es el puerto seguro y que el texto plano es rechazado:

   ```bash
   ss -tlnp | grep kube-apiserver          # expect :6443 only
   curl http://127.0.0.1:8080/api          # expect: connection refused
   ```

3. Confirmá que el puerto seguro exige una credencial de cliente:

   ```bash
   curl -k $APISERVER/api/v1/nodes          # 401 (no creds) — not a plaintext 200
   ```

> ❓ **Comprobá tu comprensión**
> 1. En un clúster v1.34, si `ps` no muestra ningún `--insecure-port`, ¿el puerto inseguro está deshabilitado o ausente — y esa distinción importa para la respuesta del examen?
> 2. Antes de la v1.20, ¿por qué `--insecure-port=8080` se consideraba un bypass crítico incluso con RBAC habilitado? (Pista: ¿qué etapas del pipeline salteaba el puerto inseguro?)

---

## Ejercicio 3 — RBAC de mínimo privilegio: un Role de solo lectura acotado a un namespace

La autenticación solo prueba *quién* sos; **RBAC** decide *qué* podés hacer. Acá construís un `Role` mínimo que otorga acceso de solo lectura a los pods de un namespace y nada más, y después demostrás los límites.

### Pasos

1. Creá el namespace y un ServiceAccount que hará de identidad:

   ```bash
   kubectl create namespace team-a
   kubectl -n team-a create serviceaccount viewer
   ```

2. Escribí un `Role` estrictamente acotado (verbos limitados a verbos de lectura; recursos limitados a pods y sus logs):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: team-a
     name: pod-reader
   rules:
   - apiGroups: [""]
     resources: ["pods", "pods/log"]
     verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```

3. Vinculá el Role al ServiceAccount con un `RoleBinding` (acotado al namespace — los permisos aplican solo dentro de `team-a`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     namespace: team-a
     name: viewer-can-read-pods
   subjects:
   - kind: ServiceAccount
     name: viewer
     namespace: team-a
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl apply -f viewer-binding.yaml
   ```

4. Probá los límites exactos con `kubectl auth can-i --as=<serviceaccount>`:

   ```bash
   kubectl -n team-a auth can-i list pods   --as=system:serviceaccount:team-a:viewer   # yes
   kubectl -n team-a auth can-i delete pods --as=system:serviceaccount:team-a:viewer   # no
   kubectl -n team-b auth can-i list pods   --as=system:serviceaccount:team-a:viewer   # no
   kubectl -n team-a auth can-i get secrets --as=system:serviceaccount:team-a:viewer   # no
   ```

5. Enumerá *todo* lo que la identidad puede hacer — la forma más rápida de detectar permisos de más:

   ```bash
   kubectl -n team-a auth can-i --list --as=system:serviceaccount:team-a:viewer
   ```

   Esperado (recortado):

   ```
   Resources    Non-Resource URLs   Resource Names   Verbs
   pods         []                  []               [get list watch]
   pods/log     []                  []               [get list watch]
   ...
   ```

> ❓ **Comprobá tu comprensión**
> 1. El `RoleBinding` vive en `team-a`. Si quisieras que `viewer` leyera pods en *todos* los namespaces con un solo permiso, ¿qué dos objetos usarías en su lugar, y cuál está acotado al namespace y cuál al clúster?
> 2. ¿Por qué `auth can-i list pods` en `team-b` devolvió `no`, si las reglas del Role `pod-reader` nunca mencionan namespaces?
> 3. La cadena completa del sujeto es `system:serviceaccount:team-a:viewer`. Descifrá cada segmento separado por dos puntos. ¿De qué grupo es miembro automáticamente este SA?

---

## Ejercicio 4 — Node authorization + admisión NodeRestriction

Los kubelets se autentican como `system:node:<nodeName>` en el grupo `system:nodes`. Dos mecanismos los confinan: el **Node authorizer** (un modo de autorización que otorga a los kubelets solo las lecturas/escrituras de la API que necesitan) y el **plugin de admisión NodeRestriction** (impide que un kubelet comprometido edite los objetos de *otros* nodos o se etiquete a sí mismo para colarse en scheduling restringido).

### Pasos

1. Confirmá que ambos están activos en el API server:

   ```bash
   ps -ef | grep kube-apiserver | grep -oE 'authorization-mode=[^ ]+'
   ps -ef | grep kube-apiserver | grep -oE 'enable-admission-plugins=[^ ]+'
   ```

   Se espera que contenga:

   ```
   authorization-mode=Node,RBAC
   enable-admission-plugins=NodeRestriction
   ```

   Si falta, editá `/etc/kubernetes/manifests/kube-apiserver.yaml`:

   ```yaml
       - --authorization-mode=Node,RBAC
       - --enable-admission-plugins=NodeRestriction
   ```

   > El orden importa: `Node` debe preceder a `RBAC`; los autorizadores se consultan de izquierda a derecha y gana el primer "allow".

2. Suplantá una identidad de kubelet y confirmá que el Node authorizer la acota. Un nodo puede leer *su propio* objeto Node pero no debe poder listar todos los secrets:

   ```bash
   NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
   kubectl auth can-i get  nodes/$NODE --as=system:node:$NODE --as-group=system:nodes   # yes
   kubectl auth can-i list secrets     --as=system:node:$NODE --as-group=system:nodes   # no
   ```

3. Demostrá qué bloquea **NodeRestriction** — un kubelet mutando un nodo *distinto*. Simulá que el nodo `nodeA` intenta etiquetar a `nodeB`:

   ```bash
   kubectl label node otherNode color=red \
     --as=system:node:nodeA --as-group=system:nodes
   ```

   Esperado — la admisión (no RBAC) lo rechaza:

   ```
   Error from server (Forbidden): nodes "otherNode" is forbidden:
   node "nodeA" is not allowed to modify node "otherNode"
   ```

4. Mostrá que NodeRestriction también impide que un kubelet elimine etiquetas relevantes para la seguridad en *sí mismo* (por ejemplo `node-restriction.kubernetes.io/*`), lo que de otro modo le permitiría esquivar el aislamiento por `nodeAffinity`:

   ```bash
   kubectl label node nodeA node-restriction.kubernetes.io/tier- \
     --as=system:node:nodeA --as-group=system:nodes
   # Forbidden: is not allowed to modify labels: node-restriction.kubernetes.io/tier
   ```

> ❓ **Comprobá tu comprensión**
> 1. El **Node authorizer** y el plugin de admisión **NodeRestriction** restringen ambos a los kubelets. ¿En qué etapa del pipeline corre cada uno, y por qué necesitás *ambos* en lugar de uno solo?
> 2. En `authorization-mode=Node,RBAC`, ¿por qué `Node` debe ir primero? ¿Qué se rompería si una petición es denegada por `Node` pero permitida por `RBAC`?
> 3. El prefijo de etiqueta `node-restriction.kubernetes.io/` es especial. ¿Qué ataque previene protegerlo cuando lo usás en el `nodeAffinity` de un pod?

---

## Ejercicio 5 — Dejar de montar tokens de ServiceAccount en pods que no los necesitan

Todo pod que monta un token de SA sostiene una credencial viva de la API. Un contenedor comprometido puede reutilizarla. Deshabilitá el automontaje donde la carga de trabajo nunca llama a la API.

### Pasos

1. Inspeccioná un pod en ejecución — el token se monta en una ruta bien conocida:

   ```bash
   kubectl run probe --image=nginx --restart=Never
   kubectl exec probe -- ls /var/run/secrets/kubernetes.io/serviceaccount
   # ca.crt  namespace  token
   ```

2. Desactivá el automontaje a nivel de **ServiceAccount** (aplica a todos los pods que lo usen, salvo que el pod lo sobrescriba):

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: no-api
     namespace: default
   automountServiceAccountToken: false
   ```

3. O sobrescribilo por **pod** (tiene precedencia sobre el ajuste del SA):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened
   spec:
     serviceAccountName: no-api
     automountServiceAccountToken: false
     containers:
     - name: app
       image: nginx
   ```

4. Verificá que no haya ningún token presente:

   ```bash
   kubectl exec hardened -- ls /var/run/secrets/kubernetes.io/serviceaccount
   # ls: cannot access ...: No such file or directory
   ```

5. Confirmá que el SA `default` de un namespace no está silenciosamente sobreprivilegiado y preferí un SA con propósito específico antes que `default`:

   ```bash
   kubectl auth can-i --list --as=system:serviceaccount:default:default
   ```

> ❓ **Comprobá tu comprensión**
> 1. Si el ServiceAccount define `automountServiceAccountToken: false` pero el Pod define `true`, ¿cuál gana y por qué?
> 2. Desactivar el automontaje elimina el *archivo* de credencial. ¿Cambia lo que ese SA está *autorizado* a hacer si el token se obtuviera por otra vía? ¿Cuál es el control complementario?
> 3. Los tokens de SA modernos montados en pods son tokens proyectados "bound" en lugar de los viejos tokens de Secret sin expiración. Nombrá dos propiedades que hacen que los tokens bound sean más difíciles de abusar.

---

## Ejercicio 6 — Aprovisionar un usuario humano con un certificado de cliente X.509 y la API de CSR, y después acotarlo

Kubernetes no tiene objetos de usuario; un "usuario" es simplemente un certificado de cliente cuyos `CN`/`O` se mapean a nombre de usuario/grupos. Vas a emitir uno mediante la API integrada `CertificateSigningRequest` y restringirlo con RBAC.

### Pasos

1. Generá una clave y una CSR. El `CN` se convierte en el nombre de usuario, el `O` en el grupo:

   ```bash
   openssl genrsa -out dev.key 2048
   openssl req -new -key dev.key -out dev.csr -subj "/CN=dev/O=developers"
   ```

2. Enviala como un `CertificateSigningRequest` de Kubernetes con el signer de cliente del kube-apiserver:

   ```yaml
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: dev
   spec:
     request: <BASE64_OF_dev.csr>
     signerName: kubernetes.io/kube-apiserver-client
     expirationSeconds: 86400
     usages:
     - client auth
   ```

   ```bash
   # produce the base64 (single line, no wrapping):
   cat dev.csr | base64 | tr -d '\n'
   kubectl apply -f dev-csr.yaml
   ```

3. Aprobá y extraé el certificado firmado:

   ```bash
   kubectl get csr                     # dev  ...  Pending
   kubectl certificate approve dev
   kubectl get csr dev -o jsonpath='{.status.certificate}' | base64 -d > dev.crt
   ```

4. Armá un contexto de kubeconfig para la nueva identidad:

   ```bash
   kubectl config set-credentials dev --client-key=dev.key --client-certificate=dev.crt --embed-certs=true
   kubectl config set-context dev --cluster=kubernetes --user=dev
   ```

5. Otorgale algo acotado (reutilizá el patrón `pod-reader` o un RoleBinding acotado al namespace hacia el *usuario*, no a un SA):

   ```bash
   kubectl -n team-a create rolebinding dev-read \
     --role=pod-reader --user=dev
   ```

6. Probá bajo el nuevo contexto:

   ```bash
   kubectl --context=dev -n team-a get pods    # works
   kubectl --context=dev -n team-a get secrets # Forbidden
   ```

> ❓ **Comprobá tu comprensión**
> 1. ¿De dónde salieron, dentro del certificado, el *nombre de usuario* y el *grupo*, y a qué `kind` de sujeto RBAC vinculás para un usuario X.509 (frente a una carga de trabajo)?
> 2. Definiste `expirationSeconds: 86400`. ¿Por qué es preferible un certificado de cliente de vida corta, y cuál es el costo operativo? (Contrastalo con el hecho de que Kubernetes **no tiene lista de revocación de certificados integrada**.)
> 3. Si hubieras firmado la CSR con tu propia CA fuera del clúster en lugar de usar el signer `kubernetes.io/kube-apiserver-client`, ¿qué tiene que ser cierto respecto de `--client-ca-file` en el API server para que el certificado autentique?

---

## Ejercicio 7 — Restringir el acceso a la API del kubelet

El kubelet expone su propia API (puerto 10250). Si acepta peticiones anónimas o sirve el puerto de solo lectura obsoleto (10255), un atacante en la red del nodo puede leer datos de pods o hacer exec dentro de contenedores, salteándose el API server por completo.

### Pasos

1. Inspeccioná la configuración del kubelet (kubeadm la guarda en `/var/lib/kubelet/config.yaml`):

   ```bash
   grep -E 'anonymous|authorization|readOnlyPort|webhook' /var/lib/kubelet/config.yaml
   ```

   Valores endurecidos:

   ```yaml
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
   authorization:
     mode: Webhook
   readOnlyPort: 0
   ```

2. Demostrá que el acceso anónimo al kubelet está cerrado. Desde el nodo:

   ```bash
   curl -sk https://localhost:10250/pods          # expect: 401 Unauthorized
   curl -s  http://localhost:10255/pods           # expect: connection refused (read-only port off)
   ```

3. Demostrá que el acceso autorizado sigue funcionando usando el certificado de cliente del API server (autorización Webhook delegada al API server):

   ```bash
   curl -sk https://localhost:10250/pods \
     --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
     --key  /etc/kubernetes/pki/apiserver-kubelet-client.key | head -c 200
   ```

4. Reiniciá el kubelet después de cualquier cambio:

   ```bash
   systemctl restart kubelet && systemctl status kubelet --no-pager
   ```

> ❓ **Comprobá tu comprensión**
> 1. Con `authorization.mode: Webhook`, ¿*quién* decide realmente si una petición a la API del kubelet se permite, y cómo ata eso el acceso al kubelet de vuelta al RBAC del clúster?
> 2. ¿Por qué es peligroso `readOnlyPort: 10255` aunque sea "de solo lectura"? Nombrá un dato que filtra.
> 3. Un pod en el nodo corre con `hostNetwork: true` y alcanza `https://localhost:10250`. ¿Qué se interpone ahora entre él y un `exec` de contenedor en ese nodo?

---

## Ejercicio 8 — Diagnosticar "quién puede hacer qué" en todo el clúster

Restringir el acceso solo es creíble si podés auditarlo. Dominá los verbos de introspección de RBAC.

### Pasos

1. Preguntá sobre *vos mismo* y sobre sujetos arbitrarios:

   ```bash
   kubectl auth can-i create deployments -n team-a
   kubectl auth can-i '*' '*' --as=system:serviceaccount:kube-system:namespace-controller
   ```

2. Listá el conjunto efectivo de permisos de cualquier identidad (el mejor comando único de triage):

   ```bash
   kubectl auth can-i --list --as=dev -n team-a
   ```

3. Encontrá *todos* los bindings que referencian un sujeto o un role — detectá el permiso de más:

   ```bash
   kubectl get clusterrolebindings,rolebindings -A -o wide | grep -i cluster-admin
   ```

4. Inspeccioná qué permite realmente un ClusterRole integrado peligroso antes de vincularlo:

   ```bash
   kubectl describe clusterrole cluster-admin
   # PolicyRule:  *.*  []  [*]     -> full access, wildcard everything
   ```

5. Confirmá que un secret específico *no* sea legible por un SA de bajo privilegio (chequeo de defensa en profundidad después del Ejercicio 5):

   ```bash
   kubectl auth can-i get secret/db-password -n team-a \
     --as=system:serviceaccount:team-a:viewer   # no
   ```

> ❓ **Comprobá tu comprensión**
> 1. `kubectl auth can-i --list` devolvió una regla con `*.*` y verbos `[*]` para un SA que creías acotado. ¿Qué único ClusterRoleBinding buscarías, y cómo lo encontrás rápido?
> 2. ¿Por qué `auth can-i` es una auditoría más confiable que leer el YAML del Role a mano? (Pensá en cómo se combinan múltiples bindings.)
> 3. RBAC es puramente aditivo, sin reglas de `deny`. Dado eso, ¿cómo *reducís* efectivamente el acceso de una identidad sobreprivilegiada?

---

## Referencia de recuperación (si el API server no vuelve)

```bash
# The kubelet keeps trying to run the static pod; read why it fails:
crictl ps -a | grep kube-apiserver
crictl logs <container-id>
journalctl -u kubelet -f
# Restore the known-good manifest:
cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## Fuentes

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Authenticating (peticiones anónimas, X.509, `AuthenticationConfiguration`) — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Autorización RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Node authorization — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Controladores de admisión (`NodeRestriction`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Certificate Signing Requests — https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Gestión de ServiceAccounts y tokens bound — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Autenticación/autorización del kubelet — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Referencia de flags de `kube-apiserver` — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/

---

<details>
<summary><strong>Respuestas — verificá tu comprensión</strong></summary>

### Ejercicio 1
1. **Etapas de autenticación vs autorización.** Con `--anonymous-auth=true`, una petición no autenticada es *aceptada* por el autenticador anónimo como `system:anonymous`, pasa la autenticación, y luego es rechazada por la **autorización (RBAC)** → `403 Forbidden` ("User system:anonymous cannot..."). Con `--anonymous-auth=false`, no hay ningún autenticador que acepte la petición, así que falla en la etapa de **autenticación** antes de que corra la autorización → `401 Unauthorized`. Un `403` significa "sé quién sos, no tenés permiso"; un `401` significa "no sé quién sos".
2. Deshabilitar el acceso anónimo solo elimina una *identidad*. Todo lo que una identidad *autenticada* puede hacer sigue gobernado por **RBAC (autorización)** más el **control de admisión**. Un token filtrado o un RoleBinding demasiado amplio no se ven afectados por el ajuste de anonimato. AuthN y AuthZ son capas independientes.
3. `/healthz`, `/livez`, `/readyz` se estaban sirviendo a `system:anonymous`; apagar el anonimato por completo devuelve 401 a las sondas no autenticadas. La solución moderna es **`AnonymousAuthConfigurableEndpoints`** (Ejercicio 1b): una `AuthenticationConfiguration` que habilita el acceso anónimo **solo** para esas rutas de salud, manteniendo el 401 en todo lo demás — en lugar de rehabilitar la auth anónima indiscriminada o darle al LB una credencial real.

### Ejercicio 1b
1. El API server **se niega a arrancar**. `--anonymous-auth` y el bloque `anonymous` de `--authentication-config` son mutuamente excluyentes; tenés que elegir un mecanismo. (Esto aparece como un static pod del kube-apiserver en crash-loop — revisá `crictl logs`.)
2. Los static pods solo ven archivos que se montan explícitamente desde el host. Un *flag* de línea de comandos está incorporado en la spec del pod y no necesita acceso al sistema de archivos, pero un *archivo de configuración* referenciado por `--authentication-config` debe hacerse visible dentro del contenedor mediante un volumen `hostPath` + `volumeMount`, o el API server reporta "no such file".

### Ejercicio 2
1. En v1.34 el flag está **ausente** — el puerto inseguro fue eliminado en v1.20, así que no hay ningún puerto que "deshabilitar". Para el examen, la acción correcta es *verificar* que se sirve solo por TLS en el 6443 (sin listener en texto plano, 401 sin credenciales), no agregar `--insecure-port=0` (que ahora es un flag desconocido y haría fallar el arranque en algunas versiones). Sabé que "eliminado" ≠ "puesto en 0".
2. El puerto inseguro se salteaba **tanto la autenticación como la autorización** — las peticiones a `localhost:8080` se trataban como totalmente privilegiadas, sin credenciales y sin evaluación de RBAC. Cualquiera con acceso local (o de red mal configurada) a ese puerto tenía `cluster-admin` de facto, sin importar cuán ajustado estuviera RBAC.

### Ejercicio 3
1. Un **ClusterRole** (acotado al clúster, define el permiso de leer pods una sola vez) vinculado con un **ClusterRoleBinding** (acotado al clúster, aplica el permiso en todos los namespaces). Role/RoleBinding están acotados al namespace; ClusterRole/ClusterRoleBinding están acotados al clúster.
2. Porque el **RoleBinding** está acotado al namespace — existe solo en `team-a`, así que el permiso solo tiene efecto ahí. Las reglas del Role describen *qué* acciones; el namespace del binding describe *dónde*. Sin binding en `team-b` = sin acceso en `team-b`.
3. `system` (prefijo integrado) : `serviceaccount` (tipo de sujeto) : `team-a` (namespace) : `viewer` (nombre del SA). Todo SA está automáticamente en el grupo `system:serviceaccounts` y en `system:serviceaccounts:<namespace>` (acá `system:serviceaccounts:team-a`).

### Ejercicio 4
1. El **Node authorizer** corre en la etapa de *autorización* y decide si una identidad de kubelet puede realizar una acción de la API en absoluto (por ejemplo, leer los secrets/configmaps de los pods programados en él). **NodeRestriction** corre en la etapa de *admisión* y limita *qué objetos* puede mutar un kubelet (solo su propio Node y los pods vinculados a él). Necesitás ambos porque la autorización otorga una *clase* de acción mientras que la admisión hace cumplir la restricción a nivel de *objeto* de "solo tu propio nodo", que la autorización no puede expresar.
2. Los autorizadores se evalúan **de izquierda a derecha y gana el primer allow explícito**; no hay un deny que detenga a los autorizadores posteriores. Poner `Node` primero permite que las peticiones específicas del kubelet sean otorgadas por el Node authorizer hecho a medida; si una petición no es un caso de Node, cae hacia `RBAC`. Una petición "denegada por Node" no es definitiva — RBAC todavía puede permitirla, así que el orden se trata de darle a cada autorizador su turno, no de que Node vete a RBAC.
3. Previene que un **kubelet comprometido reetiquete su propio nodo para derrotar el aislamiento de cargas de trabajo.** Si aislás pods sensibles con `nodeAffinity` sobre una etiqueta `node-restriction.kubernetes.io/*`, NodeRestriction le prohíbe al kubelet agregar/quitar ese prefijo de etiqueta — así que un nodo secuestrado no puede reetiquetarse para atraer (o soltar) cargas de trabajo restringidas.

### Ejercicio 5
1. Gana el **ajuste a nivel de Pod** (`true`) — la spec del pod, más específica, sobrescribe el valor por defecto del ServiceAccount. La precedencia va SA → Pod, lo más específico al final.
2. No. Quitar el montaje solo elimina el *archivo de credencial* del contenedor; **no** cambia lo que ese SA está *autorizado* a hacer. El control complementario es **RBAC** — acotá el Role/ClusterRole del SA al mínimo privilegio para que incluso un token robado sea casi inútil. Automontaje apagado y RBAC de mínimo privilegio son defensa en profundidad, no sustitutos.
3. Los tokens proyectados bound son (a) **limitados en el tiempo / rotados automáticamente** (expiran y se refrescan, a diferencia de los tokens de Secret heredados sin expiración), y (b) **atados a audiencia y objeto** (acotados a una `audience` específica y ligados al ciclo de vida del pod, por lo que son inválidos fuera de ese contexto y una vez que el pod desaparece). Además no se almacenan como un objeto Secret legible.

### Ejercicio 6
1. El **`CN` (`dev`)** se convirtió en el nombre de usuario y el **`O` (`developers`)** en un grupo; el API server deriva la identidad del subject del certificado de cliente. Para un usuario X.509 vinculás al sujeto RBAC `kind: User` (y `kind: Group` para el `O`), mientras que una carga de trabajo usa `kind: ServiceAccount`.
2. Los certificados de vida corta limitan el radio de impacto de una clave filtrada — porque **Kubernetes no tiene CRL/revocación**, un certificado firmado de larga duración es válido hasta que expira, punto. El costo es operativo: el usuario debe volver a solicitar/refirmar con frecuencia (o automatizarlo). La expiración es tu *único* mecanismo de revocación para certificados de cliente, así que mantenela corta.
3. El certificado de la CA firmante debe estar incluido en el bundle referenciado por el **`--client-ca-file`** del API server. El API server confía en un certificado de cliente solo si encadena a una CA de ese archivo; un certificado firmado por una CA desconocida autentica como nadie (401).

### Ejercicio 7
1. Con `authorization.mode: Webhook`, el kubelet **delega la decisión de autorización al API server** (SubjectAccessReview). El acceso a los endpoints del kubelet queda por lo tanto gobernado por el **RBAC** del clúster sobre los subrecursos `nodes/*` (por ejemplo `nodes/proxy`, `nodes/log`), así que quien llama necesita una identidad que el API server pueda autorizar — no solo alcanzabilidad de red.
2. El puerto de solo lectura `10255` sirve metadatos del clúster **sin ninguna autenticación** — cualquiera que pueda alcanzarlo obtiene specs de pods, detalles de los contenedores en ejecución e información de entorno/configuración (que puede filtrar la topología de servicios y, en configuraciones malas, secrets referenciados en las specs). El peligro es que no requiere credenciales, no la parte de "solo lectura".
3. **La autenticación del kubelet + la autorización Webhook.** Incluso desde `hostNetwork` sobre `localhost:10250`, la auth anónima está apagada (401 sin credencial) y cualquier petición autenticada se chequea vía SubjectAccessReview contra RBAC — así que el pod necesita una identidad con permisos de `create` sobre `nodes/proxy` (exec), que un SA de carga de trabajo normal no tiene.

### Ejercicio 8
1. Buscá un **ClusterRoleBinding a `cluster-admin`** (u otro ClusterRole con comodines) que liste tu SA como sujeto. Encontralo rápido con `kubectl get clusterrolebindings -o wide | grep <sa-name>` o `... | grep cluster-admin`, y después hacé `kubectl describe` del culpable.
2. Porque los permisos efectivos de una identidad son la **unión de cada Role/ClusterRole otorgado a través de cada Role/ClusterRoleBinding** (más las pertenencias a grupos). Leer el YAML de un solo Role se pierde los permisos que vienen de otros bindings o de ClusterRoleBindings basados en grupos. `auth can-i` evalúa el resultado *combinado* tal como lo haría realmente el API server.
3. RBAC **no tiene reglas de deny** y es puramente aditivo, así que no podés "restar" un permiso. Reducís el acceso **quitando o editando el binding/role que lo otorga** — borrá el RoleBinding/ClusterRoleBinding demasiado amplio, o reemplazá el Role vinculado por uno más estrecho. No hay nada que agregar; sacás un permiso.

</details>