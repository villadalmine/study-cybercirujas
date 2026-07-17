# Ejercicios guiados — CKS 4.3: Secure your supply chain

> Fuente de referencia: [CNCF CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf). Herramientas usadas: [Kyverno](https://kyverno.io/docs/) y [Sigstore cosign](https://docs.sigstore.dev/cosign/overview/). Se asume un cluster `kind` o `minikube` con Helm disponible.

Este set de ejercicios cubre dos controles centrales de supply chain security: **restringir qué registries pueden usarse** (permitted registries) y **firmar/validar artefactos** (image signing) antes de que lleguen a ejecutarse en el cluster.

---

## Ejercicio 1: Restringir registries permitidos con un admission controller

Vas a instalar Kyverno y crear una `ClusterPolicy` que rechace cualquier Pod cuya imagen no provenga de un registry en whitelist.

1. Instalá Kyverno vía Helm:
   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   kubectl wait --for=condition=Ready pods --all -n kyverno --timeout=120s
   ```

2. Creá el archivo `restrict-registries.yaml`:
   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-image-registries
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
       - name: allowed-registries-only
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "Solo se permiten imágenes desde registry.midominio.local o gcr.io/distroless"
           pattern:
             spec:
               containers:
                 - image: "registry.midominio.local/* | gcr.io/distroless/*"
   ```

3. Aplicá la política:
   ```bash
   kubectl apply -f restrict-registries.yaml
   ```

4. Probá con una imagen **no permitida** (debe ser rechazada por el admission webhook):
   ```bash
   kubectl run test-bad --image=docker.io/nginx:latest
   ```

5. Probá con una imagen **permitida** (debe crearse sin problemas, asumiendo que el registry existe o usando `--dry-run=server` si no tenés push todavía):
   ```bash
   kubectl run test-good --image=registry.midominio.local/nginx:1.25 --dry-run=server
   ```

**Preguntas:**

1. ¿Por qué `validationFailureAction: Enforce` es el valor que efectivamente bloquea el Pod, y qué pasaría si estuviera en `Audit`?
2. ¿En qué capa de la arquitectura de Kubernetes se ejecuta esta validación (admission chain), y por qué eso la hace más efectiva que revisar imágenes solo en el registry?

---

## Ejercicio 2: Firmar una imagen de contenedor con cosign

1. Instalá `cosign` (binario standalone):
   ```bash
   curl -sSfLo cosign https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   chmod +x cosign && sudo mv cosign /usr/local/bin/
   cosign version
   ```

2. Generá un par de claves (te va a pedir una passphrase):
   ```bash
   cosign generate-key-pair
   # genera cosign.key (privada) y cosign.pub (pública)
   ```

3. Levantá un registry local para el ejercicio (si no tenés uno accesible):
   ```bash
   docker run -d -p 5000:5000 --name registry registry:2
   ```

4. Etiquetá y subí una imagen de prueba a ese registry:
   ```bash
   docker pull nginx:1.25
   docker tag nginx:1.25 localhost:5000/nginx:1.25
   docker push localhost:5000/nginx:1.25
   ```

5. Firmá la imagen usando su **digest** (no el tag, ya que el tag es mutable):
   ```bash
   DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' localhost:5000/nginx:1.25)
   cosign sign --key cosign.key "$DIGEST"
   ```

**Preguntas:**

1. ¿Por qué `cosign sign` opera sobre el digest (`sha256:...`) y no sobre el tag de la imagen?
2. ¿Dónde queda almacenada la firma generada por cosign? (pista: no es un archivo separado que vos tengas que distribuir manualmente).

---

## Ejercicio 3: Verificar la firma manualmente

1. Verificá la firma con la clave pública correcta:
   ```bash
   cosign verify --key cosign.pub localhost:5000/nginx:1.25
   ```
   Debería devolver el payload verificado en JSON.

2. Ahora generá un **segundo** par de claves distinto y probá verificar con la clave equivocada:
   ```bash
   cosign generate-key-pair --output-key-prefix cosign-otra
   cosign verify --key cosign-otra.pub localhost:5000/nginx:1.25
   ```

3. Observá el resultado del paso 2.

**Preguntas:**

1. ¿Qué mensaje de error esperás en el paso 2, y qué garantía de seguridad te está dando ese fallo?
2. Si un atacante reemplaza la imagen en el registry pero no tiene la clave privada original, ¿puede lograr que `cosign verify` pase con la clave pública legítima?

---

## Ejercicio 4: Forzar la verificación de firmas en el admission control

Ahora vas a hacer que el cluster **rechace automáticamente** cualquier imagen no firmada, usando la regla `verifyImages` de Kyverno.

1. Creá un ConfigMap o directamente embebé la clave pública en la policy `verify-image-signature.yaml`:
   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-image-signature
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
       - name: check-signature
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         verifyImages:
           - imageReferences:
               - "localhost:5000/*"
             attestors:
               - entries:
                   - keys:
                       publicKeys: |-
                         -----BEGIN PUBLIC KEY-----
                         <contenido de cosign.pub>
                         -----END PUBLIC KEY-----
   ```

2. Aplicá la política:
   ```bash
   kubectl apply -f verify-image-signature.yaml
   ```

3. Intentá correr un Pod con una imagen **sin firmar** del mismo registry:
   ```bash
   docker tag nginx:1.25 localhost:5000/nginx:sin-firmar
   docker push localhost:5000/nginx:sin-firmar
   kubectl run test-unsigned --image=localhost:5000/nginx:sin-firmar
   ```

4. Corré un Pod con la imagen **firmada** en el Ejercicio 2:
   ```bash
   kubectl run test-signed --image=localhost:5000/nginx:1.25
   ```

5. Inspeccioná el manifiesto final del Pod firmado:
   ```bash
   kubectl get pod test-signed -o jsonpath='{.spec.containers[0].image}'
   ```

**Preguntas:**

1. ¿Qué pasó con el Pod del paso 3, y en qué se diferencia este control del Ejercicio 1 (restricción por registry)?
2. En el paso 5, ¿qué solés observar respecto al campo `image` del Pod firmado, y por qué Kyverno hace esa transformación automáticamente?

---

## Ejercicio 5: Reemplazar tags por digests en manifiestos productivos

1. Obtené el digest inmutable de una imagen:
   ```bash
   docker inspect --format='{{index .RepoDigests 0}}' localhost:5000/nginx:1.25
   ```

2. Editá un Deployment para referenciar la imagen por digest en vez de por tag:
   ```yaml
   spec:
     containers:
       - name: nginx
         image: localhost:5000/nginx@sha256:<digest-obtenido>
   ```

3. Aplicá el manifiesto y confirmá que el Pod arranca con esa imagen exacta:
   ```bash
   kubectl apply -f deployment.yaml
   kubectl describe pod -l app=nginx | grep Image
   ```

**Preguntas:**

1. ¿Qué riesgo de supply chain mitiga usar `image@sha256:...` en vez de `image:tag` que no mitiga solo firmar la imagen?
2. Si alguien hace `docker push` de una nueva imagen con el mismo tag `1.25` pero contenido distinto, ¿tu Deployment con digest fijo se ve afectado?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**

1. `Enforce` hace que el admission webhook de Kyverno **rechace** la request de creación del Pod cuando no cumple el pattern (el API server devuelve un error y el objeto nunca se persiste en etcd). Con `Audit`, la violación solo queda registrada en el `PolicyReport`, pero el Pod se crea igual — útil para medir impacto antes de aplicar la política en modo bloqueante.
2. Se ejecuta en la **validating admission chain** del API server, antes de que el objeto se escriba en etcd y antes de que el kubelet haga el pull de la imagen. Esto es más efectivo que un escaneo posterior en el registry porque previene que el workload llegue a ejecutarse, en vez de detectarlo después del hecho.

**Ejercicio 2**

1. El tag es una referencia mutable: alguien puede hacer `docker push` de contenido distinto reusando el mismo tag. El digest (`sha256:...`) es un hash del contenido, así que firmar el digest garantiza que la firma corresponde exactamente a ese conjunto de bytes, sin importar qué tag apunte a él en el futuro.
2. Cosign no genera un archivo de firma separado por defecto: la sube como un **artefacto OCI adicional** al mismo registry, con un tag derivado del digest (esquema `sha256-<digest>.sig`). Así la firma viaja junto con la imagen sin necesitar un canal de distribución aparte.

**Ejercicio 3**

1. Un error indicando que la verificación de la firma falló (la firma no corresponde a la clave pública provista). Esto confirma que cosign realmente valida criptográficamente contra la clave pública dada, y no acepta cualquier firma presente en el registry.
2. No. Sin la clave privada original no puede generar una firma válida para esa clave pública; a lo sumo podría reemplazar la imagen sin firma nueva, pero entonces `cosign verify` fallaría directamente por ausencia de firma válida.

**Ejercicio 4**

1. El Pod del paso 3 es rechazado por el admission controller porque la imagen no tiene ninguna firma verificable con la clave pública configurada. La diferencia con el Ejercicio 1 es que ahí solo se valida el **origen** (registry/path), mientras que acá se valida la **integridad y procedencia criptográfica** del artefacto: una imagen puede venir del registry correcto y aun así ser rechazada si no está firmada o fue alterada.
2. El campo `image` del Pod firmado queda resuelto automáticamente a su forma `image@sha256:<digest>` en vez del tag original. Kyverno hace esto porque, una vez verificada la firma sobre un digest específico, fija esa referencia inmutable en el Pod para eliminar la ventana de tiempo entre verificación y ejecución (evitar TOCTOU: que el tag cambie de contenido entre que se verificó y que el kubelet hace el pull).

**Ejercicio 5**

1. Mitiga el riesgo de que el mismo tag sea reapuntado a contenido distinto después de que la imagen fue auditada/firmada/aprobada (mutación de tag). Firmar sin fijar el digest en el Deployment deja abierta la posibilidad de que, aunque exista una imagen firmada válida, el kubelet termine bajando una versión distinta del tag en un pull posterior si no hay verificación en cada arranque.
2. No: como el Deployment referencia `image@sha256:<digest-fijo>`, el kubelet siempre va a resolver y descargar exactamente ese contenido, sin importar a qué apunte el tag `1.25` en el registry en el futuro.

</details>