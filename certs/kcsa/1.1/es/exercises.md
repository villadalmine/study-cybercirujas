# Ejercicios guiados — Tema 1.1: The 4Cs of Cloud Native Security (KCSA)

> **Modelo mental que vas a construir.** Las 4C —**Cloud**, **Cluster**, **Container**, **Code**— son capas concéntricas. Cada capa se apoya en la seguridad de la capa que la contiene: no podés compensar una *Cloud* insegura endureciendo el *Code*. La dirección de la defensa va de afuera hacia adentro, y una brecha en una capa externa neutraliza los controles de todas las internas. Estos ejercicios te hacen *tocar* cada capa en un cluster real y observar esa dependencia en la práctica.
>
> Fuentes: *Overview of Cloud Native Security* — https://kubernetes.io/docs/concepts/security/cloud-native-security/ · *Security concepts* — https://kubernetes.io/docs/concepts/security/ · KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

**Prerrequisitos del lab:** `kind` ≥ 0.20, `kubectl` ≥ 1.29, `docker` (o `podman`+`nerdctl`), `trivy` ≥ 0.50 y `jq`. Todo corre local; no necesitás una cuenta de nube.

---

## Ejercicio 0 — Levantar el cluster y mapear las 4 capas

**Objetivo:** materializar el diagrama de las 4C sobre un cluster concreto e identificar *qué proceso/artefacto vive en cada capa*.

1. Creá un cluster de un solo control-plane con `kind`:

   ```bash
   cat > kind-4c.yaml <<'EOF'
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: 4c-lab
   nodes:
     - role: control-plane
   EOF
   kind create cluster --config kind-4c.yaml
   ```

   Salida esperada (resumida):

   ```
   ✓ Ensuring node image (kindest/node:v1.29.x)
   ✓ Preparing nodes
   ✓ Writing configuration
   ✓ Starting control-plane
   ✓ Installing CNI
   ✓ Installing StorageClass
   Set kubectl context to "kind-4c-lab"
   ```

2. Identificá el **artefacto de cada capa**. Ejecutá y observá dónde vive cada cosa:

   ```bash
   # Cloud: la "infraestructura" — acá es el contenedor Docker que hace de nodo
   docker ps --filter "name=4c-lab" --format '{{.Names}}\t{{.Image}}'

   # Cluster: los componentes del plano de control como static pods
   kubectl -n kube-system get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName | grep -E 'apiserver|etcd|controller|scheduler'

   # Container: los contenedores que corren dentro de un Pod de aplicación
   kubectl run demo --image=nginx:1.27 --restart=Never
   kubectl get pod demo -o jsonpath='{.spec.containers[0].image}{"\n"}'

   # Code: la imagen encapsula el código; inspeccioná sus capas
   docker exec 4c-lab-control-plane crictl images 2>/dev/null | grep nginx || echo "(usa la imagen ya cacheada)"
   ```

3. Dibujá (mentalmente o en papel) el anillo: el contenedor de Docker `4c-lab-control-plane` es tu **Cloud**; los static pods `kube-apiserver`/`etcd` son el **Cluster**; el Pod `demo` es el **Container**; el binario de nginx y su config son el **Code**.

> **Preguntas de verificación (0)**
> - **0.1** Según el modelo, ¿en qué orden se deben asegurar las capas y por qué la seguridad del *Code* no puede "subir" para proteger al *Cluster*?
> - **0.2** En un cluster gestionado (EKS/GKE/AKS), ¿qué parte de la capa *Cloud* deja de ser tu responsabilidad y cuál sigue siendo tuya? Nombrá el modelo que describe ese reparto.
> - **0.3** ¿Por qué `etcd` merece un tratamiento de seguridad distinto al resto de los componentes del plano de control?

---

## Ejercicio 1 — Capa **Cloud**: el trust boundary de la infraestructura

**Objetivo:** localizar la frontera de confianza más externa: exposición del API server, cifrado de `etcd` en reposo y el clásico vector del *metadata/IMDS*.

