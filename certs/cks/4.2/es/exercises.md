# Ejercicios guiados: 4.2 Understand your supply chain

> Fuente de referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

Estos ejercicios cubren los puntos centrales del *supply chain* de Kubernetes: generación de **SBOM**, **image scanning**, control de origen de imágenes (registries permitidos), y **image signing/verification**. Se asume un cluster `kubeadm` con al menos un control-plane node y acceso a `kubectl` con permisos de cluster-admin.

---

## Ejercicio 1: Generar un SBOM de una imagen de contenedor

Un **SBOM** (Software Bill of Materials) es un inventario de todos los componentes (paquetes del OS, librerías de lenguaje, licencias) que forman una imagen. Sirve para auditar de qué está hecha una imagen sin tener que inspeccionarla manualmente.

1. Instalá `syft`, una herramienta que genera SBOMs a partir de imágenes de contenedor:
   ```bash
   curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
     | sh -s -- -b /usr/local/bin
   syft version
   ```

2. Generá un SBOM en formato tabla legible de una imagen pública:
   ```bash
   syft nginx:1.25 -o table
   ```

3. Ahora generá el mismo SBOM en formato **SPDX**, un estándar de intercambio de SBOMs:
   ```bash
   syft nginx:1.25 -o spdx-json > nginx-sbom.spdx.json
   ```

4. Inspeccioná cuántos paquetes fueron detectados y de qué tipo (`apk`, `deb`, `npm`, etc.):
   ```bash
   jq '.packages | length' nginx-sbom.spdx.json
   jq '[.packages[].name] | unique | length' nginx-sbom.spdx.json
   ```

**Preguntas de comprensión:**
1. ¿Por qué un SBOM es útil incluso si la imagen ya fue escaneada por vulnerabilidades?
2. ¿En qué etapa del pipeline de CI/CD tiene más sentido generar el SBOM: en el build, o después del deploy a producción? ¿Por qué?

---

## Ejercicio 2: Escanear vulnerabilidades con image scanning

El **image scanning** detecta CVEs conocidas en los paquetes de una imagen, comparando el SBOM (implícito) contra bases de datos de vulnerabilidades.

1. Instalá `trivy`:
   ```bash
   curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
     | sh -s -- -b /usr/local/bin
   ```

2. Escaneá una imagen con una versión vieja, que seguramente tenga CVEs conocidas:
   ```bash
   trivy image nginx:1.14
   ```

3. Filtrá el resultado para mostrar solo vulnerabilidades `CRITICAL` y `HIGH`:
   ```bash
   trivy image --severity CRITICAL,HIGH nginx:1.14
   ```

4. Configurá trivy para que falle (exit code distinto de 0) si encuentra vulnerabilidades `CRITICAL` — esto es lo que se integra como *gate* en un pipeline de CI/CD:
   ```bash
   trivy image --severity CRITICAL --exit-code 1 nginx:1.14
   echo "exit code: $?"
   ```

5. Repetí el escaneo contra una imagen actualizada y compará la cantidad de hallazgos:
   ```bash
   trivy image --severity CRITICAL,HIGH nginx:1.27
   ```

**Preguntas de comprensión:**
1. ¿En qué punto del pipeline de CI/CD conviene ubicar este `--exit-code 1` para que sea efectivo como control de supply chain?
2. Si una imagen pasa el scan hoy pero mañana aparece un CVE nuevo para uno de sus paquetes, ¿qué mecanismo permite detectarlo sin volver a buildear la imagen?

---

## Ejercicio 3: Restringir el origen de las imágenes con ValidatingAdmissionPolicy

Una de las defensas más importantes del supply chain es no permitir que el cluster ejecute imágenes de **artifact repositories** no confiables. Vamos a bloquear cualquier imagen que no venga de un registry permitido, usando `ValidatingAdmissionPolicy` (nativo desde 1.30, sin necesidad de un webhook externo).

