# 2.10 Client Security

## 1. Motivación: el cliente es el eslabón que se lleva a casa

En la mayoría de los modelos de amenaza de Kubernetes se invierte enorme esfuerzo en blindar el `plane` de control —API server, etcd, kubelet— y muy poco en el punto donde realmente empiezan casi todos los incidentes reales: **la máquina del operador y su archivo `kubeconfig`**. El API server puede tener `mTLS`, `RBAC` granular, `audit logging` y `admission control` perfectos, pero todo eso presupone que quien presenta una credencial *es* quien dice ser. El cliente es exactamente el lugar donde esa presunción se rompe.

El problema arquitectónico de producción es este: un `kubeconfig` de un `cluster-admin` es, en la práctica, **la llave del reino en texto claro dentro de `~/.kube/config`**. A diferencia de un `Secret` en etcd —que al menos vive detrás del API server con `RBAC` y puede cifrarse en reposo— el `kubeconfig` vive en laptops, en runners de CI, en imágenes de contenedores, en `bash_history`, en backups de Time Machine y en repos de Git cuando alguien hace `git add .` sin `.gitignore`. Una credencial `x509` de cliente embebida ahí es **irrevocable** en Kubernetes vanilla (el API server no consulta ninguna `CRL` ni `OCSP`), y su única defensa contra el robo es su fecha de expiración, que en demasiadas organizaciones está fijada a uno o dos años.

Los tres vectores dominantes en Client Security que un `Platform Architect` debe cerrar:

1. **Credenciales de larga vida y no revocables** — certificados de cliente `x509` con `notAfter` lejano, o `bearer tokens` estáticos que no expiran. Robada la laptop, robado el cluster hasta la fecha de vencimiento.
2. **Falla de verificación de identidad del servidor** — `insecure-skip-tls-verify: true` convierte cualquier `MITM` en una captura silenciosa de tu `bearer token`, porque tu cliente entrega la credencial a *cualquier* servidor que le respondan en esa IP.
3. **Cadena de suministro del cliente** — `kubectl` plugins (krew), `exec` credential plugins y binarios auxiliares (`aws`, `gcloud`, `az`) corren con tu identidad y ven tu `kubeconfig`. Un plugin malicioso no necesita explotar el cluster: ya *sos* el cluster para él.

La respuesta moderna, y la que el examen KCSA espera que reconozcas, es desplazarse de **credenciales estáticas de larga vida** hacia **credenciales efímeras generadas bajo demanda** vía `exec` credential plugins respaldados por un `IdP` (OIDC) o por el `IAM` del proveedor cloud, con verificación `TLS` estricta del servidor y con permisos de archivo `0600` como piso mínimo.

---

## 2. El objeto `kubeconfig`: anatomía y superficie de ataque

El `kubeconfig` no es un archivo de configuración cualquiera: es un objeto `kind: Config` (`apiVersion: v1`) con tres colecciones desacopladas —`clusters`, `users`, `contexts`— más un `current-context`. La separación importa para la seguridad: **la identidad del servidor** (`clusters[].cluster`) y **tu credencial** (`users[].user`) son independientes, y el `context` es sólo el par que las une junto con un `namespace` por defecto.

```yaml
apiVersion: v1
kind: Config
preferences: {}

clusters:
- name: prod
  cluster:
    # Verificación de identidad del SERVIDOR: el CA que firmó el cert del API server.
    # Embebido en base64; alternativa: certificate-authority: /ruta/al/ca.crt
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
    server: https://api.prod.example.com:6443
    # tls-server-name: sólo si el SAN del cert no coincide con el host de 'server'

users:
- name: alice
  user:
    # Verificación de identidad del CLIENTE (mTLS): CN=username, O=groups
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
    client-key-data: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCg==

contexts:
- name: alice@prod
  context:
    cluster: prod
    user: alice
    namespace: team-payments

current-context: alice@prod
```

Puntos de seguridad que un revisor debe marcar en cualquier `kubeconfig`:

