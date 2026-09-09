# Tema 5.1 — Describir conceptos fundamentales de seguridad en la nube
## Ejercicios guiados · Google Cloud Digital Leader (versión del examen 2026-08-12) · Peso de la sección 5: 9%

> **Qué demuestra este conjunto de laboratorios.** El examen Cloud Digital Leader te pide *describir* conceptos de seguridad, no configurarlos. Pero las descripciones memorizadas de diapositivas se derrumban ante las preguntas de escenario ("un cliente almacena PII en Cloud Storage y pregunta quién es responsable de parchear la biblioteca de cifrado…"). Cada ejercicio de abajo te hace **ejecutar aquello que después te van a pedir que describas**, de modo que el vocabulario — responsabilidad compartida, destino compartido, mínimo privilegio, separación de funciones, defensa en profundidad, zero trust, CMEK, residencia de datos — quede anclado a un artefacto que produjiste e inspeccionaste.

---

## 0. Preparación del entorno

**Roles que necesitás:** `roles/owner` sobre un proyecto **sandbox**, o la combinación `roles/resourcemanager.projectIamAdmin` + `roles/iam.roleAdmin` + `roles/cloudkms.admin` + `roles/logging.viewer` + `roles/compute.securityAdmin`.

**Advertencia de costo.** Los ejercicios 1–3, 7, 8 y 9 son gratuitos (lecturas de metadatos y escrituras de IAM). El ejercicio 4 crea versiones de clave en **Cloud KMS** (~US$0,06 por versión de clave por mes, y un key ring nunca se puede eliminar). El ejercicio 6 crea una política de seguridad de Cloud Armor — gratuita mientras no esté asociada a un balanceador de carga. Los ejercicios 5 y 6b necesitan una **organización** y se proveen con alternativas de solo lectura.

```bash
# 1. Authenticate and pin a sandbox project
gcloud auth login
export PROJECT_ID="cdl-sec-lab-$(whoami)"          # use an EXISTING sandbox project id
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION="europe-west1"
gcloud config set project "$PROJECT_ID"

# 2. Enable the APIs used across the lab
gcloud services enable \
  cloudkms.googleapis.com \
  cloudasset.googleapis.com \
  policytroubleshooter.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com
```

Salida esperada (abreviada):

```
Operation "operations/acat.p2-482913746215-9f0b...-cb1e" finished successfully.
```

Verificá con qué cuenta estás actuando — casi todo "permission denied" de este laboratorio se remonta a esta línea:

```bash
gcloud auth list --filter=status:ACTIVE --format="value(account)"
```

```
you@example.com
```

---

## Ejercicio 1 — Seguridad *de* la nube vs. seguridad *en* la nube

**Concepto evaluado:** el **modelo de responsabilidad compartida** y su evolución específica de Google, el **destino compartido** (*shared fate*). La idea de mayor rendimiento de toda la sección 5: el límite de responsabilidad *se mueve con el modelo de servicio*.

### Pasos

1. Listá qué servicios de la familia de cómputo están habilitados en el proyecto. Cada uno se sitúa en un punto distinto del espectro de responsabilidad.

   ```bash
   gcloud services list --enabled \
     --filter="config.name:(compute.googleapis.com OR container.googleapis.com OR run.googleapis.com OR cloudfunctions.googleapis.com OR bigquery.googleapis.com)" \
     --format="table(config.name, config.title)"
   ```

   ```
   NAME                        TITLE
   bigquery.googleapis.com     BigQuery API
   compute.googleapis.com      Compute Engine API
   run.googleapis.com          Cloud Run Admin API
   ```

2. Comprobá el límite empíricamente sobre **IaaS**. Creá una VM mínima y preguntale al sistema operativo invitado quién lo parchea:

   ```bash
   gcloud compute instances create resp-demo \
     --zone="${REGION}-b" \
     --machine-type=e2-micro \
     --image-family=debian-12 \
     --image-project=debian-cloud \
     --no-address \
     --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
   ```

   ```
   Created [https://www.googleapis.com/compute/v1/projects/cdl-sec-lab/zones/europe-west1-b/instances/resp-demo].
   NAME       ZONE            MACHINE_TYPE  INTERNAL_IP  STATUS
   resp-demo  europe-west1-b  e2-micro      10.132.0.7   RUNNING
   ```

3. Inspeccioná qué garantiza Google *por debajo* de esa VM — la línea base de integridad de Shielded VM — y qué explícitamente **no** cubre (todo lo que está dentro del disco):

   ```bash
   gcloud compute instances describe resp-demo --zone="${REGION}-b" \
     --format="yaml(shieldedInstanceConfig, shieldedInstanceIntegrityPolicy, disks[].licenses)"
   ```

   ```yaml
   disks:
   - licenses:
     - https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm
   shieldedInstanceConfig:
     enableIntegrityMonitoring: true
     enableSecureBoot: true
     enableVtpm: true
   shieldedInstanceIntegrityPolicy:
     updateAutoLearnPolicy: true
   ```

   Leelo literalmente: Google atestigua la **cadena de arranque** (firmware, bootloader, kernel — medidos en un vTPM). Los paquetes del espacio de usuario de Debian por encima del kernel son la imagen de `debian-cloud` y **tu** deber continuo de parcheo.

4. Ahora el contraste. Hacele la misma pregunta a un producto **serverless** — no hay siquiera superficie de sistema operativo que consultar:

   ```bash
   gcloud run services list --region="$REGION" 2>&1 | head -3
   ```

   ```
   Listed 0 items.
   ```

   No hay `--image-family`, ni kernel, ni cadencia de parcheo que vos controles. En Cloud Run, el sistema operativo, el runtime de contenedores, el autoescalador y la terminación TLS son **seguridad *de* la nube**; el contenido de tu imagen de contenedor, los bindings IAM de invocador y la lógica de la aplicación son **seguridad *en* la nube**.

5. Completá esta tabla antes de leer las respuestas. `G` = Google, `C` = Cliente, `S` = Compartido.

   | Capa | Compute Engine | GKE Standard | GKE Autopilot | Cloud Run | BigQuery |
   |---|---|---|---|---|---|
   | Centro de datos físico y hardware | | | | | |
   | Hipervisor / kernel del host | | | | | |
   | Parcheo del SO invitado / SO de nodos | | | | | |
   | Runtime de contenedores | | | | | |
   | Código de aplicación y dependencias | | | | | |
   | Política IAM sobre el recurso | | | | | |
   | Clasificación y contenido de los datos | | | | | |
   | Gestión de claves de cifrado (por defecto) | | | | | |
   | Reglas de firewall de red | | | | | |

### Preguntas de control

**Q1.** En una oración cada una, distinguí *seguridad **de** la nube* de *seguridad **en** la nube*, e indicá cuál es siempre del cliente.

**Q2.** Completá la tabla del paso 5 para la fila "Parcheo del SO invitado / SO de nodos" en los cinco servicios. Explicá por qué GKE Standard y GKE Autopilot difieren.

**Q3.** Google promociona el **destino compartido** (*shared fate*) como una evolución de la responsabilidad compartida. Nombrá tres mecanismos concretos por los cuales Google asume parte de *tu* riesgo bajo el destino compartido, y explicá por qué el destino compartido **no** transfiere la responsabilidad legal sobre tus datos.

**Q4.** Un cliente dice: "Nos mudamos a Cloud Run, así que ya no necesitamos un programa de gestión de vulnerabilidades." Identificá el error y nombrá el único artefacto que sigue siendo suyo y que puede arrastrar un CVE.

---

## Ejercicio 2 — El principio de mínimo privilegio, medido

**Concepto evaluado:** mínimo privilegio y los tres tipos de rol (**básicos**, **predefinidos** y **personalizados**). Las preguntas de escenario del CDL giran alrededor de "¿qué rol deberías otorgar?" — y la respuesta casi nunca es `roles/editor`.

### Pasos

1. Leé la política de permitir (*allow policy*) actual del proyecto. Ésta es la respuesta autoritativa a "quién puede hacer qué acá":

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" --format=yaml
   ```

   ```yaml
   bindings:
   - members:
     - user:you@example.com
     role: roles/owner
   - members:
     - serviceAccount:482913746215-compute@developer.gserviceaccount.com
     role: roles/editor
   etag: BwYh3s9kZ0M=
   version: 1
   ```

   Fijate en el `etag`: es un token de concurrencia optimista. Hacer lectura-modificación-escritura sobre IAM sin preservarlo es la forma en que dos administradores se pisan las concesiones mutuamente en silencio.

2. Cuantificá por qué los roles básicos violan el mínimo privilegio. Contá los permisos que carga cada uno:

   ```bash
   for R in roles/viewer roles/editor roles/owner; do
     N=$(gcloud iam roles describe "$R" \
           --format="value(includedPermissions)" | tr ';' '\n' | wc -l)
     printf "%-14s %6s permissions\n" "$R" "$N"
   done
   ```

   ```
   roles/viewer     4912 permissions
   roles/editor     8043 permissions
   roles/owner      8061 permissions
   ```

   > Estos números suben cada trimestre a medida que Google lanza servicios. El orden de magnitud — **miles** — es lo que importa, y es la razón por la que los roles básicos se desaconsejan fuera de proyectos sandbox.

3. Comparalo con un rol predefinido acotado a un solo trabajo:

   ```bash
   gcloud iam roles describe roles/storage.objectViewer \
     --format="yaml(name, title, stage, includedPermissions)"
   ```

   ```yaml
   includedPermissions:
   - storage.managedFolders.get
   - storage.managedFolders.list
   - storage.objects.get
   - storage.objects.list
   name: roles/storage.objectViewer
   stage: GA
   title: Storage Object Viewer
   ```

   Cuatro permisos contra 8.043. Esa proporción *es* el principio de mínimo privilegio expresado numéricamente.

4. Construí un **rol personalizado** cuando ningún rol predefinido sea lo bastante ajustado. Escribí el manifiesto:

   ```yaml
   # custom-role-log-triage.yaml
   title: "Log Triage (read-only)"
   description: "Read log entries and log-based metrics for incident triage. No export, no sink modification, no data mutation."
   stage: "GA"
   includedPermissions:
   - logging.logEntries.list
   - logging.logs.list
   - logging.logMetrics.get
   - logging.logMetrics.list
   - logging.views.access
   - resourcemanager.projects.get
   ```

   ```bash
   gcloud iam roles create logTriage \
     --project="$PROJECT_ID" \
     --file=custom-role-log-triage.yaml
   ```

   ```
   Created role [logTriage].
   description: Read log entries and log-based metrics for incident triage. No export,
     no sink modification, no data mutation.
   etag: BwYh3tA1p2Y=
   includedPermissions:
   - logging.logEntries.list
   - logging.logs.list
   - logging.logMetrics.get
   - logging.logMetrics.list
   - logging.views.access
   - resourcemanager.projects.get
   name: projects/cdl-sec-lab/roles/logTriage
   stage: GA
   title: Log Triage (read-only)
   ```

5. Ajustá todavía más con una **IAM Condition** — mínimo privilegio en las dimensiones de *tiempo* y *recurso*, no solo en la del verbo:

   ```bash
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="user:oncall@example.com" \
     --role="projects/${PROJECT_ID}/roles/logTriage" \
     --condition='expression=request.time < timestamp("2026-10-01T00:00:00Z"),title=incident-window,description=Expires after the Q3 incident review' \
     --format="yaml(bindings)"
   ```

   ```yaml
   bindings:
   - condition:
       description: Expires after the Q3 incident review
       expression: request.time < timestamp("2026-10-01T00:00:00Z")
       title: incident-window
     members:
     - user:oncall@example.com
     role: projects/cdl-sec-lab/roles/logTriage
   ```

   La `version` de la política ahora es `3`. Un binding condicional desaparece silenciosamente de una lectura con `version: 1` — un punto ciego clásico de auditoría.

6. Confirmá que la concesión expira por *descripción*, y después verificá qué puede hacer realmente el principal:

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" \
     --format="table(bindings.role, bindings.members, bindings.condition.title)"
   ```

