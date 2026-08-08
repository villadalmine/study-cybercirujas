# Ejercicios guiados — Tema 3.5: Integrating Security Scanning and Compliance Checks into Deployment Pipelines

> **Objetivo del laboratorio.** Construir un pipeline de despliegue que trate la seguridad como un *gate* (compuerta) verificable y no como un informe posterior. Al terminar habrás encadenado, en el orden en que un `Pipeline` de Tekton los ejecutaría, las cuatro comprobaciones que un `PlatformEngineer` debe poder auditar: escaneo de vulnerabilidades del artefacto, generación y consumo de un SBOM, firma criptográfica de la imagen, y admisión por política en el clúster. Cada bloque produce una salida que el siguiente consume; ese acoplamiento es el punto.
>
> **Prerrequisitos.** Un clúster (kind/minikube sirve), `kubectl`, Docker o Podman, y los binarios `trivy`, `syft`, `grype`, `cosign`, `conftest` y `kube-bench`. Todo corre local; ninguna imagen se publica en un registro externo salvo un `localhost:5000` que levantamos nosotros.
>
> Fuente del temario: CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf

---

## Bloque 1 — Escaneo de vulnerabilidades como fase que *falla el build*

La diferencia entre "escanear" y "hacer gate" es el código de salida. Un escaneo informativo imprime y devuelve `0`; un gate devuelve `≠0` cuando se cruza un umbral, y el runner del pipeline lo interpreta como fallo.

1. Prepará una imagen deliberadamente vulnerable para tener hallazgos reales que medir:

   ```bash
   cat > Dockerfile <<'EOF'
   FROM python:3.9.16-slim
   RUN pip install --no-cache-dir requests==2.19.1 pyyaml==5.1
   COPY app.py /app/app.py
   USER 1000
   ENTRYPOINT ["python", "/app/app.py"]
   EOF
   echo 'print("hello")' > app.py
   docker build -t localhost:5000/demo-app:0.1.0 .
   ```

2. Corré Trivy en modo **informativo** primero, para ver el universo de hallazgos sin condicionar el resultado:

   ```bash
   trivy image --scanners vuln localhost:5000/demo-app:0.1.0
   ```

   Salida esperada (recortada):

   ```
   localhost:5000/demo-app:0.1.0 (debian 12.4)
   ==========================================
   Total: 74 (UNKNOWN: 0, LOW: 41, MEDIUM: 24, HIGH: 8, CRITICAL: 1)

   Python (python-pkg)
   ===================
   Total: 5 (UNKNOWN: 0, LOW: 0, MEDIUM: 2, HIGH: 2, CRITICAL: 1)

   ┌──────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
   │ Library  │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
   ├──────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
   │ requests │ CVE-2018-18074 │ CRITICAL │ fixed  │ 2.19.1            │ 2.20.0        │
   │ pyyaml   │ CVE-2020-14343 │ HIGH     │ fixed  │ 5.1               │ 5.4           │
   └──────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘
   ```

3. Ahora convertí el mismo escaneo en un **gate**. Queremos que el pipeline falle si hay `CRITICAL` o `HIGH`, pero **solo** cuando exista una versión con fix disponible (romper el build por un CVE sin parche no aporta y genera fatiga de alertas):

   ```bash
   trivy image \
     --scanners vuln \
     --severity HIGH,CRITICAL \
     --ignore-unfixed \
     --exit-code 1 \
     --format table \
     localhost:5000/demo-app:0.1.0
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   ...
   Total: 3 (HIGH: 2, CRITICAL: 1)
   ...
   exit code: 1
   ```

4. Verificá que el gate se *abre* cuando corregís las dependencias. Editá el `Dockerfile` para instalar `requests==2.32.3` y `pyyaml==6.0.1`, reconstruí, y repetí el paso 3. El `exit code` debe pasar a `0`.

5. Reproducí el mismo control con **Grype** para entender que el gate no depende de un solo vendor y que las bases de datos de CVE difieren:

   ```bash
   grype localhost:5000/demo-app:0.1.0 --fail-on high -o table
   echo "exit code: $?"
   ```

**Preguntas de comprensión — Bloque 1**