- **`client-key-data` es una clave privada en base64, no cifrada.** `base64` **no es cifrado**; `base64 -d` la revela en texto. Cualquiera con lectura del archivo tiene la clave.
- **`certificate-authority-data` protege contra `MITM`.** Si falta y en su lugar aparece `insecure-skip-tls-verify: true`, la conexión ya no valida al servidor.
- **`server:` debe ser `https://` con puerto `6443`** (o el que exponga el `LB`). Un `http://` o un host inesperado es una bandera roja.
- **El `namespace` del context no es un límite de seguridad** — es sólo conveniencia. El aislamiento real lo da `RBAC`, no el `kubeconfig`.

### `KUBECONFIG` y la fusión de archivos

`kubectl` no lee sólo `~/.kube/config`. Lee la lista de rutas de la variable `KUBECONFIG` (separadas por `:` en Linux/macOS, `;` en Windows) y las **fusiona**. Esto es una superficie de ataque subestimada: un atacante con escritura en cualquiera de esas rutas —o capacidad de setear `KUBECONFIG`— puede inyectar un `cluster`/`user`/`context` que redirija tu tráfico a un API server que él controla.

```bash
$ export KUBECONFIG=~/.kube/config:~/.kube/prod-eks:/tmp/config-inyectado
$ kubectl config view --flatten   # colapsa todo a un solo documento resuelto
```

---

## 3. Métodos de autenticación del cliente: tabla de trade-offs

El API server soporta varios `authenticators` en paralelo; el cliente elige cuál usa según lo que declare en `users[].user`. La elección determina rotación, revocabilidad, soporte de `MFA` y auditabilidad.

| Método | Campo en `kubeconfig` | Vida útil típica | ¿Revocable? | ¿Expira solo? | MFA / IdP | Riesgo si se roba el `kubeconfig` |
|---|---|---|---|---|---|---|
| **Client cert `x509`** | `client-certificate-data` + `client-key-data` | 1–2 años (mala práctica) | **No** (sin CRL/OCSP en vanilla) | Sí, en `notAfter` | No | **Crítico**: acceso total hasta expirar; hay que rotar el `CA` para invalidar |
| **Bearer token estático** (SA token legacy, `--token-auth-file`) | `token` | Indefinida | Sólo borrando el `Secret`/SA | No (legacy) | No | **Crítico**: token en texto claro, reutilizable en cualquier lado |
| **SA token proyectado (bound)** | vía `exec`/montaje | 1 h (default, `expirationSeconds`) | Sí (audience+bound al pod) | Sí | No | Bajo: efímero y acotado a un `audience` |
| **OIDC id_token** (`exec` moderno) | `exec` → plugin OIDC | 5–60 min | Sí (en el IdP) | Sí | **Sí** (Google, Azure AD, Okta…) | Bajo: token corto; robar el `kubeconfig` no roba el refresh si vive en el plugin |
| **`exec` credential plugin cloud** (`aws eks get-token`, `gke-gcloud-auth-plugin`) | `exec` | ~15 min | Sí (vía IAM) | Sí (heredado del `IAM`) | Sí | Bajo: el `kubeconfig` no contiene secreto; delega en credenciales `IAM` locales |
| **`auth-provider`** (gcp/azure/oidc) | `auth-provider` | — | — | — | — | **Deprecado/removido**: migrar a `exec` |
| **Basic auth** (`username`/`password`) | `username`/`password` | Indefinida | No | No | No | **Removido en 1.19** — no debe existir |

Lectura arquitectónica: todo lo que sea **estático y de larga vida** (filas 1, 2, 6, 7) es deuda de seguridad. Lo que sea **efímero generado por `exec`** (filas 3, 4, 5) mueve el secreto fuera del `kubeconfig` y lo respalda con un sistema que sí sabe revocar (`IAM`, `IdP`). El `kubeconfig` pasa de contener el secreto a contener sólo *instrucciones para obtener un secreto corto*.

### Certificados de cliente: por qué son un problema operativo

