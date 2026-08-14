# Ejercicios — 5.6 Reglas VerifyImage

> **Alcance.** Estos ejercicios construyen una compuerta completa de cadena de suministro con Sigstore/Notary sobre un clúster descartable y después la rompen a propósito. Cada paso está pensado para ser tipeado. Donde la salida exacta depende de tu versión de Kyverno, el paso te indica *observar* en lugar de asumir — el punto del tema es que puedas leer lo que el controlador de admisión realmente te dice.
>
> **Tiempo:** ~120 min. **Peso en el examen:** 2.91.

---

## Requisitos previos del laboratorio

| Herramienta | Mínimo | Verificación |
|---|---|---|
| `kind` (o cualquier clúster que puedas romper) | 0.23 | `kind version` |
| `kubectl` | 1.28 | `kubectl version --client` |
| `helm` | 3.12 | `helm version --short` |
| Kyverno | 1.11+ (se asume 1.13) | `kubectl -n kyverno get deploy` |
| `cosign` | 2.2+ | `cosign version` |
| `crane` | 0.19+ | `crane version` |
| `jq`, `yq` (v4) | — | `jq --version; yq --version` |

El laboratorio usa **`ttl.sh`** — un registry público anónimo, efímero y sin autenticación (las imágenes expiran según el TTL del tag). Se eligió porque *tanto* el kubelet *como* el pod del controlador de admisión de Kyverno deben poder alcanzar el registry, algo que un registry de kind en `localhost:5001` no puede satisfacer. El Ejercicio 9 cubre el caso del registry privado explícitamente.

La salida hacia `ttl.sh`, `fulcio.sigstore.dev` y `rekor.sigstore.dev` es necesaria solo para el ejercicio keyless.

---

## Ejercicio 1 — Construir el laboratorio y ubicar las piezas móviles

**Objetivo:** instalar Kyverno, publicar una imagen sin firmar e identificar *qué* componente realiza el viaje de ida y vuelta al registry durante la admisión.

1. Crear el clúster.

   ```bash
   kind create cluster --name kca-5-6 --image kindest/node:v1.31.0
   kubectl config use-context kind-kca-5-6
   ```

2. Instalar Kyverno con los cuatro controladores.

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno \
     --namespace kyverno --create-namespace \
     --set admissionController.replicas=1 \
     --set backgroundController.replicas=1 \
     --set reportsController.replicas=1 \
     --set cleanupController.replicas=1
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s
   ```

3. Listar las configuraciones de webhook que Kyverno registró, **antes** de que exista ninguna política.

   ```bash
   kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations \
     -o custom-columns=NAME:.metadata.name | grep -i kyverno
   ```

   Salida representativa:

   ```
   mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-policy-mutating-webhook-cfg
   mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-resource-mutating-webhook-cfg
   mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-verify-mutating-webhook-cfg
   validatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-policy-validating-webhook-cfg
   validatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-resource-validating-webhook-cfg
   ...
   ```

   Observá que `kyverno-resource-mutating-webhook-cfg` tiene por ahora una lista `rules` vacía o sin comodines — Kyverno completa las reglas de webhook dinámicamente a partir de las políticas instaladas.

4. Instalar `cosign` y `crane`.

   ```bash
   curl -sSfL -o cosign https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   sudo install -m 0755 cosign /usr/local/bin/cosign && rm cosign
   curl -sSL https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz \
     | sudo tar -xz -C /usr/local/bin crane
   cosign version && crane version
   ```

5. Publicar dos imágenes idénticas bajo dos repositorios distintos — una que vas a firmar y otra que no.

   ```bash
   export RAND=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')
   export SIGNED="ttl.sh/kca-signed-${RAND}:24h"
   export UNSIGNED="ttl.sh/kca-unsigned-${RAND}:24h"

   crane copy busybox:1.36 "$SIGNED"
   crane copy busybox:1.36 "$UNSIGNED"

   crane digest "$SIGNED"
   crane digest "$UNSIGNED"
   echo "SIGNED=$SIGNED  UNSIGNED=$UNSIGNED"
   ```

   Ambos digests son idénticos — los mismos bytes, distintos repositorios.

6. Confirmar que el clúster efectivamente puede ejecutar una de ellas (todavía no hay ninguna política instalada).

   ```bash
   kubectl run smoke --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod smoke -o jsonpath='{.status.phase}{"\n"}'
   kubectl delete pod smoke
   ```

**Preguntas de control**

- **Q1.1** Durante la verificación de imágenes, ¿*qué proceso* abre la conexión TCP al registry, y desde qué posición de red dentro del clúster? ¿Por qué "el kubelet puede bajar la imagen" no es evidencia de que la verificación vaya a tener éxito?
- **Q1.2** Ambas imágenes tienen el mismo digest. Si firmás `$SIGNED`, ¿un `cosign verify` de `$UNSIGNED` va a tener éxito, dado que la firma cubre el digest y los digests son iguales? Explicalo en términos de *dónde* se almacena el artefacto de firma.
- **Q1.3** El controlador de admisión de Kyverno es un webhook. Nombrá los dos campos de una `ClusterPolicy` que deciden qué le pasa a la creación de un `Pod` cuando el registry es inalcanzable y la verificación se cuelga.

---

## Ejercicio 2 — Firmar la imagen e inspeccionar lo que Sigstore realmente subió

**Objetivo:** dejar de tratar a la firma como magia. Ver el artefacto OCI.

1. Generar un par de claves. La contraseña vacía es un atajo solo para el laboratorio.

   ```bash
   export COSIGN_PASSWORD=""
   cosign generate-key-pair
   ls -l cosign.key cosign.pub
   cat cosign.pub
   ```

   ```
   -----BEGIN PUBLIC KEY-----
   MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
   -----END PUBLIC KEY-----
   ```

2. Firmar la imagen **sin** subir al log de transparencia público.

   ```bash
   cosign sign --key cosign.key --tlog-upload=false --yes "$SIGNED"
   ```

   ```
   Pushing signature to: ttl.sh/kca-signed-9f3a2b1c
   ```

3. Listar los tags del repositorio y ubicar el artefacto de firma.

   ```bash
   crane ls "ttl.sh/kca-signed-${RAND}"
   cosign triangulate "$SIGNED"
   ```

   ```
   24h
   sha256-9ae97d36d5b9e7d9a29a7f3d1e0b6f4c5a2d8e7b6c4a3f2e1d0c9b8a7f6e5d4c.sig
   ```

4. Mirar dentro del manifest de la firma.

   ```bash
   crane manifest "$(cosign triangulate "$SIGNED")" | jq '.layers[0]'
   ```

   ```json
   {
     "mediaType": "application/vnd.dev.cosign.simplesigning.v1+json",
     "size": 251,
     "digest": "sha256:3b1e...",
     "annotations": {
       "dev.cosignproject.cosign/signature": "MEUCIQD8k...=="
     }
   }
   ```

5. Verificar localmente, solo con cosign — todavía sin Kyverno involucrado.

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog "$SIGNED" | jq '.[0].critical'
   ```

   ```json
   {
     "identity": { "docker-reference": "ttl.sh/kca-signed-9f3a2b1c" },
     "image": { "docker-manifest-digest": "sha256:9ae97d36..." },
     "type": "cosign container image signature"
   }
   ```

6. Ahora hacé lo mismo contra la imagen sin firmar y leé el error textualmente.

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog "$UNSIGNED"
   ```

   ```
   Error: no matching signatures:
   ...
   main.go:74: error during command execution: no matching signatures
   ```

**Preguntas de control**

- **Q2.1** La firma se almacena como un tag llamado `sha256-<digest>.sig` en el *mismo repositorio*. ¿Qué consecuencia operativa tiene eso para `crane copy` / el mirroring de registries / los pipelines de promoción en entornos air-gapped? ¿Qué opciones de cosign y de Kyverno existen para desacoplar ambas cosas?
- **Q2.2** El campo `critical.image.docker-manifest-digest` fija el digest, mientras que `critical.identity.docker-reference` registra el repositorio. ¿Qué ataque previene el segundo campo que el primero no?
- **Q2.3** Pasaste `--tlog-upload=false`. ¿A qué renunciaste, y qué tenés que cambiar ahora en la política de Kyverno para que la verificación tenga éxito?
- **Q2.4** ¿Por qué el paso 6 falló con `no matching signatures` en lugar de `no signatures found`? ¿Qué te dice la diferencia entre esos dos errores de cosign cuando estás depurando un pipeline real?

---

## Ejercicio 3 — Tu primera regla `verifyImages`, en modo Audit

**Objetivo:** escribir la regla, observar que Audit no bloquea, y leer el `PolicyReport`.

1. Renderizar la política. La clave pública se inyecta con un `sed` que indenta cada línea del PEM en **14 espacios** — debe quedar más profundo que la clave `publicKeys:` en la columna 12.

   ```bash
   cat > 01-verify-audit.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-lab-images
   spec:
     validationFailureAction: Audit
     background: false
     failurePolicy: Fail
     webhookTimeoutSeconds: 30
     rules:
     - name: check-cosign-signature
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         mutateDigest: true
         verifyDigest: true
         required: true
         attestors:
         - count: 1
           entries:
           - keys:
               publicKeys: |-
   $(sed 's/^/              /' cosign.pub)
               rekor:
                 ignoreTlog: true
   EOF
   ```

   > **Consejo — no cuentes espacios en producción.** Escribí la política con un placeholder e inyectá la clave de forma estructural:
   > ```bash
   > yq -i '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str("cosign.pub")' 01-verify-audit.yaml
   > ```

2. Revisar la sanidad del YAML antes de que llegue al API server.

   ```bash
   yq '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys' 01-verify-audit.yaml
   ```

   Tenés que ver el PEM completo, desde `-----BEGIN` hasta `-----END`, sin espacios iniciales dentro del bloque.

3. Aplicar y esperar a que la política quede lista.

   ```bash
   kubectl apply -f 01-verify-audit.yaml
   kubectl get cpol verify-lab-images
   ```

   ```
   NAME                ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
   verify-lab-images   true        false        Audit             True    5s    Ready
   ```

4. Observar que Kyverno ya registró reglas de webhook para `pods`.

   ```bash
   kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules[*].resources}{"\n"}{end}'
   ```

5. Crear ambos pods.

   ```bash
   kubectl run signed   --image="$SIGNED"   --restart=Never --command -- sleep 3600
   kubectl run unsigned --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   kubectl get pods
   ```

6. Comparar la referencia de imagen *tal como queda almacenada en el API server* para cada pod.

   ```bash
   kubectl get pod signed   -o jsonpath='{.spec.containers[0].image}{"\n"}'
   kubectl get pod unsigned -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