1. Determiná el *endpoint* del plano de control y con qué se autentica:

   ```bash
   kubectl cluster-info
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
   ```

   Salida esperada (el puerto y la IP variarán):

   ```
   Kubernetes control plane is running at https://127.0.0.1:6443
   https://127.0.0.1:6443
   ```

2. Inspeccioná los flags de seguridad del `kube-apiserver` (vive como *static pod* en el nodo, capa Cloud):

   ```bash
   docker exec 4c-lab-control-plane \
     grep -E 'anonymous-auth|authorization-mode|encryption-provider|client-ca|tls-' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Prestá atención a `--authorization-mode` (debería incluir `Node,RBAC`, **no** `AlwaysAllow`) y a si aparece `--anonymous-auth=false`.

3. Verificá si el estado sensible (`Secrets`) está **cifrado en reposo** dentro de `etcd`. Primero creá un Secret con un marcador reconocible y luego leé el raw de etcd:

   ```bash
   kubectl create secret generic canary --from-literal=token=SUPERSECRET-4C

   docker exec 4c-lab-control-plane sh -c '
     ETCDCTL_API=3 etcdctl \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/secrets/default/canary | strings | grep -c SUPERSECRET-4C'
   ```

   En un `kind` por defecto **no hay** `EncryptionConfiguration`, así que verás `1`: el token viaja **en claro** dentro de etcd. Ese `1` es el hallazgo.

4. Modelá el vector *IMDS/metadata SSRF* (por qué la capa Cloud importa aun teniendo buen RBAC). En la nube, un Pod que alcanza `169.254.169.254` puede robar credenciales del nodo. Simulá el chequeo de alcance:

   ```bash
   kubectl run imds-probe --rm -it --image=curlimages/curl:8.8.0 --restart=Never -- \
     sh -c 'curl -s -m 3 http://169.254.169.254/ -o /dev/null -w "%{http_code}\n" || echo "sin-ruta (esperado en kind)"'
   ```

   En `kind` no hay IMDS (obtendrás `sin-ruta`); el punto es reconocer que en un cloud real **esa** ruta es un límite de confianza que se cierra con hop-limit=1, IMDSv2 o una NetworkPolicy hacia el link-local.

> **Preguntas de verificación (1)**
> - **1.1** El comando del paso 3 devolvió `1`. ¿Qué demuestra exactamente y qué recurso de Kubernetes/Cloud lo remedia? Nombrá los `providers` recomendados hoy.
> - **1.2** ¿Por qué `--authorization-mode=AlwaysAllow` haría irrelevante todo el RBAC que definas en la capa Cluster? Relacionalo con el orden de las 4C.
> - **1.3** Un atacante logra SSRF desde un Pod hacia el IMDS del nodo y obtiene un token del `node instance role`. ¿En qué capa ocurrió la falla original y por qué endurecer la capa Container no lo habría evitado?
> - **1.4** Nombrá dos controles de la capa Cloud que **no** se configuran con manifiestos de Kubernetes sino en el proveedor/infra.

---

## Ejercicio 2 — Capa **Cluster**: authn/authz, admisión y aislamiento de red

**Objetivo:** trabajar los controles que la KCSA sitúa en la capa Cluster: RBAC, Pod Security Admission y NetworkPolicy.

1. Probá **RBAC** desde la perspectiva de un ServiceAccount, no del admin:

   ```bash
   kubectl create namespace app
   kubectl -n app create serviceaccount worker

   # ¿Puede este SA listar secrets? (debería ser NO por defecto)
   kubectl auth can-i list secrets \
     --as=system/serviceaccount:app:worker -n app
   ```

   Salida esperada:

   ```
   no
   ```

   (Si escribiste el `--as` con el formato correcto `system:serviceaccount:app:worker`, verás `no`; ese es el comportamiento seguro por defecto: sin RoleBinding, no hay permisos.)

2. Activá **Pod Security Admission** en modo `restricted` a nivel namespace y comprobá que rechaza un Pod privilegiado:

   ```bash
   kubectl label namespace app \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=latest

   kubectl -n app run privesc --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"privesc","image":"busybox:1.36","securityContext":{"privileged":true}}]}}' \
     -- sleep 3600
   ```

   Salida esperada (rechazo del admission controller):

   ```
   Error from server (Forbidden): pods "privesc" is forbidden: violates PodSecurity "restricted:latest":
   privileged (container "privesc" must not set securityContext.privileged=true), ...
   ```

3. Aislá la red con una **NetworkPolicy** default-deny y verificá el corte. Primero levantá dos Pods y confirmá que se hablan; luego aplicá la política:

   ```bash
   kubectl -n app run web --image=nginx:1.27 --labels app=web
   kubectl -n app expose pod web --port 80
   kubectl -n app run client --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600

   # Antes de la política: conectividad OK
   kubectl -n app exec client -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" web

   cat <<'EOF' | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: app
   spec:
     podSelector: {}
     policyTypes: [Ingress]
   EOF

   # Después: el ingress a web queda cortado (timeout)
   kubectl -n app exec client -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" web || echo "bloqueado (esperado)"
   ```

   > **Cuidado con el CNI.** El CNI por defecto de `kind` (kindnet) **no** implementa NetworkPolicy. Si el segundo `curl` sigue devolviendo `200`, la política no se está aplicando: instalá Calico (`kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml`) o recreá el cluster con `--config` desactivando el CNI y montando uno con enforcement. Este "falso positivo de seguridad" es en sí mismo el aprendizaje del paso.

> **Preguntas de verificación (2)**
> - **2.1** RBAC respondió `no` sin que definieras ninguna `Role`/`RoleBinding`. ¿Qué principio de diseño de la capa Cluster explica ese `no`?
> - **2.2** ¿Cuál es la diferencia entre los modos `enforce`, `audit` y `warn` de Pod Security Admission, y por qué querrías empezar por `warn`/`audit` antes de `enforce` en un cluster con cargas existentes?
> - **2.3** Aplicaste la NetworkPolicy pero el tráfico siguió pasando. Sin tocar la política, ¿cuál es la causa raíz más probable y en qué capa de las 4C reside ese componente?
> - **2.4** Un `RoleBinding` da `list secrets` en el namespace `app`. ¿Eso alcanza para leer secrets de `kube-system`? Justificá con el alcance (scope) de `Role` vs `ClusterRole`.

---

## Ejercicio 3 — Capa **Container**: superficie de la imagen y del runtime

**Objetivo:** reducir la superficie de ataque del contenedor: `securityContext`, capabilities, rootfs de solo lectura y escaneo de imagen.

1. Escaneá una imagen "gorda" y una minimalista y compará la superficie:

   ```bash
   trivy image --severity HIGH,CRITICAL --quiet nginx:1.27 | tail -n 20
   trivy image --severity HIGH,CRITICAL --quiet gcr.io/distroless/static-debian12 | tail -n 20
   ```

   Vas a ver que la imagen `distroless` reporta drásticamente menos (a menudo cero) CVEs de sistema: menos paquetes = menos superficie.

2. Endurecé un Pod con un `securityContext` de producción y aplicá el **principio de menor privilegio**:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened
     namespace: app
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:1.27
         ports: [{ containerPort: 8080 }]
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
         volumeMounts:
           - { name: tmp, mountPath: /tmp }
           - { name: cache, mountPath: /var/cache/nginx }
           - { name: run, mountPath: /var/run }
     volumes:
       - { name: tmp, emptyDir: {} }
       - { name: cache, emptyDir: {} }
       - { name: run, emptyDir: {} }
   EOF
   kubectl -n app get pod hardened -o wide
   ```