Un certificado de cliente codifica identidad en el `subject`: `CN` es el `username` que verá `RBAC` y cada `O` (Organization) es un `group`.

```
subject=CN = alice, O = dev-team, O = system:authenticated-extra
```

El API server confía en cualquier cert firmado por su `--client-ca-file`. **No hay revocación**: Kubernetes vanilla ignora `CRL` y no hace `OCSP`. Si el cert de `alice` se filtra, las únicas salidas son (a) esperar a que expire, o (b) **rotar el `CA` de clientes del cluster**, lo que invalida *a todos* los clientes de golpe. Por eso los certs de cliente sirven para bootstrap (kubelet, `kubeadm`) y para break-glass, pero **no** como credencial diaria de humanos. Para humanos: OIDC o `exec` cloud.

---

## 4. `exec` credential plugins: el patrón de producción

El mecanismo `exec` (grupo API `client.authentication.k8s.io`) es la pieza central de Client Security moderna. En lugar de guardar un token, el `kubeconfig` declara **un comando que `kubectl` ejecuta** antes de cada request para obtener una credencial fresca. `kubectl` cachea la credencial en memoria hasta su `expirationTimestamp`.

### 4.1 Manifiesto `exec` completo — AWS EKS

```yaml
apiVersion: v1
kind: Config
clusters:
- name: eks-prod
  cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
    server: https://ABCD1234.gr7.us-east-1.eks.amazonaws.com
users:
- name: eks-prod-user
  user:
    exec:
      # v1 es GA desde k8s 1.23; v1beta1 sigue soportado. Nunca v1alpha1.
      apiVersion: client.authentication.k8s.io/v1
      command: aws
      args:
      - --region
      - us-east-1
      - eks
      - get-token
      - --cluster-name
      - eks-prod
      - --output
      - json
      env:
      - name: AWS_PROFILE
        value: prod-readonly
      # provideClusterInfo: le pasa al plugin el server/CA vía KUBERNETES_EXEC_INFO.
      # Dejar en false salvo que el plugin lo necesite: reduce lo que ve el binario.
      provideClusterInfo: false
      # interactiveMode: Never rompe si el plugin intenta pedir input (p.ej. MFA en TTY).
      # IfAvailable es el default seguro para uso humano+CI.
      interactiveMode: IfAvailable
contexts:
- name: eks-prod
  context:
    cluster: eks-prod
    user: eks-prod-user
current-context: eks-prod
```

### 4.2 Contrato del protocolo `ExecCredential`

`kubectl` invoca el `command` y le pasa por `stdin` (y por la env var `KUBERNETES_EXEC_INFO`) un objeto `ExecCredential`. El plugin debe responder por `stdout` con:

```json
{
  "apiVersion": "client.authentication.k8s.io/v1",
  "kind": "ExecCredential",
  "status": {
    "expirationTimestamp": "2026-08-07T18:45:00Z",
    "token": "k8s-aws-v1.aHR0cHM6Ly9zdHMudXMtZWFzdC0xLmFtYXpvbmF3cy5jb20v..."
  }
}
```

También puede devolver `clientCertificateData`/`clientKeyData` en lugar de `token` para `mTLS` efímero. La clave de seguridad: **el `expirationTimestamp` fuerza la rotación**. Si el plugin lo omite, `kubectl` re-ejecuta el plugin en cada llamada (correcto pero costoso); si lo pone, cachea. Un `expirationTimestamp` muy lejano recrea el problema de las credenciales de larga vida —revisalo.

### 4.3 Modelo de amenaza de `exec`

- **El plugin corre con los privilegios de tu usuario del SO** y ve todo lo que vos ves (env, disco, `~/.aws`). Un `command` apuntando a un binario atacante (`command: ./aws` con `.` en el `PATH`) es ejecución de código. Usá **rutas absolutas o binarios verificados**, nunca relativas.
- `kubectl` **avisa** la primera vez que un `kubeconfig` de origen dudoso trae un `exec` plugin, precisamente porque ejecutar un comando arbitrario embebido en un archivo que te pasaron es peligroso. Nunca corras un `kubeconfig` que no auditaste.
- `env:` en el `kubeconfig` puede inyectar variables al plugin (`AWS_PROFILE`, `HTTPS_PROXY`). Un atacante que edite tu `kubeconfig` puede setear `HTTPS_PROXY` para el plugin y exfiltrar el flujo del token.