### Preguntas de control

**Q5.** Enunciá el principio de mínimo privilegio en una oración, y después dá la evidencia numérica que reuniste en los pasos 2–3 de que `roles/editor` lo viola.

**Q6.** Un analista de datos debe leer objetos de un solo bucket de Cloud Storage y nada más. Ordená estas cuatro opciones de mejor a peor y justificá el orden: (a) `roles/owner`, (b) `roles/storage.admin` a nivel de proyecto, (c) `roles/storage.objectViewer` sobre el bucket único, (d) un rol personalizado con `storage.objects.get` + `storage.objects.list` sobre el bucket único.

**Q7.** ¿Qué es una **IAM Condition** y qué dos dimensiones de mínimo privilegio agrega más allá de "qué permisos"?

**Q8.** ¿Por qué IAM devuelve un `etag` y qué modo de fallo produce ignorarlo?

---

## Ejercicio 3 — Separación de funciones y guardrails que están por encima de IAM

**Concepto evaluado:** **separación de funciones (SoD)**, **defensa en profundidad** y el hecho de que una restricción de Organization Policy se evalúa *antes* que IAM — un Project Owner no puede otorgarse una salida por su alrededor.

### Pasos

1. Modelá la SoD como tres funciones disjuntas. Notá que ningún principal de abajo puede a la vez *crear* una clave y *usarla* para leer datos, y ninguno puede además *auditar*:

   ```bash
   # Duty A — key custodian: manages keys, cannot decrypt data
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="group:key-custodians@example.com" \
     --role="roles/cloudkms.admin" --quiet >/dev/null

   # Duty B — data operator: uses keys to encrypt/decrypt, cannot manage or delete them
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="group:data-operators@example.com" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" --quiet >/dev/null

   # Duty C — auditor: reads everything, changes nothing
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="group:security-audit@example.com" \
     --role="roles/iam.securityReviewer" --quiet >/dev/null
   ```

   > `roles/cloudkms.admin` **excluye** deliberadamente `cloudkms.cryptoKeyVersions.useToDecrypt`. Esa exclusión es Google codificando la SoD dentro del catálogo de roles para vos.

2. Verificá la separación en lugar de confiar en ella:

   ```bash
   gcloud iam roles describe roles/cloudkms.admin \
     --format="value(includedPermissions)" | tr ';' '\n' | grep -c 'useToDecrypt'
   ```

   ```
   0
   ```

3. Ahora agregá la capa de guardrail. Inspeccioná una organization policy **efectiva** sobre el proyecto:

   ```bash
   gcloud org-policies describe constraints/compute.requireOsLogin \
     --project="$PROJECT_ID" --effective
   ```

   ```
   name: projects/cdl-sec-lab/policies/compute.requireOsLogin
   spec:
     rules:
     - enforce: false
   ```

4. Aplicala. Éste es un control **preventivo** — detiene la acción, a diferencia de un control detectivo que apenas la reporta:

   ```yaml
   # orgpolicy-require-oslogin.yaml
   name: projects/cdl-sec-lab/policies/compute.requireOsLogin
   spec:
     rules:
     - enforce: true
   ```

   ```bash
   gcloud org-policies set-policy orgpolicy-require-oslogin.yaml
   ```

   ```
   Created policy [projects/cdl-sec-lab/policies/compute.requireOsLogin].
   name: projects/cdl-sec-lab/policies/compute.requireOsLogin
   spec:
     etag: CO+9vsAGEIC...
     rules:
     - enforce: true
     updateTime: '2026-09-08T11:42:07.331Z'
   ```

5. Aplicá una **restricción de lista** que bloquee la vía de exposición de datos más común del mundo real — IPs públicas en Cloud SQL — y una restricción de dominio que bloquee por completo las identidades externas:

   ```yaml
   # orgpolicy-list-constraints.yaml
   name: projects/cdl-sec-lab/policies/sql.restrictPublicIp
   spec:
     rules:
     - enforce: true
   ```

   ```bash
   gcloud org-policies set-policy orgpolicy-list-constraints.yaml
   gcloud org-policies list --project="$PROJECT_ID" \
     --format="table(constraint, spec.rules[0].enforce)"
   ```

   ```
   CONSTRAINT                              ENFORCE
   constraints/compute.requireOsLogin      True
   constraints/sql.restrictPublicIp        True
   ```

6. Probá que el guardrail está por encima de tu propio rol de Owner. Intentá una acción que lo viole:

   ```bash
   gcloud compute instances add-metadata resp-demo --zone="${REGION}-b" \
     --metadata=enable-oslogin=FALSE
   gcloud compute instances describe resp-demo --zone="${REGION}-b" \
     --format="value(metadata.items.filter(\"key:enable-oslogin\").extract(value))"
   ```

   La escritura de metadatos tiene éxito, pero OS Login sigue siendo **obligatorio** — la organization policy se evalúa en la capa de la plataforma y la exclusión a nivel de instancia se ignora. Sos Project Owner y aun así no podés deshabilitarlo desde adentro del proyecto.

7. Agregá la capa de denegación. Las **IAM Deny policies** se evalúan *antes* que las políticas de permitir y no pueden ser anuladas por ningún binding de permitir:

   ```json
   {
     "displayName": "Block key deletion outside the custodian group",
     "rules": [
       {
         "denyRule": {
           "deniedPrincipals": ["principalSet://goog/public:all"],
           "exceptionPrincipals": ["principalSet://goog/group/key-custodians@example.com"],
           "deniedPermissions": [
             "cloudkms.googleapis.com/cryptoKeyVersions.destroy",
             "cloudkms.googleapis.com/cryptoKeys.destroy"
           ]
         }
       }
     ]
   }
   ```

   ```bash
   gcloud iam policies create deny-key-destroy \
     --attachment-point="cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}" \
     --kind=denypolicies \
     --policy-file=deny-key-destroy.json
   ```

   ```
   Created policy [deny-key-destroy].
   ```

   > **Trampa:** si tu shell o alguna herramienta no codifica en URL el punto de anclaje, pasalo precodificado como `cloudresourcemanager.googleapis.com%2Fprojects%2F${PROJECT_ID}`. Un punto de anclaje mal formado devuelve `INVALID_ARGUMENT: Invalid attachment point`, no un error de permisos.

### Preguntas de control

**Q9.** Definí separación de funciones y explicá cómo la división entre `roles/cloudkms.admin` y `roles/cloudkms.cryptoKeyEncrypterDecrypter` la implementa. ¿Qué ataque detiene que el mínimo privilegio por sí solo no detiene?

**Q10.** Ordená la evaluación de estos tres controles e indicá la consecuencia práctica de ese orden: política de permitir de IAM, política de denegar de IAM, restricción de Organization Policy.

**Q11.** Clasificá cada uno como **preventivo** o **detectivo**: (a) `constraints/sql.restrictPublicIp`, (b) un hallazgo `PUBLIC_BUCKET_ACL` de Security Command Center, (c) una IAM deny policy, (d) una entrada de Cloud Audit Log, (e) VPC Service Controls en modo aplicado.

**Q12.** Explicá la **defensa en profundidad** usando exactamente las capas que construiste en los ejercicios 2 y 3, de la más externa a la más interna.

---

## Ejercicio 4 — Cifrado: en reposo, en tránsito, y quién tiene la clave

**Concepto evaluado:** el cifrado está **activado por defecto y no es opcional**; CMEK/CSEK/EKM cambian *quién controla la clave*, no *si el cifrado ocurre*. Esta distinción se evalúa de forma directa.

### Pasos