3. Demostrá que el endurecimiento *funciona*: verificá que no corre como root, que no puede escribir el rootfs y que perdió las capabilities:

   ```bash
   # UID efectivo (no debe ser 0)
   kubectl -n app exec hardened -- id -u

   # Escritura al rootfs de solo lectura → debe fallar
   kubectl -n app exec hardened -- sh -c 'echo x > /etc/probe 2>&1 || echo "read-only (esperado)"'

   # Capabilities: el set efectivo debe estar vacío
   kubectl -n app exec hardened -- sh -c 'grep CapEff /proc/1/status'
   ```

   Salida esperada:

   ```
   10001
   read-only (esperado)     # o: /etc/probe: Read-only file system
   CapEff: 0000000000000000
   ```

4. Contrastá con el anti-patrón. Intentá `docker`-style `privileged` (ya lo bloqueó PSA en el Ej. 2) y observá que **la capa Cluster** (admission) es la que impide lo que el desarrollador de la capa Container debería haber evitado. Esa redundancia es defensa en profundidad, no duplicación inútil.

> **Preguntas de verificación (3)**
> - **3.1** `CapEff: 0000000000000000` significa "cero capabilities efectivas". ¿Por qué `drop: ["ALL"]` es preferible a listar capabilities a quitar una por una?
> - **3.2** ¿Qué hace `readOnlyRootFilesystem: true` por la seguridad y por qué obligó a montar `emptyDir` en `/tmp`, `/var/cache/nginx` y `/var/run`?
> - **3.3** `runAsNonRoot: true` y `runAsUser: 10001` — ¿qué pasa si la imagen `ENTRYPOINT` *necesita* UID 0? ¿Falla en build o en runtime, y con qué error?
> - **3.4** El escaneo con Trivy es un control de la capa Container que también toca la capa Code. Explicá esa superposición: ¿qué CVEs pertenecen a "container" (base image) y cuáles a "code" (dependencias de la app)?

