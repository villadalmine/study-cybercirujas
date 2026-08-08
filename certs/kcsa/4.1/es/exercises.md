# Ejercicios Guiados — Tema 4.1: Kubernetes Trust Boundaries and Data Flow

> **Certificación:** KCSA (Kubernetes and Cloud Native Security Associate)
> **Dominio:** Kubernetes Threat Model
> **Objetivo:** identificar dónde termina un dominio de confianza y empieza otro dentro de un clúster, y seguir el recorrido de una request y de un dato desde que entran hasta que se persisten, reconociendo en cada salto qué mecanismo criptográfico o de control protege el cruce.

Un **trust boundary** es la línea donde cambia el nivel de privilegio o el propietario del control: todo lo que está de un lado asume ciertas garantías del otro que dejan de ser válidas al cruzar. En Kubernetes esas líneas son concretas —el `kube-apiserver` frente a todo lo demás, el `control plane` frente a los `worker nodes`, el `node` frente al `Pod`, el `Pod` frente al `container`— y cada cruce está mediado por TLS, un token, una política de autorización o un `namespace`. Estos ejercicios los hacen visibles.

---

## Prerrequisitos del laboratorio

Necesitás un clúster **de un solo nodo que puedas romper** (nunca producción). Recomendado: `kind` (Kubernetes IN Docker), porque expone el control plane como contenedores inspeccionables.

```bash
# Versiones usadas al redactar (adaptá si hace falta)
kind version      # kind v0.23.0
kubectl version --client --output=yaml | grep gitVersion
# gitVersion: v1.30.0

# Clúster con audit y encryption habilitables después
kind create cluster --name kcsa-4-1
```

Salida esperada (abreviada):

```
Creating cluster "kcsa-4-1" ...
 ✓ Ensuring node image (kindest/node:v1.30.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-kcsa-4-1"
```

> El nodo `kind` es a la vez control plane y worker: podés entrar con `docker exec -it kcsa-4-1-control-plane bash` y ver los procesos estáticos del control plane. Eso es exactamente lo que necesitamos para mirar *dentro* de los boundaries.

---

## Ejercicio 1 — Inventariar los componentes y dibujar los boundaries

**Meta:** enumerar los componentes del control plane y del node, y clasificar cada relación entre ellos como *dentro del mismo dominio de confianza* o *cruce de boundary*.

**Pasos:**

1. Listá los Pods estáticos del control plane:

   ```bash
   kubectl get pods -n kube-system -o wide \
     --field-selector spec.nodeName=kcsa-4-1-control-plane \
     | grep -E 'apiserver|etcd|controller|scheduler|kube-proxy'
   ```

   Salida esperada (abreviada):

   ```
   etcd-kcsa-4-1-control-plane                      1/1   Running
   kube-apiserver-kcsa-4-1-control-plane            1/1   Running
   kube-controller-manager-kcsa-4-1-control-plane   1/1   Running
   kube-scheduler-kcsa-4-1-control-plane            1/1   Running
   kube-proxy-xxxxx                                 1/1   Running
   ```