---

## 5. Verificación de identidad del servidor (TLS): el error que regala tokens

Del lado del cliente, la parte más subestimada es que **vos también tenés que autenticar al servidor**. Si no verificás el cert del API server, entregás tu credencial a quien te intercepte.

| Configuración | Verifica al servidor | Riesgo `MITM` | Uso legítimo |
|---|---|---|---|
| `certificate-authority-data` / `certificate-authority` | **Sí** (pin al CA) | Ninguno si el CA es correcto | **Producción** |
| `tls-server-name` | Sí (ajusta el SNI/hostname esperado) | Ninguno | API tras `LB` con SAN distinto del `server` |
| *(nada de lo anterior, confía en el trust store del SO)* | Sí, si el cert es de una CA pública | Bajo | API con cert de CA pública (raro) |
| `insecure-skip-tls-verify: true` | **No** | **Total**: cualquiera en la ruta captura tu token | Nunca en prod; sólo lab desechable |

`insecure-skip-tls-verify: true` es el equivalente cliente de dejar la puerta abierta: tu `kubectl` completa el `TLS handshake` con **cualquier** cert, entrega tu `bearer token` en el header `Authorization`, y el atacante lo reproduce contra el API server real. Es incompatible con `certificate-authority-data` (`kubectl` rechaza tener ambos). En un `audit` de Client Security, `grep -r insecure-skip-tls-verify` sobre los `kubeconfig` de la flota es una de las primeras búsquedas.

```bash
# Auditoría rápida de la flota de kubeconfigs
$ grep -rl "insecure-skip-tls-verify: true" ~/.kube/ /etc/kubernetes/
/home/alice/.kube/config-staging     # <-- corregir: agregar certificate-authority-data
```

---

## 6. Higiene del archivo, exposición de secretos e impersonation

### 6.1 Permisos de archivo

```bash
$ ls -l ~/.kube/config
-rw-------  1 alice alice  5.4K Aug  7 09:12 /home/alice/.kube/config   # 0600 correcto

# kubectl advierte si el archivo es demasiado permisivo:
$ chmod 0644 ~/.kube/config
$ kubectl get pods
WARNING: Kubernetes config file ~/.kube/config is group-readable. This is insecure. Location: ~/.kube/config
WARNING: Kubernetes config file ~/.kube/config is world-readable. This is insecure. Location: ~/.kube/config
NAME                      READY   STATUS    RESTARTS   AGE
web-6d4b...               1/1     Running   0          3h
```

El piso es **`0600`** (`-rw-------`). En runners de CI, el `kubeconfig` debe inyectarse como secreto efímero (variable/volumen tmpfs), nunca commitearse ni dejarse en el workspace tras el job.

### 6.2 `view` oculta secretos; `--raw` no

Un reflejo de seguridad clave: al pegar salida de `kubectl config view` en un ticket, sabé que `kubectl` **redacta** por defecto, pero `--raw` **no**.

```bash
$ kubectl config view          # SEGURO de compartir: redacta
...
    certificate-authority-data: DATA+OMITTED
  user:
    client-certificate-data: REDACTED
    client-key-data: REDACTED

$ kubectl config view --raw    # PELIGROSO: vuelca la clave privada en claro
...
    client-key-data: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t...   # nunca en un ticket
```

### 6.3 Impersonation desde el cliente

`kubectl --as`/`--as-group` permite actuar como otra identidad **sin tener sus credenciales**, siempre que `RBAC` te otorgue el verbo `impersonate`. Es potente para debugging ("¿este `ServiceAccount` puede crear pods?") y, mal configurado, es escalada de privilegios: quien pueda `impersonate` sobre `users`/`groups`/`serviceaccounts` puede convertirse en `cluster-admin`.