---

## Ejercicio 4 — Capa **Code**: la capa que sí controlás por completo

**Objetivo:** los controles de la KCSA para la capa más interna: escaneo de dependencias, secrets fuera del código, TLS obligatorio y análisis estático.

1. Simulá un repo con un secret hardcodeado y detectalo con escaneo de filesystem:

   ```bash
   mkdir -p /tmp/app-code && cd /tmp/app-code
   cat > config.py <<'EOF'
   DB_PASSWORD = "p@ssw0rd-en-el-codigo"
   AWS_SECRET_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLEKEYabc123def456ghi789jkl"
   EOF
   cat > requirements.txt <<'EOF'
   requests==2.19.0
   pyyaml==5.1
   EOF

   trivy fs --scanners vuln,secret --severity HIGH,CRITICAL --quiet .
   ```

   Trivy reporta **dos clases de hallazgos**: `secret` (la credencial en `config.py`) y `vuln` (las versiones viejas de `requests`/`pyyaml` con CVEs conocidos). Ambos son deuda de la capa Code.

2. Reemplazá el secret hardcodeado por inyección vía Kubernetes `Secret` (la forma correcta: el código lee de env/volume, no lleva el valor):

   ```bash
   kubectl -n app create secret generic db --from-literal=password='p@ssw0rd'
   # El código consume DB_PASSWORD desde el entorno, nunca lo contiene:
   #   env:
   #     - name: DB_PASSWORD
   #       valueFrom: { secretKeyRef: { name: db, key: password } }
   ```

3. **TLS in transit** — verificá que el tráfico al API server es cifrado y con verificación de certificado (nunca `--insecure-skip-tls-verify`):

   ```bash
   kubectl get --raw='/readyz?verbose' | head -n 3
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | head -c 20; echo " ...(CA presente)"
   ```

   Que exista `certificate-authority-data` prueba que el cliente valida la identidad del server: TLS mutuo real, no confianza ciega.

4. Cerrá el loop: bumpea las dependencias y re-escaneá para confirmar que el hallazgo desaparece.

   ```bash
   cat > requirements.txt <<'EOF'
   requests==2.32.3
   pyyaml==6.0.2
   EOF
   trivy fs --scanners vuln --severity HIGH,CRITICAL --quiet . && echo "sin HIGH/CRITICAL (esperado)"
   ```