2. Entrá al nodo y mirá quién habla con quién a través de los flags del `kube-apiserver`:

   ```bash
   docker exec -it kcsa-4-1-control-plane \
     grep -E 'etcd-servers|client-ca|kubelet-client|service-account' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Salida esperada (abreviada):

   ```
   - --etcd-servers=https://127.0.0.1:2379
   - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
   - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
   - --client-ca-file=/etc/kubernetes/pki/ca.crt
   - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
   - --service-account-key-file=/etc/kubernetes/pki/sa.pub
   ```

3. Confirmá que **todo componente habla con `etcd` únicamente a través del `kube-apiserver`** (ningún otro componente tiene flags `--etcd-servers`):

   ```bash
   docker exec -it kcsa-4-1-control-plane \
     grep -l 'etcd-servers' /etc/kubernetes/manifests/*.yaml
   ```

   Salida esperada:

   ```
   /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

**Preguntas de comprensión (Bloque 1):**

- **1.1** ¿Por qué el `kube-apiserver` es el único componente con acceso directo a `etcd`, y qué propiedad de seguridad se perdería si el `scheduler` o el `controller-manager` hablaran con `etcd` directamente?
- **1.2** En el paso 2, ¿por qué hay dos pares de certificados distintos hacia `etcd` (`apiserver-etcd-client`) y hacia el `kubelet` (`apiserver-kubelet-client`) en lugar de reutilizar uno solo?
- **1.3** Clasificá cada relación como *mismo dominio* o *cruce de boundary*: (a) `scheduler → apiserver`, (b) `apiserver → etcd`, (c) `apiserver → kubelet`, (d) `kubelet → container runtime`.

---

## Ejercicio 2 — Trazar el data flow de una request al API server

**Meta:** ver los tres controles secuenciales que toda request cruza al entrar al clúster: **Authentication → Authorization → Admission Control**, y comprobar que fallan en ese orden.

**Pasos:**

1. Emití una request con verbosidad máxima para ver el TLS handshake, el token y el cuerpo:

   ```bash
   kubectl get pods -A --v=8 2>&1 | grep -E 'Request Headers|Authorization|Response Status' | head
   ```

   Salida esperada (abreviada):

   ```
   Request Headers:
       Authorization: Bearer <masked>
       Accept: application/json
   Response Status: 200 OK
   ```

2. Provocá un fallo de **Authentication** usando un token inventado:

   ```bash
   APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
   curl -k -H "Authorization: Bearer token-que-no-existe" "$APISERVER/api/v1/namespaces/default/pods"
   ```

   Salida esperada (abreviada):

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "Unauthorized",
     "reason": "Unauthorized",
     "code": 401
   }
   ```

3. Provocá un fallo de **Authorization** con un usuario válido pero sin permisos. Creá un ServiceAccount sin RBAC y usá su token:

   ```bash
   kubectl create serviceaccount sin-permisos
   TOKEN=$(kubectl create token sin-permisos)
   curl -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/kube-system/secrets"
   ```

   Salida esperada (abreviada):

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "secrets is forbidden: User \"system:serviceaccount:default:sin-permisos\" cannot list resource \"secrets\" ...",
     "reason": "Forbidden",
     "code": 403
   }
   ```

4. Provocá un fallo de **Admission Control**. Habilitá un límite y mandá algo que lo viole. Aplicá una `ResourceQuota` y luego intentá superarla:

   ```bash
   kubectl create namespace admision-demo
   kubectl apply -n admision-demo -f - <<'EOF'
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: solo-2-pods
   spec:
     hard:
       pods: "2"
   EOF

   # Intentar crear 3 pods supera la quota en el admission controller
   for i in 1 2 3; do
     kubectl run p$i -n admision-demo --image=nginx --restart=Never
   done
   ```

   Salida esperada (el tercero):

   ```
   Error from server (Forbidden): pods "p3" is forbidden: exceeded quota: solo-2-pods,
   requested: pods=1, used: pods=2, limited: pods=2
   ```

**Preguntas de comprensión (Bloque 2):**

- **2.1** Ordená los tres códigos de error que viste (`401`, `403`, `Forbidden ... exceeded quota`) según la etapa del data flow que los emitió, y explicá por qué el `401` nunca puede ocurrir *después* del `403`.
- **2.2** En el paso 2 el token es falso y en el paso 3 el token es real pero sin permisos. Desde la perspectiva de trust boundary, ¿qué garantía distinta está verificando cada etapa?
- **2.3** El Admission Control tiene una fase *mutating* y una *validating*. ¿Cuál corre primero y por qué el orden importa para la seguridad (pensá en un `mutating webhook` que inyecta un sidecar y un `validating webhook` que exige que todo sidecar esté firmado)?
- **2.4** ¿Por qué la request del paso 1 usa `Bearer <masked>` sobre TLS y no sobre HTTP plano? ¿Qué dato exacto quedaría expuesto en un cruce de boundary sin TLS?

---

## Ejercicio 3 — etcd como *crown jewel*: el dato en reposo

**Meta:** demostrar que un `Secret` de Kubernetes, por defecto, se guarda en `etcd` en **base64 (no cifrado)**, y que cruzar el boundary del disco de `etcd` equivale a leer todos los secretos del clúster. Luego habilitar **encryption at rest**.

**Pasos:**

1. Creá un Secret con un valor reconocible:

   ```bash
   kubectl create secret generic joya-etcd \
     --from-literal=password='SUPERSECRETO-KCSA-2026'
   ```

2. Leelo directamente de `etcd`, saltándote el `kube-apiserver` (esto es exactamente lo que haría un atacante con acceso al disco o al socket de `etcd`):

   ```bash
   docker exec -it kcsa-4-1-control-plane sh -c '
     ETCDCTL_API=3 etcdctl \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/secrets/default/joya-etcd | strings'
   ```

   Salida esperada (abreviada):

   ```
   /registry/secrets/default/joya-etcd
   k8s
   v1  Secret
   joya-etcd
   default
   password
   SUPERSECRETO-KCSA-2026
   ```

   > El valor aparece **en texto claro**. El `base64` de la API no es cifrado; es solo transporte.

3. Habilitá **EncryptionConfiguration** con `aescbc`. Creá el archivo de configuración dentro del nodo:

   ```bash
   docker exec -it kcsa-4-1-control-plane sh -c '
   cat > /etc/kubernetes/pki/enc.yaml <<EOF
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources:
         - secrets
       providers:
         - aescbc:
             keys:
               - name: clave1
                 secret: '"$(head -c 32 /dev/urandom | base64)"'
         - identity: {}
   EOF'
   ```

4. Referenciá el archivo desde el `kube-apiserver` añadiendo el flag y el volumen (editá el manifiesto estático; el `kubelet` reiniciará el Pod automáticamente):

   ```bash
   docker exec -it kcsa-4-1-control-plane \
     sed -i '/- kube-apiserver/a\    - --encryption-provider-config=/etc/kubernetes/pki/enc.yaml' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   # Esperá ~30 s a que el apiserver vuelva
   kubectl get --raw='/readyz' && echo
   ```

   Salida esperada:

   ```
   ok
   ```

5. **Reescribí** todos los Secrets para que se re-persistan cifrados (los ya escritos no se cifran retroactivamente solos):

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

6. Volvé a leer de `etcd` como en el paso 2:

   ```bash
   docker exec -it kcsa-4-1-control-plane sh -c '
     ETCDCTL_API=3 etcdctl \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/secrets/default/joya-etcd | strings'
   ```

   Salida esperada (abreviada):

   ```
   /registry/secrets/default/joya-etcd
   k8s:enc:aescbc:v1:clave1:
   <bytes binarios ilegibles>
   ```

   > Ahora el prefijo `k8s:enc:aescbc:v1:clave1` indica que el provider cifró el valor. `SUPERSECRETO-KCSA-2026` ya no aparece.

**Preguntas de comprensión (Bloque 3):**

- **3.1** Antes del paso 3, ¿el `base64` de un Secret ofrecía *alguna* protección de confidencialidad? Justificá con lo que viste en el paso 2.
- **3.2** ¿Por qué el paso 5 (`replace`) es obligatorio y no basta con habilitar el flag del paso 4? ¿Qué le pasa a un Secret creado *antes* de habilitar encryption si nunca lo reescribís?
- **3.3** En la `EncryptionConfiguration`, `identity: {}` aparece como *segundo* provider. ¿Qué pasaría de seguridad si lo pusieras *primero*, antes de `aescbc`?
- **3.4** Encryption at rest con `aescbc` guarda la clave **en el mismo disco del control plane** (`enc.yaml`). ¿Contra qué amenaza protege realmente entonces, y contra cuál NO? ¿Qué provider (`kms v2`) cambiaría ese trust boundary?

---

## Ejercicio 4 — El boundary entre `kube-apiserver` y `kubelet`, y Node Authorization

**Meta:** entender que el `kubelet` de cada node es un principal con identidad propia (`system:node:<nombre>`), restringido por el **Node Authorizer** y el **NodeRestriction admission plugin** para que un node comprometido no pueda leer los secretos de otro node.

**Pasos:**

1. Verificá que ambos plugins de autorización de nodos estén activos:

   ```bash
   docker exec -it kcsa-4-1-control-plane \
     grep -E 'authorization-mode|enable-admission-plugins' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Salida esperada (abreviada):

   ```
   - --authorization-mode=Node,RBAC
   - --enable-admission-plugins=NodeRestriction
   ```

2. Inspeccioná la identidad con la que se autentica el `kubelet` (su client cert):

   ```bash
   docker exec -it kcsa-4-1-control-plane sh -c '
     openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject 2>/dev/null \
       || grep client-certificate-data /etc/kubernetes/kubelet.conf'
   ```

   Salida esperada (una de las dos formas):

   ```
   subject=O = system:nodes, CN = system:node:kcsa-4-1-control-plane
   ```

   > El `O` (Organization) `system:nodes` es el **group** y el `CN` es el **user**. El Node Authorizer usa esa identidad para limitar qué objetos puede leer ese `kubelet`.

3. Comprobá el efecto: el `kubelet` de un node solo debería poder leer Secrets de Pods programados *en ese node*. Consultá qué está autorizado ese principal a hacer:

   ```bash
   kubectl auth can-i get secrets \
     --as=system:node:kcsa-4-1-control-plane \
     --as-group=system:nodes \
     -n kube-system
   ```

   Salida esperada:

   ```
   no
   ```

   > Responde `no` a un `get` genérico: el Node Authorizer **no** concede acceso amplio a secretos por group; solo concede acceso a los objetos concretos vinculados a los Pods de ese node, resueltos dinámicamente por el grafo del authorizer, no por un `RoleBinding` estático.

**Preguntas de comprensión (Bloque 4):**

- **4.1** Si un atacante roba el `kubelet-client-current.pem` del `node-A`, ¿qué Secrets puede leer y cuáles no? ¿Qué mecanismo exacto le impide leer los del `node-B`?
- **4.2** ¿Qué evita el admission plugin **NodeRestriction** que el **Node Authorizer** por sí solo no evitaría? (Pista: pensá en un `kubelet` que intenta *escribir*, no leer — por ejemplo editar el objeto `Node` de otro node o quitarse un taint.)
- **4.3** ¿Por qué la identidad del `kubelet` es un certificado X.509 con `O=system:nodes` y no un ServiceAccount token como el del Ejercicio 2? ¿Qué implica esto para la rotación de credenciales en el boundary node ↔ control plane?

---

## Ejercicio 5 — Boundaries dentro del data plane: namespace, Pod y container

**Meta:** distinguir los boundaries que **sí** son de seguridad de los que **solo** son de organización. El `namespace` es un boundary *administrativo* (scope de nombres y RBAC), no un boundary de aislamiento en runtime; el aislamiento real lo dan los kernel namespaces del container y las NetworkPolicies.

**Pasos:**

1. Demostrá que un `namespace` **no** aísla la red por defecto. Creá dos namespaces y un Pod en cada uno:

   ```bash
   kubectl create ns equipo-a
   kubectl create ns equipo-b
   kubectl run web -n equipo-a --image=nginx
   kubectl expose pod web -n equipo-a --port=80
   kubectl run atacante -n equipo-b --image=nicolaka/netshoot --command -- sleep 3600
   kubectl wait --for=condition=Ready pod/web -n equipo-a --timeout=60s
   kubectl wait --for=condition=Ready pod/atacante -n equipo-b --timeout=60s
   ```

2. Desde el Pod de `equipo-b`, alcanzá el servicio de `equipo-a` cruzando el "boundary" de namespace:

   ```bash
   IP=$(kubectl get pod web -n equipo-a -o jsonpath='{.status.podIP}')
   kubectl exec -n equipo-b atacante -- curl -s -o /dev/null -w "%{http_code}\n" http://$IP
   ```

   Salida esperada:

   ```
   200
   ```

   > El namespace **no** detuvo el tráfico. La red del clúster es plana por defecto.

3. Ahora imponé un boundary real con una **NetworkPolicy** default-deny en `equipo-a`:

   ```bash
   kubectl apply -n equipo-a -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
   EOF
   ```

   > **Nota:** requiere un CNI que implemente NetworkPolicy (Calico, Cilium…). El CNI default de `kind` (`kindnetd`) **no** las aplica; si querés que el paso 4 funcione, recreá el clúster con `--config` deshabilitando el default CNI e instalá Calico. Si no, tratá el paso 4 como resultado esperado documentado.

4. Repetí el `curl` del paso 2:

   ```bash
   kubectl exec -n equipo-b atacante -- curl -s --max-time 5 -o /dev/null -w "%{http_code}\n" http://$IP
   ```

   Salida esperada (con CNI que soporta NetworkPolicy):

   ```
   000
   ```

   > `000` = timeout: el tráfico ahora está bloqueado. Ese es un boundary de seguridad real.

5. Mirá el boundary Pod ↔ container ↔ node: comprobá qué kernel namespaces aíslan al container y cuál se comparte dentro del Pod:

   ```bash
   kubectl run inspector -n equipo-b --image=nicolaka/netshoot --command -- sleep 3600
   kubectl wait --for=condition=Ready pod/inspector -n equipo-b --timeout=60s
   kubectl exec -n equipo-b inspector -- sh -c 'ls -la /proc/1/ns/'
   ```

   Salida esperada (abreviada):

   ```
   lrwxrwxrwx net -> net:[4026532...]
   lrwxrwxrwx mnt -> mnt:[4026532...]
   lrwxrwxrwx pid -> pid:[4026532...]
   lrwxrwxrwx uts -> uts:[4026532...]
   ```

**Preguntas de comprensión (Bloque 5):**

- **5.1** El paso 2 devolvió `200` cruzando dos namespaces. Entonces, ¿qué tipo de boundary es realmente un `namespace` de Kubernetes: de seguridad o administrativo? ¿Qué **sí** aísla un namespace (nombrá dos cosas)?
- **5.2** ¿Por qué una NetworkPolicy `default-deny-ingress` es un boundary "condicional" que depende del CNI? ¿Qué riesgo de seguridad real se esconde en un clúster donde los operadores *creen* tener NetworkPolicies pero el CNI las ignora silenciosamente?
- **5.3** Dentro de un mismo Pod, todos los containers comparten el **network namespace** (`localhost`). ¿Qué implica esto para el trust boundary entre containers de un Pod? ¿Por qué un `sidecar` malicioso es más peligroso que un Pod vecino?
- **5.4** El boundary más fuerte del data plane es Pod ↔ node (kernel). ¿Por qué un `hostPath` volume, `hostNetwork: true` o `privileged: true` "perforan" ese boundary, y por qué ese cruce lleva del data plane hacia el control del node completo?

---

## Ejercicio 6 — Auditoría: reconstruir el data flow desde el registro

**Meta:** habilitar el **audit log** del `kube-apiserver` y usarlo para reconstruir, después del hecho, quién cruzó qué boundary — la evidencia forense del data flow.

**Pasos:**

1. Creá una policy de auditoría mínima en el nodo:

   ```bash
   docker exec -it kcsa-4-1-control-plane sh -c '
   cat > /etc/kubernetes/pki/audit-policy.yaml <<EOF
   apiVersion: audit.k8s.io/v1
   kind: Policy
   rules:
     - level: RequestResponse
       resources:
         - group: ""
           resources: ["secrets"]
     - level: Metadata
   EOF'
   ```

2. Conectá la policy al `kube-apiserver` (flags de policy y de destino del log):

   ```bash
   docker exec -it kcsa-4-1-control-plane sh -c '
     sed -i "/- kube-apiserver/a\    - --audit-policy-file=/etc/kubernetes/pki/audit-policy.yaml\n    - --audit-log-path=/var/log/kubernetes/audit.log" \
       /etc/kubernetes/manifests/kube-apiserver.yaml
     mkdir -p /var/log/kubernetes'
   # Esperá el reinicio del apiserver
   sleep 30 && kubectl get --raw='/readyz' && echo
   ```

3. Generá un evento sobre un Secret y buscalo en el log:

   ```bash
   kubectl get secret joya-etcd -o yaml >/dev/null
   docker exec -it kcsa-4-1-control-plane sh -c '
     grep joya-etcd /var/log/kubernetes/audit.log | tail -1 | python3 -m json.tool' \
     | grep -E '"user"|"verb"|"resource"|"stage"|"responseStatus"' -A1
   ```

   Salida esperada (abreviada):

   ```json
   "verb": "get",
   "user": { "username": "kubernetes-admin", "groups": ["system:masters"] },
   "objectRef": { "resource": "secrets", "name": "joya-etcd", "namespace": "default" },
   "stage": "ResponseComplete",
   "responseStatus": { "code": 200 }
   ```

**Preguntas de comprensión (Bloque 6):**

- **6.1** El audit log registró `user`, `verb`, `objectRef` y `responseStatus`. ¿Cuál de las tres etapas del Ejercicio 2 (authN/authZ/admission) determina cada uno de esos campos?
- **6.2** ¿Por qué la policy usa `RequestResponse` para `secrets` pero solo `Metadata` para el resto? ¿Qué riesgo introduciría poner `RequestResponse` global sobre `secrets` — es decir, qué dato sensible terminaría escrito en el propio audit log?
- **6.3** El audit log vive en el disco del control plane (`/var/log/kubernetes/`). Desde una óptica de trust boundary, ¿por qué en producción ese log debe enviarse fuera del node (webhook backend) y no quedarse local?

---

## Limpieza

```bash
kind delete cluster --name kcsa-4-1
```

---

<details>
<summary><strong>Respuestas y explicaciones</strong></summary>

### Bloque 1

**1.1** — `etcd` es la única fuente de verdad del clúster: contiene todos los objetos, incluidos los Secrets y los tokens de ServiceAccount. Centralizar su acceso en el `kube-apiserver` hace que exista **un solo punto donde se aplican authN, authZ, admission y auditoría** sobre cada lectura/escritura de estado. Si el `scheduler` o el `controller-manager` hablaran directo con `etcd`, cruzarían el boundary del estado del clúster *sin pasar por esos controles*, y un compromiso de cualquiera de esos componentes daría acceso plano a todos los datos. Se perdería el principio de **choke point único** (mediación completa).

**1.2** — Son dos boundaries distintos con roles opuestos. Hacia `etcd`, el `kube-apiserver` es **cliente** y `etcd` valida su cert (`apiserver-etcd-client`). Hacia el `kubelet`, el `kube-apiserver` también es cliente pero de otra CA/propósito (`apiserver-kubelet-client`). Separar los pares limita el blast radius: comprometer la credencial de un boundary no habilita el otro, y permite rotarlos y revocarlos de forma independiente (principio de **least privilege / separación de credenciales por relación de confianza**).

**1.3** — (a) `scheduler → apiserver`: **cruce de boundary** (el scheduler se autentica con su propia identidad y pasa por authZ). (b) `apiserver → etcd`: **cruce de boundary** (mTLS entre dos componentes con confianza limitada). (c) `apiserver → kubelet`: **cruce de boundary** (control plane → data plane, mTLS). (d) `kubelet → container runtime`: **cruce de boundary** (por el CRI socket, del gestor del node al runtime privilegiado). Ninguna de estas cuatro es "mismo dominio": todas cruzan una línea de confianza, y por eso todas están mediadas por TLS/identidad.

### Bloque 2

**2.1** — Orden del data flow: **Authentication (`401`) → Authorization (`403`) → Admission Control (`exceeded quota`)**. El `401` no puede ocurrir después del `403` porque **la autorización necesita saber *quién* sos antes de decidir *qué* podés hacer**: sin una identidad autenticada no hay sujeto sobre el cual evaluar RBAC. Las etapas son estrictamente secuenciales; fallar una corta las siguientes.

**2.2** — AuthN verifica **identidad** ("¿el que dice ser este principal realmente lo es?" — el token falso no corresponde a ningún principal). AuthZ verifica **permiso** ("este principal, ya identificado, ¿puede hacer esta acción sobre este recurso?" — el SA existe pero no tiene RBAC). Son garantías ortogonales: una identidad válida no implica ningún permiso.

**2.3** — Primero corren los **mutating** admission webhooks, después los **validating**. El orden importa porque un validating webhook debe ver el objeto **en su forma final** —después de todas las mutaciones— para poder rechazar lo que viole la política. En el ejemplo: si el mutating inyecta un sidecar, el validating (que exige sidecars firmados) recién lo verá inyectado y podrá aprobarlo o rechazarlo. Si validaras antes de mutar, el sidecar inyectado escaparía a la validación — un bypass de política.

**2.4** — Va sobre TLS porque el `Bearer` token es una **credencial portadora**: quien la posee es autenticado como el principal, sin prueba adicional. Sobre HTTP plano, cualquiera en la ruta (cruce de boundary red) capturaría el token y lo reutilizaría (**replay / robo de credencial**). El dato expuesto sería el token del ServiceAccount o del usuario — equivalente a entregar la identidad completa.

### Bloque 3

**3.1** — No, **ninguna**. `base64` es una codificación reversible sin clave: el paso 2 mostró el valor en claro con solo aplicar `strings`. Es un formato de transporte para bytes binarios en JSON/YAML, no un control de confidencialidad. Tratar `base64` como "protección" es un error conceptual clásico.

**3.2** — El flag del paso 4 solo hace que el `kube-apiserver` **cifre lo que escriba a partir de ahora**; no reescribe lo ya persistido. Los Secrets viejos siguen en `etcd` con el provider anterior (`identity`, o sea en claro). El `replace` del paso 5 fuerza una reescritura de cada objeto, que ahora pasa por el provider `aescbc`. Un Secret creado antes y nunca reescrito **permanece en texto claro en `etcd`** indefinidamente, aunque el flag esté activo.

**3.3** — El **primer** provider de la lista es el que se usa para **cifrar** (escribir); todos se prueban en orden para **descifrar** (leer). Si `identity: {}` (que es "sin cifrado") fuera primero, el `kube-apiserver` escribiría todos los Secrets **en claro** y `aescbc` solo serviría para leer los viejos. Sería una habilitación de encryption completamente inútil — un error de configuración silencioso y peligroso.

**3.4** — Protege contra el robo del **medio de `etcd` en reposo**: un backup de `etcd`, un disco/snapshot robado, o acceso al almacenamiento sin acceso al proceso del `kube-apiserver`. **NO** protege contra un atacante que ya comprometió el node del control plane, porque la clave (`enc.yaml`) está en el mismo disco. El provider **KMS v2** cambia ese boundary: la clave de cifrado de datos se envuelve con una clave que vive en un **KMS externo** (HSM/servicio de nube), de modo que robar el disco de `etcd` *y* el `enc.yaml` no alcanza — hace falta además acceso al KMS.

### Bloque 4

**4.1** — Con el cert de `node-A` puede leer únicamente los Secrets **montados por Pods programados en `node-A`** (más su propio ServiceAccount, ConfigMaps y PVCs de esos Pods). No puede leer los de `node-B` porque el **Node Authorizer** mantiene un **grafo** de qué objetos están vinculados a qué node vía los Pods asignados, y autoriza cada lectura contra ese grafo. La identidad `system:node:node-A` no aparece vinculada a los objetos de `node-B`, así que la lectura se deniega.

**4.2** — El Node Authorizer controla **lecturas/accesos permitidos**; el **NodeRestriction** limita lo que un `kubelet` puede **escribir/modificar**. Sin NodeRestriction, un `kubelet` comprometido podría, por ejemplo, editar el objeto `Node` de *otro* node, quitarse taints/labels para atraer Pods sensibles hacia sí, o modificar el estado de Pods que no le corresponden. NodeRestriction restringe a cada `kubelet` a modificar **solo su propio objeto `Node` y los Pods ligados a él**. Uno protege el read side, el otro el write side del mismo boundary.

**4.3** — Un certificado X.509 con `O=system:nodes` porque la identidad del node es de larga vida y de infraestructura, arrancada vía **TLS bootstrap + CSR** y **rotada** automáticamente (`kubelet-client-current.pem`) sin intervención humana. El group va en el `O` y el user en el `CN`, de modo que la mTLS establece identidad y pertenencia en el propio handshake. Implica que la seguridad del boundary node↔control plane depende de la protección del private key en disco del node y de la rotación/revocación de certificados (CRL o expiración corta), no de la revocación de un token.

### Bloque 5

**5.1** — Es un boundary **administrativo**, no de seguridad de runtime: el `200` demostró que el tráfico cruza namespaces libremente. Un namespace **sí** aísla: (a) el **scope de nombres** (dos objetos con el mismo nombre pueden coexistir en namespaces distintos), y (b) el **scope de RBAC / ResourceQuota / LimitRange** (los `Role`/`RoleBinding` namespaced y las quotas se aplican por namespace). No aísla red, ni PIDs, ni acceso al kernel entre Pods.

**5.2** — Porque la NetworkPolicy es un **objeto de la API que solo tiene efecto si el CNI instalado lo implementa**. El `kube-apiserver` acepta y persiste la policy aunque nadie la haga cumplir. El riesgo real: un equipo aplica `default-deny`, ve el objeto creado con `kubectl get netpol` y **asume que está protegido**, pero si el CNI no soporta NetworkPolicies (o no están habilitadas) el tráfico fluye igual. Es una falsa sensación de segmentación — un boundary que existe en la API pero no en el data plane.

**5.3** — Los containers de un Pod comparten el **network namespace**, así que se ven por `localhost` y comparten IP y puertos: **no hay boundary de red entre ellos**. Un sidecar malicioso puede interceptar/leer todo el tráfico local del container principal (por ejemplo, un proxy que ve credenciales en `localhost`), acceder a puertos que el container principal creía "internos", y compartir volúmenes montados. Un Pod vecino, en cambio, está detrás de al menos el boundary de red (IP distinta, sujeto a NetworkPolicy) — por eso el sidecar, que ya está *dentro* del boundary del Pod, es más peligroso.

**5.4** — Esos tres flags perforan el boundary Pod↔node porque **reconectan el container a los namespaces/recursos del host** en vez de a los aislados del Pod: `hostPath` monta el filesystem del node (acceso a `/var/lib/kubelet`, sockets, certs), `hostNetwork: true` pone al Pod en el network namespace del node (ve todo el tráfico y servicios locales del host, incluido el `kubelet`/metadata), y `privileged: true` desactiva la mayoría de las restricciones del container (capabilities completas, acceso a `/dev`, capacidad de montar y de manipular el kernel). Cualquiera de los tres convierte un compromiso del Pod en un compromiso del **node**, y desde el node —con acceso a los kubeconfig/certs del `kubelet` y a los Secrets montados— el atacante escala hacia el control del clúster. Por eso el cruce Pod→node es el pivote clásico del threat model.

### Bloque 6

**6.1** — `user`/`groups` los determina **Authentication** (quién quedó identificado). `verb`/`objectRef` describen la request tal como llegó y se resuelven al evaluar **Authorization** (qué acción sobre qué recurso se permitió). `responseStatus` refleja el resultado final tras **Admission Control** y la ejecución (p. ej. `200`, o `403`/`Forbidden` si admission rechazó). El audit log es, literalmente, el registro del data flow de las tres etapas.

**6.2** — `RequestResponse` registra el **cuerpo completo** de request y response. Para el resto de recursos alcanza `Metadata` (quién/qué/cuándo) para no inflar el log. Poner `RequestResponse` global sobre `secrets` significaría escribir **el contenido descifrado del Secret** (el `data`) dentro del audit log — es decir, el propio mecanismo de auditoría filtraría el dato sensible a un archivo de texto. En la práctica se audita el *acceso* a Secrets a nivel `Metadata`/`Request`, evitando volcar sus valores. (El ejercicio usa `RequestResponse` a propósito para que se vea el trade-off; en producción se restringe.)

**6.3** — Porque el audit log local **comparte el trust boundary del propio componente que audita**: un atacante que compromete el control plane puede editar o borrar `/var/log/kubernetes/audit.log` y **borrar sus huellas**. Enviarlo fuera del node (audit **webhook backend** hacia un SIEM/almacén append-only e independiente) coloca la evidencia del otro lado de un boundary que el atacante del node no controla, preservando su integridad para análisis forense.

</details>

---

### Fuentes oficiales

- CNCF — *KCSA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes — *Controlling Access to the Kubernetes API*: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes — *Authenticating*: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes — *Authorization / Node Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes — *Using Admission Controllers*: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — *Operating etcd clusters for Kubernetes*: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes — *Overview of Cloud Native Security (4Cs)*: https://kubernetes.io/docs/concepts/security/overview/