7. Inspeccionar las anotaciones que Kyverno estampó en cada pod.

   ```bash
   kubectl get pod signed   -o jsonpath='{.metadata.annotations}' | jq .
   kubectl get pod unsigned -o jsonpath='{.metadata.annotations}' | jq .
   ```

8. Leer el policy report (dale unos segundos al controlador de reports).

   ```bash
   sleep 10
   kubectl get polr -n default
   kubectl get polr -n default -o yaml | yq '.items[].results[] | {rule, result, message}'
   ```

   ```yaml
   rule: check-cosign-signature
   result: fail
   message: 'failed to verify image ttl.sh/kca-unsigned-9f3a2b1c:24h: .attestors[0].entries[0].keys: no signatures found'
   ```

**Preguntas de control**

- **Q3.1** El pod `unsigned` está en `Running`. ¿Qué campo permitió eso, y dónde sobrevive la falla en su lugar?
- **Q3.2** Compará las dos cadenas de imagen del paso 6. ¿Qué cambió Kyverno en el pod `signed`, y qué campo es el responsable?
- **Q3.3** ¿Qué anotación aparece en el pod verificado, qué codifica su valor, y por qué Kyverno persiste el resultado en el objeto en lugar de solo registrarlo en el log?
- **Q3.4** El mensaje del report contiene la ruta JSON `.attestors[0].entries[0].keys`. Reconstruí qué te está diciendo esa ruta y cómo la usarías en una política con cuatro entradas de attestor.
- **Q3.5** `spec.background` está en `false`. Probá ponerlo en `true` y volver a aplicar. Sea cual sea la respuesta del API server, explicá *por qué* la verificación de imágenes encaja mal con el escaneo en background.

---

## Ejercicio 4 — Enforce, y leer la denegación correctamente

**Objetivo:** identificar qué webhook rechaza una falla de `verifyImages`, y por qué no es el de validación.

1. Pasar la política a `Enforce`.

   ```bash
   kubectl patch cpol verify-lab-images --type merge \
     -p '{"spec":{"validationFailureAction":"Enforce"}}'
   kubectl delete pod signed unsigned --ignore-not-found
   ```

2. Recrear el pod sin firmar y capturar el error completo.

   ```bash
   kubectl run unsigned --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   ```

   Salida representativa:

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

   resource Pod/default/unsigned was blocked due to the following policies

   verify-lab-images:
     check-cosign-signature: 'failed to verify image ttl.sh/kca-unsigned-9f3a2b1c:24h:
       .attestors[0].entries[0].keys: no signatures found'
   ```

3. Confirmar que el pod firmado sigue siendo admitido.

   ```bash
   kubectl run signed --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

4. Usar un dry run del lado del servidor — la forma estándar de probar una política sin dejar objetos atrás.

   ```bash
   kubectl run probe --image="$UNSIGNED" --restart=Never --dry-run=server -o yaml
   ```

5. Ahora probá con un controlador, no con un pod suelto.

   ```bash
   kubectl create deployment bad-deploy --image="$UNSIGNED"
   kubectl get deploy bad-deploy 2>/dev/null || echo "deployment was rejected"
   ```

6. Mirar lo que Kyverno generó en tu nombre.

   ```bash
   kubectl get cpol verify-lab-images -o yaml | yq '.status'
   kubectl get cpol verify-lab-images -o yaml | yq '.metadata.annotations'
   ```

7. Observar los eventos que Kyverno emitió.

   ```bash
   kubectl get events -n default --sort-by=.lastTimestamp | tail -n 10
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
     | grep -iE 'imageverify|cosign|verifyimages'
   ```

**Preguntas de control**

- **Q4.1** La denegación vino de `mutate.kyverno.svc-fail`, no de un webhook de validación. Explicá por qué una regla `verifyImages` se evalúa en la fase de admisión mutante, y qué implica eso respecto del orden en relación con otras mutaciones que reescriben el campo `image`.
- **Q4.2** En el nombre del webhook, ¿qué significa el sufijo `-fail`, y qué campo de la política lo produjo? ¿Cuál sería el sufijo si configuraras el otro valor?
- **Q4.3** En el paso 5, ¿el `Deployment` fue rechazado de plano, o fue aceptado y luego falló a nivel de ReplicaSet? ¿Qué funcionalidad de Kyverno decide esto, y qué anotación la controla?
- **Q4.4** Un colega argumenta que `Enforce` en una regla `verifyImages` es peligroso porque "si el registry está lento, no se puede desplegar nada". Dá las tres palancas de configuración que moldean ese riesgo y el compromiso que hace cada una.

---

## Ejercicio 5 — `mutateDigest`, `verifyDigest`, `required`

**Objetivo:** estos tres booleanos son la parte más evaluada del tema. Cambiá uno por vez y observá.

1. Desactivar la mutación del digest y volver a probar.

   ```bash
   kubectl patch cpol verify-lab-images --type json -p '[
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":false},
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/verifyDigest","value":false}
   ]'
   kubectl delete pod signed --ignore-not-found
   kubectl run signed --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

2. Ahora exigí un digest pero negate a agregar uno.

   ```bash
   kubectl patch cpol verify-lab-images --type json -p '[
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/verifyDigest","value":true}
   ]'
   kubectl delete pod signed --ignore-not-found
   kubectl run signed --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   Salida representativa:

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

   resource Pod/default/signed was blocked due to the following policies

   verify-lab-images:
     check-cosign-signature: 'image ttl.sh/kca-signed-9f3a2b1c:24h does not have a digest'
   ```

3. Satisfacela fijando el digest vos mismo.

   ```bash
   export DIG=$(crane digest "$SIGNED")
   kubectl run signed-pinned --image="ttl.sh/kca-signed-${RAND}@${DIG}" \
     --restart=Never --command -- sleep 3600
   kubectl get pod signed-pinned -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

4. Restaurar los valores por defecto seguros.

   ```bash
   kubectl patch cpol verify-lab-images --type json -p '[
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":true},
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/verifyDigest","value":true}
   ]'
   ```

5. Probar el alcance de la regla. `nginx` *no* es alcanzado por `ttl.sh/kca-*`.

   ```bash
   kubectl run offscope --image=nginx:1.27 --restart=Never
   kubectl get pod offscope -o jsonpath='{.spec.containers[0].image}{"\n"}'
   kubectl get pod offscope -o jsonpath='{.metadata.annotations}' | jq .
   ```

6. Inspeccionar cómo Kyverno normaliza las referencias de imagen cortas antes de hacer el match.

   ```bash
   kubectl -n kyverno get cm kyverno -o yaml | yq '.data | {defaultRegistry, enableDefaultRegistryMutation}'
   ```

7. Cerrar el agujero con una entrada catch-all más exclusiones explícitas.

   ```bash
   cat > 02-catch-all.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: deny-unverified-images
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: everything-must-be-verified
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "*"
         skipImageReferences:
         - "ttl.sh/kca-*"
         - "registry.k8s.io/*"
         - "ghcr.io/kyverno/*"
         required: true
         mutateDigest: true
         attestors:
         - count: 1
           entries:
           - keyless:
               subject: "https://github.com/my-org/*"
               issuer: "https://token.actions.githubusercontent.com"
               rekor:
                 url: https://rekor.sigstore.dev
   EOF
   kubectl apply -f 02-catch-all.yaml
   kubectl delete pod offscope --ignore-not-found
   kubectl run offscope --image=nginx:1.27 --restart=Never
   kubectl get polr -n default -o yaml | yq '.items[].results[] | select(.policy=="deny-unverified-images")'
   ```

8. Limpiar el catch-all antes de continuar.

   ```bash
   kubectl delete -f 02-catch-all.yaml
   kubectl delete pod --all --ignore-not-found
   ```

**Preguntas de control**

- **Q5.1** Escribí, en una oración cada uno, qué hacen `mutateDigest`, `verifyDigest` y `required`, y dá el valor por defecto de cada campo.
- **Q5.2** ¿Por qué `mutateDigest: true` es un control de *seguridad* y no una mera comodidad? Nombrá la carrera concreta que cierra entre la admisión y el pull del `kubelet`.
- **Q5.3** En el paso 2, la verificación de la firma ya había **tenido éxito**, y sin embargo el pod fue denegado. ¿Cuál de los tres booleanos lo denegó, y por qué esa combinación (`verifyDigest: true`, `mutateDigest: false`) es una elección legítima de producción para algunos equipos?
- **Q5.4** En el paso 5, el pod `nginx` fue admitido aun con `required: true`. Explicá con precisión el alcance de `required`. ¿Cuál es la *única* forma correcta de hacer verdadero que "cualquier imagen no cubierta por una regla de verificación es denegada"?
- **Q5.5** `required` es el campo que sobrevive a la fase mutante. Describí el camino de admisión donde la verificación nunca corre pero `required` igual bloquea el pedido.
- **Q5.6** `skipImageReferences` en el paso 7 excluye `registry.k8s.io/*`. Argumentá ambos lados: por qué excluir imágenes del plano de control es práctica estándar, y qué te cuesta.

---

## Ejercicio 6 — Conjuntos de attestors: `count`, AND vs OR, y rotación de claves

**Objetivo:** modelar "dos equipos independientes deben firmar" y después rotar una clave sin tiempo de indisponibilidad.

1. Generar un segundo par de claves, que representa al equipo de seguridad.

   ```bash
   mkdir -p sec && (cd sec && COSIGN_PASSWORD="" cosign generate-key-pair)
   ls sec/cosign.key sec/cosign.pub
   ```

2. Construir una política con **un** conjunto de attestors que contenga **dos** entradas y `count: 1`.

   ```bash
   cat > 03-attestors-or.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-two-keys
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
     - name: any-of-two-keys
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         attestors:
         - count: 1
           entries:
           - keys:
               publicKeys: |-
   $(sed 's/^/              /' cosign.pub)
               rekor:
                 ignoreTlog: true
           - keys:
               publicKeys: |-
   $(sed 's/^/              /' sec/cosign.pub)
               rekor:
                 ignoreTlog: true
   EOF
   kubectl delete cpol verify-lab-images --ignore-not-found
   kubectl apply -f 03-attestors-or.yaml
   kubectl run or-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   La imagen lleva solo la firma de la *primera* clave y es admitida.

3. Cambiar `count` a `2` y reintentar.

   ```bash
   kubectl patch cpol verify-two-keys --type json \
     -p '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/attestors/0/count","value":2}]'
   kubectl delete pod or-test --ignore-not-found
   kubectl run and-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   ...
     any-of-two-keys: 'failed to verify image ttl.sh/kca-signed-9f3a2b1c:24h:
       .attestors[0].entries[1].keys: no matching signatures'
   ```

4. Agregar la segunda firma y reintentar.

   ```bash
   COSIGN_PASSWORD="" cosign sign --key sec/cosign.key --tlog-upload=false --yes "$SIGNED"
   crane ls "ttl.sh/kca-signed-${RAND}"
   kubectl run and-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod and-test -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

   Observá que `crane ls` sigue mostrando un **único** tag `.sig`.

5. Ahora expresá el mismo requisito como **dos conjuntos de attestors** y confirmá que se comporta idénticamente.

   ```bash
   kubectl get cpol verify-two-keys -o yaml \
     | yq '.spec.rules[0].verifyImages[0].attestors' > /tmp/attestors.yaml
   # Split the single set of two entries into two sets of one entry each:
   yq -i '.spec.rules[0].verifyImages[0].attestors =
     [ {"entries":[ .spec.rules[0].verifyImages[0].attestors[0].entries[0] ]},
       {"entries":[ .spec.rules[0].verifyImages[0].attestors[0].entries[1] ]} ]' 03-attestors-or.yaml
   yq '.spec.rules[0].verifyImages[0].attestors | length' 03-attestors-or.yaml
   kubectl apply -f 03-attestors-or.yaml
   kubectl delete pod and-test --ignore-not-found
   kubectl run and-test-2 --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

6. Sacar una clave del cuerpo de la política y llevarla a un `Secret` — el patrón que querés en Git.

   ```bash
   COSIGN_PASSWORD="" cosign generate-key-pair k8s://kyverno/cosign-rotation
   kubectl -n kyverno get secret cosign-rotation -o jsonpath='{.data}' | jq 'keys'
   ```

   ```json
   ["cosign.key","cosign.password","cosign.pub"]
   ```

   ```bash
   cat > 04-secret-key.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-secret-key
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: key-from-secret
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         attestors:
         - count: 1
           entries:
           - keys:
               secret:
                 name: cosign-rotation
                 namespace: kyverno
               rekor:
                 ignoreTlog: true
   EOF
   kubectl apply -f 04-secret-key.yaml
   kubectl get cpol verify-secret-key
   ```

7. Limpiar.

   ```bash
   kubectl delete cpol verify-two-keys verify-secret-key --ignore-not-found
   kubectl delete pod --all --ignore-not-found
   ```

**Preguntas de control**

- **Q6.1** Enunciá con precisión el álgebra booleana de `attestors`: qué significa una lista de *conjuntos* de attestors, qué significa una lista de *entradas* dentro de un conjunto, y qué cambia `count`. ¿Cuál es el valor por defecto cuando se omite `count`?
- **Q6.2** En el paso 4, `crane ls` sigue mostrando un solo tag `.sig` después de dos firmas. ¿A dónde fue la segunda firma, y cómo hace el `count: 2` de Kyverno para ver dos firmas distintas en un solo artefacto?
- **Q6.3** Los pasos 3 y 5 imponen el mismo requisito de dos formas distintas. Dá una razón concreta para preferir dos conjuntos de attestors por sobre `count: 2` en una política real.
- **Q6.4** Diseñá una **rotación de claves sin tiempo de indisponibilidad**: tenés que retirar la clave A y adoptar la clave B en miles de imágenes sin ninguna ventana en la que los deployments en ejecución queden bloqueados. Escribí la secuencia de ediciones de política y pasos de re-firma en orden.
- **Q6.5** `keys.secret` lee un `Secret` en el namespace `kyverno`. ¿Cuáles son las dos propiedades de seguridad de esa elección de namespace, y qué error de RBAC derrotaría silenciosamente toda la política?
- **Q6.6** Además de `keys`, nombrá los otros tipos de entrada de attestor y un escenario donde cada uno es la elección correcta.

---

## Ejercicio 7 — Verificación keyless y anclaje de identidad

**Objetivo:** verificar por *quién firmó* en lugar de por *qué clave*, y ver cómo un patrón de identidad descuidado anula el control.

> Los pasos 1–3 requieren un flujo OIDC interactivo por navegador y salida hacia Fulcio y Rekor. Si no podés ejecutarlos, hacé del paso 4 en adelante — el análisis es lo que evalúa el examen.

1. Firmar en modo keyless. Se abre una ventana del navegador para OIDC.

   ```bash
   cosign sign --yes "$SIGNED"
   ```

2. Inspeccionar el certificado efímero de Fulcio que se emitió para vos.

   ```bash
   cosign verify --certificate-identity "you@example.com" \
     --certificate-oidc-issuer "https://accounts.google.com" "$SIGNED" | jq '.[0].optional.Subject'
   ```

3. Ubicar la entrada del log de transparencia de Rekor.

   ```bash
   cosign verify --certificate-identity "you@example.com" \
     --certificate-oidc-issuer "https://accounts.google.com" "$SIGNED" \
     | jq '.[0].optional.Bundle.Payload | {logIndex, integratedTime}'
   ```

4. Escribir una política keyless para una **identidad de CI**, que es lo que vas a hacer realmente en producción.

   ```bash
   cat > 05-keyless.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-keyless-ci
   spec:
     validationFailureAction: Audit
     background: false
     webhookTimeoutSeconds: 30
     rules:
     - name: github-actions-identity
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ghcr.io/my-org/*"
         mutateDigest: true
         required: true
         attestors:
         - count: 1
           entries:
           - keyless:
               issuer: "https://token.actions.githubusercontent.com"
               subjectRegExp: "^https://github\\.com/my-org/[^/]+/\\.github/workflows/release\\.yaml@refs/heads/main$"
               rekor:
                 url: https://rekor.sigstore.dev
               ctlog:
                 ignoreSCT: false
   EOF
   kubectl apply -f 05-keyless.yaml
   kubectl get cpol verify-keyless-ci
   ```

5. Ahora escribí — **antes** de leer las respuestas — qué permitiría cada una de estas cuatro variantes. No las apliques; esto es un ejercicio de escritorio.

   ```yaml
   # (a)
   keyless: { issuer: "https://token.actions.githubusercontent.com", subject: "*" }

   # (b)
   keyless: { issuer: "https://accounts.google.com", subject: "release-bot@my-org.com" }

   # (c)
   keyless: { issuer: "https://token.actions.githubusercontent.com",
              subjectRegExp: "https://github.com/my-org/.*" }

   # (d)
   keyless: { issuer: "https://token.actions.githubusercontent.com",
              subjectRegExp: "^https://github\\.com/my-org/[^/]+/\\.github/workflows/release\\.yaml@refs/tags/v.*$" }
   ```

6. Esbozar la variante de Sigstore privado (BYO Fulcio/Rekor), que es el despliegue empresarial habitual.

   ```yaml
   attestors:
   - entries:
     - keyless:
         issuer: "https://oidc.corp.example.com"
         subject: "spiffe://corp.example.com/ns/ci/sa/builder"
         roots: |-
           -----BEGIN CERTIFICATE-----
           <corporate Fulcio root CA>
           -----END CERTIFICATE-----
         rekor:
           url: https://rekor.corp.example.com
           pubkey: |-
             -----BEGIN PUBLIC KEY-----
             <corporate Rekor log public key>
             -----END PUBLIC KEY-----
         ctlog:
           pubkey: |-
             -----BEGIN PUBLIC KEY-----
             <corporate CT log public key>
             -----END PUBLIC KEY-----
   ```

7. Limpiar.

   ```bash
   kubectl delete cpol verify-keyless-ci --ignore-not-found
   ```

**Preguntas de control**

- **Q7.1** En modo keyless no hay ninguna clave de larga vida. ¿Qué la reemplaza como raíz de confianza, y cuál es el tiempo de vida del certificado de firma? ¿Por qué un log de transparencia es *obligatorio* y no opcional en ese diseño?
- **Q7.2** Ordená las variantes (a)–(d) de la más débil a la más fuerte y enunciá el ataque concreto que permite cada una de las más débiles.
- **Q7.3** La variante (c) usa `subjectRegExp` sin anclas. Construí una cadena de subject que un atacante podría obtener y que haga match con (c) pero no con (d).
- **Q7.4** ¿Qué desactiva cada uno de `rekor.ignoreTlog: true` y `ctlog.ignoreSCT: true`, y en cuál de los dos modos — basado en claves o keyless — es relevante cada uno?
- **Q7.5** Tu organización opera un Fulcio privado. ¿Qué tres campos del paso 6 hay que completar, y qué se rompe si completás `roots` pero omitís `ctlog.pubkey`?
- **Q7.6** La verificación keyless hace una llamada saliente a Rekor en cada admisión única. ¿Cuáles son las consecuencias de disponibilidad y latencia, y qué dos configuraciones de Kyverno las mitigan?

---

## Ejercicio 8 — Attestations: verificar *afirmaciones*, no solo autoría

**Objetivo:** adjuntar procedencia SLSA a la imagen y condicionar su contenido con condiciones JMESPath.

1. Escribir un predicado mínimo de procedencia SLSA v0.2.

   ```bash
   cat > provenance.json <<'EOF'
   {
     "builder": { "id": "https://ci.example.com/kca-lab@v1" },
     "buildType": "https://ci.example.com/build@v1",
     "invocation": {
       "configSource": {
         "uri": "git+https://github.com/example/app@refs/heads/main",
         "digest": { "sha1": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" },
         "entryPoint": "release.yaml"
       }
     },
     "metadata": {
       "buildInvocationID": "4711",
       "reproducible": false,
       "completeness": { "parameters": true, "environment": false, "materials": false }
     },
     "materials": [
       { "uri": "git+https://github.com/example/app",
         "digest": { "sha1": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" } }
     ]
   }
   EOF
   ```

2. Adjuntarlo como una attestation in-toto firmada.

   ```bash
   COSIGN_PASSWORD="" cosign attest --key cosign.key --type slsaprovenance \
     --predicate provenance.json --tlog-upload=false --yes "$SIGNED"
   crane ls "ttl.sh/kca-signed-${RAND}"
   ```

   ```
   24h
   sha256-9ae97d36...d4c.sig
   sha256-9ae97d36...d4c.att
   ```

3. Leer la attestation de vuelta y decodificar la sentencia in-toto.

   ```bash
   cosign verify-attestation --key cosign.pub --type slsaprovenance \
     --insecure-ignore-tlog "$SIGNED" \
     | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject}'
   ```

   ```json
   {
     "_type": "https://in-toto.io/Statement/v0.1",
     "predicateType": "https://slsa.dev/provenance/v0.2",
     "subject": [{ "name": "ttl.sh/kca-signed-9f3a2b1c",
                   "digest": { "sha256": "9ae97d36..." } }]
   }
   ```

4. Escribir una política que verifique la attestation **y** afirme hechos sobre el predicado.

   ```bash
   cat > 06-attestations.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-slsa-provenance
   spec:
     validationFailureAction: Enforce
     background: false
     webhookTimeoutSeconds: 30
     rules:
     - name: check-provenance
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         mutateDigest: true
         attestations:
         - type: https://slsa.dev/provenance/v0.2
           attestors:
           - count: 1
             entries:
             - keys:
                 publicKeys: |-
   $(sed 's/^/                  /' cosign.pub)
                 rekor:
                   ignoreTlog: true
           conditions:
           - all:
             - key: "{{ builder.id }}"
               operator: Equals
               value: "https://ci.example.com/kca-lab@v1"
             - key: "{{ regex_match('^git\\\\+https://github\\\\.com/example/app@refs/heads/main\$', invocation.configSource.uri) }}"
               operator: Equals
               value: true
   EOF
   yq '.spec.rules[0].verifyImages[0].attestations[0].conditions' 06-attestations.yaml
   kubectl apply -f 06-attestations.yaml
   ```

   > Nota sobre indentación: `attestations[].attestors` está dos niveles más profundo que en el Ejercicio 3, así que acá el cuerpo del PEM se indenta **18 espacios**.

5. Probar el caso que pasa, y después romper la condición a propósito.

   ```bash
   kubectl delete pod --all --ignore-not-found
   kubectl run prov-ok --image="$SIGNED" --restart=Never --command -- sleep 3600

   kubectl patch cpol verify-slsa-provenance --type json -p '[
     {"op":"replace",
      "path":"/spec/rules/0/verifyImages/0/attestations/0/conditions/0/all/0/value",
      "value":"https://ci.example.com/some-other-builder@v1"}
   ]'
   kubectl delete pod prov-ok --ignore-not-found
   kubectl run prov-bad --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   ...
     check-provenance: 'failed to verify image ttl.sh/kca-signed-9f3a2b1c:24h:
       attestation checks failed for https://slsa.dev/provenance/v0.2 and predicate ...'
   ```

6. Probar el caso "firmada pero sin attestation" con la imagen *sin firmar*.

   ```bash
   kubectl run prov-missing --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   ```

7. Limpiar.

   ```bash
   kubectl delete cpol verify-slsa-provenance --ignore-not-found
   kubectl delete pod --all --ignore-not-found
   ```

**Preguntas de control**

- **Q8.1** Distinguí una *firma* de una *attestation* en tres niveles: qué se firma, dónde se almacena en el registry, y qué pregunta de seguridad responde cada una.
- **Q8.2** En el bloque `conditions` escribiste `{{ builder.id }}`, no `{{ predicate.builder.id }}`. ¿Cuál es la raíz de evaluación JMESPath para `attestations[].conditions`, y cuál sería la expresión si la raíz fuera la sentencia in-toto completa?
- **Q8.3** La entrada `attestations[]` lleva sus propios `attestors`. ¿Qué significa que una entrada `verifyImages` tenga **a la vez** un `attestors` de nivel superior y una lista `attestations[].attestors`?
- **Q8.4** Las attestations son la forma de condicionar cosas que una firma no puede expresar. Dá tres compuertas de producción que podrías imponer así, y nombrá el tipo de predicado de cada una.
- **Q8.5** Una imagen lleva el tipo de predicado SLSA correcto pero la attestation está firmada con una clave no confiable. ¿Cuál de los dos mensajes de falla esperás — "no matching signatures" o "attestation checks failed" — y por qué importa el orden para depurar?
- **Q8.6** `--tlog-upload=false` en `cosign attest` también salteó el log. En un pipeline SLSA L3 real, ¿por qué saltear el log de transparencia para la procedencia es peor que saltearlo para una firma común?

---

## Ejercicio 9 — Notary Project (`type: Notary`) y registries privados

**Objetivo:** el segundo formato de firma soportado, y el camino de credenciales que se rompe en todo clúster real.

1. Instalar `notation` y crear un certificado de prueba.

   ```bash
   curl -sSL https://github.com/notaryproject/notation/releases/latest/download/notation_Linux_amd64.tar.gz \
     | sudo tar -xz -C /usr/local/bin notation
   notation version
   notation cert generate-test --default "kca-lab.io"
   notation cert ls
   ```

2. Firmar la imagen con notation e inspeccionar lo que aterrizó en el registry.

   ```bash
   notation sign "$SIGNED"
   notation ls "$SIGNED"
   crane manifest "$SIGNED" | jq '.mediaType'
   ```

   > Si tu registry no implementa la **API de referrers** de OCI 1.1, `notation sign` recae en un esquema de tag de referrers (`sha256-<digest>`). Registrá cuál observaste.

3. Exportar el certificado para la política.

   ```bash
   CERT=$(ls ~/.config/notation/localkeys/kca-lab.io.crt)
   cat "$CERT" | head -3
   ```

4. Escribir la política de Notary.

   ```bash
   cat > 07-notary.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-notary
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: check-notation-signature
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - type: Notary
         imageReferences:
         - "ttl.sh/kca-*"
         mutateDigest: true
         attestors:
         - count: 1
           entries:
           - certificates:
               cert: |-
   $(sed 's/^/              /' "$CERT")
   EOF
   kubectl apply -f 07-notary.yaml
   kubectl delete pod --all --ignore-not-found
   kubectl run notary-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get polr -n default -o yaml | yq '.items[].results[] | select(.policy=="verify-notary")'
   ```

5. Ahora modelá un **registry privado**. Creá un pull secret en el namespace de Kyverno y conectalo a la regla.

   ```bash
   kubectl -n kyverno create secret docker-registry regcred \
     --docker-server=registry.corp.example.com \
     --docker-username=ci-bot \
     --docker-password='<token>'

   cat > 08-private-registry.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-private-registry
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: check-corp-images
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "registry.corp.example.com/*"
         imageRegistryCredentials:
           allowInsecureRegistry: false
           providers:
           - default
           - amazon
           - google
           secrets:
           - regcred
         useCache: true
         mutateDigest: true
         attestors:
         - count: 1
           entries:
           - keyless:
               issuer: "https://oidc.corp.example.com"
               subject: "spiffe://corp.example.com/ns/ci/sa/builder"
   EOF
   kubectl apply -f 08-private-registry.yaml
   ```

6. Inspeccionar las perillas globales de credenciales y caché en el controlador de admisión.

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'imagepull|imageverifycache|registry'
   ```

   ```
   "--imagePullSecrets=regcred"
   "--imageVerifyCacheEnabled=true"
   "--imageVerifyCacheMaxSize=1000"
   "--imageVerifyCacheTTLDuration=60m"
   ```

7. Limpiar.

   ```bash
   kubectl delete cpol verify-notary verify-private-registry --ignore-not-found
   kubectl delete pod --all --ignore-not-found
   ```

**Preguntas de control**

- **Q9.1** ¿En qué se diferencia una firma de Notary Project de una de cosign en cuanto a *dónde la almacena el registry*? ¿De qué funcionalidad de la API del registry depende Notary, y cuál es la falla práctica que ves en un registry que no la tiene?
- **Q9.2** En una regla `type: Notary`, ¿qué tipo de entrada de attestor usás, y por qué `keys.publicKeys` no es el campo correcto?
- **Q9.3** `imageRegistryCredentials.secrets` nombra un secret — ¿en qué namespace debe existir, y por qué no en el namespace del pod? ¿Cuál es la consecuencia de multi-tenancy de esa respuesta?
- **Q9.4** ¿Qué agrega `providers: [amazon, google]` que un secret estático no da? ¿Qué funcionalidad de identidad del clúster está consumiendo?
- **Q9.5** `allowInsecureRegistry: true` — ¿qué relaja exactamente, y por qué es un control estrictamente peor que agregar la CA del registry al almacén de confianza de Kyverno?
- **Q9.6** La caché de verificación tiene un TTL de 60 minutos. Descubrís que una clave de firma fue comprometida y la sacás de la política a las 14:00. Razoná la ventana exacta de exposición para (a) nuevos pods de una imagen ya verificada a las 13:59, y (b) una imagen nunca vista antes. ¿Qué perilla la acorta y qué cuesta eso?

---

## Ejercicio 10 — Probar políticas en CI y diagnosticar fallas

**Objetivo:** sacar la verificación del clúster y meterla en un pull request, y después construir un diccionario de fallas.

1. Restaurar la política del Ejercicio 3 y crear un manifiesto de recursos para pruebas offline.

   ```bash
   kubectl apply -f 01-verify-audit.yaml
   cat > pods.yaml <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: good
   spec:
     containers:
     - name: app
       image: ${SIGNED}
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad
   spec:
     containers:
     - name: app
       image: ${UNSIGNED}
   EOF
   ```

2. Ejecutar la política con la CLI de Kyverno. `--registry` es lo que habilita las llamadas reales al registry.

   ```bash
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry
   ```

   Salida representativa:

   ```
   Applying 1 policy rule(s) to 2 resource(s)...

   policy verify-lab-images -> resource default/Pod/bad failed:
   1. check-cosign-signature: failed to verify image ttl.sh/kca-unsigned-9f3a2b1c:24h: .attestors[0].entries[0].keys: no signatures found

   pass: 1, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. Convertir eso en un test declarativo sobre el que CI pueda hacer aserciones.

   ```bash
   cat > kyverno-test.yaml <<'EOF'
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: verify-image-signatures
   policies:
   - 01-verify-audit.yaml
   resources:
   - pods.yaml
   results:
   - policy: verify-lab-images
     rule: check-cosign-signature
     kind: Pod
     resources:
     - good
     result: pass
   - policy: verify-lab-images
     rule: check-cosign-signature
     kind: Pod
     resources:
     - bad
     result: fail
   EOF
   kyverno test . --registry
   ```

4. Producí deliberadamente cada falla de abajo y registrá el mensaje exacto que obtenés. Completá la tabla vos mismo antes de mirar las respuestas.

   ```bash
   # (a) wrong key
   (cd /tmp && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix wrong)
   yq -i '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str("/tmp/wrong.pub")' 01-verify-audit.yaml
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry

   # (b) transparency log required but absent
   yq -i 'del(.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.rekor)' 01-verify-audit.yaml
   yq -i '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str("cosign.pub")' 01-verify-audit.yaml
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry

   # (c) pattern that never matches
   yq -i '.spec.rules[0].verifyImages[0].imageReferences = ["kca-*"]' 01-verify-audit.yaml
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry
   ```

   | # | Falla inyectada | Mensaje observado | Causa raíz |
   |---|---|---|---|
   | a | clave pública equivocada | | |
   | b | `rekor.ignoreTlog` eliminado | | |
   | c | `imageReferences: ["kca-*"]` | | |

5. Aprender dónde vive la señal en tiempo de ejecución.

   ```bash
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=300 \
     | grep -iE 'imageVerify|cosign|notation|attestor'
   kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail
   kubectl get clusterpolicyreports,policyreports -A
   kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
   curl -s localhost:8000/metrics | grep -E 'kyverno_policy_results_total|kyverno_admission_review_duration'
   ```

6. Cubrir imágenes que **no** están en un pod spec — un campo de un CRD. Leé esta regla y predecí su comportamiento.

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-tekton-step-images
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
     - name: check-task-steps
       match:
         any:
         - resources:
             kinds:
             - tasks.tekton.dev/v1beta1
       imageExtractors:
         Task:
         - path: /spec/steps/*/image
       verifyImages:
       - imageReferences:
         - "ghcr.io/my-org/*"
         mutateDigest: true
         attestors:
         - entries:
           - keyless:
               issuer: "https://token.actions.githubusercontent.com"
               subjectRegExp: "^https://github\\.com/my-org/.+@refs/heads/main$"
   ```

7. Desmontar todo.

   ```bash
   kubectl delete cpol --all
   kind delete cluster --name kca-5-6
   ```

**Preguntas de control**

- **Q10.1** ¿Por qué `kyverno apply` necesita una bandera `--registry` explícita en lugar de contactar siempre a los registries? Dá la consecuencia en CI de olvidarla.
- **Q10.2** Completá la tabla de fallas del paso 4 y explicá, para cada una, el siguiente comando de diagnóstico más eficiente.
- **Q10.3** La falla (c) es la peligrosa. La CLI no reportó ninguna falla. ¿Cómo se veía el resumen de resultados, y por qué una política que silenciosamente no hace match con nada es peor que una que falla ruidosamente? ¿Qué aserción de test la detecta?
- **Q10.4** En el paso 6, ¿qué le pasaría a esa política *sin* el bloque `imageExtractors`, y qué reescribe `mutateDigest: true` en un `Task`?
- **Q10.5** Estás de guardia. Pods de todo el clúster empiezan de golpe a fallar la admisión con `context deadline exceeded` desde `mutate.kyverno.svc-fail`. Enumerá, en orden, las cuatro verificaciones que hacés y la mitigación inmediata que **no** borra la política.
- **Q10.6** Enumerá las formas en que un operador determinado con acceso al clúster puede saltear una compuerta `verifyImages`, y decí cuál cierra `required: true`.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** El **pod del controlador de admisión de Kyverno** realiza el viaje de ida y vuelta al registry, desde dentro del clúster, usando la red de pods y el entorno de la ServiceAccount de Kyverno (su propio DNS, política de egress, variables de entorno de proxy y credenciales). La capacidad del kubelet de bajar imágenes no tiene relación: el kubelet corre en la red del nodo, puede usar credenciales a nivel de nodo y un proxy distinto, y baja la *imagen*, mientras que Kyverno trae los *artefactos de firma y attestation*. Esta asimetría es la causa más común de "funciona en mi laptop y el nodo puede bajar la imagen, pero la admisión falla": una `NetworkPolicy` sobre el namespace `kyverno`, un proxy de egress que el pod no hereda, o un registry alcanzable solo desde la red del nodo.

**A1.2** Va a fallar. La firma no está embebida en el manifest de la imagen; cosign empuja un **artefacto OCI separado al mismo repositorio**, con el tag `sha256-<digest>.sig`. `$UNSIGNED` vive en un repositorio distinto, así que ese tag no existe ahí — cosign reporta `no signatures found`. Contenido idéntico no implica firmas idénticas, porque la ubicación de almacenamiento de la firma tiene alcance de repositorio, y porque el payload también registra `docker-reference`.

**A1.3** `spec.failurePolicy` (`Fail` bloquea el pedido cuando el webhook falla o expira; `Ignore` lo admite) y `spec.webhookTimeoutSeconds` (cuánto espera el API server; Kubernetes lo topea en 30). Juntos definen el compromiso disponibilidad/seguridad de la compuerta.

### Ejercicio 2

**A2.1** Como la firma es un tag hermano en lugar de parte del manifest, `crane copy image:tag newrepo/image:tag` copia la imagen y **deja la firma atrás en silencio** — la imagen promovida después falla la verificación en el entorno destino. Remedios: copiar el repositorio entero o copiar explícitamente el tag `.sig` (`cosign copy src dst`, que también copia firmas/attestations); o desacoplar el almacenamiento por completo con `COSIGN_REPOSITORY` al momento de firmar y el campo `repository:` correspondiente en el attestor de Kyverno, de modo que las firmas siempre vivan en un repo dedicado sin importar a dónde vaya la imagen.

**A2.2** `docker-manifest-digest` ata la firma a un contenido exacto. `docker-reference` la ata al *nombre* bajo el cual fue firmada, lo que previene un **ataque de confusión/relocalización de repositorios**: un atacante que pueda hacer push a un repo en el que confiás no puede tomar un artefacto legítimamente firmado desde un repo no confiable y rehospedarlo bajo un nombre confiable, porque la referencia registrada no va a coincidir.

**A2.3** Salteaste subir la entrada de la firma al log de transparencia de Rekor, así que no hay un registro independiente, a prueba de manipulación y con timestamp de que la firma existió — perdés la detectabilidad del compromiso de una clave y la capacidad de verificar firmas hechas antes de que una clave fuera revocada. En consecuencia el attestor de Kyverno debe poner `rekor: { ignoreTlog: true }`; si no, Kyverno exige una entrada en el log y falla aunque la firma en sí sea válida.

**A2.4** `no signatures found` significa que el artefacto `.sig` no existe en absoluto en ese repositorio (nunca se firmó nada, o estás mirando el repo/digest equivocado). `no matching signatures` significa que **sí** existen artefactos de firma pero ninguno verifica contra el material que suministraste (clave equivocada, identidad equivocada, cadena de certificados equivocada, o un requisito de Rekor/SCT no satisfecho). El paso 6 produjo `no matching signatures` en la fraseología de cosign porque solo distingue en tiempo de verificación. La regla práctica: *found* → problema de registry/repo/copia; *matching* → problema de material de confianza. Esa sola distinción encamina correctamente la mayoría de los incidentes en el primer intento.

### Ejercicio 3

**A3.1** `spec.validationFailureAction: Audit`. La falla queda registrada en un `PolicyReport` en el namespace del recurso (y como un `Event` de Kubernetes), mientras que el pedido es admitido. En Kyverno 1.13+ el equivalente es el `spec.rules[].verifyImages[].failureAction` por regla, quedando `validationFailureAction` deprecado — reconocé ambas grafías.

**A3.2** La imagen del pod `signed` fue reescrita para contener `@sha256:…`, fijándola al manifest exacto que fue verificado. `mutateDigest: true` (el valor por defecto) hace esto. El pod `unsigned` quedó intacto porque la verificación falló — Kyverno no fija lo que no pudo verificar.

**A3.3** `kyverno.io/verify-images`, cuyo valor es un mapa JSON de referencia de imagen → booleano de verificación, por ejemplo `{"ttl.sh/kca-signed-9f3a2b1c:24h":true}`. Persistirlo en el objeto (a) le permite a la fase de validación confirmar que la verificación efectivamente ocurrió sin volver a contactar al registry, (b) hace que la decisión sea auditable en el recurso mismo, y (c) evita re-verificar en actualizaciones posteriores de una imagen sin cambios. Es estado gestionado por Kyverno, no una entrada del cliente.

**A3.4** La ruta ubica la falla dentro de la estructura propia de la regla: conjunto de attestors índice 0 → entrada índice 0 → el tipo de attestor `keys`. Con cuatro entradas la leés como "la entrada N del conjunto M es la que no verificó", que es exactamente lo que necesitás cuando falla una regla `count: 2` de 4 y tenés que saber *cuál* firmante falta en lugar de reprobar las cuatro a mano.

**A3.5** Kyverno excluye las reglas `verifyImages` del escaneo en background, y la configuración recomendada (y en muchas versiones obligatoria) es `background: false`. Las razones son sustantivas, no cosméticas: los escaneos en background reevalúan recursos ya almacenados fuera de la admisión, donde no hay ningún pedido que mutar — así que `mutateDigest` no puede aplicarse — y cada escaneo volvería a emitir llamadas al registry y a Rekor por cada pod del clúster en cada intervalo de escaneo, convirtiendo un costo por admisión en uno continuo, con resultados que quedan obsoletos apenas se mueve un tag. La verificación pertenece a la admisión, donde puede tanto decidir como fijar.

### Ejercicio 4

**A4.1** `verifyImages` corre en la fase de admisión **mutante** porque una verificación exitosa debe poder reescribir la referencia de imagen a su digest y estampar la anotación `kyverno.io/verify-images` — ambas son mutaciones. Una regla que puede mutar tiene que correr donde las mutaciones están permitidas, así que su denegación también aparece desde el webhook mutante. Consecuencia de ordenamiento: cualquier otra mutación que reescriba `image` (una regla mutate que reescribe el registry, un inyector de mirror, otro webhook) debe ordenarse **antes** de la verificación, o vas a verificar una referencia y ejecutar otra. Dentro de Kyverno, las reglas de verificación de imágenes se procesan antes que las reglas mutate ordinarias por esta razón; entre webhooks, lo controlás con el orden de webhooks y manteniendo la reescritura de imágenes dentro de Kyverno.

**A4.2** `-fail` codifica `spec.failurePolicy: Fail`. Kyverno registra endpoints de webhook separados por política de falla para que las políticas `Fail` e `Ignore` puedan coexistir; con `failurePolicy: Ignore` el pedido sería manejado por `mutate.kyverno.svc-ignore`.

**A4.3** El `Deployment` es rechazado de plano, porque la **autogeneración** (autogen) de Kyverno sintetiza reglas equivalentes para los controladores de pods — `Deployment`, `DaemonSet`, `StatefulSet`, `Job`, `CronJob`, `ReplicaSet`, `ReplicationController` — y podés verlas bajo `status.autogen.rules`. La anotación `pod-policies.kyverno.io/autogen-controllers` controla el conjunto (por ejemplo `none` para desactivarlo, o una lista explícita). Esto importa enormemente para la experiencia de uso: sin autogen, `kubectl create deployment` tiene éxito y la falla aparece asincrónicamente como eventos de ReplicaSet que el usuario nunca ve.

**A4.4** (1) `failurePolicy` — `Ignore` mantiene el clúster desplegable cuando Kyverno o el registry están caídos, al costo de una ventana de fail-open; `Fail` es la opción segura y convierte al registry en una dependencia del plano de control. (2) `webhookTimeoutSeconds` — un timeout más corto limita la latencia del API server pero convierte a los registries lentos en fallas más rápido. (3) Caché de verificación (`useCache`, `--imageVerifyCacheTTLDuration`) — saca al registry del camino crítico para digests ya vistos, al costo de un retraso en la revocación. Palancas secundarias: `resourceFilters` en el ConfigMap `kyverno` para excluir `kube-system` y el namespace `kyverno` de modo que una política rota no pueda trabar el plano de control, y correr el controlador de admisión con múltiples réplicas y un PDB.

### Ejercicio 5

**A5.1** `mutateDigest` (por defecto `true`): después de una verificación exitosa, reescribe la referencia de imagen para incluir el digest `@sha256:` resuelto. `verifyDigest` (por defecto `true`): exige que la referencia de imagen contenga un digest — una validación, no una mutación. `required` (por defecto `true`): exige que cada imagen que esta regla selecciona lleve efectivamente un resultado de verificación aprobado; se impone en la fase de validación.

**A5.2** Sin fijar el digest hay una brecha genuina de **tiempo-de-chequeo a tiempo-de-uso**: Kyverno resuelve `app:v1` a un digest, verifica la firma sobre ese digest y admite el pod — pero el pod spec sigue diciendo `app:v1`. Entre la admisión y el pull del kubelet (y en cada reinicio posterior, reprogramación o reemplazo de nodo), un atacante con acceso de push puede mover el tag `v1` a otro manifest distinto y sin firmar, y el kubelet lo va a bajar tan contento. `mutateDigest: true` escribe el digest verificado en el spec, así el kubelet baja exactamente los bytes que fueron verificados, para siempre.

**A5.3** `verifyDigest: true` lo denegó: la firma verificó, pero la referencia no tenía digest y a Kyverno no se le permitió agregar uno. La combinación es legítima para equipos que exigen que *su CI* emita manifiestos con digest fijado — el clúster se niega a adivinar. Hace que la procedencia sea responsabilidad del pipeline, mantiene el spec almacenado byte a byte idéntico a lo que se revisó en Git (importante para la detección de drift en GitOps, ya que una mutación de Kyverno aparecería si no como drift permanente contra el estado deseado de Argo CD/Flux), y evita que Kyverno mute recursos en absoluto.

**A5.4** `required` tiene alcance sobre las imágenes que seleccionan los `imageReferences` de esta regla. No significa "todas las imágenes del clúster deben ser verificadas"; una imagen con la que ninguna entrada `verifyImages` hace match simplemente está fuera de la jurisdicción de la regla y es admitida. La única forma correcta de hacer verdadero "lo no verificado es denegado" es una **regla catch-all** — `imageReferences: ["*"]` con `required: true` — más una allowlist deliberada en `skipImageReferences` para las imágenes que aceptás sin firmar (imágenes del plano de control, imágenes base de terceros). Notá que Kyverno normaliza las referencias cortas usando las claves `defaultRegistry` y `enableDefaultRegistryMutation` del ConfigMap `kyverno`, así que `nginx` hace match como `docker.io/nginx`; escribí siempre patrones totalmente calificados y probalos con `kyverno apply` en lugar de asumir.

**A5.5** La fase mutante puede saltearse o fallar en verificar — la política de falla `Ignore` tragándose un error del webhook, un namespace excluido por `resourceFilters` o por el `namespaceSelector` del webhook, una interacción de `reinvocationPolicy`, o una **actualización** de un pod existente que cambia una imagen sin volver a disparar la verificación. En todos estos casos la anotación `kyverno.io/verify-images` está ausente o no cubre la imagen, y la fase de validación — impulsada por `required: true` — rechaza el pedido. `required` es la segunda cerradura; ponerlo en `false` elimina el único chequeo que sobrevive a una mutación saltada.

**A5.6** *A favor:* las imágenes del plano de control y de la CNI se bajan antes de que Kyverno mismo esté corriendo, y una política `Fail` que las cubra puede trabar el reinicio de un clúster — nada puede arrancar porque el verificador no puede arrancar. Las imágenes propias de Kubernetes tampoco están firmadas con cosign con una clave que vos tengas. *En contra:* cada entrada en `skipImageReferences` es un agujero permanente y no monitoreado. `registry.k8s.io/*` es amplio, y un compromiso ahí o una ruta con typosquatting dentro de él saltea la compuerta por completo. Mitigá fijando esas imágenes por digest mediante una regla mutate/validate aparte, manteniendo la lista de exclusiones corta y revisada, y alertando sobre cambios en ella.

### Ejercicio 6

**A6.1** Una lista de **conjuntos de attestors** es un **AND** lógico — todos los conjuntos deben satisfacerse. Dentro de un conjunto, `entries` combinado con `count` es un **umbral**: al menos `count` entradas deben verificar. Por lo tanto `count: 1` es OR; `count: N` con N entradas es AND. Cuando se omite `count`, el valor por defecto es que **todas las entradas** deben hacer match.

**A6.2** Cosign agrega cada firma como una **capa adicional con sus propias anotaciones dentro del mismo artefacto `.sig`**; el nombre del tag se deriva del digest de la imagen y nunca cambia, así que la cantidad de tags se queda en uno mientras el manifest gana una capa. Kyverno trae ese artefacto, itera sobre todas las capas, y prueba cada entrada de attestor contra cada firma — así que `count: 2` se satisface cuando dos entradas distintas encuentran cada una una capa que pueden verificar.

**A6.3** Dos conjuntos expresan *independencia organizacional* en lugar de un umbral numérico. Con `count: 2` sobre cuatro entradas, dos cualesquiera de las cuatro alcanzan — incluidas dos claves en poder del mismo equipo. Dos conjuntos de una entrada cada uno dicen "la clave del equipo de desarrollo **y** la clave del equipo de seguridad", que es el requisito real de separación de funciones. También documenta la intención en el YAML y falla con una ruta (`.attestors[1]...`) que nombra al responsable.

**A6.4** (1) Agregar la clave B como una **segunda entrada en el mismo conjunto de attestors** y asegurarse de `count: 1` — ahora se acepta A *o* B; nada se rompe. (2) Migrar el pipeline de CI para firmar con B, y firmar retroactivamente el inventario de imágenes existente con B (`cosign sign --key B` sobre cada digest todavía desplegado — por esto importa tener un inventario de imágenes). (3) Verificar cobertura: ninguna imagen en ejecución o desplegable carece de una firma de B. (4) Quitar la entrada de A de la política. (5) Revocar/destruir la clave A y, si estaba en un KMS, deshabilitarla. La invariante es que en ningún momento el conjunto de claves aceptadas queda vacío de las claves que están actualmente en tus imágenes.

**A6.5** (a) Mantiene el material de confianza fuera del objeto de política, que es legible por cualquiera con `get clusterpolicies`, y fuera de Git. (b) Centraliza la rotación: actualizar el `Secret` cambia la verificación en todas partes sin editar la política. El error de RBAC: darle acceso de escritura al namespace `kyverno` — o a ese `Secret` específico — a alguien fuera del equipo de plataforma/seguridad. Quien pueda actualizar `cosign.pub` en ese `Secret` puede sustituir su propia clave y firmar cualquier cosa, silenciosamente, sin ningún cambio visible en la política ni en Git. Tratalo como una raíz de confianza: restringido por RBAC, auditado, e idealmente reconciliado desde un almacén de secretos sellado/externo.

**A6.6** `keys` — una clave pública fija que vos controlás (también `secret:` para un `Secret` de Kubernetes, y `kms:` para una URI como `awskms://…`, `gcpkms://…`, `azurekms://…`, `hashivault://…`, que es la elección correcta cuando la clave privada nunca debe salir de un HSM). `certificates` — verificación contra un certificado y su cadena; obligatorio para firmas de Notary Project y usado para firma cosign basada en X.509. `keyless` — verificación basada en identidad Fulcio/OIDC, la elección correcta para imágenes firmadas por CI donde ninguna clave necesita custodia. `attestor` — un conjunto de attestors anidado, para componer bloques de confianza reutilizables. Adicionalmente `annotations` restringe las anotaciones de firma requeridas, y `repository` apunta la verificación a un repositorio de firmas distinto del propio de la imagen.

### Ejercicio 7

**A7.1** La raíz de confianza pasa a ser una **identidad OIDC** atestiguada por **Fulcio**, que emite un certificado de firma X.509 de vida corta (≈10 minutos) atado a esa identidad. Como el certificado expira casi de inmediato, un verificador en el tiempo T no puede chequear si el certificado era válido al momento de firmar — así que la firma debe venir acompañada de una entrada en un **log de transparencia (Rekor)** que provea un timestamp independiente y a prueba de manipulación que demuestre que la firma se hizo mientras el certificado era válido. Sin el log, la verificación keyless no tiene forma de distinguir una firma hecha durante la vigencia del certificado de una falsificada después; por eso el log es estructural, no opcional. Ese mismo log es lo que hace *detectable* el mal uso de claves/identidades después del hecho.

**A7.2** De la más débil a la más fuerte:
- **(a)** `subject: "*"` — cualquiera con *cualquier* workflow de GitHub Actions en *cualquier* repositorio de GitHub puede firmar una imagen que tu clúster acepta. Esto es efectivamente ningún control.
- **(c)** `subjectRegExp: "https://github.com/my-org/.*"` — sin anclas, así que cualquier subject que *contenga* esa cadena hace match; ver A7.3. Además acepta cualquier workflow, cualquier rama, cualquier repo de la organización, incluido el workflow de un fork o una build disparada por un pull request.
- **(b)** la identidad Google de una sola persona — una restricción real, pero una cuenta humana con credenciales phishables y ninguna garantía de integridad de build; el humano puede firmar cualquier cosa desde una laptop.
- **(d)** regexp anclada que fija la organización, un nombre de repo de un solo segmento, un archivo de workflow específico, y una ref de tag — firmar solo es posible desde un workflow de release sobre un commit taggeado. La más fuerte de las cuatro.

**A7.3** Como (c) no está anclada, cualquier subject que meramente *contenga* la subcadena hace match. Un atacante que controle la organización de GitHub `evil-my-org-clone` o el repositorio `attacker/x` puede obtener un certificado de Fulcio cuyo subject sea, por ejemplo,
`https://github.com/attacker/evil/.github/workflows/build.yaml@refs/heads/https://github.com/my-org/anything` — o más simplemente, dado que la regexp no está anclada en ninguno de los dos extremos, cualquier subject con el literal `https://github.com/my-org/` en cualquier parte, incluida una ruta de repositorio que un atacante pueda crear como `https://github.com/attacker/https://github.com/my-org/x/...`. La variante (d) rechaza todas estas porque `^`/`$` fuerzan a que el subject completo haga match y `[^/]+` impide segmentos de ruta extra. **Anclá siempre las regexps de identidad y escapá los puntos.**

**A7.4** `rekor.ignoreTlog: true` desactiva el requisito de que la firma tenga una **entrada verificable en el log de transparencia** — relevante para ambos modos, pero solo *seguro* en modo basado en claves con `--tlog-upload=false`, y nunca seguro en modo keyless (ver A7.1). `ctlog.ignoreSCT: true` desactiva la verificación del **Signed Certificate Timestamp**, la prueba de que el certificado de Fulcio fue publicado en un log de transparencia de certificados — relevante solo donde existe un certificado, es decir attestors keyless y `certificates`. Ambos son válvulas de escape para despliegues de Sigstore privados o air-gapped; cada uno elimina silenciosamente un mecanismo de detección, así que emparejalos con valores de `roots`/`pubkey` de tu propia infraestructura siempre que sea posible.

**A7.5** `keyless.roots` (tu CA raíz de Fulcio), `keyless.rekor.url` más `keyless.rekor.pubkey` (la clave pública de tu log), y `keyless.ctlog.pubkey` (la clave pública de tu log de CT). Si configurás `roots` pero omitís `ctlog.pubkey`, la verificación va a intentar validar el SCT contra la clave del log de CT **público** de Sigstore, que no puede verificar un certificado emitido por tu Fulcio privado — obtenés una falla de verificación de SCT. La solución (peor) es `ctlog.ignoreSCT: true`; el arreglo correcto es suministrar la clave de tu log de CT.

**A7.6** Cada digest de imagen único que no esté en caché cuesta al menos una validación de cadena de Fulcio y una consulta a Rekor en el camino crítico de la admisión, dentro del timeout de webhook del API server. Si Rekor está lento o inalcanzable y `failurePolicy: Fail`, los despliegues se detienen en todo el clúster — convertiste un servicio público de internet en una dependencia de tu plano de control. Mitigaciones: la **caché de verificación de imágenes** (`useCache: true` más `--imageVerifyCacheEnabled`/`--imageVerifyCacheTTLDuration`), que saca los digests repetidos del camino crítico, y `webhookTimeoutSeconds` ajustado contra la latencia medida del registry. Estructuralmente, correr un **Rekor/Fulcio privado** elimina la dependencia externa por completo; `failurePolicy: Ignore` es la válvula de escape de disponibilidad y debería ser una decisión deliberada y documentada.

### Ejercicio 8

**A8.1** *Qué se firma:* una firma cubre únicamente el **digest** de la imagen. Una attestation cubre una **Statement in-toto** — un documento con un `subject` (el digest de la imagen) y un `predicate` (afirmaciones estructuradas arbitrarias), que luego se firma a su vez. *Dónde se almacena:* las firmas en `sha256-<digest>.sig`, las attestations en `sha256-<digest>.att`, ambas hermanas de la imagen en el mismo repositorio. *Qué responde cada una:* una firma responde "**quién** avala estos bytes exactos"; una attestation responde "**qué se afirma** sobre estos bytes, y quién avala esa afirmación" — cómo fue construida, desde qué fuente, si pasó un escaneo.

**A8.2** La raíz de evaluación para `attestations[].conditions` es el contenido del **predicate**, así que `builder.id` direcciona `predicate.builder.id` en la statement completa. Si la raíz fuera la Statement in-toto completa escribirías `{{ predicate.builder.id }}`, y además podrías alcanzar `{{ _type }}`, `{{ predicateType }}` y `{{ subject[0].digest.sha256 }}`. Kyverno ya verifica por vos el sobre de la statement (tipo y vínculo con el subject), y por eso las conditions operan sobre el payload que realmente te importa.

**A8.3** Son requisitos independientes y acumulativos, combinados con AND. Los `attestors` de nivel superior exigen una **firma** válida sobre la imagen; `attestations[].attestors` exige que la **attestation de ese tipo de predicado** esté firmada por esos attestors. Una política realista usa ambos con material de confianza distinto: la imagen debe estar firmada por la clave de release, *y* la procedencia SLSA debe estar firmada por la identidad keyless del sistema de build. Omitir los `attestors` de nivel superior significa que verificás afirmaciones sobre la imagen sin exigir jamás que la imagen misma esté firmada.

**A8.4** (1) **Procedencia de build** — `https://slsa.dev/provenance/v0.2` o `https://slsa.dev/provenance/v1` — afirmar el ID del builder, el repositorio fuente y la rama/tag, de modo que una imagen construida en la laptop de un desarrollador sea rechazada. (2) **Resultados de escaneo de vulnerabilidades** — `https://cosign.sigstore.dev/attestation/vuln/v1` — afirmar que se hizo un escaneo recientemente (comparar `metadata.scanFinishedOn` con una ventana de frescura) y que no encontró hallazgos críticos. (3) **SBOM** — `https://spdx.dev/Document` o CycloneDX — afirmar la presencia de un SBOM y condicionar sobre la ausencia de un componente o licencia prohibidos. Otros que vale conocer: SARIF para análisis estático, y tipos de predicado personalizados para aprobaciones internas como IDs de tickets de gestión de cambios.

**A8.5** Esperás **`no matching signatures`** (o un error equivalente de firma de attestation) en lugar de `attestation checks failed`, porque Kyverno verifica la firma de la attestation *antes* de confiar en su contenido lo suficiente como para evaluar las condiciones JMESPath. El orden importa porque particiona el problema al instante: un error con forma de firma significa que tu material de confianza está mal (clave, identidad, requisito de Rekor) y las condiciones nunca se evaluaron; un error de `conditions`/`attestation checks failed` significa que la firma era *válida* y la disputa es sobre el contenido de la afirmación — andá a leer el predicado decodificado con `cosign verify-attestation | jq` y compará campo por campo. Depurar las conditions cuando la falla real es la clave desperdicia el incidente entero.

**A8.6** Porque la procedencia es el documento que afirma *cómo se construyó el artefacto*, y los niveles superiores de SLSA dependen de que esa afirmación sea **no falsificable y auditable**. Una firma sin entrada en el log todavía puede chequearse contra una clave que controlás hoy. La procedencia sin entrada en el log no puede corroborarse independientemente después del hecho: si más adelante se descubre que la clave de build fue comprometida, no tenés ningún registro con timestamp que distinga la procedencia generada por el builder real de la procedencia falsificada después, así que no podés determinar cuáles de tus imágenes desplegadas están afectadas. El log de transparencia es lo que hace posible el dimensionamiento retroactivo de un incidente — exactamente el escenario para el que existe la procedencia.

### Ejercicio 9

**A9.1** Cosign almacena las firmas bajo un **tag derivado** (`sha256-<digest>.sig`) — un tag de imagen común que funciona en cualquier registry. Notary Project almacena la firma como un **artefacto OCI con un descriptor `subject`** que apunta a la imagen, descubierto a través de la **API de referrers de OCI Distribution v1.1** (`GET /v2/<name>/referrers/<digest>`). En un registry que no implementa referrers, los clientes recaen en el **esquema de tags** de referrers (`sha256-<digest>`), y si el registry no soporta ninguno de los dos, `notation sign` o la verificación no logran encontrar la firma — el síntoma clásico en versiones viejas de registry. Diferencia práctica: cosign funciona esencialmente en todos lados; Notary necesita un registry moderno pero produce un vínculo más limpio y alineado con los estándares.

**A9.2** `certificates`, con `cert` (el certificado de firma o ancla de confianza) y opcionalmente `certChain`. Las firmas de Notary están **basadas en certificados X.509**, así que la confianza se establece validando el certificado de firma contra una raíz de confianza, no comparando contra una clave pública pelada. `keys.publicKeys` describe un par de claves crudo sin identidad, cadena, período de validez ni semántica de revocación, que no es cómo funciona el modelo de confianza de Notary.

**A9.3** En el namespace **`kyverno`** — el namespace del controlador de admisión que realiza el pull. No puede ser el namespace del pod porque entonces el inquilino dueño de ese namespace podría suministrar las credenciales que se le antojen, y porque Kyverno necesitaría acceso de lectura a secrets en todos los namespaces, convirtiendo al controlador de admisión en un lector de secrets a nivel de clúster. La consecuencia de multi-tenancy es deliberada: las credenciales de registry usadas para la verificación son **propiedad del equipo de plataforma**, no del inquilino, así que un inquilino no puede apuntar la verificación a un registry que él controle. También implica que el equipo de plataforma debe mantener credenciales para cada registry que use cualquier inquilino.

**A9.4** `providers` usa los **llaveros de credenciales** de la nube — IAM Roles for Service Accounts en EKS, Workload Identity en GKE, Managed Identity en AKS, y el proveedor de tokens de GitHub — así Kyverno se autentica contra ECR/GAR/ACR/GHCR usando la identidad de nube del propio pod, con tokens de vida corta rotados automáticamente y sin ningún secret estático que se filtre o haya que rotar. `default` es el llavero estándar de Docker (archivo de configuración más `--imagePullSecrets`). Esto es estrictamente mejor que un secret estático dondequiera que esté disponible.

**A9.5** `allowInsecureRegistry: true` permite HTTP plano y saltea la verificación del certificado TLS para la conexión con el registry. Es peor que confiar en la CA del registry porque desactiva por completo la autenticación del *servidor*: cualquiera capaz de interceptar la conexión entre el pod de Kyverno y el registry puede servir artefactos de firma fabricados, de modo que la verificación devuelve "verificado" para imágenes elegidas por un atacante. Derrota el control que aparenta sostener. Usalo solo para un laboratorio descartable; en producción, montá la CA del registry en el almacén de confianza del pod de Kyverno y dejá la bandera en `false`.

**A9.6** (a) **Digest ya verificado:** la caché está indexada por el digest y los parámetros de verificación, así que los pods creados después de las 14:00 que referencien ese digest pueden ser admitidos desde la caché hasta que transcurra el TTL de la entrada — en el peor caso ~60 minutos después de que la entrada se pobló, o sea hasta ~59 minutos pasado tu cambio de política. (Kyverno invalida las entradas de caché cuando cambia la política, así que en las versiones actuales la edición misma debería limpiarlas — verificá esto en tu versión en lugar de asumirlo, ya que todo el argumento de exposición descansa sobre eso.) (b) **Imagen nunca vista:** no existe entrada de caché, así que la nueva política aplica de inmediato, con exposición cero. La perilla es `--imageVerifyCacheTTLDuration` (y `useCache: false` por regla). Acortarla cuesta viajes de ida y vuelta al registry y a Rekor en el camino crítico de la admisión — más latencia por creación de pod, más carga sobre el registry, y un radio de impacto mayor si el registry está lento. Durante un incidente activo de compromiso de claves, la jugada correcta no es ajustar el TTL sino sacar la clave de la política *y* reiniciar el controlador de admisión, lo que descarta la caché en memoria de plano.

### Ejercicio 10

**A10.1** Porque `kyverno apply` y `kyverno test` están diseñados para correr offline y de forma hermética — en un chequeo de pull request sin credenciales de registry, sin salida de red y sin clúster. Contactar registries por defecto haría que cada prueba de política fuera lenta, inestable y dependiente de disponibilidad externa. La consecuencia en CI de olvidar `--registry`: las reglas de verificación de imágenes no pueden traer firmas, así que se saltean o dan error en lugar de evaluarse genuinamente, y una suite de tests que se ve verde no prueba nada sobre tus reglas `verifyImages`. Hacé aserciones sobre los conteos del resumen, no solo sobre el código de salida.

**A10.2**
| # | Falla | Mensaje | Causa raíz | Siguiente comando |
|---|---|---|---|---|
| a | clave pública equivocada | `.attestors[0].entries[0].keys: no matching signatures` | el artefacto de firma existe pero ninguna capa verifica contra esta clave | `cosign verify --key <policy key> --insecure-ignore-tlog $IMG` — reproduce el chequeo exacto fuera de Kyverno |
| b | bloque `rekor` eliminado | la verificación de la firma falla citando el log de transparencia / ninguna entrada tlog válida | Kyverno ahora exige una entrada en Rekor que la imagen nunca obtuvo (`--tlog-upload=false`) | `cosign verify --key cosign.pub $IMG` *sin* `--insecure-ignore-tlog` — la misma falla, confirmando que es el requisito del log, no la clave |
| c | `imageReferences: ["kca-*"]` | **ningún mensaje**; el recurso no es ni pass ni fail | el patrón no hace match con la referencia totalmente calificada `ttl.sh/kca-…`, así que la regla nunca aplica | `kyverno apply … --registry` y leer los conteos; después `kubectl -n kyverno get cm kyverno -o yaml \| yq .data.defaultRegistry` para confirmar la normalización |

**A10.3** El resumen decía `pass: 0, fail: 0, warn: 0, error: 0, skip: 2` (o reportaba la regla como skipped) — una **política silenciosamente inerte**. Esto es peor que una falla ruidosa porque cada dashboard, reporte y código de salida dice "limpio": la política existe, está `Ready`, `kubectl get cpol` muestra `Enforce`, y los auditores lo van a aceptar — mientras imágenes sin firmar entran al clúster sin ser cuestionadas. Una falla ruidosa se arregla en una hora; una política inerte sobrevive meses. La aserción que la detecta es una expectativa **positiva** en `kyverno-test.yaml`: afirmar `result: pass` para un recurso conocidamente bueno y `result: fail` para uno conocidamente malo. Si la regla deja de hacer match, la expectativa de `pass` también falla, así que el test se rompe en ambas direcciones. Nunca escribas un test de política que solo afirme fallas.

**A10.4** Sin `imageExtractors`, Kyverno solo sabe cómo encontrar imágenes en los pod specs bien conocidos de Kubernetes (`containers`, `initContainers`, `ephemeralContainers`). Un `Task` de Tekton guarda sus imágenes en `/spec/steps/*/image`, que Kyverno no puede descubrir, así que la regla encontraría **cero imágenes** y admitiría todo — el modo de falla de la política inerte de A10.3, ahora sobre las definiciones de tu propio sistema de CI. Con el extractor declarado, `mutateDigest: true` reescribe cada `spec.steps[*].image` del `Task` a su digest verificado, exactamente como reescribiría una imagen de contenedor en un pod.

**A10.5** (1) Confirmar que es Kyverno y no el API server en general: `kubectl -n kyverno get pods` y `kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200`, buscando timeouts de registry/Rekor. (2) Confirmar la alcanzabilidad desde la posición de red de Kyverno, no la tuya: `kubectl -n kyverno exec deploy/kyverno-admission-controller -- <probe>` o un pod de debug en ese namespace contra el registry y `rekor.sigstore.dev`; chequear si hay una `NetworkPolicy` nueva, una falla de DNS o un cambio de proxy. (3) Chequear el lado del registry/Rekor — estado del proveedor, rate limiting (`429`), credenciales vencidas en el pull secret. (4) Chequear carga y recursos: la duración de admission review en el endpoint de métricas, throttling de CPU, y si la caché fue invalidada recientemente por una edición de política (una caché fría después de un cambio de política convierte cada pod en un viaje al registry y es un disparador muy común de exactamente este síntoma). **Mitigación inmediata sin borrar la política:** pasar `spec.failurePolicy` a `Ignore` — la compuerta deja de bloquear ante errores del webhook pero sigue vigente para los pedidos que sí puede evaluar. Subir `webhookTimeoutSeconds` hacia el techo de 30 segundos ayuda solo si el registry está lento en lugar de inalcanzable, y hace más lenta cada admisión. Pasar la regla a `Audit` es el siguiente escalón hacia abajo si `Ignore` no alcanza. Registrá la ventana de fail-open; es un evento de seguridad, no solo una interrupción.

**A10.6** Bypasses disponibles para un operador con acceso al clúster: **(1)** editar o borrar la `ClusterPolicy`; **(2)** borrar o editar las configuraciones de webhook de Kyverno, o agregar una exclusión con `namespaceSelector`/`objectSelector`; **(3)** agregar su namespace a `resourceFilters` en el ConfigMap `kyverno`; **(4)** escalar el controlador de admisión a cero mientras `failurePolicy: Ignore` está configurado — la compuerta desaparece silenciosamente; **(5)** crear un recurso cuyas imágenes vivan en un campo que ningún extractor cubre; **(6)** actualizar una carga de trabajo existente y ya verificada para intercambiar una imagen distinta; **(7)** enviar un recurso que lleve una anotación `kyverno.io/verify-images` escrita a mano. **`required: true` cierra (6) y (7)**: se evalúa en la fase de validación, así que una actualización cuyas imágenes no tengan un resultado de verificación aprobado es rechazada, y una anotación suministrada por el cliente no sobrevive porque Kyverno recalcula el estado de verificación durante la fase mutante en lugar de confiar en el pedido. No cierra nada más — (1) a (4) son problemas de **RBAC** (nadie fuera del equipo de plataforma debería tener acceso de escritura a `clusterpolicies`, `*webhookconfigurations`, el namespace `kyverno`, o su ConfigMap), y (5) es un problema de **cobertura** que se resuelve con `imageExtractors` más una regla catch-all. Una política de firmas es solo tan fuerte como el RBAC que la protege.

</details>

---

## Referencias

- Kyverno — documentación de políticas *Verify Images*: <https://kyverno.io/docs/writing-policies/verify-images/>
- Kyverno — biblioteca de políticas (ejemplos de verificación de imágenes): <https://kyverno.io/policies/>
- Kyverno — código fuente y tipos de la API: <https://github.com/kyverno/kyverno>
- Kyverno — CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Sigstore — cosign: <https://github.com/sigstore/cosign> · documentación: <https://docs.sigstore.dev/>
- Notary Project: <https://notaryproject.dev/docs/>
- Especificación de Attestation in-toto: <https://github.com/in-toto/attestation>
- Predicado de procedencia SLSA: <https://slsa.dev/spec/v1.0/provenance>
- Especificación de OCI Distribution (API de referrers): <https://github.com/opencontainers/distribution-spec>
- Kubernetes — control de admisión dinámico (`failurePolicy`, `timeoutSeconds`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- CNCF — currículum KCA: <https://github.com/cncf/curriculum>