> **Preguntas de verificación (4)**
> - **4.1** ¿Por qué inyectar el password vía `Secret` no lo "hace seguro" por sí solo? Nombrá **dos** controles de capas externas que un `Secret` de K8s todavía necesita para no ser leído en claro (pista: revisá el Ejercicio 1).
> - **4.2** Trivy encontró un CVE en `requests==2.19.0`. ¿En qué se diferencia este hallazgo (capa Code) de un CVE en la base image de `nginx` (capa Container), en términos de *quién* lo remedia y *cómo*?
> - **4.3** La KCSA lista "TLS for internal traffic" y "no hardcoded credentials" en la capa Code. ¿Por qué el cifrado *en tránsito* (TLS) es Code pero el cifrado *en reposo* de etcd es Cloud/Cluster?
> - **4.4** ¿Qué tipo de análisis (SAST, DAST, SCA) corresponde a cada uno: detectar el secret en `config.py`, detectar el CVE en `requests`, y probar la app corriendo contra inyección SQL?

---

## Ejercicio 5 — Defensa en profundidad: por qué el **orden** de las 4C importa

**Objetivo:** demostrar empíricamente la tesis central del tema: una brecha en una capa externa anula los controles de las internas.

1. Construí el escenario. Tenés (de los ejercicios previos) un Pod `hardened` impecable en la capa Code/Container. Ahora abrí una brecha en la capa **Cluster** otorgando permisos excesivos a un ServiceAccount:

   ```bash
   kubectl -n app create serviceaccount overprivileged
   kubectl create clusterrolebinding oops \
     --clusterrole=cluster-admin \
     --serviceaccount=app:overprivileged
   ```

2. Montá ese SA en un Pod cualquiera y mostrá que, pese al *Code* perfecto, la brecha de *Cluster* permite tomar todo:

   ```bash
   kubectl -n app run attacker --image=bitnami/kubectl:1.29 \
     --overrides='{"spec":{"serviceAccountName":"overprivileged"}}' \
     --restart=Never -- sleep 3600

   # Desde el Pod, con el token montado, leé secrets de OTRO namespace:
   kubectl -n app exec attacker -- kubectl get secret -n kube-system
   ```

   El Pod lista secrets de `kube-system`: el endurecimiento de la capa Container/Code no evitó nada, porque la falla estaba una capa más afuera.

3. Limpiá la brecha y confirmá el cierre:

   ```bash
   kubectl delete clusterrolebinding oops
   kubectl -n app exec attacker -- kubectl get secret -n kube-system 2>&1 | head -n 2
   ```

   Ahora debería aparecer `Error from server (Forbidden)`.

4. Teardown del lab:

   ```bash
   kind delete cluster --name 4c-lab
   ```

> **Preguntas de verificación (5)**
> - **5.1** El Pod `attacker` no tenía ninguna capability, corría non-root y con rootfs read-only. Aun así comprometió el cluster. ¿Qué frase del modelo de las 4C resume por qué?
> - **5.2** Ordená estas fallas de la más "externa" a la más "interna" y decí qué controla cada capa: (a) etcd sin cifrar, (b) dependencia con CVE, (c) `cluster-admin` de más, (d) contenedor `privileged`.
> - **5.3** Si tuvieras presupuesto para arreglar **una sola** capa primero, ¿cuál elegirías según el modelo y por qué invertir primero "adentro" (Code) sería un error?

---

<details>
<summary><strong>Respuestas</strong> (desplegar sólo después de intentar)</summary>

**Ejercicio 0**
- **0.1** Orden: **Cloud → Cluster → Container → Code**, de afuera hacia adentro. Cada capa se ejecuta *sobre* la anterior y confía en ella; por eso la seguridad del Code no puede compensar una capa externa débil: el código corre dentro de un contenedor, que corre en un cluster, que corre sobre infraestructura Cloud. Si la Cloud está comprometida, el atacante ya está "por debajo" del Code y ningún control de Code lo alcanza. La cita canónica: *"You cannot safeguard against poor security standards in the base (Cloud, Cluster, Container) by only addressing security at the Code level."*
- **0.2** En un cluster gestionado, el proveedor asume la seguridad física del datacenter, el plano de control gestionado (a veces el hardening del API server/etcd) y el hardware. Vos seguís siendo responsable de la configuración de red (VPC, security groups), IAM, los nodos worker (según el modelo), y todo Cluster/Container/Code. Es el **Shared Responsibility Model**.
- **0.3** `etcd` es el *source of truth* del cluster: guarda todos los objetos, incluidos los `Secrets`. Acceso de lectura a etcd ≈ acceso a todo el estado (y a las credenciales) del cluster. Por eso requiere cifrado en tránsito (mTLS entre apiserver y etcd), cifrado en reposo (`EncryptionConfiguration`), y aislamiento de red estricto.

**Ejercicio 1**
- **1.1** Devolver `1` prueba que el valor del Secret está **en claro** dentro de etcd (cifrado en reposo *desactivado*). Se remedia con un `EncryptionConfiguration` referenciado por `--encryption-provider-config` en el API server. Providers recomendados hoy: **KMS v2** (envelope encryption con un KMS externo) como primera opción; `aescbc`/`secretbox` como alternativas locales. `identity` = sin cifrado.
- **1.2** `AlwaysAllow` hace que el authorizer apruebe *toda* petición ya autenticada, sin evaluar `Role`/`ClusterRole`. Tus RBAC (capa Cluster) quedan inertes porque nunca se consultan. Es exactamente el efecto "capa externa mal configurada anula la interna": el modo de autorización se fija en el API server (infra/Cloud-Cluster) y gobierna lo que RBAC podría decidir.
- **1.3** La falla original está en la capa **Cloud** (el IMDS del nodo accesible desde un Pod + credenciales de instancia potentes). Endurecer el Container no ayuda porque el token robado es del *nodo/instancia*, no del contenedor; el atacante usa credenciales de infraestructura que viven fuera del pod sandbox. Mitigación: IMDSv2, hop-limit=1, restringir el rol de instancia, y NetworkPolicy/egress hacia `169.254.169.254`.
- **1.4** Ejemplos: security groups / firewall del VPC, IAM roles y políticas del proveedor, cifrado de discos EBS/PD, IMDSv2, control de acceso físico, aislamiento de red entre nodos. Ninguno es un objeto de la API de Kubernetes.

**Ejercicio 2**
- **2.1** *Secure by default / deny by default*: RBAC es aditivo — sin un binding explícito, no hay permisos. No existen reglas "deny"; simplemente la ausencia de un `allow` es un `no`. El menor privilegio es el estado inicial.
- **2.2** `enforce` rechaza el Pod que viola el estándar; `audit` lo deja pasar pero anota una entrada en el audit log; `warn` lo deja pasar y devuelve un warning al cliente. Empezás por `warn`/`audit` para descubrir qué cargas existentes violarían `restricted` sin romper producción, y recién después subís a `enforce`.
- **2.3** Causa raíz: el **CNI no implementa NetworkPolicy** (kindnet en `kind`). El objeto `NetworkPolicy` se admite en la API pero nadie lo *aplica* en el dataplane. El CNI/plugin de red es un componente de la capa **Cluster** (aislamiento de red). Solución: un CNI con enforcement (Calico, Cilium).
- **2.4** No. Un `Role`+`RoleBinding` está *namespaced*: sólo aplica dentro de `app`. Para leer secrets de `kube-system` haría falta un `ClusterRole` con un `ClusterRoleBinding`, o un `RoleBinding` a un `ClusterRole` *dentro* de `kube-system`. El scope del recurso limita el alcance del permiso.

**Ejercicio 3**
- **3.1** `drop: ["ALL"]` parte de cero y sólo agregás lo estrictamente necesario (allowlist). Listar capabilities a quitar (denylist) es frágil: si una versión futura de Kubernetes/containerd agrega una capability nueva al set por defecto, tu denylist no la contempla y la heredás sin querer. Allowlist > denylist.
- **3.2** `readOnlyRootFilesystem: true` impide que un atacante escriba binarios/config en el contenedor (persistencia, tampering) y reduce el impacto de un RCE. nginx necesita escribir rutas de trabajo temporales; por eso se montan `emptyDir` *writable* sólo en `/tmp`, `/var/cache/nginx` y `/var/run`, dejando el resto del rootfs inmutable.
- **3.3** Falla en **runtime**: el kubelet arranca el contenedor y, al detectar que el proceso quiere UID 0 con `runAsNonRoot: true`, lo mata con un error tipo `container has runAsNonRoot and image will run as root` (`CreateContainerConfigError`). La solución es una imagen que declare un `USER` no-root (p. ej. `nginx-unprivileged`).
- **3.4** Trivy reporta ambas: los CVEs de **paquetes del OS de la base image** (glibc, openssl del layer Debian/Alpine) son deuda de la capa **Container** — se arreglan actualizando/cambiando la base image. Los CVEs de **dependencias de la aplicación** (librerías en `requirements.txt`, `package-lock.json`, `go.mod`) son capa **Code** — se arreglan bumpeando la dependencia en el repo.

**Ejercicio 4**
- **4.1** Un `Secret` de K8s se guarda base64 (no cifrado) en etcd, y es legible por cualquiera con RBAC suficiente. Necesita al menos: (1) **cifrado en reposo de etcd** (`EncryptionConfiguration`/KMS) — capa Cloud/Cluster; (2) **RBAC restrictivo** sobre `get/list secrets` — capa Cluster. Sin esos, el Secret está "en claro" para quien acceda a etcd o tenga permisos de más.
- **4.2** El CVE de `requests` (Code) lo remedia el **equipo de la app** bumpeando la versión en el manifiesto de dependencias y reconstruyendo. El CVE de la base image de nginx (Container) lo remedia actualizando la **base image** (nueva etiqueta/digest del proveedor) o rebase a una distroless; a menudo no depende del código de tu app.
- **4.3** TLS *in transit* protege datos que viajan por la red *entre procesos de la app/servicios* — es responsabilidad de cómo el código establece conexiones (elegir HTTPS/mTLS, verificar certs): capa Code. El cifrado *en reposo* de etcd protege datos almacenados por la **infraestructura del cluster**, algo que el código de la app no controla: se configura en el API server/etcd (Cloud/Cluster).
- **4.4** Secret en `config.py` → **SAST** (o secret scanning, análisis estático del fuente). CVE en `requests` → **SCA** (Software Composition Analysis / escaneo de dependencias). Inyección SQL contra la app corriendo → **DAST** (análisis dinámico).

**Ejercicio 5**
- **5.1** *"No podés proteger contra malos estándares de seguridad en las capas base atendiendo sólo la capa Code."* El `attacker` tenía Code/Container impecables, pero la brecha en Cluster (`cluster-admin` de más) estaba una capa más afuera, y por eso los ganó a todos.
- **5.2** De externa a interna: **(a) etcd sin cifrar → Cloud/Cluster** (estado/infra en reposo); **(c) `cluster-admin` de más → Cluster** (authz/RBAC); **(d) contenedor `privileged` → Container** (runtime/aislamiento); **(b) dependencia con CVE → Code** (fuente/dependencias).
- **5.3** Elegirías la capa **más externa** que esté rota (empezar por Cloud/Cluster). Invertir primero "adentro" (Code) es un error porque una capa externa comprometida vuelve irrelevante todo el trabajo interno: podés tener el código perfecto y aun así perderlo todo por un etcd sin cifrar o un RBAC laxo. La defensa se construye de afuera hacia adentro.

</details>