1. Creá un bucket y observá que ya está cifrado con **claves administradas por Google** — no hiciste nada para pedirlo:

   ```bash
   export BUCKET="gs://cdl-sec-lab-${PROJECT_NUMBER}"
   gcloud storage buckets create "$BUCKET" \
     --location="$REGION" \
     --uniform-bucket-level-access \
     --public-access-prevention

   gcloud storage buckets describe "$BUCKET" \
     --format="yaml(name, location, default_kms_key, iamConfiguration)"
   ```

   ```yaml
   default_kms_key: null
   iamConfiguration:
     publicAccessPrevention: enforced
     uniformBucketLevelAccess:
       enabled: true
       lockedTime: '2026-09-08T11:50:12.004Z'
   location: EUROPE-WEST1
   name: cdl-sec-lab-482913746215
   ```

   `default_kms_key: null` **no** significa "sin cifrar". Significa lo predeterminado: Google genera, rota y almacena la clave de cifrado de datos (DEK), envuelta por una clave de cifrado de claves (KEK) en el KMS interno de Google. AES-256 en reposo, siempre, sin costo y sin interruptor.

2. Tomá el control de la KEK — **CMEK**. Creá un key ring y una clave con rotación:

   ```bash
   gcloud kms keyrings create cdl-sec-ring --location="$REGION"

   gcloud kms keys create bucket-cmek \
     --location="$REGION" \
     --keyring=cdl-sec-ring \
     --purpose=encryption \
     --rotation-period=90d \
     --next-rotation-time="$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"

   gcloud kms keys describe bucket-cmek \
     --location="$REGION" --keyring=cdl-sec-ring \
     --format="yaml(name, purpose, rotationPeriod, nextRotationTime, versionTemplate)"
   ```

   ```yaml
   name: projects/cdl-sec-lab/locations/europe-west1/keyRings/cdl-sec-ring/cryptoKeys/bucket-cmek
   nextRotationTime: '2026-12-07T11:55:00Z'
   purpose: ENCRYPT_DECRYPT
   rotationPeriod: 7776000s
   versionTemplate:
     algorithm: GOOGLE_SYMMETRIC_ENCRYPTION
     protectionLevel: SOFTWARE
   ```

3. Otorgale al **agente de servicio de Cloud Storage** — no a vos mismo — permiso para usar la clave. Olvidarse de esto es el fallo número uno de CMEK:

   ```bash
   export GCS_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"

   gcloud kms keys add-iam-policy-binding bucket-cmek \
     --location="$REGION" --keyring=cdl-sec-ring \
     --member="serviceAccount:${GCS_AGENT}" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
   ```

   ```
   Updated IAM policy for key [bucket-cmek].
   bindings:
   - members:
     - serviceAccount:service-482913746215@gs-project-accounts.iam.gserviceaccount.com
     role: roles/cloudkms.cryptoKeyEncrypterDecrypter
   ```

4. Asociá la clave y comprobá que surtió efecto sobre un objeto nuevo:

   ```bash
   gcloud storage buckets update "$BUCKET" \
     --default-encryption-key="projects/${PROJECT_ID}/locations/${REGION}/keyRings/cdl-sec-ring/cryptoKeys/bucket-cmek"

   echo "classified payload" > sample.txt
   gcloud storage cp sample.txt "${BUCKET}/sample.txt"

   gcloud storage objects describe "${BUCKET}/sample.txt" \
     --format="yaml(name, kms_key, storage_class)"
   ```

   ```yaml
   kms_key: projects/cdl-sec-lab/locations/europe-west1/keyRings/cdl-sec-ring/cryptoKeys/bucket-cmek/cryptoKeyVersions/1
   name: sample.txt
   storage_class: STANDARD
   ```

5. Ejercé el control que acabás de comprar. Deshabilitá la versión de la clave y observá que los datos se vuelven **criptográficamente inalcanzables** — también para Google:

   ```bash
   gcloud kms keys versions disable 1 \
     --key=bucket-cmek --keyring=cdl-sec-ring --location="$REGION"

   gcloud storage cat "${BUCKET}/sample.txt"
   ```

   ```
   ERROR: (gcloud.storage.cat) HTTPError 400: Cloud KMS error when decrypting
   the object: The key used to encrypt this object has been disabled or destroyed.
   ```

   Volvé a habilitarla para continuar:

   ```bash
   gcloud kms keys versions enable 1 \
     --key=bucket-cmek --keyring=cdl-sec-ring --location="$REGION"
   gcloud storage cat "${BUCKET}/sample.txt"
   ```

   ```
   classified payload
   ```

6. Observá el **cifrado en tránsito**. Todo endpoint de API de Google Cloud es solo TLS; no hay un puerto en texto plano al que caer:

   ```bash
   curl -sS -o /dev/null -w "http=%{http_code} tls=%{ssl_verify_result}\n" \
     https://storage.googleapis.com/storage/v1/b/${BUCKET#gs://}
   curl -sS --max-time 5 http://storage.googleapis.com/ -o /dev/null -w "%{http_code}\n" 2>&1 | tail -1
   ```

   ```
   http=401 tls=0
   301
   ```

   El `401` (y no `000`) prueba que el handshake TLS se completó y que la verificación del certificado devolvió `0`; la solicitud fue rechazada por *autenticación*, no por transporte. El HTTP plano se redirige con `301` a HTTPS, nunca se sirve.

7. Compará los tres modelos de control de claves sin ejecutarlos (CSEK y Cloud EKM requieren material externo). Prestá atención a la diferencia de sintaxis:

   ```bash
   # CSEK — you supply the raw AES-256 key, base64-encoded. Google never stores it.
   # Lose it and the data is unrecoverable, with no support path.
   gcloud storage cp secret.txt "${BUCKET}/secret.txt" \
     --encryption-key="$(openssl rand -base64 32)"    # <-- keep this string or lose the object
   ```

### Preguntas de control

**Q13.** ¿Están cifrados en reposo los datos en Cloud Storage cuando `default_kms_key` es `null`? Respondé sí/no y explicá qué indica realmente ese campo.

**Q14.** Distinguí las claves administradas por Google, **CMEK**, **CSEK** y **Cloud EKM** en dos ejes: *dónde vive el material de la clave* y *quién puede volver ilegibles los datos*.

**Q15.** En el paso 5, deshabilitar una versión de clave dejó el objeto ilegible. Nombrá el requisito de cumplimiento que satisface esta capacidad y el riesgo operativo que introduce.

**Q16.** Un regulador pregunta: "¿Puede un empleado de Google leer nuestros datos de Cloud Storage?" Dá la respuesta por capas, nombrando los mecanismos de transparencia y de control de acceso implicados.

**Q17.** ¿Por qué el binding de CMEK fue a `service-<PROJECT_NUMBER>@gs-project-accounts.iam.gserviceaccount.com` y no a tu propia cuenta de usuario?

---

## Ejercicio 5 — Residencia de datos, soberanía de datos y privacidad

**Concepto evaluado:** residencia (*dónde están los bytes*), soberanía (*qué ley los gobierna y quién puede obligar al acceso*) y privacidad (*de quién son los datos*). El examen trata estas como tres palabras distintas.

### Pasos

1. Comprobá que la residencia es una propiedad que elegís y podés verificar:

   ```bash
   gcloud storage buckets describe "$BUCKET" \
     --format="value(location, location_type, custom_placement_config)"
   ```

   ```
   EUROPE-WEST1    region
   ```

2. Aplicá la residencia a nivel de toda la organización para que no quede librada a quien ejecute `gcloud`:

   ```yaml
   # orgpolicy-resource-locations.yaml
   name: projects/cdl-sec-lab/policies/gcp.resourceLocations
   spec:
     rules:
     - values:
         allowedValues:
         - in:eu-locations
   ```

   ```bash
   gcloud org-policies set-policy orgpolicy-resource-locations.yaml
   gcloud org-policies describe constraints/gcp.resourceLocations \
     --project="$PROJECT_ID" --effective
   ```

   ```
   name: projects/cdl-sec-lab/policies/gcp.resourceLocations
   spec:
     rules:
     - values:
         allowedValues:
         - in:eu-locations
   ```

3. Probalo. Un bucket fuera del grupo de valores de la UE ahora debe ser rechazado:

   ```bash
   gcloud storage buckets create "gs://cdl-sec-lab-us-${PROJECT_NUMBER}" --location=us-central1
   ```

   ```
   ERROR: (gcloud.storage.buckets.create) HTTPError 412: Constraint
   constraints/gcp.resourceLocations violated for projects/cdl-sec-lab attempting
   to create a bucket in us-central1. See https://cloud.google.com/resource-manager/docs/organization-policy/defining-locations
   ```

   El HTTP **412 Precondition Failed** es la firma de una denegación por organization policy — distinguilo del `403 PERMISSION_DENIED` (IAM) al hacer triaje.

4. Inspeccioná los controles de soberanía sin comprarlos. **Assured Workloads** agrega garantías de acceso de personal, de ubicación del personal de soporte y de controles del proveedor por encima de la residencia:

   ```bash
   gcloud assured workloads list \
     --organization=YOUR_ORG_ID --location=europe-west1 2>&1 | head -5
   ```

   ```
   Listed 0 items.
   ```

   *¿No tenés organización?* Leé en cambio el catálogo de controles:

   ```bash
   gcloud alpha assured locations list 2>&1 | head -5
   ```

5. Inventariá por dónde podrían filtrarse datos personales, usando Cloud Asset Inventory como un barrido de privacidad gratuito a nivel de toda la organización:

   ```bash
   gcloud asset search-all-iam-policies \
     --scope="projects/${PROJECT_ID}" \
     --query="policy:(allUsers OR allAuthenticatedUsers)" \
     --format="table(resource, policy.bindings.role)"
   ```

   ```
   Listed 0 items.
   ```

   Un resultado vacío acá es el desenlace que querés. Cualquier fila es un hallazgo de exposición pública.

### Preguntas de control

**Q18.** Definí residencia de datos, soberanía de datos y privacidad de datos, y dá un control de Google Cloud que aborde principalmente cada uno.

**Q19.** En el paso 3 el fallo fue HTTP `412`, no `403`. ¿Qué te dice cada estado sobre *cuál* control bloqueó la solicitud, y cómo cambia eso tu remediación?

**Q20.** Un cliente europeo almacena datos en `europe-west1` y pregunta si eso solo satisface los requisitos de soberanía digital. Respondé, y nombrá las dos dimensiones adicionales que Assured Workloads aborda más allá de la ubicación de los bytes.

**Q21.** Bajo los principios de confianza de Google Cloud, ¿quién es dueño de los datos del cliente, y a qué se compromete Google respecto de su uso para publicidad y para entrenamiento?

---

## Ejercicio 6 — Zero trust, el perímetro y las amenazas comunes

**Concepto evaluado:** **zero trust / BeyondCorp** ("nunca confiar, siempre verificar — la red no es el perímetro; la identidad y la postura del dispositivo sí lo son"), más los pares amenaza/mitigación que enumera el examen: DDoS, ataques web de OWASP, exfiltración de datos, phishing/robo de credenciales.

### Pasos — 6a. Cloud Armor contra DDoS y OWASP (a nivel de proyecto, gratuito de crear)

1. Creá una política de seguridad de borde con Adaptive Protection (DDoS de capa 7, basada en ML):

   ```bash
   gcloud compute security-policies create cdl-edge-policy \
     --description="Zero-trust edge: WAF + rate limiting + adaptive DDoS"

   gcloud compute security-policies update cdl-edge-policy \
     --enable-layer7-ddos-defense
   ```

   ```
   Created [https://www.googleapis.com/compute/v1/projects/cdl-sec-lab/global/securityPolicies/cdl-edge-policy].
   Updated [.../securityPolicies/cdl-edge-policy].
   ```

2. Agregá una regla WAF preconfigurada para inyección SQL — vos no escribís las firmas, las mantiene Google a partir del OWASP ModSecurity Core Rule Set:

   ```bash
   gcloud compute security-policies rules create 1000 \
     --security-policy=cdl-edge-policy \
     --expression="evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})" \
     --action=deny-403 \
     --description="Block SQL injection (CRS 3.3, low false-positive tier)"

   gcloud compute security-policies rules create 1100 \
     --security-policy=cdl-edge-policy \
     --expression="evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})" \
     --action=deny-403 \
     --description="Block cross-site scripting"
   ```

3. Agregá limitación de tasa — el control contra el abuso volumétrico:

   ```bash
   gcloud compute security-policies rules create 2000 \
     --security-policy=cdl-edge-policy \
     --src-ip-ranges="*" \
     --action=throttle \
     --rate-limit-threshold-count=100 \
     --rate-limit-threshold-interval-sec=60 \
     --conform-action=allow \
     --exceed-action=deny-429 \
     --enforce-on-key=IP \
     --description="100 req/min per source IP"
   ```

4. Revisá la política ensamblada en orden de evaluación (primero el número de prioridad más bajo):

   ```bash
   gcloud compute security-policies describe cdl-edge-policy \
     --format="table(rules[].priority, rules[].action, rules[].description)"
   ```

   ```
   PRIORITY     ACTION     DESCRIPTION
   1000         deny-403   Block SQL injection (CRS 3.3, low false-positive tier)
   1100         deny-403   Block cross-site scripting
   2000         throttle   100 req/min per source IP
   2147483647   allow      Default rule, higher priority overrides it
   ```

   > La red global de Google absorbe el DDoS volumétrico de **capa 3/4** por defecto y sin cargo, para todos los clientes y sin configuración alguna. Cloud Armor es la capa **7**, consciente de la aplicación, a la que optás por adherirte.

### Pasos — 6b. La identidad como perímetro

5. Inspeccioná la exposición de la VM. En un diseño zero trust **no** abrís el puerto 22 a internet:

   ```bash
   gcloud compute firewall-rules list \
     --format="table(name, network, direction, sourceRanges.list(), allowed[].map().firewall_rule().list())"
   ```

   ```
   NAME                   NETWORK  DIRECTION  SOURCE_RANGES  ALLOWED
   default-allow-ssh      default  INGRESS    0.0.0.0/0      tcp:22
   default-allow-icmp     default  INGRESS    0.0.0.0/0      icmp
   default-allow-internal default  INGRESS    10.128.0.0/9   tcp:0-65535,udp:0-65535,icmp
   ```

   `0.0.0.0/0 → tcp:22` es exactamente el modelo de perímetro de confianza implícita que zero trust reemplaza. Eliminala y usá el **reenvío TCP de IAP**, que intermedia la conexión a través del front end de Google después de verificar la *identidad* y la *autorización IAM*:

   ```bash
   gcloud compute firewall-rules delete default-allow-ssh --quiet

   # IAP's fixed range — the only source that may reach port 22
   gcloud compute firewall-rules create allow-ssh-from-iap \
     --network=default --direction=INGRESS \
     --action=allow --rules=tcp:22 \
     --source-ranges=35.235.240.0/20 \
     --description="Zero trust: SSH only via Identity-Aware Proxy"

   gcloud compute ssh resp-demo --zone="${REGION}-b" --tunnel-through-iap --command="hostname"
   ```

   ```
   External IP address was not found; defaulting to using IAP tunneling.
   resp-demo
   ```

   La VM **no tiene IP externa** (el paso 2 del ejercicio 1 usó `--no-address`) y el firewall ya no confía en internet. El acceso lo otorga el rol IAM `roles/iap.tunnelResourceAccessor`, no la ubicación de red.

6. Inspeccioná el control de exfiltración. **VPC Service Controls** traza un perímetro alrededor de los *servicios de API*, de modo que unas credenciales robadas no puedan extraer datos hacia el proyecto de un atacante:

   ```bash
   gcloud access-context-manager perimeters list \
     --policy=YOUR_ACCESS_POLICY_ID 2>&1 | head -3
   ```

   ```
   Listed 0 items.
   ```

   El patrón de creación seguro para producción es **primero en dry-run** — VPC-SC en modo aplicado rompe pipelines que funcionan, al instante:

   ```bash
   gcloud access-context-manager perimeters dry-run create prod-data-perimeter \
     --policy=YOUR_ACCESS_POLICY_ID \
     --perimeter-title="Prod data perimeter" \
     --perimeter-resources="projects/${PROJECT_NUMBER}" \
     --perimeter-restricted-services="storage.googleapis.com,bigquery.googleapis.com" \
     --perimeter-type=regular
   ```

### Preguntas de control

**Q22.** Enunciá la premisa de zero trust en una oración, y después explicá cómo reemplazar `0.0.0.0/0 → tcp:22` por el reenvío TCP de IAP la implementa. ¿Qué reemplazó a la red como señal de confianza?

**Q23.** ¿Qué protección contra DDoS recibís por defecto, sin configuración y sin cargo, y cuál requiere Cloud Armor? Asigná cada una a una capa OSI.

**Q24.** Emparejá cada amenaza con su mitigación principal en Google Cloud: (a) inyección SQL, (b) inundación volumétrica L3/L4, (c) exfiltración de datos de BigQuery por una cuenta de servicio comprometida, (d) phishing de la contraseña de un administrador, (e) un rol personalizado con permisos excesivos otorgado por un project owner.

**Q25.** IAM protege contra el acceso no autorizado y, sin embargo, VPC Service Controls existe como producto aparte. Dá el escenario concreto que IAM no puede abordar y VPC-SC sí.

**Q26.** ¿Por qué conviene crear los perímetros de VPC Service Controls primero en modo dry-run, y qué produce realmente el dry-run?

---

## Ejercicio 7 — Registro de auditoría: la capa de evidencia

**Concepto evaluado:** los cuatro tipos de Cloud Audit Log, cuáles son gratuitos y siempre activos frente a cuáles hay que habilitar y pagar, y por qué importa la inmutabilidad para el cumplimiento.

### Pasos

1. Leé los logs de Admin Activity — éstos están **siempre activos, no se pueden deshabilitar y son gratuitos**:

   ```bash
   gcloud logging read \
     'logName="projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Factivity"' \
     --limit=3 --freshness=1d \
     --format="table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName, resource.type)"
   ```

   ```
   TIMESTAMP                       PRINCIPAL_EMAIL      METHOD_NAME                         RESOURCE_TYPE
   2026-09-08T11:55:31.882Z        you@example.com      google.cloud.kms.v1.KeyManagementService.CreateCryptoKey  cloudkms_cryptokey
   2026-09-08T11:50:11.204Z        you@example.com      storage.buckets.create              gcs_bucket
   2026-09-08T11:42:07.331Z        you@example.com      SetOrgPolicy                        project
   ```

   Cada acción administrativa de este laboratorio queda registrada con **quién**, **qué**, **cuándo** y **desde dónde** — sin que configures nada.

2. Confirmá que los logs de Data Access están **desactivados por defecto** (excepto BigQuery) — son de alto volumen y facturables:

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" --format="yaml(auditConfigs)"
   ```

   ```yaml
   auditConfigs: null
   ```

3. Habilitá el logging de Data Access solo para Cloud Storage, exceptuando una cuenta de servicio de pipeline ruidosa:

   ```yaml
   # audit-config.yaml  (merge into the full policy before setting)
   auditConfigs:
   - auditLogConfigs:
     - logType: DATA_READ
       exemptedMembers:
       - serviceAccount:etl-pipeline@cdl-sec-lab.iam.gserviceaccount.com
     - logType: DATA_WRITE
     service: storage.googleapis.com
   ```

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" --format=yaml > policy.yaml
   # append the auditConfigs block above to policy.yaml, preserving the etag
   gcloud projects set-iam-policy "$PROJECT_ID" policy.yaml
   ```

   ```
   Updated IAM policy for project [cdl-sec-lab].
   auditConfigs:
   - auditLogConfigs:
     - exemptedMembers:
       - serviceAccount:etl-pipeline@cdl-sec-lab.iam.gserviceaccount.com
       logType: DATA_READ
     - logType: DATA_WRITE
     service: storage.googleapis.com
   ```

4. Generá y recuperá un evento de acceso a datos:

   ```bash
   gcloud storage cat "${BUCKET}/sample.txt" >/dev/null
   sleep 45
   gcloud logging read \
     'logName="projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Fdata_access"
      AND protoPayload.resourceName:"sample.txt"' \
     --limit=1 --freshness=1h \
     --format="yaml(protoPayload.authenticationInfo.principalEmail, protoPayload.methodName, protoPayload.requestMetadata.callerIp)"
   ```

   ```yaml
   protoPayload:
     authenticationInfo:
       principalEmail: you@example.com
     methodName: storage.objects.get
     requestMetadata:
       callerIp: 203.0.113.44
   ```

5. Encontrá la consulta de mayor señal en respuesta a incidentes — **quién cambió los permisos**:

   ```bash
   gcloud logging read \
     'protoPayload.methodName="SetIamPolicy"' \
     --limit=5 --freshness=7d \
     --format="table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.resourceName)"
   ```

### Preguntas de control

**Q27.** Nombrá los cuatro tipos de Cloud Audit Log e indicá, para cada uno, si está habilitado por defecto y si es facturable.

**Q28.** ¿Por qué los logs de Admin Activity no se pueden deshabilitar, ni siquiera por un Project Owner? Encuadrá la respuesta en términos del modelo de responsabilidad compartida.

**Q29.** Tenés que demostrarle a un auditor que nadie leyó un objeto específico el trimestre pasado, pero los logs de Data Access nunca se habilitaron. ¿Qué podés afirmar con veracidad y cuál es la acción correctiva?

**Q30.** Clasificá los Cloud Audit Logs como preventivos, detectivos o correctivos, y explicá por qué las otras dos categorías siguen necesitando controles aparte.

---

## Ejercicio 8 — Diagnosticar un fallo de permisos

**Concepto evaluado:** fluidez operativa con el modelo de acceso. En producción, "ayer funcionaba" suele deberse a una de cinco causas; un líder capaz de nombrarlas se comunica con credibilidad con el equipo de seguridad.

### Pasos

1. Reproducí una denegación suplantando una cuenta de servicio de bajo privilegio:

   ```bash
   gcloud iam service-accounts create lowpriv-tester \
     --display-name="Least-privilege test principal"
   export SA="lowpriv-tester@${PROJECT_ID}.iam.gserviceaccount.com"

   gcloud storage buckets describe "$BUCKET" \
     --impersonate-service-account="$SA"
   ```

   ```
   ERROR: (gcloud.storage.buckets.describe) HTTPError 403: lowpriv-tester@cdl-sec-lab.iam.gserviceaccount.com
   does not have storage.buckets.get access to the Google Cloud Storage bucket.
   Permission 'storage.buckets.get' denied on resource (or it may not exist).
   ```

2. No adivines. Preguntale a **Policy Troubleshooter** qué política produjo esa respuesta:

   ```bash
   gcloud policy-troubleshoot iam \
     "//storage.googleapis.com/projects/_/buckets/${BUCKET#gs://}" \
     --principal-email="$SA" \
     --permission="storage.buckets.get" \
     --format="yaml(access, explainedPolicies[].access, explainedPolicies[].fullResourceName)"
   ```

   ```yaml
   access: NOT_GRANTED
   explainedPolicies:
   - access: NOT_GRANTED
     fullResourceName: //storage.googleapis.com/projects/_/buckets/cdl-sec-lab-482913746215
   - access: NOT_GRANTED
     fullResourceName: //cloudresourcemanager.googleapis.com/projects/cdl-sec-lab
   ```

   Tanto la política del bucket **como** la política heredada del proyecto dicen `NOT_GRANTED` — así que se trata de un binding de permitir faltante, no de una deny policy ni de una organization policy.

3. Otorgá el mínimo que lo arregla, en el alcance más estrecho:

   ```bash
   gcloud storage buckets add-iam-policy-binding "$BUCKET" \
     --member="serviceAccount:${SA}" \
     --role="roles/storage.legacyBucketReader"

   gcloud storage buckets describe "$BUCKET" \
     --impersonate-service-account="$SA" --format="value(name)"
   ```

   ```
   cdl-sec-lab-482913746215
   ```

4. Ejecutá la consulta inversa — **Policy Analyzer** responde "¿a qué puede llegar esta identidad?", que es la pregunta que realmente hacen los auditores:

   ```bash
   gcloud asset analyze-iam-policy \
     --scope="projects/${PROJECT_ID}" \
     --identity="serviceAccount:${SA}" \
     --format="yaml(mainAnalysis.analysisResults[].attachedResourceFullName, mainAnalysis.analysisResults[].iamBinding.role)"
   ```

   ```yaml
   mainAnalysis:
     analysisResults:
     - attachedResourceFullName: //storage.googleapis.com/projects/_/buckets/cdl-sec-lab-482913746215
       iamBinding:
         role: roles/storage.legacyBucketReader
   ```

5. Memorizá la escalera de triaje que produjo este ejercicio — revisá en este orden:

   | # | Causa | Firma | Comando que lo confirma |
   |---|---|---|---|
   | 1 | Binding de permitir faltante | `403` + `NOT_GRANTED` en todas las políticas | `gcloud policy-troubleshoot iam` |
   | 2 | IAM **deny** policy | `403` + `access: DENIED` citando una regla de denegación | `gcloud iam policies list-attached` |
   | 3 | Restricción de Organization Policy | **`412`** + `Constraint ... violated` | `gcloud org-policies describe --effective` |
   | 4 | VPC Service Controls | `403` + `VPC_SERVICE_CONTROLS` + un id de solicitud único | `gcloud logging read 'protoPayload.status.details.violations.type="VPC_SERVICE_CONTROLS"'` |
   | 5 | IAM Condition vencida | Ayer funcionaba, hoy `403`, el binding sigue visible | `get-iam-policy` con `--format=yaml` (requiere política `version: 3`) |
   | 6 | Clave CMEK deshabilitada/destruida | `400` + `Cloud KMS error when decrypting` | `gcloud kms keys versions list` |

### Preguntas de control

**Q31.** Distinguí las preguntas que responden Policy Troubleshooter y Policy Analyzer, e indicá cuál necesita un auditor que pregunta "¿quién puede leer los datos de producción?".

**Q32.** Un job que corrió con éxito durante seis meses empezó a devolver `403` de un día para el otro, sin despliegue y sin ningún cambio de IAM en el log de auditoría. Dá las dos causas más probables de la tabla de triaje y el comando que las distingue.

**Q33.** Un `403` cita `VPC_SERVICE_CONTROLS` con un identificador único. ¿Por qué el mensaje de error es deliberadamente vago sobre *qué* fue bloqueado, y cuál es el paso correcto a seguir?

---

## Ejercicio 9 — Síntesis: mapear el escenario al control

Hacé esto sin ejecutar comandos. Cada fila tiene la forma de un ítem de examen de la sección 5.

| # | Escenario | Nombrá el concepto **y** el producto/control de Google Cloud |
|---|---|---|
| 1 | La página de checkout de un comercio recibe una inundación de 4 Tbps de tráfico UDP | |
| 2 | Los auditores exigen prueba de cada cambio de permisos durante 400 días | |
| 3 | Un banco alemán debe garantizar que ningún ingeniero de soporte radicado en EE. UU. pueda acceder a sus datos | |
| 4 | El `roles/editor` a nivel de proyecto de un contratista que se fue nunca se revocó | |
| 5 | Una clave de cuenta de servicio se filtró en GitHub y se usó para copiar un dataset de BigQuery a un proyecto externo | |
| 6 | Los empleados deben llegar a las apps internas desde portátiles no administradas y sin VPN | |
| 7 | Un proveedor de salud debe poder volver permanentemente ilegibles las historias clínicas cuando se lo pidan | |
| 8 | Los desarrolladores siguen creando instancias de Cloud SQL con IPs públicas | |
| 9 | El equipo de seguridad quiere una única consola que liste malas configuraciones y amenazas activas en toda la organización | |
| 10 | Un formulario de login está siendo sondeado con `' OR 1=1--` | |

### Pregunta de control

**Q34.** Completá la tabla de arriba.

---

## Limpieza

```bash
gcloud compute instances delete resp-demo --zone="${REGION}-b" --quiet
gcloud compute security-policies delete cdl-edge-policy --quiet
gcloud compute firewall-rules delete allow-ssh-from-iap --quiet
gcloud storage rm -r "$BUCKET"
gcloud iam service-accounts delete "$SA" --quiet
gcloud iam roles delete logTriage --project="$PROJECT_ID" --quiet
gcloud iam policies delete deny-key-destroy \
  --attachment-point="cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}" --kind=denypolicies --quiet

# Org policies: reset to inherited, do not leave a project pinned to a stale constraint
for C in compute.requireOsLogin sql.restrictPublicIp gcp.resourceLocations; do
  gcloud org-policies delete "constraints/${C}" --project="$PROJECT_ID" --quiet
done

# KMS: key versions can be scheduled for destruction (24h+ delay);
# key rings and keys are PERMANENT and cannot be deleted. Budget ~$0.06/version/month.
gcloud kms keys versions destroy 1 \
  --key=bucket-cmek --keyring=cdl-sec-ring --location="$REGION" --quiet
```

```
Destroyed key version [1]. It will be destroyed after 2026-09-09T12:31:00Z.
```

---

<details>
<summary><strong>Clave de respuestas — clic para desplegar</strong></summary>

### Ejercicio 1

**A1.** *Seguridad **de** la nube* es todo lo que Google opera y asegura por debajo del límite del servicio: centros de datos, hardware propio (Titan), el hipervisor, el kernel del host, la red global, la destrucción física de los medios. *Seguridad **en** la nube* es todo lo que el cliente configura por encima de ese límite. El lado del cliente siempre incluye, como mínimo, la **clasificación de datos, la gestión de accesos (IAM) y la lógica de la capa de aplicación** — eso nunca se transfiere a Google en ningún modelo de servicio.

**A2.** Parcheo del SO invitado / SO de nodos:

| Servicio | Responsable | Por qué |
|---|---|---|
| Compute Engine | **C** | Elegiste la imagen; corrés `apt upgrade` o la reconstruís |
| GKE Standard | **S** | Google publica imágenes de nodo y canales de auto-actualización; **vos** sos dueño de la ventana de actualización, la configuración de surge y de si la auto-actualización está activada |
| GKE Autopilot | **G** | Google es dueño de los nodos y los parchea; no podés hacer SSH a ellos ni instalar un DaemonSet que requiera privilegios de host |
| Cloud Run | **G** | No existe ningún nodo dentro de tu superficie de responsabilidad |
| BigQuery | **G** | Servicio de analítica totalmente administrado; no hay superficie de SO en absoluto |