- **1a.** El paso 3 usa `--ignore-unfixed`. Un revisor de seguridad objeta: "estás ocultando vulnerabilidades reales". ¿Cuál es el argumento técnico a favor de `--ignore-unfixed` en el *gate*, y por qué esa decisión no equivale a ignorar esos CVE?
- **1b.** ¿Por qué el paso 2 (informativo) y el paso 3 (gate) son fases separadas del pipeline y no un solo comando? ¿Qué se pierde si solo corrés el paso 3?
- **1c.** Trivy y Grype pueden reportar conteos distintos de CRITICAL para la misma imagen. ¿Significa esto que uno "está mal"? ¿Qué implica para el diseño de un gate corporativo que debe ser reproducible?

---

## Bloque 2 — SBOM: generar el inventario una vez, escanearlo N veces

Escanear la imagen re-descarga y re-analiza sus capas cada vez. En un pipeline maduro se genera el SBOM (Software Bill of Materials) **una** vez como artefacto firmable, y las herramientas posteriores lo consumen. Esto también permite re-escanear un artefacto ya desplegado contra CVE descubiertos *después* del build, sin reconstruir nada.

1. Generá el SBOM en formato **SPDX** y en **CycloneDX**, los dos estándares que el ecosistema CNCF consume:

   ```bash
   syft localhost:5000/demo-app:0.1.0 -o spdx-json=sbom.spdx.json
   syft localhost:5000/demo-app:0.1.0 -o cyclonedx-json=sbom.cdx.json
   ```

   Salida esperada:

   ```
    ✔ Parsed image        sha256:9a1b...
    ✔ Cataloged contents
      ├── ✔ Packages                  [187 packages]
      ├── ✔ File digests              [2 files]
      └── ✔ Executable metadata       [0 executables]
   ```

2. Confirmá que el SBOM es una lista de componentes, no un informe de vulnerabilidades — son cosas distintas:

   ```bash
   jq -r '.packages[] | select(.name=="requests") | "\(.name) \(.versionInfo)"' sbom.spdx.json
   ```

   Salida esperada:

   ```
   requests 2.19.1
   ```

3. Ahora escaneá **el SBOM**, no la imagen. Notá que Grype acepta el artefacto directamente:

   ```bash
   grype sbom:./sbom.spdx.json --fail-on critical -o table
   ```

4. Simulá el escenario clave de supply chain: **un CVE nuevo aparece mañana**. No reconstruís nada; volvés a escanear el SBOM archivado con la base de datos actualizada:

   ```bash
   grype db update
   grype sbom:./sbom.spdx.json -o json | jq '.matches | length'
   ```

5. Adjuntá el SBOM a la imagen como *attestation* para que viaje con el artefacto (esto lo verificaremos firmado en el Bloque 3):

   ```bash
   cosign attach sbom --sbom sbom.cdx.json localhost:5000/demo-app:0.1.0
   ```

**Preguntas de comprensión — Bloque 2**

- **2a.** El paso 4 encuentra vulnerabilidades sin reconstruir la imagen. Explicá por qué esto es imposible con un flujo que solo escanea imágenes en tiempo de build, y qué propiedad del SBOM lo habilita.
- **2b.** SPDX y CycloneDX describen el mismo binario. ¿Por qué generarías ambos en lugar de elegir uno? Da un consumidor concreto que prefiera cada uno.
- **2c.** Un compañero propone "borremos el SBOM después del escaneo, ocupa espacio y ya sabemos que la imagen pasó". ¿Qué capacidad de respuesta a incidentes perdés al hacer eso?

---

## Bloque 3 — Firma y verificación de la cadena de suministro (Sigstore / cosign)

Un escaneo limpio no dice nada sobre *quién construyó* la imagen ni si fue alterada después. La firma cierra ese hueco. Usaremos cosign en modo **keyless** (OIDC + transparency log), que es el patrón que SLSA recomienda por encima de claves de larga vida.

1. Generá un par de claves para el ejercicio local (en producción usarías keyless, pero la mecánica de verificación es idéntica):

   ```bash
   cosign generate-key-pair
   ```

2. Firmá la imagen. La firma se almacena **junto a la imagen** en el registro, como un artefacto OCI con tag derivado del digest:

   ```bash
   cosign sign --key cosign.key localhost:5000/demo-app:0.1.0
   ```

   Salida esperada:

   ```
   Pushing signature to: localhost:5000/demo-app
   ```

3. Verificá la firma. Este comando es el que un admission controller ejecutará implícitamente en el Bloque 4:

   ```bash
   cosign verify --key cosign.pub localhost:5000/demo-app:0.1.0 | jq '.[0].optional'
   ```

   Salida esperada (recortada):

   ```json
   {
     "Subject": "",
     "Bundle": { "SignedEntryTimestamp": "MEUC...", "Payload": { "logIndex": 12345678 } }
   }
   ```

