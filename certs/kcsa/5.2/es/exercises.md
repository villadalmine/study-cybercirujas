# Material de estudio de KCSA: Tema 5.2 - Image Repository

**Certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** Supply Chain Security  
**Tema 5.2:** Image Repository  
**Peso en el examen:** 2.29%  

---

## Análisis arquitectónico profundo y compromisos de producción

Un Image Repository (o Container Registry) sirve como el almacén de artefactos primario en las cadenas de suministro cloud-native. En las arquitecturas modernas de seguridad de Kubernetes, asegurar el ciclo de vida del repositorio de imágenes abarca tres límites distintos: **Autenticación y control de acceso**, **Integridad y autenticidad del artefacto** y **Gobernanza de vulnerabilidades**.

```
  +-----------------------------------------------------------------------------------+
  |                                 CONTAINER REGISTRY                                |
  |                                                                                   |
  |  +---------------------+      +---------------------+      +-------------------+  |
  |  |   OCI Image Manifest|      |  Layer Blobs (tar)  |      | Cosign Signature  |  |
  |  |   (sha256 digest)   |      |  (read-only layers) |      | (OCI Artifact)    |  |
  |  +----------+----------+      +----------+----------+      +---------+---------+  |
  +-------------|----------------------------|---------------------------|------------+
                |                            |                           |
                v                            v                           v
  +-----------------------------------------------------------------------------------+
  |                             KUBERNETES CONTROL PLANE                              |
  |                                                                                   |
  |  +-----------------------------------------------------------------------------+  |
  |  | ValidatingAdmissionWebhook (e.g., Kyverno / OPA Gatekeeper / ImagePolicy)  |  |
  |  | - Verifies Cosign Signature against PKI / Rekor Transparency Log           |  |
  |  | - Enforces Image Digest Pinning (mutates tag to @sha256:<hash>)             |  |
  |  +-------------------------------------+---------------------------------------+  |
  +----------------------------------------|------------------------------------------+
                                           v
  +-----------------------------------------------------------------------------------+
  |                                  WORKER NODE                                      |
  |                                                                                   |
  |  +-----------------------------------------------------------------------------+  |
  |  | Kubelet / CRI Runtime (containerd/CRI-O)                                    |  |
  |  | - Kubelet Credential Provider (exec plugin fetches short-lived OIDC tokens) |  |
  |  | - Pulls layers to local store (/var/lib/containerd/io.containerd.content)   |  |
  |  +-----------------------------------------------------------------------------+  |
  +-----------------------------------------------------------------------------------+
```

### 1. Mecánica de autenticación y autorización
* **ImagePullSecrets & ServiceAccounts:** Kubernetes desacopla las definiciones de Pods de las credenciales del registry adjuntando `imagePullSecrets` directamente a los objetos `ServiceAccount` o a las definiciones de `PodSpec`. Durante la transición de estado programada del Pod, el Kubelet extrae el token del secret (`.dockerconfigjson` codificado en Base64) y lo transmite a través de autenticación HTTP Basic o tokens bearer al endpoint del registry.
* **Kubelet Image Credential Provider:** Los `imagePullSecrets` estáticos tradicionales pueden filtrar credenciales entre namespaces si se configuran de manera errónea. Los clusters de producción de Kubernetes utilizan el patrón de plugin `Kubelet Image Credential Provider` (`--image-credential-provider-config`). El Kubelet llama a un binario ejecutable fuera de banda en el nodo para obtener dinámicamente tokens IAM de nube de corta duración (por ejemplo, AWS ECR, GCP GAR, Azure ACR) justo antes de las operaciones de obtención de capas (layer fetch).

### 2. Verificación e integridad de imágenes (Supply Chain Security)
* **Fijación por Tag vs. Digest (Digest Pinning):** Los tags como `v1.2.0` o `latest` son referencias mutables sujetas a sustitución por **man-in-the-middle (MITM)** o a una sobrescritura maliciosa en el repositorio. Los digests criptográficos (`sha256:abcd...`) representan hashes criptográficos inmutables del OCI Image Index/Manifest.
* **Sigstore & Cosign:** El firmado moderno de artefactos utiliza Sigstore (`cosign`). Las firmas se pueden almacenar dentro del OCI registry junto a la imagen como artefactos OCI estándar o almacenarse fuera del registry. La verificación ocurre en la capa de Kubernetes Admission Control utilizando webhooks de mutación/validación antes de la programación (scheduling) del Pod.

### 3. Escaneo de vulnerabilidades y análisis estático
* **Alcances de escaneo (Scanning Scopes):** El análisis estático de imágenes ocurre en tres etapas del pipeline:
  1. **Gate del pipeline de CI/CD:** Bloquea el push del artefacto si se superan los umbrales de severidad de CVE.
  2. **Escaneo del lado del registry:** Escaneo asíncrono continuo de capas almacenadas (por ejemplo, integración de Harbor + Trivy).
  3. **Gate de Admission Control:** Valida la metadata del resultado del escaneo antes de la admisión de la carga de trabajo (workload).

---

## Referencias oficiales
* [Kubernetes Documentation: Images](https://kubernetes.io/docs/concepts/containers/images/)
* [Kubernetes Documentation: Kubelet Credential Provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
* [CNCF KCSA Exam Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* [Sigstore Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
* [Trivy Vulnerability Scanner Documentation](https://aquasecurity.github.io/trivy/)
* [Kyverno Image Verification Documentation](https://kyverno.io/docs/writing-policies/verify-images/)

---

## Ejercicios guiados

### Ejercicio 1: Aplicación de digests de imagen inmutables e ImagePullSecrets en ServiceAccounts

#### Contexto y objetivos
Necesitás configurar un namespace de producción seguro donde las cargas de trabajo tengan restringida la extracción de tags mutables (`:latest`) y deban autenticarse contra un OCI registry privado (`registry.internal.enterprise.io`) utilizando un enlace de credenciales de `ServiceAccount` dedicado.

#### Paso 1: Crear un Secret de Kubernetes Docker Registry
Ejecutá el comando de CLI para sintetizar un secret `.dockerconfigjson` que contenga tokens de acceso autenticados para el repositorio privado:

```bash
kubectl create secret docker-registry private-registry-creds \
  --namespace=prod-secure \
  --docker-server=registry.internal.enterprise.io \
  --docker-username=svc-image-puller \
  --docker-password=dGhpcy1pcy1hLXNlY3VyZS10b2tlbi1mb3ItY3Jp \
  --docker-email=security-ops@enterprise.io \
  --dry-run=client -o yaml > registry-secret.yaml

kubectl create namespace prod-secure
kubectl apply -f registry-secret.yaml
```

**Salida esperada:**
```
secret/private-registry-creds created (dry run)
namespace/prod-secure created
secret/private-registry-creds created
```

#### Paso 2: Configurar la autoinyección de ImagePullSecrets en el ServiceAccount
Creá un manifiesto declarativo de ServiceAccount (`serviceaccount-secure.yaml`) que adjunte automáticamente `private-registry-creds` a cualquier Pod que se ejecute bajo su contexto:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secure-app-sa
  namespace: prod-secure
imagePullSecrets:
  - name: private-registry-creds
```

Aplicá el manifiesto del ServiceAccount:

```bash
kubectl apply -f serviceaccount-secure.yaml
```

**Salida esperada:**
```
serviceaccount/secure-app-sa created
```

#### Paso 3: Desplegar un Pod con fijación por Digest (`sha256`)
Desplegá un manifiesto de pod (`pod-digest-pinned.yaml`) vinculado a `secure-app-sa` utilizando una fijación estricta por digest SHA256 en lugar de un tag mutable:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: payment-processor
  namespace: prod-secure
  labels:
    tier: payment
spec:
  serviceAccountName: secure-app-sa
  containers:
  - name: processor
    image: registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    imagePullPolicy: IfNotPresent
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
```

Aplicá el manifiesto del Pod:

```bash
kubectl apply -f pod-digest-pinned.yaml
```

**Salida esperada:**
```
pod/payment-processor created
```

---

#### Preguntas de comprensión - Ejercicio 1
1. **Pregunta 1.1:** ¿Por qué hacer referencia a una imagen mediante un tag mutable (por ejemplo, `image:v1.2.0`) introduce un riesgo crítico para la cadena de suministro en comparación con la referencia por digest inmutable (`image@sha256:...`), incluso si `imagePullPolicy` está configurado en `Always`?
2. **Pregunta 1.2:** Si un desarrollador envía un manifiesto de Pod sin especificar `imagePullSecrets`, pero el Pod especifica `serviceAccountName: secure-app-sa`, ¿cómo evalúa el Kubelet las credenciales de autenticación frente al container registry?

---

### Ejercicio 2: Escaneo estático de vulnerabilidades y generación de políticas de Gatekeeper usando Trivy

#### Contexto y objetivos
Estás auditando una imagen de contenedor OCI (`nginx:1.21.6`) antes de permitir su ingreso a producción. Ejecutarás un escaneo de vulnerabilidades usando `trivy`, filtrarás CVEs de severidad `CRITICAL`, generarás un reporte de vulnerabilidades y crearás un constraint de OPA Gatekeeper para bloquear imágenes vulnerables en la admisión.

#### Paso 1: Ejecutar el escaneo de la imagen de contenedor a través de la CLI de Trivy
Ejecutá `trivy` para realizar un análisis estático de vulnerabilidades por capa, parseando paquetes del sistema operativo y dependencias de la aplicación:

```bash
trivy image --severity CRITICAL,HIGH \
  --format table \
  --ignore-unfixed \
  nginx:1.21.6
```

**Salida esperada:**
```
nginx:1.21.6 (debian 11.3)

Total: 28 (HIGH: 22, CRITICAL: 6)

+------------------+------------------+----------+-------------------+---------------+---------------------------------------+
| LIBRARY          | VULNERABILITY ID | SEVERITY | INSTALLED VERSION | FIXED VERSION | TITLE                                 |
+------------------+------------------+----------+-------------------+---------------+---------------------------------------+
| zlib1g           | CVE-2022-37434   | CRITICAL | 1.2.11.dfsg-2+deb11u1 | 1.2.11.dfsg-2+deb11u2 | zlib: heap-based buffer overflow in   |
|                  |                  |          |                   |               | inflate() via large gzip header extra |
| libssl1.1        | CVE-2023-0286    | CRITICAL | 1.1.1n-0+deb11u1  | 1.1.1t-0+deb11u1 | openssl: BN_mod_exp overrun in        |
|                  |                  |          |                   |               | X509 verification                     |
| dpkg             | CVE-2022-36227   | HIGH     | 1.20.9            | 1.20.12       | libarchive: Buffer overflow           |
+------------------+------------------+----------+-------------------+---------------+---------------------------------------+
```

#### Paso 2: Formular un ConstraintTemplate de OPA Gatekeeper para bloquear tags mutables
Creá un ConstraintTemplate de OPA Gatekeeper (`ct-disallow-tags.yaml`) que rechace cualquier Pod cuya cadena de imagen no contenga un string de digest `@sha256:` explícito:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: kcsadisallowtags
spec:
  crd:
    spec:
      names:
        kind: KCSADisallowTags
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package kcsadisallowtags

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not contains(container.image, "@sha256:")
          msg := sprintf("Container image '%v' in pod '%v' must specify an immutable digest (@sha256:). Mutable tags are forbidden.", [container.image, input.review.object.metadata.name])
        }
```

Aplicá el ConstraintTemplate:

```bash
kubectl apply -f ct-disallow-tags.yaml
```

**Salida esperada:**
```
constrainttemplate.templates.gatekeeper.sh/kcsadisallowtags created
```

#### Paso 3: Instanciar el Constraint de aplicación de Gatekeeper
Creá el recurso de constraint (`constraint-enforce-digests.yaml`) orientado a todas las solicitudes de creación de Pods en namespaces de producción:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: KCSADisallowTags
metadata:
  name: enforce-image-digests
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "prod-secure"
```

Aplicá el Constraint:

```bash
kubectl apply -f constraint-enforce-digests.yaml
```

**Salida esperada:**
```
kcsadisallowtags.constraints.gatekeeper.sh/enforce-image-digests created
```

#### Paso 4: Validar el rechazo de la política de admisión
Intentá desplegar una carga de trabajo insegura utilizando un tag mutable (`pod-violating.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rogue-workload
  namespace: prod-secure
spec:
  containers:
  - name: web
    image: nginx:1.21.6
```

Aplicá el manifiesto del Pod infractor:

```bash
kubectl apply -f pod-violating.yaml
```

**Salida esperada (Traza de rechazo):**
```
Error from server (Forbidden): error when creating "pod-violating.yaml": admission webhook "validation.gatekeeper.sh" denied the request: [enforce-image-digests] Container image 'nginx:1.21.6' in pod 'rogue-workload' must specify an immutable digest (@sha256:). Mutable tags are forbidden.
```

---

#### Preguntas de comprensión - Ejercicio 2
1. **Pregunta 2.1:** ¿Cuál es la diferencia técnica entre usar `--ignore-unfixed` en un escaneo de Trivy frente a ejecutar un escaneo sin este flag, y cómo afecta esto a la toma de decisiones de SRE durante los gates de despliegue en producción?
2. **Pregunta 2.2:** En la política de Rego para OPA Gatekeeper provista, ¿cómo maneja la evaluación de `input.review.object.spec.containers[_]` los Pods que contienen init containers o ephemeral containers?

---

### Ejercicio 3: Verificación criptográfica de la cadena de suministro usando Cosign y Kyverno

#### Contexto y objetivos
Generarás un par de claves asimétricas utilizando `cosign` de Sigstore, firmarás una imagen de contenedor OCI en un registry local y desplegarás una `ClusterPolicy` de Kyverno que valide criptográficamente las firmas antes de la admisión del Pod.

#### Paso 1: Generar el par de claves criptográficas a través de la CLI de Cosign
Ejecutá `cosign` para crear un par de claves pública/privada para el firmado de artefactos:

```bash
export COSIGN_PASSWORD="ProductionSecurityPassphrase123!"
cosign generate-key-pair
```

**Salida esperada:**
```
Private key written to cosign.key
Public key written to cosign.pub
```

#### Paso 2: Firmar el digest de la imagen de contenedor
Firmá un artefacto de imagen publicado en un registry de destino (`myregistry.internal.enterprise.io/apps/auth-service@sha256:7f83b1657ff1fc53b92cb1...`):

```bash
cosign sign --key cosign.key \
  myregistry.internal.enterprise.io/apps/auth-service@sha256:7f83b1657ff1fc53b92cb1015b6d51a66c8b9134015ef05d76201a4e1d6e3f22
```

**Salida esperada:**
```
Enter password for private key: 
Pushing signature to: myregistry.internal.enterprise.io/apps/auth-service:sha256-7f83b1657ff1fc53b92cb1015b6d51a66c8b9134015ef05d76201a4e1d6e3f22.sig
```

#### Paso 3: Extraer el contenido de la clave pública para su inclusión en la política
Visualizá la clave pública exportada:

```bash
cat cosign.pub
```

**Salida esperada:**
```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7p3V+p23Hk6kXw+Fv98L8mO8sY8N
W+4m1h3901nK1qW4LgS8K8z+y1Hw8m8z43s1n2m9k0L1==
-----END PUBLIC KEY-----
```

#### Paso 4: Crear una política de verificación de imágenes en Kyverno
Escribí una `ClusterPolicy` declarativa de Kyverno (`kyverno-verify-signature.yaml`) que aplique comprobaciones de firma con respecto a `cosign.pub`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-cosign-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaces:
              - prod-secure
      verifyImages:
      - imageReferences:
        - "myregistry.internal.enterprise.io/apps/*"
        key: |
          -----BEGIN PUBLIC KEY-----
          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7p3V+p23Hk6kXw+Fv98L8mO8sY8N
          W+4m1h3901nK1qW4LgS8K8z+y1Hw8m8z43s1n2m9k0L1==
          -----END PUBLIC KEY-----
```

Aplicá la ClusterPolicy de Kyverno:

```bash
kubectl apply -f kyverno-verify-signature.yaml
```

**Salida esperada:**
```
clusterpolicy.kyverno.io/verify-image-signature created
```

---

#### Preguntas de comprensión - Ejercicio 3
1. **Pregunta 3.1:** ¿Dónde almacena Cosign la firma criptográfica por defecto al firmar una imagen OCI, y cómo afecta esto a la gestión de permisos del registry?
2. **Pregunta 3.2:** ¿Cuál es la diferencia fundamental entre el firmado con **Cosign basado en claves** (Key-Based, como se usó anteriormente) y el firmado **sin claves** (Keyless) utilizando la arquitectura Fulcio y Rekor de Sigstore?

---

### Ejercicio 4: Diagnóstico avanzado y solución de problemas de seguridad de imágenes en el Kubelet

#### Contexto y objetivos
Un microservicio crítico está atascado en `ImagePullBackOff`. Debés realizar un análisis de diagnóstico de bajo nivel utilizando `kubectl`, `crictl` y logs del sistema a nivel de nodo para aislar si el fallo es causado por un fallo de autenticación, una mala configuración en el handshake de TLS o una discrepancia en el digest de la imagen.

#### Paso 1: Inspeccionar el estado del Pod y el flujo de eventos
Consultá el estado del Pod con fallos en el cluster:

```bash
kubectl get pod payment-processor -n prod-secure -o wide
```

**Salida esperada:**
```
NAME                READY   STATUS             RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
payment-processor   0/1     ImagePullBackOff   0          4m    10.244.1.15   worker-node-2 <none>           <none>
```

Ejecutá `kubectl describe` para extraer el registro detallado de eventos de Kubernetes:

```bash
kubectl describe pod payment-processor -n prod-secure
```

**Salida esperada (Fragmento):**
```
Events:
  Type     Reason     Age                  From               Message
  ----     ------     ----                 ----               -------
  Normal   Scheduled  4m12s                default-scheduler  Successfully assigned prod-secure/payment-processor to worker-node-2
  Normal   Pulling    2m40s (x3 over 4m)   kubelet            Pulling image "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442..."
  Warning  Failed     2m38s (x3 over 4m)   kubelet            Failed to pull image "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442...": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference: pull access denied, repository does not exist or may require login: authorization failed
  Warning  Failed     2m38s (x3 over 4m)   kubelet            Error: ErrImagePull
  Normal   BackOff    1m15s (x6 over 3m)   kubelet            Back-off pulling image "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442..."
```

#### Paso 2: Diagnóstico de bajo nivel en el nodo utilizando `crictl` y `journalctl`
Iniciá sesión en `worker-node-2` y usá `crictl` para consultar la capa Container Runtime Interface (CRI) directamente:

```bash
# SSH into worker-node-2
crictl pull --creds "svc-image-puller:wrong-password" \
  registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

**Salida esperada:**
```
FATAL[0001] pulling image failed: rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442...": pull access denied, repository does not exist or may require login: server message: insufficient_scope: authorization failed
```

Extraé el log del journal de `containerd`/`kubelet` para verificar errores de ejecución del proveedor de credenciales:

```bash
journalctl -u kubelet --since "10 minutes ago" | grep -E "credentialprovider|imagePull"
```

**Salida esperada:**
```
Aug 07 20:15:10 worker-node-2 kubelet[1245]: E0807 20:15:10.112443    1245 provider.go:142] "Credential provider plugin returned error" plugin="aws-ecr-credential-provider" err="exit status 1"
Aug 07 20:15:10 worker-node-2 kubelet[1245]: E0807 20:15:10.112510    1245 kuberuntime_image.go:154] "PullImage from image service failed" err="rpc error: code = Unknown desc = failed to pull and unpack image..."
```

---

#### Preguntas de comprensión - Ejercicio 4
1. **Pregunta 4.1:** ¿Cuál es la diferencia técnica entre el estado de error `ErrImagePull` y el estado `ImagePullBackOff` en Kubernetes?
2. **Pregunta 4.2:** Si `kubectl describe pod` revela `x509: certificate signed by unknown authority` durante la extracción de la imagen, ¿qué configuración específica a nivel de nodo debe ajustarse en `containerd` o `CRI-O` sin deshabilitar la verificación TLS?

---

<details>
<summary>Respuestas y explicaciones</summary>

### Soluciones del Ejercicio 1

* **Respuesta 1.1:**  
  Hacer referencia a una imagen por un tag como `v1.2.0` se basa en un puntero mutable en el registry. Si un atacante obtiene acceso de escritura al repositorio, puede sobrescribir `v1.2.0` con una carga útil (payload) de capa maliciosa sin cambiar el nombre del tag. Incluso con `imagePullPolicy: Always`, el Kubelet extrae el tag actualizado, lo que conduce a la ejecución remota de código (RCE) arbitrario. Por el contrario, un digest SHA256 inmutable (`@sha256:...`) es un hash criptográfico del manifiesto de la imagen. Si las capas de la imagen se alteran, el hash resultante cambia, lo que hace que la operación de extracción falle la verificación de integridad criptográfica.

* **Respuesta 1.2:**  
  Cuando un Pod omite `imagePullSecrets`, el Kubelet inspecciona el `ServiceAccount` especificado en `spec.serviceAccountName` (o `default` si no se especifica). Lee el arreglo `imagePullSecrets` definido en ese objeto `ServiceAccount`, recupera los datos del `Secret` asociado que contienen `.dockerconfigjson`, decodifica las credenciales en Base64 y las utiliza para autenticarse contra el OCI registry de destino. Si los proveedores de credenciales a nivel de nodo están habilitados, el Kubelet recurre a llamar al ejecutable del plugin del proveedor de credenciales si el ServiceAccount carece de las credenciales relevantes.

---

### Soluciones del Ejercicio 2

* **Respuesta 2.1:**  
  El flag `--ignore-unfixed` le indica a Trivy que excluya las CVEs para las cuales la distribución/mantenedor upstream **no** ha lanzado un parche de seguridad (`FIXED VERSION` está vacío).  
  * **Compromiso de SRE (SRE Trade-off):** Usar `--ignore-unfixed` reduce la fatiga de alertas al ocultar vulnerabilidades no accionables, lo que permite que los pipelines de compilación automatizados se concentren solo en soluciones accionables. Sin embargo, desde una postura de Zero Trust, las vulnerabilidades `CRITICAL` sin parche permanecen presentes en el contenedor en ejecución y requieren controles compensatorios (por ejemplo, AppArmor, Seccomp, NetworkPolicies).

* **Respuesta 2.2:**  
  La línea de Rego `container := input.review.object.spec.containers[_]` evalúa **únicamente** los contenedores de aplicación estándar. **No** evalúa `initContainers` ni `ephemeralContainers` porque en el esquema de PodSpec de Kubernetes, estos residen en arreglos separados (`spec.initContainers` y `spec.ephemeralContainers`). Para cubrir todos los tipos de contenedores, la política de Rego debe iterar sobre un arreglo combinado:
  ```rego
  all_containers := array.concat(
    object.get(input.review.object.spec, "containers", []),
    object.get(input.review.object.spec, "initContainers", [])
  )
  container := all_containers[_]
  ```

---

### Soluciones del Ejercicio 3

* **Respuesta 3.1:**  
  Por defecto, Cosign escribe las firmas directamente en el OCI container registry de destino como un artefacto OCI independiente. El tag de la firma se nombra de manera determinista utilizando el prefijo del digest de la imagen: `sha256-<digest>.sig`.  
  * **Impacto en los permisos:** El service account de CI/CD o la identidad humana que ejecuta `cosign sign` debe poseer **permisos de escritura/push** en la ubicación del repositorio de imágenes, ya que carga una capa de manifiesto diferenciada que contiene la carga útil (payload) de la firma.

* **Respuesta 3.2:**  
  * **Firmado basado en claves (Key-Based):** Utiliza una clave privada estática (por ejemplo, `cosign.key`) protegida por una frase de paso (passphrase). La clave pública debe distribuirse manualmente a los consumidores (o incrustarse en controladores de admisión como Kyverno). La rotación y revocación de claves requieren actualizaciones manuales de políticas en todos los clusters.
  * **Firmado sin claves (Keyless - Fulcio + Rekor):** Utiliza certificados X.509 de corta duración emitidos por Fulcio basados en tokens de identidad OIDC (por ejemplo, GitHub Actions, Google IAM). El evento de firma se registra en Rekor, un registro público de transparencia a prueba de manipulaciones. La verificación se basa en confiar en la CA raíz de Fulcio e inspeccionar la entrada del registro de Rekor, eliminando la necesidad de almacenar y rotar claves privadas estáticas de larga duración.

---

### Soluciones del Ejercicio 4

* **Respuesta 4.1:**  
  * `ErrImagePull`: Representa un fallo inmediato de un único intento de extracción de imagen (por ejemplo, tiempo de espera de red agotado, 404 Not Found, 401 Unauthorized o manifiesto no válido).
  * `ImagePullBackOff`: Representa el estado de la máquina de estados del Kubelet de Kubernetes cuando la extracción de una imagen falla repetidamente. El Kubelet entra en un bucle de reintento exponencial (esperando 10s, 20s, 40s, hasta 5 minutos) antes de reintentar la operación de extracción para evitar sobrecargar el container registry o agotar los recursos de CPU/red del nodo.

* **Respuesta 4.2:**  
  El error indica que el runtime de contenedores CRI (`containerd` o `CRI-O`) no confía en el certificado CA raíz personalizado del container registry interno. Para resolver esto sin deshabilitar la verificación TLS (antipatrón `insecure_skip_verify`):
  1. Copiá el certificado CA empresarial interno (`ca.crt`) al almacén de confianza del sistema del nodo (por ejemplo, `/usr/local/share/ca-certificates/` en Debian/Ubuntu o `/etc/pki/ca-trust/source/anchors/` en RHEL) y ejecutá `update-ca-certificates`.
  2. Configurá los ajustes del host de `containerd` en `/etc/containerd/certs.d/registry.internal.enterprise.io/hosts.toml`:
     ```toml
     server = "https://registry.internal.enterprise.io"

     [host."https://registry.internal.enterprise.io"]
       ca = "/etc/containerd/certs.d/registry.internal.enterprise.io/ca.crt"
     ```
  3. Reiniciá el servicio de `containerd`: `systemctl restart containerd`.

</details>