GKE Standard y Autopilot difieren porque Autopilot le quita al cliente por completo la configuración a nivel de nodo — el límite de responsabilidad sube junto con la abstracción. Ésa es la regla general: **cuanto más administrado el servicio, más porción del stack asegura Google, y más chica (nunca cero) es la tajada del cliente.**

**A3.** Destino compartido significa que Google no se limita a publicar un límite y dejarte del otro lado — te ayuda activamente a tener éxito de tu lado y comparte el resultado. Tres mecanismos: (1) **configuraciones y blueprints seguros por defecto** (Security Foundations blueprint, Assured Workloads, imágenes base endurecidas, cifrado por defecto) para que el camino seguro sea el camino predeterminado; (2) **programas de protección de riesgos** — ofertas de ciberseguro de aseguradoras socias, tarifadas según tu postura en Security Command Center; (3) **guardrails y herramientas de postura** que Google construye y mantiene para vos (restricciones de Organization Policy, detectores de SCC, recomendaciones de Policy Intelligence). El destino compartido **no** transfiere la responsabilidad legal: bajo regímenes tipo GDPR el cliente es el **responsable del tratamiento** (*data controller*) y Google Cloud es el **encargado del tratamiento** (*data processor*). La responsabilidad contractual y regulatoria sobre los datos en sí sigue siendo del cliente.

**A4.** El error: Cloud Run les quita el SO y el runtime de su responsabilidad, pero **la imagen de contenedor sigue siendo suya**. Todo paquete de SO en la imagen base y toda dependencia de aplicación (npm, PyPI, Maven) puede arrastrar un CVE. Siguen necesitando escaneo de imágenes (Artifact Registry vulnerability scanning / Artifact Analysis), una cadencia de reconstrucción y controles de cadena de suministro (Binary Authorization). El artefacto que carga el CVE es la **imagen de contenedor y sus dependencias**.

### Ejercicio 2

**A5.** Mínimo privilegio: **otorgar a un principal solo los permisos necesarios para realizar su tarea prevista, solo sobre los recursos que necesita, y solo durante el tiempo que los necesita.** Evidencia: `roles/editor` carga aproximadamente **8.000 permisos**, mientras que la tarea "leer objetos de un bucket" necesita **cuatro** (`roles/storage.objectViewer`). Otorgarle Editor a ese analista sobre-concede por un factor de ~2.000 e incluye permisos destructivos (eliminar VMs, modificar bases de datos, alterar redes) totalmente ajenos a la tarea.

**A6.** De mejor a peor: **(c) ≈ (d) > (b) > (a)**.
- (c) `roles/storage.objectViewer` sobre el bucket único — verbos correctos, alcance correcto, y Google lo mantiene a medida que los servicios evolucionan. Ésta es la respuesta correcta.
- (d) es funcionalmente equivalente e igual de ajustada, pero un rol personalizado es **deuda operativa**: tenés que mantenerlo vos mismo a medida que la API agrega permisos, y no va a incorporar automáticamente, por ejemplo, nuevos permisos de managed folders. Preferí un rol predefinido cuando alguno encaje; reservá los personalizados para cuando ninguno lo haga.
- (b) `roles/storage.admin` a nivel de proyecto — verbos equivocados (**escritura y borrado**, incluido `storage.buckets.delete`) y alcance equivocado (**todos** los buckets).
- (a) `roles/owner` — sobre-concesión catastrófica; además le permite al analista cambiar IAM y otorgarse cualquier otra cosa.

**A7.** Una IAM Condition es una **expresión CEL adjunta a un binding de rol**, evaluada en tiempo de solicitud; el binding solo surte efecto cuando la expresión evalúa a verdadero. Más allá de "qué permisos", agrega: **(1) tiempo** — `request.time < timestamp(...)` para acceso con vencimiento o just-in-time, y **(2) recurso** — `resource.name.startsWith(...)` o `resource.type == ...` para acotar un binding a un subconjunto de recursos. (Los atributos de la solicitud, como la IP de origen vía Access Levels, son una tercera dimensión.) Los bindings condicionales requieren la **versión 3** de la política IAM; leer la política en versión 1 los oculta.

**A8.** El `etag` es un token de **control de concurrencia optimista**: `set-iam-policy` tiene éxito solo si el etag que enviás todavía coincide con la política actual del servidor. Ignorarlo — escribir una política armada a partir de una lectura vieja — produce el modo de fallo de **actualización perdida** (*lost update*): la lectura-modificación-escritura del admin B borra silenciosamente el binding que el admin A agregó segundos antes, sin ningún error. Usá siempre `add-iam-policy-binding` / `remove-iam-policy-binding` (que manejan el etag y reintentan), o preservá el etag cuando hagas un `set-iam-policy` completo.

### Ejercicio 3

**A9.** Separación de funciones: **ningún principal debería controlar de punta a punta un flujo de trabajo sensible completo** — quien autoriza no es quien ejecuta, y ninguno de los dos es quien audita. La división de KMS la implementa porque `roles/cloudkms.admin` puede crear, rotar, deshabilitar y programar la destrucción de claves pero **no puede descifrar** (le falta `cryptoKeyVersions.useToDecrypt`), mientras que `roles/cloudkms.cryptoKeyEncrypterDecrypter` puede usar claves sobre datos pero no puede crearlas, deshabilitarlas ni destruirlas.

Qué detiene que el mínimo privilegio por sí solo no detiene: **el abuso interno y el fraude no detectado por parte de un único actor legítimamente privilegiado.** El mínimo privilegio pregunta "¿es este permiso necesario para el trabajo?" — un custodio de claves legítimamente necesita administrar claves, y un operador de datos legítimamente necesita descifrar. Ambas concesiones pasan individualmente una revisión de mínimo privilegio. La SoD es la regla adicional de que no deben recaer sobre el **mismo** principal, porque ese principal podría entonces crear una clave, descifrar datos con ella, exfiltrar y destruir la clave para borrar el rastro. La SoD restringe *combinaciones*; el mínimo privilegio restringe *cantidades*.

**A10.** Orden de evaluación: **Organization Policy → IAM deny policy → IAM allow policy.** Consecuencia práctica: una restricción de Organization Policy no puede ser anulada por *ninguna* concesión de IAM, así que un Project Owner no puede otorgarse una excepción desde adentro del proyecto — solo alguien con `roles/orgpolicy.policyAdmin` en un nodo superior puede cambiarla. Del mismo modo, una regla de denegación le gana a todo binding de permitir, incluido `roles/owner`. Por eso los guardrails son el control correcto para "esto nunca debe pasar", e IAM es el control correcto para "quién puede hacer esto".

**A11.** (a) **Preventivo** — la llamada a la API se rechaza. (b) **Detectivo** — SCC reporta una mala configuración existente después del hecho. (c) **Preventivo**. (d) **Detectivo** — los audit logs registran, no bloquean. (e) **Preventivo** en modo aplicado (en modo dry-run es **detectivo**: registra lo que *habría* sido bloqueado).

**A12.** Defensa en profundidad = **múltiples capas independientes, de modo que ningún fallo o evasión individual alcance**. De la más externa a la más interna, tal como se construyó:
1. **Organization Policy** — `requireOsLogin`, `restrictPublicIp` bloquean clases enteras de configuración insegura antes siquiera de consultar a IAM.
2. **IAM deny policy** — `deny-key-destroy` bloquea permisos peligrosos específicos sin importar ninguna concesión de permitir.
3. **IAM allow policy** — roles predefinidos/personalizados de mínimo privilegio definen quién puede actuar siquiera.
4. **IAM Conditions** — acotan aún más esas concesiones en tiempo y alcance de recursos.
5. **Separación de funciones** entre principales — ni siquiera una única cuenta comprometida puede completar un flujo destructivo entero.
6. **Cloud Audit Logs** — si todas las capas de arriba fallan, la acción igual queda registrada de forma inmutable.

### Ejercicio 4

**A13.** **Sí.** Todos los datos en reposo en Google Cloud están cifrados por defecto con AES-256, sin configuración, sin cargo y sin posibilidad de desactivarlo. `default_kms_key: null` significa únicamente que **no hay una clave administrada por el cliente configurada**, con lo cual Google genera y administra la clave de cifrado de claves en su KMS interno. El campo indica *quién controla la clave*, no *si hay cifrado*.

**A14.**

| Modelo | Dónde vive el material de la clave | Quién puede volver ilegibles los datos |
|---|---|---|
| **Administrada por Google (por defecto)** | El KMS interno de Google; generada, rotada y almacenada por Google | Solo Google (operativamente: nadie, por diseño) |
| **CMEK** (Cloud KMS) | Cloud KMS en *tu* proyecto (SOFTWARE, o HSM para FIPS 140-2 L3) | **Vos** — deshabilitar o destruir una versión de clave bloquea al instante todo descifrado, incluido el de los servicios de Google |
| **CSEK** | **Completamente fuera de Google.** Enviás la clave AES-256 en crudo con cada solicitud; Google la retiene solo en memoria y nunca la persiste | Vos — y cargás en soledad con el riesgo de pérdida: si perdés la clave, los datos son irrecuperables, sin vía de recuperación por soporte |
| **Cloud EKM** | Un socio externo de gestión de claves (Thales, Fortanix, Equinix…) fuera de la infraestructura de Google | Vos, a través del socio externo — podés revocar el acceso a la clave *y* demostrar que la clave nunca residió en instalaciones de Google |