```bash
# ¿Puede el SA 'ci-deployer' del namespace 'cd' crear deployments?  (sin robar su token)
$ kubectl auth can-i create deployments \
    --as=system:serviceaccount:cd:ci-deployer -n cd
yes

# Comprobá quién puede impersonar (bandera roja si es amplio):
$ kubectl get clusterrolebindings -o json | \
    jq -r '.items[] | select(.roleRef.name|test("impersonat|admin")) | .metadata.name'
```

Regla de arquitectura: el verbo `impersonate` es efectivamente `sudo` del cluster. Restringilo a grupos concretos y auditálo; nunca lo incluyas en roles amplios.

---

## 7. Comandos de diagnóstico: ¿quién soy y qué puedo?

```bash
# ¿Qué identidad presenta mi kubeconfig actual? (k8s 1.26+)
$ kubectl auth whoami
ATTRIBUTE   VALUE
Username    alice
Groups      [dev-team system:authenticated]
Extra: ...  ...

# Contexto activo, cluster y user en uso
$ kubectl config current-context
alice@prod
$ kubectl config get-contexts
CURRENT   NAME         CLUSTER   AUTHINFO   NAMESPACE
*         alice@prod   prod      alice      team-payments
          alice@stg    stg       alice      default

# Lo que efectivamente puedo hacer con esta credencial (evalúa RBAC end-to-end)
$ kubectl auth can-i --list -n team-payments
Resources                     Non-Resource URLs   Resource Names   Verbs
pods                          []                  []               [get list watch]
pods/log                      []                  []               [get]
deployments.apps              []                  []               [get list]
selfsubjectaccessreviews...   []                  []               [create]
```

`kubectl auth whoami` es el chequeo definitivo de "qué credencial estoy usando de verdad" —resuelve la incertidumbre cuando hay `KUBECONFIG` fusionado, varios contexts y `exec` plugins en juego.

### Inspección del certificado de cliente (expiración y grupos)

```bash
$ kubectl config view --raw \
    -o jsonpath='{.users[?(@.name=="alice")].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -enddate -issuer
subject=CN = alice, O = dev-team
notAfter=Aug  7 12:00:00 2027 GMT
issuer=CN = kubernetes-ca

# ¿Cuántos días quedan? Un cert de cliente con años por delante es deuda de seguridad.
$ kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -checkend $((90*24*3600)) \
  && echo "vigente >90d (rotar plan)" || echo "expira en <90d"
```

---

## 8. Guía de diagnóstico de fallas

| Síntoma / salida | Causa raíz | Acción |
|---|---|---|
| `error: You must be logged in to the server (Unauthorized)` | Credencial inválida/expirada (cert o token vencido; SA token borrado) | `kubectl auth whoami`; inspeccionar `notAfter` del cert; re-ejecutar `exec` plugin; renovar token |
| `x509: certificate signed by unknown authority` | `certificate-authority-data` no coincide con el CA del API server (o rotó el CA) | Actualizar el CA en el `kubeconfig`; **no** "arreglar" con `insecure-skip-tls-verify` |
| `x509: certificate is valid for X, not Y` | El `SAN` del cert del server no cubre el host de `server:` | Corregir `server:` al hostname del `SAN`, o setear `tls-server-name` |
| `Unable to connect to the server: ... exec plugin: invalid apiVersion "client.authentication.k8s.io/v1alpha1"` | Plugin/`kubectl` con versiones incompatibles del contrato `exec` | Actualizar el `kubeconfig` a `v1`/`v1beta1`; actualizar el binario del plugin |
| `exec: executable aws not found` / `no such file or directory` | El `command` del `exec` no está en `PATH` del contexto que corre `kubectl` (típico en CI/systemd) | Usar ruta absoluta en `command:`; asegurar el binario en la imagen del runner |
| `error: You must be logged in ... (the server has asked for the client to provide credentials)` con `interactiveMode: Never` | El plugin necesitaba TTY (MFA/OIDC) pero se le negó interacción | Ajustar `interactiveMode: IfAvailable`; en CI usar credenciales no interactivas |
| `Error from server (Forbidden): ... cannot ... in the namespace` | Autenticación OK pero `RBAC` deniega | `kubectl auth can-i ...`; el problema es autorización, no la credencial |
| Todo funciona pero **no sabés con qué identidad** | `KUBECONFIG` fusionado / context equivocado | `kubectl auth whoami` + `kubectl config current-context` |