4. Firmá también una **attestation** que declare que la imagen pasó el escaneo del Bloque 1. Esto convierte "confía en mí, escaneé" en una afirmación verificable:

   ```bash
   trivy image --format cyclonedx -o trivy.cdx.json localhost:5000/demo-app:0.1.0
   cosign attest --key cosign.key \
     --type cyclonedx \
     --predicate trivy.cdx.json \
     localhost:5000/demo-app:0.1.0
   ```

5. Demostrá que la firma detecta manipulación. Reconstruí la imagen con el **mismo tag** pero contenido distinto (una capa nueva), volvé a pushear, y verificá SIN volver a firmar:

   ```bash
   echo 'print("tampered")' > app.py
   docker build -t localhost:5000/demo-app:0.1.0 . && docker push localhost:5000/demo-app:0.1.0
   cosign verify --key cosign.pub localhost:5000/demo-app:0.1.0
   ```

   Salida esperada:

   ```
   Error: no matching signatures:
   ...
   main.go:...: error during command execution: no matching signatures
   ```

**Preguntas de comprensión — Bloque 3**

- **3a.** En el paso 5 el tag `0.1.0` sigue existiendo y "resuelve", pero la verificación falla. ¿Contra qué firma cosign realmente — el tag o el digest? ¿Qué ataque concreto previene esa elección?
- **3b.** ¿Cuál es la diferencia entre `cosign sign` (paso 2) y `cosign attest` (paso 4)? ¿Por qué un gate de admisión podría exigir *ambas*?
- **3c.** El modo keyless usa un certificado efímero (~10 min) en vez de una clave persistente. Si el certificado ya expiró, ¿cómo puede seguir verificándose la firma meses después? ¿Qué componente de Sigstore lo hace posible?

---

## Bloque 4 — Compliance del clúster y admisión por política

El pipeline empujó un artefacto escaneado y firmado. El último gate vive **en el clúster**: rechazar en admisión todo lo que no cumpla la política, para que un `kubectl apply` manual no pueda saltear el pipeline. Combinamos dos niveles: benchmark del clúster (kube-bench / CIS) y política de admisión (Kyverno).

1. Corré **kube-bench** contra los nodos para medir contra el CIS Kubernetes Benchmark:

   ```bash
   kubectl run kube-bench --rm -i --restart=Never \
     --image=aquasec/kube-bench:latest -- run --targets node
   ```

   Salida esperada (recortada):

   ```
   [INFO] 4 Worker Node Security Configuration
   [PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600
   [FAIL] 4.2.6 Ensure that the --protect-kernel-defaults argument is set to true
   [WARN] 4.2.10 Ensure that the --tls-cert-file argument is set as appropriate

   == Summary ==
   38 checks PASS
   8 checks FAIL
   6 checks WARN
   ```

2. Validá manifiestos **antes de aplicarlos** con Conftest/OPA, en el propio pipeline. Escribí una política Rego que exija imágenes firmadas por digest y prohíba `latest`:

   ```rego
   # policy/deploy.rego
   package main

   deny[msg] {
     input.kind == "Deployment"
     img := input.spec.template.spec.containers[_].image
     endswith(img, ":latest")
     msg := sprintf("la imagen '%s' usa el tag latest", [img])
   }

   deny[msg] {
     input.kind == "Deployment"
     img := input.spec.template.spec.containers[_].image
     not contains(img, "@sha256:")
     msg := sprintf("la imagen '%s' no está fijada por digest", [img])
   }
   ```

   ```bash
   conftest test deployment.yaml -p policy/
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   FAIL - deployment.yaml - main - la imagen 'localhost:5000/demo-app:0.1.0' no está fijada por digest
   1 test, 0 passed, 0 warnings, 1 failure
   exit code: 1
   ```