1. Creá la política de validación que solo permite imágenes del registry `registry.internal.local/`:
   ```yaml
   # allowed-registry-policy.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: allowed-registry-policy
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
       - apiGroups: [""]
         apiVersions: ["v1"]
         operations: ["CREATE"]
         resources: ["pods"]
     validations:
       - expression: >
           object.spec.containers.all(c,
             c.image.startsWith('registry.internal.local/'))
         message: "Solo se permiten imagenes de registry.internal.local/"
   ```
   ```bash
   kubectl apply -f allowed-registry-policy.yaml
   ```

2. Creá el binding que activa la política sobre todo el cluster:
   ```yaml
   # allowed-registry-binding.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: allowed-registry-binding
   spec:
     policyName: allowed-registry-policy
     validationActions: ["Deny"]
   ```
   ```bash
   kubectl apply -f allowed-registry-binding.yaml
   ```

3. Intentá crear un pod con una imagen de Docker Hub (no permitida) y observá el rechazo:
   ```bash
   kubectl run test-denied --image=nginx:1.27
   ```

4. Ahora probá con una imagen del registry permitido (podés usar un nombre ficticio para confirmar que pasa la validación, ya que el pod puede quedar en `ImagePullBackOff` pero fue **admitido**):
   ```bash
   kubectl run test-allowed --image=registry.internal.local/nginx:1.27
   kubectl get pod test-allowed
   ```

**Preguntas de comprensión:**
1. ¿Cuál es la diferencia entre que un pod sea *rechazado por el admission controller* y que quede en `ImagePullBackOff`?
2. ¿Por qué `failurePolicy: Fail` es la opción correcta para un control de seguridad de supply chain, y no `Ignore`?

---

## Ejercicio 4: Firmar y verificar imágenes con cosign

El **image signing** garantiza que una imagen fue efectivamente publicada por quien dice haberla publicado, y que no fue alterada después. `cosign` (proyecto Sigstore) es la herramienta de referencia.

1. Instalá `cosign`:
   ```bash
   curl -sSLo cosign https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   chmod +x cosign && sudo mv cosign /usr/local/bin/
   ```

2. Generá un par de claves (privada/pública) para firmar:
   ```bash
   cosign generate-key-pair
   # genera cosign.key y cosign.pub
   ```

3. Etiquetá y subí una imagen a un registry al que tengas acceso de push (ajustá `<tu-registry>`):
   ```bash
   docker tag nginx:1.27 <tu-registry>/nginx:1.27
   docker push <tu-registry>/nginx:1.27
   ```

4. Firmá la imagen ya publicada (la firma se sube al registry como un artefacto asociado):
   ```bash
   cosign sign --key cosign.key <tu-registry>/nginx:1.27
   ```

5. Verificá la firma usando la clave pública:
   ```bash
   cosign verify --key cosign.pub <tu-registry>/nginx:1.27
   ```

6. Verificá qué pasa si intentás validar una imagen que nunca fue firmada:
   ```bash
   cosign verify --key cosign.pub <tu-registry>/redis:7
   ```

**Preguntas de comprensión:**
1. ¿Qué garantiza `cosign verify` que un simple `image scanning` (Ejercicio 2) no garantiza?
2. En un pipeline de CI/CD real, ¿en qué paso debería ejecutarse `cosign sign`, y quién debería tener acceso a `cosign.key`?

---

## Ejercicio 5: Autenticación segura contra un artifact repository privado

Los **artifact repositories** (registries privados) requieren credenciales. Un error común de supply chain es dejar esas credenciales expuestas o con permisos más amplios de lo necesario.