Ejemplo de sesión de diagnóstico real:

```bash
$ kubectl get nodes
E0807 09:41:02.113  couldn't get current server API group list:
  Get "https://api.prod.example.com:6443/api?timeout=32s":
  x509: certificate signed by unknown authority
Unable to connect to the server: x509: certificate signed by unknown authority

# ¿El CA del kubeconfig corresponde al que presenta el server?
$ kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d | openssl x509 -noout -fingerprint -sha256
sha256 Fingerprint=AA:BB:CC:...

$ echo | openssl s_client -connect api.prod.example.com:6443 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
sha256 Fingerprint=DD:EE:FF:...        # <-- distinto => el CA rotó o hay MITM

# Correcto: verificar el nuevo CA por un canal fuera de banda y actualizar el kubeconfig.
# INCORRECTO: kubectl config set-cluster prod --insecure-skip-tls-verify=true
```

---

## 9. Checklist de endurecimiento del cliente (producción)

- [ ] **Sin certs de cliente `x509` de larga vida para humanos.** OIDC o `exec` cloud; certs sólo para bootstrap/break-glass con `notAfter` corto.
- [ ] **Sin `bearer tokens` estáticos** en `kubeconfig`; migrar a `exec` con `expirationTimestamp`.
- [ ] **`certificate-authority-data` presente; cero `insecure-skip-tls-verify: true`** en toda la flota.
- [ ] **`~/.kube/config` en `0600`**; en CI, `kubeconfig` efímero en tmpfs, nunca commiteado.
- [ ] **`exec` `command:` con ruta absoluta o binario verificado**; `PATH` sin `.`.
- [ ] **`kubectl` plugins (krew) auditados**: corren con tu identidad y ven tu `kubeconfig`.
- [ ] **`impersonate` restringido** a grupos nominados y auditado como `sudo` del cluster.
- [ ] **Nunca compartir `kubectl config view --raw`**; usar la salida redactada por defecto.
- [ ] **Rotación validada** con `openssl x509 -checkend` y alertas antes de `notAfter`.
- [ ] **`kubectl auth whoami` / `can-i --list`** como paso previo a operar en un cluster nuevo.

---

## 10. Referencias

- Kubernetes — *Authenticating* (client certs, tokens, OIDC, exec plugins): https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes — *Client authentication (exec) reference* (`client.authentication.k8s.io`, `ExecCredential`): https://kubernetes.io/docs/reference/config-api/client-authentication.v1/
- Kubernetes — *Organizing Cluster Access Using kubeconfig Files*: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Kubernetes — *Configure Access to Multiple Clusters* (`KUBECONFIG`, merge, `--flatten`): https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/
- Kubernetes — *kubectl config* / *kubectl auth* (`whoami`, `can-i`): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands
- Kubernetes — *Authorization / Impersonation* (`--as`, verbo `impersonate`): https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation
- Kubernetes — *Certificate Signing Requests* (identidad `x509`, `CN`/`O`): https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Kubernetes — *OpenID Connect Tokens*: https://kubernetes.io/docs/reference/access-authn-authz/authentication/#openid-connect-tokens
- CNCF — *KCSA Curriculum* (dominio Kubernetes Cluster Component Security): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- AWS EKS — *Create a kubeconfig for Amazon EKS* (`aws eks get-token`): https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html
- Google GKE — *gke-gcloud-auth-plugin* (exec credential plugin): https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl
- Krew — *Security model / plugin verification*: https://krew.sigs.k8s.io/docs/user-guide/setup/security/