3. Instalá Kyverno y aplicá una `ClusterPolicy` que **verifique la firma cosign en admisión**. Este es el eslabón que hace inviable saltear el Bloque 3:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-signed-images
   spec:
     validationFailureAction: Enforce
     webhookTimeoutSeconds: 30
     rules:
       - name: verify-cosign-signature
         match:
           any:
             - resources:
                 kinds: [Pod]
         verifyImages:
           - imageReferences:
               - "localhost:5000/demo-app*"
             attestors:
               - count: 1
                 entries:
                   - keys:
                       publicKeys: |-
                         -----BEGIN PUBLIC KEY-----
                         MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                         -----END PUBLIC KEY-----
   ```

   ```bash
   kubectl apply -f require-signed-images.yaml
   ```

4. Probá el gate de admisión con una imagen **firmada** (la del Bloque 3, sin manipular) y con una **no firmada**:

   ```bash
   kubectl run signed --image=localhost:5000/demo-app:0.1.0        # debe admitirse
   kubectl run unsigned --image=nginx:latest                       # debe rechazarse
   ```

   Salida esperada para la segunda:

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   ...
   failed to verify image nginx:latest: .attestors[0].entries[0]: no matching signatures
   ```

5. Cerrá el círculo: mostrá que Kyverno **muta** la referencia al digest resuelto tras verificar, de modo que el Pod termina fijado aunque hayas pedido un tag:

   ```bash
   kubectl get pod signed -o jsonpath='{.spec.containers[0].image}'; echo
   ```

   Salida esperada:

   ```
   localhost:5000/demo-app:0.1.0@sha256:9a1b...
   ```

**Preguntas de comprensión — Bloque 4**

- **4a.** El Bloque 1 ya escanea en el pipeline. ¿Por qué agregar además un gate de admisión en el clúster (Kyverno) en vez de confiar en que el pipeline hizo su trabajo? Nombrá un vector concreto que el gate de pipeline **no** cubre y el de admisión sí.
- **4b.** kube-bench reporta `[WARN]` y `[FAIL]`. ¿Deberías fallar el pipeline con un `[WARN]`? Distinguí entre los dos y explicá cómo tratarías cada uno en un gate de compliance automatizado.
- **4c.** En el paso 5, Kyverno reescribe la imagen del tag al `tag@sha256:...`. Relacioná esto con la pregunta 3a: ¿por qué esa mutación es una defensa de seguridad y no una mera comodidad?
- **4d.** `validationFailureAction: Enforce` vs `Audit`. Describí una estrategia de *rollout* de esta política en un clúster con cargas existentes que ya podrían estar violándola, sin causar una interrupción.

---

## Bloque 5 — Ensamblar el gate completo en un pipeline

Los cuatro bloques anteriores son etapas de un mismo `Pipeline`. Este bloque las ordena y expone el principio de diseño: **fail-fast, artefactos inmutables entre etapas, y todo gate produce un código de salida auditable.**