**A15.** El requisito es el **crypto-shredding** (también llamado borrado criptográfico): volver los datos permanentemente ilegibles destruyendo la clave en lugar de sobrescribir los bytes. Satisface el "derecho al olvido"/artículo 17 del GDPR y los mandatos de destrucción de registros a escala, ya que destruir una versión de clave vuelve ilegibles terabytes al instante. El riesgo operativo es la **denegación de servicio autoinfligida y la pérdida permanente de datos**: deshabilitar una clave por error tira producción abajo de inmediato (como en el paso 5), y una destrucción es irreversible una vez pasada la ventana de demora obligatoria. Mitigalo con una IAM deny policy sobre `cryptoKeyVersions.destroy` (construida en el ejercicio 3), la demora mínima de destrucción de 24 horas y alertas sobre eventos administrativos de KMS.

**A16.** Respuesta por capas:
1. **El cifrado en reposo y en tránsito es automático y universal**, y además los datos se fragmentan en chunks, cada uno cifrado por separado y distribuido — no hay un único archivo "tus datos" en un disco.
2. **CMEK/Cloud EKM** te permiten tener la clave, de modo que los sistemas de Google no pueden descifrar si la revocás.
3. **El acceso está denegado por defecto**; los empleados de Google no tienen acceso permanente al contenido del cliente, y el acceso administrativo requiere una justificación documentada y basada en el trabajo.
4. **Access Transparency** produce logs del acceso del personal de Google a tu contenido, con el motivo y la referencia del ticket — lo ves ocurrir.
5. **Access Approval** va más allá: Google debe solicitar tu **aprobación explícita** antes de que ese acceso ocurra, y podés denegarla.
6. **Assured Workloads** puede además restringir al personal de soporte a nacionalidades y geografías específicas.

**A17.** Porque es Cloud Storage — no vos — quien realiza el cifrado y el descifrado. Cuando el bucket tiene una CMEK, el **agente de servicio**, una cuenta de servicio administrada por Google creada automáticamente por proyecto y por servicio, llama a Cloud KMS en nombre del bucket. Otorgarte a vos mismo `cryptoKeyEncrypterDecrypter` te permite llamar a KMS directamente, pero no hace nada por el servicio, así que las escrituras fallan con `Permission denied on Cloud KMS key`. Esto también es un patrón de mínimo privilegio: la concesión está acotada a una clave y a una identidad de servicio, no a una persona.

### Ejercicio 5

**A18.**
- **Residencia de datos** — la *ubicación física/geográfica* donde los datos se almacenan y procesan. Control: `constraints/gcp.resourceLocations` más elegir recursos regionales (no multirregionales).
- **Soberanía de datos** — *qué jurisdicción y qué leyes gobiernan los datos y quién puede obligar legalmente al acceso*, incluida la nacionalidad y la ubicación del personal que puede tocarlos. Control: **Assured Workloads**, **Cloud EKM**, **Access Approval** y ofertas de socios soberanos.
- **Privacidad de datos** — *de quién son los datos personales y qué límites hay a su uso*. Control: **Cloud DLP / Sensitive Data Protection** para descubrimiento, clasificación y desidentificación, más IAM y VPC Service Controls para limitar quién puede alcanzarlos, y los principios contractuales de confianza de Google.

**A19.** `403 PERMISSION_DENIED` significa que decidió **IAM**: al principal le falta un permiso requerido, o coincidió una regla de denegación. Remediación: otorgar el rol correcto en el alcance correcto, o enmendar la deny policy. `412 Precondition Failed` con `Constraint ... violated` significa que una **Organization Policy** bloqueó la solicitud *antes* de consultar a IAM. La remediación es completamente distinta: ningún cambio de IAM lo arregla — hay que modificar la restricción en el nodo de organización/carpeta/proyecto con `roles/orgpolicy.policyAdmin`, o cumplir con la restricción (elegir una ubicación permitida). Confundir ambas manda a los equipos a horas de depuración inútil de IAM.

**A20.** Elegir la región da **residencia**, no **soberanía**. La soberanía agrega: **(1) controles de personal** — restringir qué personal de soporte y de operaciones de Google puede acceder a los datos, por nacionalidad y por ubicación física (soberanía de datos de las *operaciones*); y **(2) supervivencia y soberanía de claves y software** — la capacidad del cliente de controlar las claves de cifrado fuera de la infraestructura de Google (Cloud EKM), aprobar o denegar cada acceso administrativo (Access Approval) y, en las ofertas más fuertes, operar bajo un socio local de modo que ningún proceso legal extranjero pueda obligar a la divulgación. Assured Workloads empaqueta todo esto como un régimen de cumplimiento aplicado a una carpeta, con monitoreo continuo que señala las desviaciones.

**A21.** **El cliente es dueño de sus datos, no Google.** Los principios de confianza declarados por Google se comprometen a que: los datos del cliente no se usan para publicidad; los datos del cliente no se venden a terceros; Google no usa los datos del cliente para entrenar sus modelos sin permiso; los clientes controlan dónde se almacenan los datos y pueden exportarlos o eliminarlos en cualquier momento; el acceso del personal de Google es limitado, justificado y registrado (Access Transparency) y requiere aprobación del cliente donde Access Approval esté habilitado; y Google publica sus certificaciones de cumplimiento (ISO/IEC 27001, 27017, 27018, 27701, SOC 1/2/3, PCI DSS, HIPAA, FedRAMP, GDPR) con informes de auditoría de terceros disponibles en el Compliance Reports Manager.

### Ejercicio 6

**A22.** Zero trust: **ninguna solicitud es confiable por el lugar de donde vino; cada solicitud se autentica, se autoriza y se cifra en función de la identidad, el estado del dispositivo y el contexto, en cada acceso.** La regla `0.0.0.0/0 → tcp:22` es el modelo opuesto — concede alcanzabilidad por *posición de red*, y quien llegue a la IP puede intentar autenticarse. Con el reenvío TCP de IAP, la VM no tiene IP externa y el firewall admite únicamente el rango de IAP de Google (`35.235.240.0/20`); IAP termina la conexión en el front end de Google, verifica la **identidad de Google** de quien llama, comprueba el permiso IAM `iap.tunnelInstances.accessViaIAP` y puede además exigir postura de dispositivo y contexto mediante Access Levels. **La identidad verificada (más el dispositivo y el contexto) reemplazó a la ubicación de red como señal de confianza.** Éste es el modelo BeyondCorp que Google adoptó internamente tras abandonar su propio perímetro de VPN corporativa.

**A23.** El **DDoS volumétrico de capa 3/4** (inundaciones SYN, amplificación UDP, ataques de reflexión) se absorbe **por defecto, de forma automática y sin cargo adicional** gracias a la infraestructura global de front end y la red anycast de Google, para todo lo que esté detrás de los balanceadores de carga de Google — sin configuración alguna. Los **ataques de capa 7, a nivel de aplicación** (inundaciones HTTP, slowloris, abuso específico de la aplicación, inyecciones de OWASP) requieren **Cloud Armor**, cuyo Adaptive Protection usa ML para establecer la línea base del tráfico normal y proponer reglas de mitigación dirigidas, y cuyas reglas WAF preconfiguradas implementan el OWASP Core Rule Set.

**A24.**
- (a) Inyección SQL → regla WAF preconfigurada de **Cloud Armor** (`sqli-v33-stable`), basada en el OWASP CRS.
- (b) Inundación volumétrica L3/L4 → **protección DDoS por defecto de Google** en el balanceador de carga global; agregá Cloud Armor Adaptive Protection para el componente L7.
- (c) Exfiltración por una cuenta de servicio comprometida → **VPC Service Controls** (el perímetro bloquea la llamada a la API hacia un destino fuera de él, incluso con credenciales válidas); apoyarse en **Cloud Armor** *no* es relevante acá.
- (d) Phishing de la contraseña de un administrador → **verificación en dos pasos, idealmente con llaves de seguridad resistentes al phishing (Titan/FIDO2)**, más SSO de Cloud Identity y, para cuentas de alto riesgo, el Programa de Protección Avanzada. El despliegue interno de llaves de seguridad en Google eliminó por completo el phishing de cuentas de empleados.
- (e) Rol personalizado con permisos excesivos → **IAM Recommender / Policy Intelligence** (detectivo: señala permisos sin usar) más **Organization Policy e IAM deny policies** (preventivos), y hallazgos de SCC por privilegios excesivos.

**A25.** IAM responde "**¿tiene permitido este principal realizar esta operación?**" — pero no puede distinguir *hacia dónde va el resultado*. Una cuenta de servicio legítimamente autorizada a leer un dataset de BigQuery, cuya clave es robada, sigue estando autorizada: el atacante usa credenciales válidas para hacer una llamada a la API permitida y copia el dataset a un proyecto que controla. IAM no ve nada malo. **VPC Service Controls** agrega un perímetro de servicio: la API `bigquery.googleapis.com` rechaza las solicitudes que cruzan el límite del perímetro, de modo que esas mismas credenciales válidas fallan al usarse desde afuera — o al usarse para mover datos hacia afuera. Defiende contra **robo de credenciales, exfiltración interna y acceso público mal configurado**, que son precisamente los casos donde IAM está funcionando exactamente como fue configurado.

**A26.** Porque un perímetro de VPC-SC en modo aplicado bloquea **todas** las llamadas a la API que cruzan el límite, de inmediato, y los entornos reales tienen dependencias no documentadas — un job de ingesta de un socio, un pipeline de CI, una herramienta de analítica, un backup en otro proyecto. Aplicarlo a ciegas causa una caída amplia y difícil de diagnosticar. **El modo dry-run produce entradas de log que registran cada solicitud que *habría sido* denegada**, sin denegarla (`protoPayload.metadata.dryRun: true` con detalles de violación de `VPC_SERVICE_CONTROLS`). Lo corrés durante un ciclo de negocio completo, construís a partir de esos logs las reglas de ingreso/egreso y los access levels necesarios, y recién entonces lo promovés a modo aplicado.

### Ejercicio 7

**A27.**

| Tipo de log | Habilitado por defecto | Facturable | Registra |
|---|---|---|---|
| **Admin Activity** | Sí — **siempre activo, no se puede deshabilitar** | **No, gratuito** | Escrituras de configuración/metadatos: `SetIamPolicy`, creación/actualización/eliminación de recursos |
| **Data Access** | **No** (excepción: el acceso a datos de BigQuery está activo por defecto) | **Sí** | Lecturas de datos de usuario y escrituras sobre datos de usuario |
| **System Event** | Sí — siempre activo | **No, gratuito** | Acciones iniciadas por el sistema de Google, p. ej. la migración en vivo automática de una VM |
| **Policy Denied** | Sí, cuando un servicio deniega el acceso por una política de seguridad | **Sí** | Denegaciones de VPC Service Controls y motores de política similares |

**A28.** Porque el logging de Admin Activity está del lado de Google en el límite de responsabilidad — es parte de la **garantía de integridad de la plataforma**, no una funcionalidad configurable por el cliente. Si un Project Owner (o un atacante que llega a serlo) pudiera deshabilitarlo, el log no valdría nada como evidencia: el primer acto de cualquier compromiso sería apagarlo. Hacerlo inmutable y no deshabilitable significa que Google garantiza el rastro de auditoría *de* la nube, mientras que el cliente sigue siendo responsable de **exportarlo y retenerlo** (log sinks a Cloud Storage con retención/Bucket Lock, o a BigQuery), de habilitar los logs opcionales de Data Access y de revisarlos efectivamente. Notá que la retención por defecto de Admin Activity es de 400 días en `_Required`; una retención mayor es trabajo del cliente.

**A29.** Solo podés afirmar con veracidad que **no ocurrió ningún cambio administrativo sobre ese objeto ni sobre sus permisos** (a partir de los logs de Admin Activity) y que **la política IAM del objeto no permitía el acceso a nadie fuera de los bindings registrados** (a partir de la política actual e histórica, vía la API de historial de Cloud Asset Inventory). **No** podés afirmar que nadie lo leyó — la ausencia de logs de Data Access es ausencia de evidencia, no evidencia de ausencia, y decir lo contrario ante un auditor sería una atestación falsa. Acción correctiva: habilitar ahora la configuración de auditoría `DATA_READ`/`DATA_WRITE` para los servicios pertinentes (paso 3 del ejercicio 7), configurar un log sink hacia un bucket de Cloud Storage con retención bloqueada o hacia BigQuery por el período requerido, presupuestar el volumen de logs, usar `exemptedMembers` para cuentas de servicio de alto volumen y no sensibles, y documentar el hueco y sus fechas de inicio/fin en la respuesta a la auditoría.

**A30.** Los Cloud Audit Logs son **detectivos**. Registran lo que pasó; nunca bloquean ni reparan nada. Siguen haciendo falta controles preventivos porque una entrada de log no detiene la exfiltración que registra — para eso están Organization Policy, IAM deny policies, VPC-SC y las reglas de firewall. Y siguen haciendo falta controles correctivos porque detectar sin responder deja el daño en pie — para eso hacen falta alertas sobre métricas basadas en logs, remediación automatizada (Cloud Functions disparadas por Pub/Sub desde un log sink o desde un hallazgo de SCC), rotación de claves, revocación de credenciales y restauración desde backup. Las tres categorías son complementarias, y **la defensa en profundidad requiere las tres**.

### Ejercicio 8

**A31.** **Policy Troubleshooter** responde una consulta *hacia adelante, de pregunta única*: "**¿Por qué** el principal P tiene (o no tiene) el permiso X sobre el recurso R?" — recorre cada política de la cadena de herencia y muestra cuál produjo el veredicto. Es la herramienta de depuración. **Policy Analyzer** (Cloud Asset Inventory) responde la consulta *inversa, de conjunto*: "**¿Qué** principales pueden hacer **qué** sobre **qué** recursos dentro de este alcance?" — podés fijar cualquiera de los tres ejes, dos, o ninguno. El auditor que pregunta "¿quién puede leer los datos de producción?" necesita **Policy Analyzer**, fijando el recurso y el permiso y pidiendo el conjunto de identidades, incluido el acceso heredado de grupos y de carpetas ancestro.

**A32.** Las dos causas más probables son **(5) una IAM Condition vencida** y **(6) una versión de clave CMEK deshabilitada o destruida** — ambas cambian el acceso efectivo sin que aparezca ninguna escritura nueva de IAM en el log de auditoría. Un tercer candidato fuerte es el **vencimiento de una clave de cuenta de servicio o la deshabilitación de la cuenta de servicio**. Distinguilas primero por el error en sí: un fallo de CMEK devuelve **`400` con `Cloud KMS error when decrypting`**, no `403`. Ante la sospecha de una condición vencida, ejecutá:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --format="yaml(bindings)" | grep -A4 'condition:'
```

Leer la política sin solicitar la versión 3 no va a mostrar los bindings condicionales en absoluto — que es exactamente por qué esta causa se pasa por alto tan seguido. Confirmalo con `gcloud policy-troubleshoot iam`, que evalúa las condiciones contra la hora actual de la solicitud e informa `CONDITIONAL` / `NOT_GRANTED`.

**A33.** El mensaje es deliberadamente vago — da un identificador único y ningún detalle sobre el perímetro, el recurso o la regla — porque **el error en sí no debe convertirse en un canal de divulgación de información**. Un mensaje verboso le diría a un atacante con credenciales robadas que el recurso existe, qué perímetro lo protege y qué servicio está restringido, permitiéndole mapear el entorno a fuerza de sondeos. El paso correcto es entregarle ese **identificador único de solicitud** a alguien con permiso para leer los logs de violaciones del perímetro, quien consulta:

```bash
gcloud logging read \
  'protoPayload.status.details.violations.type="VPC_SERVICE_CONTROLS"' \
  --freshness=1h --format=json
```

La entrada de log — visible solo para principales autorizados — contiene el nombre del perímetro, la regla de ingreso/egreso violada y la identidad de quien llamó.

### Ejercicio 9

**A34.**

| # | Concepto | Control |
|---|---|---|
| 1 | DDoS volumétrico L3/L4 | **Protección DDoS por defecto** de Google en el balanceador de carga externo global (gratuita, automática); **Cloud Armor Adaptive Protection** para el componente L7 |
| 2 | Auditabilidad / no repudio | **Cloud Audit Logs** (Admin Activity, inmutables) exportados mediante un **log sink** a Cloud Storage con **Bucket Lock**/política de retención, o a BigQuery |
| 3 | Soberanía de datos (controles de personal) | **Assured Workloads** (regiones de la UE + controles de soporte con personal de la UE), reforzado por **Access Approval**, **Access Transparency** y **Cloud EKM** |
| 4 | Mínimo privilegio / acceso obsoleto | **IAM Recommender** (Policy Intelligence) para sacar a la luz permisos sin usar; **IAM Conditions** con vencimiento para prevenir la reincidencia; baja del personal vía **Cloud Identity** para deshabilitar el principal |
| 5 | Exfiltración de datos con credenciales válidas | Perímetro de **VPC Service Controls** alrededor de `bigquery.googleapis.com`; prevení la causa raíz con **restricciones sobre claves de cuenta de servicio** (`constraints/iam.disableServiceAccountKeyCreation`) y **Workload Identity Federation** en lugar de claves descargables |
| 6 | Zero trust / BeyondCorp | **Identity-Aware Proxy** con access levels de **BeyondCorp Enterprise** (identidad + postura del dispositivo + contexto), sin VPN |
| 7 | Crypto-shredding / derecho al olvido | **CMEK** en Cloud KMS — destruir la versión de la clave para volver los datos permanentemente ilegibles |
| 8 | Guardrail preventivo | Organization Policy **`constraints/sql.restrictPublicIp`** |
| 9 | Gestión centralizada de postura y amenazas | **Security Command Center** (niveles Premium/Enterprise para Event Threat Detection, Security Health Analytics y simulación de rutas de ataque) |
| 10 | Ataque de inyección de OWASP | Regla WAF preconfigurada `sqli-v33-stable` de **Cloud Armor** |

</details>

---

## Fuentes

- Google Cloud, *Cloud Digital Leader Certification Exam Guide* — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Google Cloud, *Shared responsibilities and shared fate on Google Cloud* — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google Cloud, *IAM overview* — https://cloud.google.com/iam/docs/overview
- Google Cloud, *IAM Conditions overview* — https://cloud.google.com/iam/docs/conditions-overview
- Google Cloud, *Deny policies* — https://cloud.google.com/iam/docs/deny-overview
- Google Cloud, *Organization Policy Service* — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Google Cloud, *Restricting resource locations* — https://cloud.google.com/resource-manager/docs/organization-policy/defining-locations
- Google Cloud, *Default encryption at rest* — https://cloud.google.com/docs/security/encryption/default-encryption
- Google Cloud, *Encryption in transit* — https://cloud.google.com/docs/security/encryption-in-transit
- Google Cloud, *Customer-managed encryption keys (CMEK)* — https://cloud.google.com/kms/docs/cmek
- Google Cloud, *Cloud External Key Manager* — https://cloud.google.com/kms/docs/ekm
- Google Cloud, *Assured Workloads overview* — https://cloud.google.com/assured-workloads/docs/overview
- Google Cloud, *Access Transparency / Access Approval* — https://cloud.google.com/assured-workloads/access-approval/docs/overview
- Google Cloud, *Cloud Audit Logs overview* — https://cloud.google.com/logging/docs/audit
- Google Cloud, *VPC Service Controls overview* — https://cloud.google.com/vpc-service-controls/docs/overview
- Google Cloud, *Identity-Aware Proxy: TCP forwarding* — https://cloud.google.com/iap/docs/using-tcp-forwarding
- Google Cloud, *BeyondCorp Enterprise* — https://cloud.google.com/beyondcorp-enterprise/docs/overview
- Google Cloud, *Cloud Armor: preconfigured WAF rules* — https://cloud.google.com/armor/docs/waf-rules
- Google Cloud, *Cloud Armor Adaptive Protection* — https://cloud.google.com/armor/docs/adaptive-protection-overview
- Google Cloud, *Security Command Center overview* — https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Google Cloud, *Policy Troubleshooter / Policy Analyzer* — https://cloud.google.com/policy-intelligence/docs/troubleshoot-access
- Google Cloud, *Trust principles* — https://cloud.google.com/security/transparency