1. Creá un secret de tipo `docker-registry` con las credenciales del registry privado:
   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=registry.internal.local \
     --docker-username=ci-bot \
     --docker-password='<password>' \
     --docker-email=ci@example.com
   ```

2. Referenciá el secret en un pod para poder pullear una imagen privada:
   ```yaml
   # private-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: private-pod
   spec:
     containers:
     - name: app
       image: registry.internal.local/nginx:1.27
     imagePullSecrets:
     - name: regcred
   ```
   ```bash
   kubectl apply -f private-pod.yaml
   ```

3. Verificá que el secret nunca queda expuesto en texto plano al listar el objeto:
   ```bash
   kubectl get secret regcred -o yaml
   kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
   ```

4. Restringí qué `ServiceAccount` puede usar ese `imagePullSecret`, en vez de dejarlo disponible pod por pod:
   ```bash
   kubectl patch serviceaccount default \
     -p '{"imagePullSecrets": [{"name": "regcred"}]}'
   ```

**Preguntas de comprensión:**
1. ¿Por qué el paso 3 muestra que el secret está codificado en base64 y no cifrado, y qué implica eso sobre el control de acceso RBAC al recurso `secrets`?
2. Si un `ServiceAccount` tiene el `imagePullSecret` configurado (paso 4), ¿todavía hace falta declarar `imagePullSecrets` en el `spec` de cada pod?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
1. El scanning de vulnerabilidades solo detecta CVEs *conocidas* en el momento del scan. El SBOM es el inventario base que permite, más adelante, volver a chequear la imagen contra nuevas CVEs sin re-analizar el binario, hacer auditorías de licencias, y responder rápido ante un incidente tipo Log4Shell ("¿tenemos este paquete en algún lado?").
2. Conviene generarlo en el **build**, inmediatamente después de armar la imagen, porque en ese momento el pipeline tiene el contexto completo del build (versiones exactas, capas). Generarlo después del deploy requeriría inspeccionar la imagen ya corriendo, perdiendo trazabilidad con el commit/build que la originó.

**Ejercicio 2**
1. Conviene ubicarlo en el paso de **build de la imagen en CI**, antes del `push` al registry — así una imagen con CVEs críticas nunca llega a estar disponible para deploy. Ponerlo solo en el deploy es tarde: la imagen vulnerable ya está publicada y pudo haber sido pulleada por otros.
2. Ese mecanismo es el **re-scanning periódico** del artifact repository (la mayoría de los registries y scanners soportan escanear imágenes ya almacenadas contra la base de CVEs actualizada), no solo el scan en build time.

**Ejercicio 3**
1. `ImagePullBackOff` significa que el pod **fue admitido** por el API server (pasó todos los admission controllers) pero el kubelet no pudo descargar la imagen del registry (no existe, no hay credenciales, etc.). El rechazo del admission controller ocurre **antes**, en el `kubectl run`/`create`, y el objeto Pod ni siquiera llega a persistirse en etcd.
2. `failurePolicy: Fail` asegura que si el admission controller no puede evaluar la política (por ejemplo, un error interno), la request se **rechaza por defecto**. Con `Ignore`, un fallo temporal de la política dejaría pasar imágenes sin control, lo cual es inaceptable para un gate de seguridad de supply chain (fail-closed vs. fail-open).

**Ejercicio 4**
1. `cosign verify` garantiza **integridad y autenticidad**: que la imagen no fue modificada después de la firma y que fue firmada por quien posee la clave privada correspondiente. El image scanning solo te dice si hay CVEs conocidas en el contenido, pero no te dice si esa imagen es realmente la que tu organización publicó (podría ser una imagen suplantada sin ninguna CVE y aun así maliciosa).
2. Debería ejecutarse **al final del pipeline de CI**, inmediatamente después del `push` exitoso al registry (y típicamente después de pasar el gate de scanning). `cosign.key` debe vivir solo en el entorno de CI (como secret gestionado, ej. KMS o secret manager), nunca en el repositorio de código ni accesible a desarrolladores individuales — solo el pipeline automatizado debería poder firmar.

**Ejercicio 5**
1. `kubectl get secret -o yaml` muestra el valor en **base64**, que es solo una codificación (reversible sin clave), no cifrado. Esto implica que cualquiera con permiso RBAC de `get`/`list` sobre `secrets` en ese namespace puede leer la credencial en texto plano — por eso el acceso a `secrets` debe restringirse fuertemente con RBAC, y en producción conviene usar cifrado en reposo (`EncryptionConfiguration`) en etcd.
2. No. Al estar configurado en el `ServiceAccount`, el `imagePullSecret` se aplica automáticamente a todos los pods que usen ese `ServiceAccount`, sin necesidad de repetirlo en cada `spec.imagePullSecrets`.

</details>