1. Escribí el pipeline como script para ver el encadenamiento y los puntos de corte:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   IMG="localhost:5000/demo-app"
   TAG="0.2.0"

   # Etapa 1: build y captura del digest inmutable
   docker build -t "$IMG:$TAG" .
   docker push "$IMG:$TAG"
   DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMG:$TAG")
   echo ">> artefacto: $DIGEST"

   # Etapa 2: SBOM (una vez, sobre el digest)
   syft "$DIGEST" -o spdx-json=sbom.spdx.json

   # Etapa 3: gate de vulnerabilidades sobre el SBOM
   grype "sbom:./sbom.spdx.json" --fail-on high

   # Etapa 4: firma + attestation del SBOM
   cosign sign --key cosign.key "$DIGEST"
   cosign attest --key cosign.key --type spdxjson --predicate sbom.spdx.json "$DIGEST"

   # Etapa 5: gate de política sobre el manifiesto
   sed "s|IMAGE_PLACEHOLDER|$DIGEST|" deployment.tmpl.yaml > deployment.yaml
   conftest test deployment.yaml -p policy/

   # Etapa 6: deploy (admisión de Kyverno hace el gate final en el clúster)
   kubectl apply -f deployment.yaml
   ```

2. Corré el script completo y confirmá que **todas** las etapas devuelven `0`. Luego introducí una regresión (bajá `requests` a `2.19.1`) y observá en qué etapa exacta se detiene y con qué mensaje.

3. Comprobá la propiedad de inmutabilidad: verificá que el `$DIGEST` que firmaste en la Etapa 4 es idéntico al que Kyverno admite en el clúster (`kubectl get deploy demo-app -o jsonpath='{.spec.template.spec.containers[0].image}'`).

**Preguntas de comprensión — Bloque 5**

- **5a.** El script pasa `$DIGEST` (no `$IMG:$TAG`) a todas las etapas después del build. Explicá qué clase de bug o ataque *time-of-check-to-time-of-use* (TOCTOU) previene esa decisión.
- **5b.** El orden es SBOM → escaneo → firma → política. ¿Por qué la firma va *después* del escaneo y no antes? ¿Qué afirmarías por accidente si firmaras primero?
- **5c.** Si tuvieras que reducir este pipeline a **un solo** gate por presupuesto de mantenimiento, ¿cuál conservarías y por qué? Justificá en términos de qué garantía es imposible recuperar aguas abajo.

---

<details>
<summary><strong>Respuestas</strong></summary>

**1a.** El gate rompe el build para forzar una acción del desarrollador; si no hay `Fixed Version`, no existe acción posible salvo esperar, así que romper solo genera un build rojo permanente y fatiga de alertas que termina en gente ignorando el gate. `--ignore-unfixed` **no** ignora el CVE: sigue apareciendo en el escaneo informativo (paso 2), en el SBOM y en el re-escaneo del Bloque 2. Se excluye únicamente de la *condición de fallo*. El CVE sin parche se gestiona por otra vía (VEX/allowlist con vencimiento, mitigación de configuración, o cambio de base image), no bloqueando ciegamente.

**1b.** Son fases separadas porque tienen consumidores distintos. El paso 2 (informativo, `exit 0`) alimenta dashboards, tendencias y triage: querés ver los 74 hallazgos aunque no rompan el build. El paso 3 (gate, `exit 1`) alimenta la decisión binaria de promover o no. Si solo corrés el paso 3 perdés visibilidad de todo lo `MEDIUM/LOW` y de lo unfixed — la deuda de seguridad se vuelve invisible y nunca se prioriza porque "el build está verde".

**1c.** No significa que uno esté mal: Trivy y Grype usan bases de datos y heurísticas de *matching* (mapeo paquete→CVE) distintas, con distinta latencia de actualización y distinto tratamiento de backports de distro. Para un gate corporativo reproducible implica: (1) fijar la herramienta *y* su versión de DB, (2) versionar la allowlist/VEX, y (3) idealmente correr ambas y unir resultados para no depender de la cobertura de un solo vendor — a costa de más falsos positivos que hay que triar.

**2a.** El re-escaneo sin rebuild es posible porque el SBOM es un **inventario declarativo e inmutable** de componentes y versiones, desacoplado de la base de datos de vulnerabilidades. La correlación componente↔CVE ocurre en tiempo de *escaneo*, no de *build*. Un flujo que solo escanea imágenes acopla ambas cosas: para evaluar un CVE nuevo tenés que re-descargar y re-analizar la imagen (o peor, reconstruirla, cambiando el artefacto). Con SBOM, el artefacto queda fijo y solo cambia la DB.

**2b.** Ambos describen lo mismo pero sus consumidores difieren. **SPDX** (linaje Linux Foundation) es el formato que exigen muchos requisitos de licenciamiento/compliance y órdenes ejecutivas gubernamentales; su modelo de relaciones y licencias es más rico. **CycloneDX** (linaje OWASP) está orientado a seguridad/supply-chain, se integra nativamente con herramientas de VEX y es el `--type` que cosign/Kyverno consumen con fluidez para attestations. Generás ambos para no forzar a cada consumidor a convertir.

**2c.** Perdés la capacidad de responder a un *zero-day futuro* sobre artefactos ya desplegados. Cuando mañana se publique un CVE, sin el SBOM archivado no podés contestar rápido "¿qué imágenes en producción contienen la librería afectada?" sin re-escanear todo el fleet imagen por imagen. El SBOM firmado y archivado es tu índice de exposición para respuesta a incidentes; borrarlo cambia una consulta de segundos por una campaña de re-escaneo.

**3a.** cosign firma el **digest** (`sha256:...`), nunca el tag. El tag es un puntero mutable; el digest es el contenido. En el paso 5 el tag `0.1.0` se re-apunta a un contenido nuevo (otro digest), así que la firma —que ampara el digest viejo— ya no matchea. Previene el ataque de **mutable tag / re-tag**: alguien con acceso al registro reemplaza el contenido detrás de un tag ya aprobado sin cambiar el nombre que el pipeline pidió.

**3b.** `cosign sign` produce una firma sobre el digest: afirma "esta entidad avala este artefacto" (autenticidad/integridad). `cosign attest` produce una **attestation**: un predicado estructurado firmado que afirma un *hecho* sobre el artefacto (ej. "pasó este escaneo", "se construyó con este SBOM", "salió de este pipeline SLSA"). Un gate de admisión puede exigir ambas: la firma prueba *quién*, y la attestation prueba *qué propiedad* cumple (p. ej. "escaneado sin CRITICAL por Trivy vX"). La firma sola no dice nada sobre el escaneo.

**3c.** La firma se verifica meses después gracias al **transparency log (Rekor)**. En keyless el certificado efímero es válido solo ~10 min, pero al firmar se registra una entrada en Rekor con un *signed timestamp*. La verificación comprueba que la firma se hizo *mientras el certificado estaba vigente*, según el timestamp del log, no según el reloj actual. El log inmutable y auditable de Sigstore es lo que hace innecesaria (y desaconsejable) la clave de larga vida.

**4a.** Se agrega admisión porque el gate de pipeline solo cubre lo que *pasa por el pipeline*. Vectores que no cubre y admisión sí: un `kubectl apply` manual de un operador que saltea CI; un GitOps mal configurado que despliega una imagen no promovida; un atacante con credenciales que aplica un Pod directo; o un tag mutado *después* de que el pipeline pasó (Bloque 3, paso 5). El gate de admisión es el único punto donde **toda** carga que entra al clúster —venga de donde venga— se valida.

**4b.** No deberías fallar por un `[WARN]` de forma automática. `[FAIL]` es un control CIS *scored* que la máquina puede evaluar de modo determinista → apto para gate duro. `[WARN]` marca controles *not scored* o que dependen del contexto (p. ej. requieren juicio sobre si un flag aplica a tu topología, o kube-bench no puede inspeccionar la configuración remota del control plane gestionado). Tratamiento: `FAIL` → gate bloqueante con excepciones versionadas; `WARN` → ticket/revisión manual, reportado pero no bloqueante, revisado periódicamente.

**4c.** Porque fija el TOCTOU entre *admisión* y *ejecución*. Kyverno verifica la firma del digest y **reescribe** la spec del Pod a ese digest exacto; así el kubelet tira precisamente del contenido verificado, no de "lo que el tag apunte cuando el nodo haga el pull". Sin la mutación, existiría una ventana en la que el tag podría re-apuntar a contenido no firmado entre la verificación y el pull. Es la misma defensa del 3a aplicada dentro del clúster: verificar por firma pero ejecutar por tag reabriría el agujero.

**4d.** Rollout en dos fases. Primero desplegás la política con `validationFailureAction: Audit`: no rechaza nada, solo emite `PolicyReports`/eventos con las violaciones. Con eso inventariás qué cargas existentes incumplen y las remediás (firmar, fijar digests). Cuando el reporte de audit esté limpio (o con excepciones explícitas para namespaces legacy), cambiás a `Enforce`. Podés acotar el blast radius con `match` por namespace o labels, promoviendo namespace por namespace en vez de todo el clúster de una.

**5a.** Pasar `$DIGEST` fija el **contenido exacto** verificado en cada etapa; usar `$IMG:$TAG` reintroduce un puntero mutable que podría resolver a contenido distinto entre la etapa de escaneo y la de firma o deploy (time-of-check-to-time-of-use). El escenario: escaneás `tag`→digest A (limpio), pero entre el escaneo y el push del deploy el tag se re-apunta a digest B (malicioso); el pipeline "verde" desplegaría B. Anclando al digest desde el build, todas las etapas hablan del mismo artefacto inmutable.

**5b.** La firma va después del escaneo porque firmar es *avalar*. Si firmaras antes de escanear, tu firma —y la attestation asociada— afirmaría "yo respaldo este artefacto" sin haber comprobado que pasa el gate de vulnerabilidades; estarías certificando algo que aún no verificaste, y peor, podrías firmar y luego el escaneo fallar, dejando en Rekor una firma de un artefacto rechazado. El orden garantiza que solo se firma —y por tanto solo puede admitirse— lo que ya superó el escaneo.

**5c.** Conservaría el **gate de admisión con verificación de firma en el clúster** (Bloque 4/Kyverno). Razón: cualquier garantía de escaneo o SBOM que vive solo en el pipeline es *evadible* — un `apply` directo la saltea y no hay forma de recuperarla aguas abajo. El punto de admisión es el único chokepoint que ve *todo* lo que corre. Es un segundo-mejor honesto: no reemplaza escanear, pero al exigir firma obliga a que *algo* haya avalado el artefacto, mientras que sin él no hay ningún punto de control ineludible. (Compromiso: la firma es tan buena como lo que el firmante verificó, por eso en el mundo real no se sacrifica el escaneo.)

</details>