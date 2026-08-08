# Ejercicios guiados — Tema 3.3: Authentication (KCSA)

> **Dominio 3 del temario KCSA: _Kubernetes Security Fundamentals_.** La autenticación (authn) es el primer eslabón de la cadena de control de acceso del API server: `Authentication → Authorization → Admission Control`. Antes de que RBAC decida _qué_ podés hacer, authn decide _quién sos_. Estos ejercicios te llevan a observar, romper y reconstruir cada mecanismo de authn.
>
> **Entorno de laboratorio.** Todo está pensado para un cluster desechable local. Levantá uno con `kind`:
> ```bash
> kind create cluster --name kcsa-authn
> kubectl cluster-info
> ```
> Nunca ejecutes los pasos destructivos (rotación de CA, edición de flags del API server) contra un cluster productivo.
>
> Fuente primaria del temario: [KCSA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf). Referencia técnica transversal: [Authenticating — kubernetes.io](https://kubernetes.io/docs/reference/access-authn-authz/authentication/).

---

## Ejercicio 1 — Descubrir tu propia identidad ante el API server

**Objetivo:** entender que toda request lleva una identidad `(username, uid, groups, extra)` y que el API server la deriva de las credenciales, no de un objeto `User` en etcd.

1. Preguntá al API server quién sos, usando la API `SelfSubjectReview` (disponible desde Kubernetes v1.26 estable):

   ```bash
   kubectl auth whoami
   ```

   Salida esperada en un cluster `kind` (autenticándote con el client cert del `kubeconfig` de admin):

   ```
   ATTRIBUTE   VALUE
   Username    kubernetes-admin
   Groups      [kubernetes:masters system:authenticated]
   ```

2. Mirá la request cruda que hay detrás de ese comando: es un `POST` a la API `authentication.k8s.io/v1`:

   ```bash
   kubectl auth whoami -o yaml
   ```

   Salida esperada (recortada):

   ```yaml
   apiVersion: authentication.k8s.io/v1
   kind: SelfSubjectReview
   status:
     userInfo:
       username: kubernetes-admin
       groups:
       - kubernetes:masters
       - system:authenticated
   ```

3. Confirmá que **no existe** ningún objeto `User` ni `Group` en el cluster:

   ```bash
   kubectl api-resources | grep -iE '(^|/)users|^groups' || echo "no existe el recurso"
   ```

   Salida esperada:

   ```
   no existe el recurso
   ```

**Preguntas de comprensión**

- 1a. Si `kubernetes-admin` no es un objeto almacenado en etcd, ¿de dónde saca el API server el `username` y los `groups` en el paso 1?
- 1b. El grupo `system:authenticated` aparece aunque nunca lo asignaste explícitamente. ¿Quién lo agrega y qué significa?
- 1c. ¿Qué componente del pipeline de acceso (`authn` / `authz` / `admission`) responde a `kubectl auth whoami`, y por qué esa respuesta llega **antes** de que RBAC evalúe permisos?

---

## Ejercicio 2 — Autenticación por X.509 client certificate

**Objetivo:** crear un "usuario" real mediante un certificado firmado por la CA del cluster, y ver cómo el API server mapea `CN → username` y `O → group`.

1. Generá una clave privada y una CSR para un usuario llamado `dev-ana` que pertenezca al grupo `developers`. El **Common Name (CN)** será el username; cada **Organization (O)** será un group:

   ```bash
   openssl genrsa -out ana.key 2048
   openssl req -new -key ana.key -out ana.csr \
     -subj "/CN=dev-ana/O=developers"
   ```

2. Enviá la CSR al cluster mediante la API `CertificateSigningRequest` (`certificates.k8s.io/v1`), pidiendo el uso `client auth`:

   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: dev-ana
   spec:
     request: $(base64 -w0 ana.csr)
     signerName: kubernetes.io/kube-apiserver-client
     expirationSeconds: 86400
     usages:
     - client auth
   EOF
   ```

3. Aprobá la CSR (esto es un acto de un administrador; el signer del control plane recién entonces la firma):

   ```bash
   kubectl certificate approve dev-ana
   kubectl get csr dev-ana
   ```

   Salida esperada:

   ```
   NAME      SIGNERNAME                            REQUESTOR          CONDITION
   dev-ana   kubernetes.io/kube-apiserver-client   kubernetes-admin   Approved,Issued
   ```

4. Extraé el certificado firmado y armá un `kubeconfig` para `dev-ana`:

   ```bash
   kubectl get csr dev-ana -o jsonpath='{.status.certificate}' | base64 -d > ana.crt

   # Inspeccioná el subject del certificado emitido
   openssl x509 -in ana.crt -noout -subject
   ```

   Salida esperada:

   ```
   subject=CN = dev-ana, O = developers
   ```

5. Usá ese certificado para preguntar tu identidad como `dev-ana` (sin todavía darle permisos):

   ```bash
   APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
   kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt

   kubectl --server="$APISERVER" --certificate-authority=ca.crt \
     --client-certificate=ana.crt --client-key=ana.key \
     auth whoami
   ```

   Salida esperada:

   ```
   ATTRIBUTE   VALUE
   Username    dev-ana
   Groups      [developers system:authenticated]
   ```

6. Ahora probá una acción real y observá que authn **sí** te reconoce pero authz te rechaza:

   ```bash
   kubectl --server="$APISERVER" --certificate-authority=ca.crt \
     --client-certificate=ana.crt --client-key=ana.key \
     get pods
   ```

   Salida esperada:

   ```
   Error from server (Forbidden): pods is forbidden: User "dev-ana" cannot list resource "pods" in API group "" ... 
   ```

**Preguntas de comprensión**

- 2a. En el mensaje `Forbidden` del paso 6, el API server ya te nombra como `User "dev-ana"`. ¿Qué te dice eso sobre en qué etapa falló la request, y qué demuestra sobre la separación entre authn y authz?
- 2b. Si un atacante roba `ana.key` y `ana.crt`, ¿cómo se revoca ese acceso? (Pista: Kubernetes **no** tiene una CRL/lista de revocación que el API server consulte.) Nombrá al menos dos estrategias reales.
- 2c. ¿Por qué es peligroso emitir un certificado con `O=system:masters`? ¿Qué privilegio implícito trae ese grupo y por qué no lo frena RBAC?
- 2d. ¿Qué rol cumple el campo `signerName: kubernetes.io/kube-apiserver-client` y qué habría pasado si usabas `kubernetes.io/kubelet-serving`?

---

## Ejercicio 3 — ServiceAccount tokens y la TokenRequest API

**Objetivo:** distinguir la autenticación de _workloads_ (ServiceAccounts, que **sí** son objetos del cluster) de la de _usuarios_ (X.509/OIDC, externos), e inspeccionar el JWT que el API server firma y valida.

1. Creá un namespace y una ServiceAccount:

   ```bash
   kubectl create namespace app
   kubectl create serviceaccount robot -n app
   ```

2. Pedí un token corto para esa SA usando la **TokenRequest API** (`kubectl create token` la invoca por debajo). Fijate en la audiencia y la duración:

   ```bash
   TOKEN=$(kubectl create token robot -n app --audience=api --duration=10m)
   echo "$TOKEN" | cut -c1-25
   ```

   Salida esperada (prefijo de un JWT):

   ```
   eyJhbGciOiJSUzI1NiIsImtpZ
   ```

3. Decodificá el _payload_ del JWT (segundo segmento, separado por `.`) sin verificarlo, para leer los claims:

   ```bash
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Salida esperada (recortada):

   ```json
   {
     "aud": ["api"],
     "exp": 1754570000,
     "iss": "https://kubernetes.default.svc.cluster.local",
     "kubernetes.io": {
       "namespace": "app",
       "serviceaccount": { "name": "robot", "uid": "..." }
     },
     "sub": "system:serviceaccount:app:robot"
   }
   ```

4. Usá el token como **Bearer token** contra el API server y confirmá la identidad derivada:

   ```bash
   kubectl --server="$APISERVER" --certificate-authority=ca.crt \
     --token="$TOKEN" auth whoami
   ```

   Salida esperada:

   ```
   ATTRIBUTE   VALUE
   Username    system:serviceaccount:app:robot
   Groups      [system:serviceaccounts system:serviceaccounts:app system:authenticated]
   ```

5. Verificá que un Pod recibe un token **proyectado** automáticamente (rotado y con audiencia acotada), no un Secret estático de larga vida:

   ```bash
   kubectl run probe -n app --image=busybox --serviceaccount=robot \
     --restart=Never --command -- sleep 3600
   kubectl exec -n app probe -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -c1-25
   kubectl exec -n app probe -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

   Salida esperada:

   ```
   eyJhbGciOiJSUzI1NiIsImtpZ
   ca.crt
   namespace
   token
   ```

**Preguntas de comprensión**

- 3a. El `sub` del token es `system:serviceaccount:app:robot`. Descomponé ese string: ¿qué significa cada segmento y por qué el namespace forma parte de la identidad?
- 3b. El token del paso 2 tiene `"aud": ["api"]` y `exp` a 10 minutos. ¿Por qué la audiencia (`aud`) y la expiración corta son mejoras de seguridad frente a los viejos tokens de SA que se guardaban como Secrets permanentes (comportamiento previo a Kubernetes v1.24)?
- 3c. En el paso 5, ¿por qué el token dentro del Pod es un **projected volume** y no un `Secret` montado? ¿Qué le pasa a ese token cuando se acerca su expiración?
- 3d. ¿Un ServiceAccount es un mecanismo pensado para autenticar **humanos** o **workloads**? Justificá con lo que observaste sobre grupos y `sub`.

---

## Ejercicio 4 — Requests anónimas y la cadena de authenticators

**Objetivo:** ver qué pasa cuando ninguna credencial es válida, entender el usuario `system:anonymous` y por qué `--anonymous-auth` importa.

1. Hacé una request al API server **sin ninguna credencial**:

   ```bash
   curl -k "$APISERVER/version"
   ```

   Salida esperada (la ruta `/version` está permitida a anónimos):

   ```json
   { "major": "1", "minor": "31", "gitVersion": "v1.31.x", ... }
   ```

2. Ahora pedí un recurso que sí requiere autorización, todavía sin credenciales:

   ```bash
   curl -k -s "$APISERVER/api/v1/namespaces/default/pods" | python3 -m json.tool
   ```

   Salida esperada (recortada):

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\" ...",
     "reason": "Forbidden",
     "code": 403
   }
   ```

3. Presentá un token **inválido** (basura) y observá que ahí sí obtenés `401`, no `403`:

   ```bash
   curl -k -s -H "Authorization: Bearer tokendementira" \
     "$APISERVER/api/v1/namespaces/default/pods" | python3 -m json.tool
   ```

   Salida esperada (recortada):

   ```json
   {
     "kind": "Status",
     "message": "Unauthorized",
     "reason": "Unauthorized",
     "code": 401
   }
   ```

**Preguntas de comprensión**

- 4a. En el paso 2 la request llega como `system:anonymous` y termina en `403 Forbidden`. En el paso 3, con un token inválido, termina en `401 Unauthorized`. Explicá la diferencia: ¿en qué etapa muere cada una y por qué authn trata distinto "sin credencial" de "credencial mal formada/no reconocida"?
- 4b. ¿A qué grupo pertenece `system:anonymous` y por qué endpoints como `/version` o `/healthz` suelen quedar accesibles para ese grupo?
- 4c. Un pentester encuentra `--anonymous-auth=true` en un API server expuesto. Aun sin RBAC que le dé permisos, ¿por qué sigue siendo un hallazgo relevante? ¿Qué configuración endurecería esto?

---

## Ejercicio 5 — Estrategias externas: OIDC y Webhook token authentication (conceptual + inspección)

**Objetivo:** reconocer que los usuarios "reales" en producción no se autentican por certs a mano sino por un **Identity Provider** externo, y saber leer los flags del API server que lo habilitan.

1. Inspeccioná qué authenticators tiene activados el API server de tu cluster mirando sus flags:

   ```bash
   kubectl -n kube-system get pod -l component=kube-apiserver \
     -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | \
     grep -iE 'oidc|token-auth|authentication|anonymous|client-ca'
   ```

   Salida esperada (varía según el cluster; en `kind` verás al menos):

   ```
   "--client-ca-file=/etc/kubernetes/pki/ca.crt"
   "--service-account-issuer=https://kubernetes.default.svc.cluster.local"
   "--service-account-key-file=/etc/kubernetes/pki/sa.pub"
   ```

2. Estudiá (sin aplicar) cómo se vería habilitar un proveedor **OIDC**. Estos son flags del `kube-apiserver`, no un objeto del cluster:

   ```
   --oidc-issuer-url=https://accounts.example.com
   --oidc-client-id=kubernetes
   --oidc-username-claim=email
   --oidc-groups-claim=groups
   --oidc-ca-file=/etc/kubernetes/pki/oidc-ca.crt
   ```

3. Simulá el lado cliente de OIDC: un `id_token` es un JWT igual que el de la SA. Decodificá cualquier JWT que tengas a mano (reutilizá el `$TOKEN` del Ejercicio 3) y ubicá los claims que OIDC usaría como identidad:

   ```bash
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | \
     python3 -c 'import sys,json;d=json.load(sys.stdin);print("iss:",d.get("iss"));print("sub:",d.get("sub"));print("aud:",d.get("aud"))'
   ```

   Salida esperada:

   ```
   iss: https://kubernetes.default.svc.cluster.local
   sub: system:serviceaccount:app:robot
   aud: ['api']
   ```

**Preguntas de comprensión**

- 5a. En OIDC, ¿por qué el API server **no** necesita hablar con el IdP en cada request para validar un `id_token`? (Pista: firma asimétrica y JWKS.) ¿Qué claim identifica al emisor y cuál al usuario?
- 5b. `--oidc-username-claim` y `--oidc-groups-claim` mapean claims del JWT a la identidad Kubernetes. Si configurás `--oidc-username-claim=email`, ¿qué riesgo hay si el IdP permite que un usuario cambie su email? ¿Por qué suele recomendarse usar un claim inmutable como `sub` y un prefijo de username?
- 5c. ¿En qué se diferencia **Webhook Token Authentication** de OIDC? ¿Quién valida el token en cada caso y qué implicancia de latencia/disponibilidad tiene el webhook?
- 5d. Ordená de menor a mayor idoneidad para autenticar a **decenas de humanos** en producción: (i) static token file, (ii) X.509 emitidos a mano, (iii) OIDC. Justificá.

---

## Ejercicio 6 — Limpieza

```bash
kubectl delete csr dev-ana --ignore-not-found
kubectl delete ns app --ignore-not-found
rm -f ana.key ana.csr ana.crt ca.crt
kind delete cluster --name kcsa-authn
```

---

<details>
<summary><strong>Respuestas y explicaciones</strong></summary>

### Ejercicio 1

- **1a.** El API server _deriva_ la identidad de las credenciales presentadas en la request, no de un registro en etcd. Con el `kubeconfig` de admin estás presentando un **X.509 client certificate**; el authenticator de certificados toma el `CN` como `username` (`kubernetes-admin`) y cada `O` como `group` (`kubernetes:masters`). Los usuarios normales son entidades **externas** a Kubernetes: el cluster nunca los almacena.
- **1b.** El propio API server (los authenticators) agrega `system:authenticated` a **toda** request que superó la autenticación con éxito. Es un grupo sintético del sistema; sirve para escribir políticas RBAC que apliquen a "cualquier usuario autenticado". Su contraparte es `system:unauthenticated`, para requests anónimas.
- **1c.** Responde la etapa de **authentication**. `SelfSubjectReview` devuelve exactamente el `userInfo` que los authenticators construyeron, _antes_ de que el authorizer (RBAC) intervenga; por eso funciona aun sin permisos: preguntar "¿quién soy?" no requiere autorización sobre ningún recurso.

### Ejercicio 2

- **2a.** Falló en **authorization**, no en authentication. El hecho de que el mensaje te nombre correctamente como `User "dev-ana"` prueba que authn tuvo éxito (te identificó por el cert) y que la barrera fue RBAC (`Forbidden`/403). Es la demostración canónica de que authn y authz son etapas independientes: "sé quién sos, pero no tenés permiso".
- **2b.** Kubernetes **no** consulta una CRL en cada request, así que no se puede "revocar" un cert individual directamente. Estrategias reales: (1) emitir certs de **vida corta** (como el `expirationSeconds: 86400` del ejercicio) para que el robo caduque solo; (2) **rotar la CA** del cluster (invalida todos los certs firmados por ella — impacto amplio); (3) no usar certs para humanos y delegar en un IdP OIDC donde sí se puede revocar la sesión/refresh token. La lección de seguridad: los client certs son difíciles de revocar, por eso se prefieren para casos acotados y de corta vida.
- **2c.** `system:masters` es un grupo con un binding por defecto (`ClusterRoleBinding cluster-admin`) y, además, el authorizer RBAC lo trata como **superusuario efectivo**: obtiene acceso total y no hay política que lo limite. Un cert con `O=system:masters` es equivalente a un root del cluster que **no se puede revocar sin rotar la CA**. Es uno de los hallazgos más graves en una auditoría.
- **2d.** `signerName` selecciona qué firmante del control plane procesa la CSR y para qué sirve el cert resultante. `kubernetes.io/kube-apiserver-client` produce un certificado válido para **autenticarse como cliente** ante el API server. `kubernetes.io/kubelet-serving` es para certificados **de servidor** del kubelet: no habría servido para hacer `auth whoami` como cliente, y probablemente ni se habría aprobado por el flujo esperado.

### Ejercicio 3

- **3a.** `system:serviceaccount:app:robot` = prefijo fijo `system:serviceaccount` + `namespace` (`app`) + `nombre de la SA` (`robot`). El namespace es parte de la identidad porque las ServiceAccounts están **namespaced**: `robot` en `app` y `robot` en `prod` son identidades distintas. Esto permite políticas RBAC por namespace.
- **3b.** La **audiencia** (`aud`) ata el token a un receptor específico: un token emitido para `api` no sirve si un servicio valida que la audiencia sea otra, lo que frena ataques de _token replay_ entre servicios. La **expiración corta** limita la ventana de un token robado. Los viejos tokens de SA guardados como `Secret` (comportamiento hasta v1.24) no expiraban, tenían audiencia amplia y quedaban en etcd — long-lived credentials, un objetivo clásico de post-explotación.
- **3c.** Es un **projected service account token volume**: el kubelet lo solicita a la TokenRequest API en nombre del Pod, con audiencia y expiración acotadas, y lo **rota automáticamente** re-solicitándolo antes de que caduque (aproximadamente al 80–90% de su vida, o cuando le quedan ~pocos minutos). No es un Secret estático: si el Pod desaparece, el token deja de renovarse y caduca.
- **3d.** Para **workloads**. Lo delatan el `sub` con prefijo `system:serviceaccount:`, los grupos `system:serviceaccounts*`, y que es un objeto del cluster montado automáticamente en Pods. Los humanos se autentican por mecanismos externos (X.509, OIDC), no por ServiceAccounts (aunque técnicamente se pueda abusar de ellas — mala práctica).

### Ejercicio 4

- **4a.** Paso 2: no se presentó credencial, así que ningún authenticator "matchea" pero (con `--anonymous-auth=true`) la request se acepta como `system:anonymous` y **avanza** hasta authz, donde RBAC no le da permisos → **403 Forbidden**. Paso 3: se presentó un token que **ningún authenticator pudo validar** → la request se rechaza en la etapa de **authentication** → **401 Unauthorized**. Regla mnemónica: **401 = "no sé quién sos"** (falla authn), **403 = "sé quién sos, pero no podés"** (falla authz).
- **4b.** Pertenece al grupo `system:unauthenticated`. Endpoints como `/version`, `/healthz`, `/livez`, `/readyz` suelen exponerse a anónimos porque son necesarios para health checks y descubrimiento básico sin credenciales, y no revelan datos sensibles.
- **4c.** Aunque RBAC no le dé permisos hoy, `--anonymous-auth=true` amplía la superficie de ataque: (1) filtra información por endpoints permitidos a anónimos; (2) cualquier `ClusterRoleBinding` mal hecho hacia `system:anonymous` o `system:unauthenticated` (un error real y frecuente) se vuelve explotable sin credenciales; (3) históricamente hubo escaladas por combinarlo con bindings amplios. Endurecimiento: `--anonymous-auth=false` (o `AuthenticationConfiguration` con anonymous restringido a endpoints puntuales) y auditar que nada esté bindeado a los grupos anónimos.

### Ejercicio 5

- **5a.** Porque el `id_token` es un **JWT firmado** con la clave privada del IdP; el API server valida la **firma** con la clave pública del IdP (publicada vía JWKS en el `.well-known` del issuer, cacheada localmente). No necesita una llamada online por request. El claim `iss` identifica al **emisor** (debe coincidir con `--oidc-issuer-url`) y el claim configurado en `--oidc-username-claim` (p. ej. `sub` o `email`) identifica al **usuario**.
- **5b.** Si mapeás la identidad a `email` y el IdP permite cambiarlo (o reasignarlo a otra persona), la identidad Kubernetes —y por ende los `RoleBinding` que la referencian— puede quedar apuntando a un principal distinto: riesgo de **suplantación/escalada**. Por eso se recomienda un claim **inmutable** como `sub`, y usar `--oidc-username-prefix` para evitar colisiones con nombres de sistema (`system:`) o con otros IdP.
- **5c.** En **OIDC** el API server valida el token localmente (firma + claims) sin llamar al IdP en cada request. En **Webhook Token Authentication** el API server envía cada bearer token a un **servicio externo** (`TokenReview`) que responde si es válido y con qué `userInfo`. Diferencia clave: el webhook agrega una llamada de red por request → **latencia** y una **dependencia de disponibilidad** (si el webhook cae, la autenticación con esos tokens falla). OIDC es más resiliente para tokens JWT autoverificables.
- **5d.** De menor a mayor idoneidad: **(i) static token file** (peor: credenciales en texto plano en disco, sin expiración, requiere reiniciar el API server para cambios, sin rotación) < **(ii) X.509 a mano** (mejor que tokens estáticos, pero no escala: emisión manual, revocación casi imposible sin rotar CA) < **(iii) OIDC** (mejor: gestión centralizada de usuarios/grupos en el IdP, MFA, expiración y revocación de sesiones, sin secretos de larga vida en el cluster). Para humanos en producción: **OIDC**.

</details>

---

**Fuentes oficiales**

- Authenticating — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- ServiceAccount tokens y TokenRequest — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Managing Service Accounts / projected tokens — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Certificate Signing Requests — https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- `kubectl auth whoami` / SelfSubjectReview — https://kubernetes.io/docs/reference/access-authn-authz/authentication/#self-subject-review
- KCSA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf