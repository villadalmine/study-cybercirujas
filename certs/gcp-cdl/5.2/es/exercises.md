# Tema 5.2 — Ejercicios guiados

## Describir el valor de negocio de hacer que Google forme parte del equipo de seguridad de una organización: defensa en profundidad y un enfoque multicapa de la seguridad en la nube

**Certificación:** Google Cloud Digital Leader (versión de examen 2026-08-12)
**Peso del dominio:** 9.0
**Referencia principal:** [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

---

## Cómo usar este documento

Cada ejercicio es una **capa** de la pila de defensa en profundidad. Ejecutás la capa, observás lo que Google ya hizo por vos y después respondés la pregunta de negocio que el examen realmente hace: *¿qué le compró esa capa a la organización?*

El examen de Cloud Digital Leader no es un examen práctico. Igual vas a correr estos comandos, porque "Google forma parte de tu equipo de seguridad" es un eslogan vacío hasta que viste un bucket cifrado sin que hicieras nada, una org policy bloqueando un error que todavía no ocurrió y Security Command Center nombrando una mala configuración que no sabías que tenías.

### Requisitos previos

| Requisito | Por qué |
|---|---|
| Un proyecto de Google Cloud con facturación habilitada | Los ejercicios 4, 5 y 8 crean recursos facturables |
| `gcloud` CLI ≥ 470.0.0, autenticado | Todos los ejercicios |
| Roles a nivel de organización (`roles/orgpolicy.policyAdmin`, `roles/securitycenter.admin`, `roles/accesscontextmanager.policyAdmin`) | Ejercicios 2, 5, 6 |
| Una organización de Cloud Identity o Workspace | Ejercicios 2, 3, 5, 6, 9 |

> **Si no tenés nodo de organización** (una cuenta personal de `gmail.com` crea proyectos sin padre), los pasos con alcance de organización están marcados con **`[ORG]`**. Leelos, ejecutá la alternativa con alcance de proyecto que se indica en cada bloque y respondé las preguntas a partir de la documentación. El razonamiento de negocio es la parte examinable; el nodo de organización no lo es.

> **Advertencia de costos.** El ejercicio 4 crea un key ring de Cloud KMS — **los key rings y las claves no se pueden eliminar**, solo se destruyen sus versiones de clave, y cada versión activa factura mensualmente. El ejercicio 8 crea una Confidential VM (un sobreprecio respecto del precio estándar de N2D). Eliminá la VM cuando termines. Todo lo demás en este documento es gratuito o de capa gratuita.

### Definí tus variables de trabajo

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export ORG_ID="$(gcloud organizations list --format='value(ID)' | head -n1)"   # [ORG]
export REGION="us-central1"
export ZONE="us-central1-a"
echo "project=$PROJECT_ID number=$PROJECT_NUMBER org=${ORG_ID:-<none>}"
```

---

## Ejercicio 1 — Encontrar el trabajo de seguridad que Google ya hizo antes de que iniciaras sesión

**Capa:** infraestructura y criptografía
**Pregunta de negocio:** ¿cuál es el valor de un control que no tuviste que construir, dotar de personal ni auditar?

### Pasos

1. Creá un bucket sin ninguna bandera de seguridad — la acción más perezosa posible:

    ```bash
    gcloud storage buckets create "gs://${PROJECT_ID}-defaults" --location="$REGION"
    ```

2. Preguntá qué cifrado usa ese bucket:

    ```bash
    gcloud storage buckets describe "gs://${PROJECT_ID}-defaults" \
      --format="json(name, location, default_kms_key, uniform_bucket_level_access)"
    ```

    Salida ilustrativa:

    ```json
    {
      "name": "example-proj-defaults",
      "location": "US-CENTRAL1",
      "uniform_bucket_level_access": {
        "enabled": true,
        "lockedTime": "2026-12-07T00:00:00.000Z"
      }
    }
    ```

3. Fijate en lo que **falta** en esa salida: no hay `default_kms_key` ni bloque `encryption`. Ahora leé la declaración de la plataforma sobre lo que le pasa a esos datos de todos modos:

    > *"Cloud Storage always encrypts your data on the server side, before it is written to disk, at no additional charge."*
    > — [Default encryption at rest](https://cloud.google.com/docs/security/encryption/default-encryption)

4. Subí un objeto y confirmá que el cifrado del lado del servidor se reporta por objeto:

    ```bash
    echo "layer-1 test" > /tmp/l1.txt
    gcloud storage cp /tmp/l1.txt "gs://${PROJECT_ID}-defaults/l1.txt"
    gcloud storage objects describe "gs://${PROJECT_ID}-defaults/l1.txt" \
      --format="json(name, size, storage_class, crc32c_hash, customer_encryption)"
    ```

5. Inspeccioná qué protege esos mismos datos *en movimiento*. Trazá una petición desde tu estación de trabajo hacia la API y observá dónde termina el TLS:

    ```bash
    curl -sS -o /dev/null -w 'http=%{http_code} tls=%{ssl_verify_result} ip=%{remote_ip}\n' \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://storage.googleapis.com/storage/v1/b/${PROJECT_ID}-defaults"
    ```

    Salida ilustrativa:

    ```
    http=200 tls=0 ip=142.250.65.80
    ```

    Esa IP es un **Google Front End (GFE)**, no los servidores de almacenamiento. El GFE termina el TLS, absorbe el DoS volumétrico y reenvía la petición por el backbone privado de Google usando **ALTS** (Application Layer Transport Security), el cifrado RPC interno con autenticación mutua de Google. Ver [Encryption in transit](https://cloud.google.com/docs/security/encryption-in-transit) y [Google infrastructure security design](https://cloud.google.com/docs/security/infrastructure/design).

6. Anotá, en papel, la lista de controles que **no** configuraste pero que ahora están protegiendo este bucket. Una lista correcta incluye como mínimo: cifrado AES-256 en reposo con claves de cifrado de datos por chunk; envoltura y rotación de claves en el KMS interno de Google; terminación TLS en el GFE con un certificado gestionado por Google; ALTS en el salto interno; absorción de DDoS en el edge; raíz de confianza en hardware (**Titan**) atestiguando las máquinas que sirven la petición; seguridad física del centro de datos; arranque seguro y procedencia del firmware del host.

### Verificá tu comprensión

**Q1.1** La salida de `describe` no mostró ningún campo `encryption`. Explicá en una frase por qué eso *no* es evidencia de que el objeto esté sin cifrar, y qué indica realmente la ausencia del campo.

**Q1.2** Un CFO pregunta: "Ya pagamos un producto de cifrado de disco on-premises. ¿Por qué el cifrado por defecto de Google es un beneficio *de negocio* y no solo técnico?" Dá dos argumentos de negocio distintos.

**Q1.3** Nombrá los tres estados de cifrado en los que pueden estar los datos de una carga de trabajo, y decí cuál de los tres *no* está cubierto por los valores por defecto que acabás de observar.

**Q1.4** El auditor de tu organización pide evidencia de que Google cifra el tráfico entre sus propios centros de datos. ¿Qué dos artefactos presentarías — uno el nombre de una tecnología, otro una clase de documento — sin necesidad de ejecutar nada en tu proyecto?

---

## Ejercicio 2 — La capa de gobernanza: prevenir el error que todavía no ocurrió

**Capa:** guardrails preventivos
**Pregunta de negocio:** ¿cuánto vale un control que hace imposible toda una clase de incidente, en toda la organización, de forma permanente?

### Pasos

1. **`[ORG]`** Listá las restricciones disponibles en tu organización:

    ```bash
    gcloud org-policies list --organization="$ORG_ID"
    ```

2. Preguntá cuál es la política *efectiva* para direcciones IP públicas en VMs — "efectiva" significa el valor una vez resuelta la herencia hacia abajo en la jerarquía:

    ```bash
    gcloud org-policies describe constraints/compute.vmExternalIpAccess \
      --organization="$ORG_ID" --effective
    ```

    Salida ilustrativa en una organización sin endurecer:

    ```yaml
    name: organizations/123456789012/policies/compute.vmExternalIpAccess
    spec:
      rules:
      - allowValues:
        - ALLOW_ALL
    ```

3. **Alternativa con alcance de proyecto si no tenés nodo de organización** — todos los comandos de abajo funcionan con `--project="$PROJECT_ID"` en lugar de `--organization="$ORG_ID"`. La lección es idéntica; solo cambia el radio de impacto del guardrail.

4. Escribí una política que frene la fuga de credenciales de nube más común — service account keys de larga vida subidas a un repositorio:

    ```bash
    cat > /tmp/no-sa-keys.yaml <<EOF
    name: organizations/${ORG_ID}/policies/iam.disableServiceAccountKeyCreation
    spec:
      rules:
      - enforce: true
    EOF
    gcloud org-policies set-policy /tmp/no-sa-keys.yaml
    ```

5. Comprobá que el guardrail funciona intentando violarlo:

    ```bash
    gcloud iam service-accounts create leaky-sa --display-name="Guardrail test" || true
    gcloud iam service-accounts keys create /tmp/leak.json \
      --iam-account="leaky-sa@${PROJECT_ID}.iam.gserviceaccount.com"
    ```

    Salida ilustrativa:

    ```
    ERROR: (gcloud.iam.service-accounts.keys.create) FAILED_PRECONDITION: Key creation is
    not allowed on this service account.
    ```

    Fijate *quién* lo aplicó: no un script, no un escáner, no un revisor. La API se negó. No hay ventana entre el error y su detección, porque no hay error.

6. Ahora hacé lo mismo **sin** romper nada — usá el modo dry-run de org policy, que evalúa y registra las violaciones mientras sigue permitiendo la acción:

    ```bash
    cat > /tmp/dryrun-extip.yaml <<EOF
    name: organizations/${ORG_ID}/policies/compute.vmExternalIpAccess
    dryRunSpec:
      rules:
      - denyAll: true
    EOF
    gcloud org-policies set-policy /tmp/dryrun-extip.yaml
    ```

7. Leé las violaciones potenciales desde Cloud Logging tras algunas horas de actividad normal:

    ```bash
    gcloud logging read \
      'protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.OrgPolicyViolationInfo"' \
      --organization="$ORG_ID" --limit=20 --format="value(protoPayload.resourceName)"
    ```

8. Limpiá para que los ejercicios posteriores no queden bloqueados:

    ```bash
    gcloud org-policies delete constraints/iam.disableServiceAccountKeyCreation --organization="$ORG_ID"
    gcloud org-policies delete constraints/compute.vmExternalIpAccess --organization="$ORG_ID"
    gcloud iam service-accounts delete "leaky-sa@${PROJECT_ID}.iam.gserviceaccount.com" --quiet
    ```

Referencia: [Organization Policy Service overview](https://cloud.google.com/resource-manager/docs/organization-policy/overview).

### Verificá tu comprensión

**Q2.1** Clasificá cada uno de estos como **preventivo**, **detectivo** o **correctivo**: (a) una org policy que deniega IPs externas, (b) un hallazgo de Security Command Center titulado `PUBLIC_IP_ADDRESS`, (c) una Cloud Function que elimina IPs públicas cada noche. ¿Cuál de los tres tiene el menor costo total de propiedad, y por qué?

**Q2.2** Explicale el propósito de negocio del **modo dry-run** a un VP of Engineering que teme que un mandato de seguridad rompa producción un viernes.

**Q2.3** La jerarquía de recursos es Organización → Carpeta → Proyecto → Recurso. Dá una razón de negocio por la que una empresa fijaría una política estricta en el nodo de organización y otorgaría una *excepción* en una sola carpeta, en lugar de fijar la política en cada proyecto.

**Q2.4** Tu empresa adquiere a un competidor y hereda 400 de sus proyectos. Describí, en dos frases, cómo la jerarquía más la org policy convierten una remediación de seguridad de 400 proyectos en una pieza de trabajo acotada.

---

## Ejercicio 3 — La capa de identidad: mínimo privilegio, descubierto por máquina

**Capa:** autenticación y autorización
**Pregunta de negocio:** la identidad es el nuevo perímetro — ¿cuánto cuesta mantener ese perímetro a mano, y quién lo paga?

### Pasos

1. Volcá la política IAM actual de tu proyecto y contá los bindings:

    ```bash
    gcloud projects get-iam-policy "$PROJECT_ID" --format=json > /tmp/iam.json
    jq '.bindings | length' /tmp/iam.json
    jq -r '.bindings[] | select(.role | test("roles/(owner|editor)$")) | "\(.role)\t\(.members | join(", "))"' /tmp/iam.json
    ```

    Salida ilustrativa:

    ```
    7
    roles/owner	user:founder@example.com
    roles/editor	serviceAccount:123456789012-compute@developer.gserviceaccount.com
    ```

    `roles/editor` sobre la service account por defecto de Compute es un rol básico con acceso de escritura a casi todos los servicios del proyecto. Toda VM que la use hereda eso.

2. Pedile a Google que encuentre el exceso de permisos por vos. **IAM Recommender** analiza 90 días de uso real de la API y propone un rol más estrecho:

    ```bash
    gcloud services enable recommender.googleapis.com policyanalyzer.googleapis.com
    gcloud recommender recommendations list \
      --project="$PROJECT_ID" \
      --location=global \
      --recommender=google.iam.policy.Recommender \
      --format="table(name.basename(), primaryImpact.category, stateInfo.state, description)"
    ```

    Salida ilustrativa:

    ```
    NAME                                  CATEGORY  STATE   DESCRIPTION
    b1c2d3e4-5f60-7182-93a4-b5c6d7e8f901  SECURITY  ACTIVE  Replace the current role with a smaller role to cover the permissions needed.
    ```

    Fijate en la economía: este análisis se produce de forma continua, sin costo marginal para vos, en cada proyecto de la organización. Un consultor de revisión de accesos produce el mismo artefacto una vez por ciclo de auditoría, a tarifa diaria.

3. Respondé la pregunta del auditor — "¿quién puede leer este bucket, por cualquier vía?" — con **Policy Analyzer**, que resuelve bindings heredados, pertenencia a grupos y condiciones:

    ```bash
    gcloud asset analyze-iam-policy \
      --organization="$ORG_ID" \
      --full-resource-name="//storage.googleapis.com/${PROJECT_ID}-defaults" \
      --permissions="storage.objects.get" \
      --format=json | jq -r '.mainAnalysis.analysisResults[].iamBinding.members[]' | sort -u
    ```

    Alternativa con alcance de proyecto:

    ```bash
    gcloud asset analyze-iam-policy --project="$PROJECT_ID" \
      --permissions="storage.objects.get" --format=json | jq '.mainAnalysis.analysisResults | length'
    ```

4. Pasá de "quién sos" a "quién sos, desde dónde, en qué dispositivo". Inspeccioná la superficie de niveles de acceso que respalda el **context-aware access** y **Chrome Enterprise Premium** (antes BeyondCorp Enterprise):

    ```bash
    gcloud access-context-manager policies list --organization="$ORG_ID"
    export POLICY_ID="$(gcloud access-context-manager policies list \
      --organization="$ORG_ID" --format='value(name)' | sed 's|accessPolicies/||')"

    cat > /tmp/level.yaml <<'EOF'
    - devicePolicy:
        requireScreenlock: true
        requireCorpOwned: true
        osConstraints:
        - osType: DESKTOP_CHROME_OS
        - osType: DESKTOP_MAC
      regions:
      - AR
      - ES
      - US
    EOF

    gcloud access-context-manager levels create trusted_corp_device \
      --policy="$POLICY_ID" \
      --title="Corp-owned, screenlocked, allowed regions" \
      --basic-level-spec=/tmp/level.yaml \
      --combine-function=AND
    ```

5. Leé ese YAML como una frase: *el acceso requiere un dispositivo propiedad de la empresa, con bloqueo de pantalla, ejecutando un sistema operativo aprobado, conectándose desde uno de tres países* — y notá que **no aparece ninguna VPN por ningún lado**. Esa es la sustitución zero-trust: la decisión de confianza se movió de la ubicación de red a la identidad verificada más la postura del dispositivo.

Referencias: [Role recommendations](https://cloud.google.com/policy-intelligence/docs/role-recommendations-overview), [Chrome Enterprise Premium](https://cloud.google.com/chrome-enterprise-premium/docs), [BeyondCorp zero trust model](https://cloud.google.com/beyondcorp).

### Verificá tu comprensión

**Q3.1** Enunciá la diferencia entre **autenticación** y **autorización**, y nombrá el servicio de Google Cloud principalmente responsable de cada una.

**Q3.2** IAM Recommender necesitó 90 días de datos de uso. ¿Qué riesgo de negocio asume una organización al actuar sobre una recomendación *antes* de que esa ventana esté completa, y cómo le plantearías ese riesgo a un comité de dirección no técnico?

**Q3.3** Una empresa de retail contrata 3.000 empleados de temporada cada noviembre y los libera en enero. Explicá por qué el modelo zero-trust del paso 4 del ejercicio 3 escala mejor financieramente que emitir 3.000 cuentas VPN.

**Q3.4** ¿Cuál de estos es la evidencia más fuerte de que "Google forma parte de tu equipo de seguridad" y no simplemente que "Google te vende una herramienta de seguridad": (a) la org policy del ejercicio 2, (b) la recomendación de IAM del paso 2, (c) el nivel de acceso del paso 4? Defendé tu elección en dos frases.

---

## Ejercicio 4 — La capa de datos: custodia de claves y encontrar los datos sensibles que olvidaste

**Capa:** protección de datos
**Pregunta de negocio:** ¿quién tiene las claves, a quién se le puede exigir entregarlas, y cuánto vale eso para un negocio regulado?

### Pasos

1. Creá un key ring y una clave simétrica con rotación. **Este es el paso facturable** — los key rings y las claves son permanentes:

    ```bash
    gcloud services enable cloudkms.googleapis.com
    gcloud kms keyrings create cdl-lab --location="$REGION"
    gcloud kms keys create bucket-cmek \
      --location="$REGION" --keyring=cdl-lab \
      --purpose=encryption \
      --rotation-period=90d \
      --next-rotation-time="$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"
    gcloud kms keys describe bucket-cmek --location="$REGION" --keyring=cdl-lab \
      --format="yaml(name, purpose, rotationPeriod, versionTemplate)"
    ```

2. Otorgale al service agent de Cloud Storage permiso para usar la clave y después creá un bucket cifrado con CMEK:

    ```bash
    export GCS_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"
    gcloud kms keys add-iam-policy-binding bucket-cmek \
      --location="$REGION" --keyring=cdl-lab \
      --member="serviceAccount:${GCS_AGENT}" \
      --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"

    gcloud storage buckets create "gs://${PROJECT_ID}-cmek" \
      --location="$REGION" \
      --default-encryption-key="projects/${PROJECT_ID}/locations/${REGION}/keyRings/cdl-lab/cryptoKeys/bucket-cmek"

    gcloud storage buckets describe "gs://${PROJECT_ID}-cmek" --format="value(default_kms_key)"
    ```

3. Demostrá qué significa operativamente "vos tenés las claves" — deshabilitá la clave y mirá cómo los datos se vuelven ilegibles *sin borrar un solo byte*:

    ```bash
    echo "regulated payload" > /tmp/reg.txt
    gcloud storage cp /tmp/reg.txt "gs://${PROJECT_ID}-cmek/reg.txt"

    gcloud kms keys versions disable 1 --key=bucket-cmek --keyring=cdl-lab --location="$REGION"
    sleep 30
    gcloud storage cat "gs://${PROJECT_ID}-cmek/reg.txt"
    ```

    Salida ilustrativa:

    ```
    ERROR: (gcloud.storage.cat) HTTPError 400: Cloud KMS error when decrypting: key version
    is not enabled, current state is: DISABLED
    ```

    Volvé a habilitarla:

    ```bash
    gcloud kms keys versions enable 1 --key=bucket-cmek --keyring=cdl-lab --location="$REGION"
    ```

    Ese único interruptor es **crypto-shredding**: una revocación instantánea, demostrable e independiente de la jurisdicción del acceso a conjuntos de datos arbitrariamente grandes. Es el mecanismo detrás de muchos controles de "derecho al olvido" y de offboarding.

4. Ahora encontrá los datos sensibles de los que nadie te avisó. Invocá **Sensitive Data Protection** (antes Cloud DLP) sobre una cadena de ejemplo:

    ```bash
    gcloud services enable dlp.googleapis.com

    cat > /tmp/inspect.json <<'EOF'
    {
      "item": {
        "value": "Ticket #4471 from Ana Ruiz, ana.ruiz@example.com, card 4111 1111 1111 1111, phone +54 11 4555 0100"
      },
      "inspectConfig": {
        "infoTypes": [
          {"name": "PERSON_NAME"},
          {"name": "EMAIL_ADDRESS"},
          {"name": "CREDIT_CARD_NUMBER"},
          {"name": "PHONE_NUMBER"}
        ],
        "minLikelihood": "POSSIBLE",
        "includeQuote": true
      }
    }
    EOF

    curl -sS -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      -d @/tmp/inspect.json \
      "https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/global/content:inspect" \
    | jq -r '.result.findings[] | "\(.infoType.name)\t\(.likelihood)\t\(.quote)"'
    ```

    Salida ilustrativa:

    ```
    PERSON_NAME	        LIKELY	    Ana Ruiz
    EMAIL_ADDRESS	    LIKELY	    ana.ruiz@example.com
    CREDIT_CARD_NUMBER	VERY_LIKELY	4111 1111 1111 1111
    PHONE_NUMBER	    LIKELY	    +54 11 4555 0100
    ```

5. Repetí la llamada con `"deidentifyConfig"` en lugar de `"inspectConfig"` contra el endpoint `content:deidentify`, usando un `characterMaskConfig`, y observá que el registro sobrevive con los identificadores enmascarados. Notá la consecuencia de negocio: el equipo de analítica se queda con el dataset, la oficina de privacidad se queda con la garantía, y ninguno tiene que negociar con el otro.

6. Limpiá los recursos que no son VMs:

    ```bash
    gcloud storage rm -r "gs://${PROJECT_ID}-cmek" "gs://${PROJECT_ID}-defaults"
    ```

Referencias: [Cloud KMS](https://cloud.google.com/kms/docs), [Cloud KMS Autokey](https://cloud.google.com/kms/docs/autokey/overview), [Sensitive Data Protection](https://cloud.google.com/sensitive-data-protection/docs).

### Verificá tu comprensión

**Q4.1** Ordená estas cuatro opciones de gestión de claves por *grado de control del cliente*, de menor a mayor: CMEK, cifrado por defecto gestionado por Google, Cloud External Key Manager (EKM), CSEK. Para cada escalón hacia arriba, nombrá algo que el cliente gana y una carga operativa que asume.

**Q4.2** En el paso 3 hiciste ilegibles los datos en unos 30 segundos sin tocar los datos. Dá dos escenarios de negocio donde esa propiedad sea el factor decisivo en una decisión de compra.

**Q4.3** Un banco debe demostrar que Google **no puede** descifrar su dataset más sensible ni siquiera bajo una orden judicial dirigida a Google. ¿Qué combinación de productos aborda esto, y cuál es la limitación honesta que tenés que declararle al banco?

**Q4.4** Sensitive Data Protection encontró un número de tarjeta de crédito en un ticket de soporte. Describí la consecuencia de cumplimiento de que ese ticket esté en un bucket de logging sin clasificar, y cómo el descubrimiento más la desidentificación convierten un alcance de cumplimiento *ilimitado* en uno *acotado*.

---

## Ejercicio 5 — La capa de red y perímetro: WAF en el edge, frontera de exfiltración adentro

**Capa:** defensa de red y control de egreso de datos
**Pregunta de negocio:** ¿qué le pasa a tu modelo de costos cuando la absorción de DDoS es una capacidad compartida de la plataforma en lugar de ancho de banda que comprás?

### Pasos

1. Construí una política de edge de Cloud Armor con las reglas WAF preconfiguradas de Google — están mantenidas por Google contra el OWASP ModSecurity Core Rule Set, así que estás consumiendo un conjunto de reglas que no escribís ni ajustás desde cero:

    ```bash
    gcloud compute security-policies create edge-waf \
      --description="Defence-in-depth lab: L7 filtering at the edge"

    gcloud compute security-policies rules create 1000 \
      --security-policy=edge-waf \
      --expression="evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})" \
      --action=deny-403 \
      --description="Block SQL injection"

    gcloud compute security-policies rules create 1010 \
      --security-policy=edge-waf \
      --expression="evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})" \
      --action=deny-403 \
      --description="Block cross-site scripting"

    gcloud compute security-policies rules create 1020 \
      --security-policy=edge-waf \
      --expression="origin.region_code == 'KP'" \
      --action=deny-403 \
      --description="Geo restriction example"
    ```

2. Activá **Adaptive Protection**, que construye una línea base de ML de tu tráfico normal y propone una regla de mitigación durante un ataque:

    ```bash
    gcloud compute security-policies update edge-waf --enable-layer7-ddos-defense
    gcloud compute security-policies describe edge-waf \
      --format="yaml(name, adaptiveProtectionConfig, rules.priority, rules.action)"
    ```

    Salida ilustrativa:

    ```yaml
    adaptiveProtectionConfig:
      layer7DdosDefenseConfig:
        enable: true
        ruleVisibility: STANDARD
    name: edge-waf
    ```

3. Observá dónde se aplica esta política: en el **Google Front End**, en el edge de Google, antes de que el tráfico llegue a tu VPC o consuma tu egreso. Una inundación volumétrica L3/L4 es absorbida por la misma infraestructura que sirve Search y YouTube. No aprovisionaste capacidad para el pico de ataque, y no se te factura el tráfico de ataque que tus backends nunca vieron.

4. Ahora la frontera interna. IAM responde *quién*; **VPC Service Controls** responde *desde dónde se puede alcanzar un servicio y hacia dónde pueden viajar sus datos*. Creá el perímetro en modo dry-run para que nada se rompa:

    ```bash
    gcloud access-context-manager perimeters dry-run create data-perimeter \
      --policy="$POLICY_ID" \
      --perimeter-title="Regulated data perimeter" \
      --perimeter-type=regular \
      --perimeter-resources="projects/${PROJECT_NUMBER}" \
      --perimeter-restricted-services=storage.googleapis.com,bigquery.googleapis.com
    ```

5. Generá tráfico (volvé a ejecutar cualquiera de los comandos de storage de arriba) y después leé lo que el perímetro *habría* bloqueado:

    ```bash
    gcloud logging read \
      'protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"
       AND protoPayload.metadata.dryRun="true"' \
      --project="$PROJECT_ID" --limit=10 \
      --format="table(timestamp, protoPayload.methodName, protoPayload.metadata.violationReason)"
    ```

6. Razoná sobre la amenaza que esto cierra y que IAM no puede: un insider o una credencial comprometida con permiso **legítimo** `storage.objects.get` copiando un dataset a un proyecto personal. Todas las comprobaciones de IAM pasan. El perímetro rechaza el egreso porque el destino está fuera de la frontera.

7. Limpiá:

    ```bash
    gcloud access-context-manager perimeters delete data-perimeter --policy="$POLICY_ID" --quiet
    gcloud compute security-policies delete edge-waf --quiet
    ```

Referencias: [Cloud Armor security policies](https://cloud.google.com/armor/docs/security-policy-overview), [VPC Service Controls](https://cloud.google.com/vpc-service-controls/docs/overview).

### Verificá tu comprensión

**Q5.1** Cloud Armor y VPC Service Controls suenan ambos a "seguridad de red". Enunciá con precisión contra qué protege cada uno, y dá un ataque que solo uno de ellos detiene.

**Q5.2** Explicale a un CFO por qué la protección contra DDoS en Google Cloud cambia la *forma* del costo, no solo el monto — hacé referencia a lo que una organización on-premises debe comprar para alcanzar una capacidad comparable.

**Q5.3** "Tenemos IAM bien configurado, así que no necesitamos VPC Service Controls." Refutalo en tres frases usando el escenario del paso 6.

**Q5.4** Nombrá las capas de defensa que una sola petición HTTP maliciosa tiene ahora que sobrevivir, en orden, desde la internet pública hasta una fila en BigQuery. Apuntá a al menos cinco.

---

## Ejercicio 6 — La capa de detección: la inteligencia de amenazas de Google, aplicada a tu parque

**Capa:** detección, investigación y respuesta
**Pregunta de negocio:** ¿qué paga hoy una organización para construir el contenido de detección, la inteligencia de amenazas y la cobertura de analistas 24/7 que esta capa entrega como producto?

### Pasos

1. **`[ORG]`** Listá las fuentes de detección activas en tu organización. Estos son los servicios integrados que escriben hallazgos en **Security Command Center**:

    ```bash
    gcloud scc sources list "organizations/${ORG_ID}" \
      --format="table(displayName, description)"
    ```

    Salida ilustrativa:

    ```
    DISPLAY_NAME                 DESCRIPTION
    Security Health Analytics    Detects misconfigurations in Google Cloud resources.
    Event Threat Detection       Detects threats in Cloud Logging using Google threat intelligence.
    Container Threat Detection   Detects runtime attacks in GKE containers.
    Web Security Scanner         Detects web application vulnerabilities.
    ```

    Leé esa lista como un plan de contratación que no tuviste que ejecutar: un escáner de malas configuraciones, un detector de amenazas basado en logs alimentado por la inteligencia de amenazas de Google, un sensor de runtime de contenedores y un escáner DAST — cuatro capacidades distintas de ingeniería de seguridad, activadas por defecto en el nivel Standard.

2. Listá tus hallazgos activos, los peores primero:

    ```bash
    gcloud scc findings list "organizations/${ORG_ID}" \
      --source=- \
      --filter='state="ACTIVE" AND severity="HIGH"' \
      --format="table(finding.category, finding.severity, finding.resourceName.basename(), finding.eventTime)" \
      --limit=20
    ```

    Salida ilustrativa:

    ```
    CATEGORY                        SEVERITY  RESOURCE_NAME         EVENT_TIME
    PUBLIC_BUCKET_ACL               HIGH      example-proj-public   2026-09-06T04:11:07Z
    OVER_PRIVILEGED_SERVICE_ACCOUNT HIGH      default-compute-sa    2026-09-06T04:11:07Z
    MFA_NOT_ENFORCED                HIGH      example.com           2026-09-05T22:40:12Z
    ```

    Alternativa con alcance de proyecto:

    ```bash
    gcloud scc findings list --project="$PROJECT_ID" --source=- --limit=10
    ```

3. Agrupá los hallazgos para producir el número que un ejecutivo realmente lee — un conteo por categoría, no una lista de 4.000 filas:

    ```bash
    gcloud scc findings group "organizations/${ORG_ID}" \
      --source=- \
      --group-by="category" \
      --filter='state="ACTIVE"'
    ```

4. Suprimí el ruido conocido y aceptado para que la señal sobreviva, usando una mute config en lugar de cerrar hallazgos a mano:

    ```bash
    gcloud scc muteconfigs create accepted-lab-risk \
      --organization="$ORG_ID" \
      --description="Accepted risk: lab projects" \
      --filter='resource.project_display_name="cdl-lab"'
    ```

5. Mapeá los niveles a la capacidad de negocio que compran. Confirmá tu nivel en la consola bajo **Security Command Center → Settings**:

    | Nivel | Agrega | La capacidad que la organización tendría que comprar o construir de otro modo |
    |---|---|---|
    | **Standard** | Security Health Analytics (subconjunto), Web Security Scanner (escaneos personalizados), inventario de activos | Cloud Security Posture Management (CSPM), básico |
    | **Premium** | Event Threat Detection, Container Threat Detection, VM Threat Detection, Attack Path Simulation, paneles de cumplimiento (CIS, PCI DSS, NIST 800-53, ISO 27001) | CSPM completo + CWPP + reporte continuo de cumplimiento |
    | **Enterprise** | Google SecOps (SIEM/SOAR), inteligencia de amenazas y experiencia de Mandiant, cobertura multicloud (AWS, Azure), gestión de casos | SIEM + SOAR + una suscripción de inteligencia de amenazas + un retainer de respuesta a incidentes |

6. Notá el activo específico detrás del nivel Enterprise: **Mandiant**, adquirida por Google en 2022, es una práctica de respuesta a incidentes que trabaja las mayores brechas de la industria. Sus hallazgos de primera línea se convierten en contenido de detección en Google SecOps y en Google Threat Intelligence. Ese es el significado concreto de "Google en tu equipo de seguridad" — estás consumiendo inteligencia derivada de brechas en las que no estuviste.

7. Limpiá:

    ```bash
    gcloud scc muteconfigs delete accepted-lab-risk --organization="$ORG_ID" --quiet
    ```

Referencias: [Security Command Center overview](https://cloud.google.com/security-command-center/docs/security-command-center-overview), [Google Security Operations](https://cloud.google.com/security/products/security-operations), [Google Threat Intelligence](https://cloud.google.com/security/products/threat-intelligence).

### Verificá tu comprensión

**Q6.1** Distinguí un hallazgo de **mala configuración** de un hallazgo de **amenaza**. Nombrá el servicio de SCC que produce cada uno y explicá por qué una organización necesita ambos.

**Q6.2** Silenciaste un hallazgo en lugar de cerrarlo. Explicá la diferencia de gobernanza, y por qué a un auditor le importa.

**Q6.3** Una empresa de 200 personas evalúa contratar un analista de seguridad (costo totalmente cargado, un empleado a tiempo completo) frente a actualizar a SCC Premium. Enumerá tres cosas que el analista aporta y Premium no, y tres cosas que Premium aporta y un solo analista no puede.

**Q6.4** Articulá el valor de negocio de que Mandiant forme parte de Google Cloud, en la forma en que un Digital Leader se lo diría a un directorio: una frase, sin más nombres de producto que esos dos.

---

## Ejercicio 7 — La capa de la cadena de suministro de software: confiar en lo que desplegás

**Capa:** integridad de build y despliegue
**Pregunta de negocio:** después de que un compromiso de la cadena de suministro se volviera tema de directorio, ¿qué le hace la procedencia demostrable del build a tu registro de riesgos?

### Pasos

1. Exportá la política actual de Binary Authorization de tu proyecto:

    ```bash
    gcloud services enable binaryauthorization.googleapis.com containeranalysis.googleapis.com
    gcloud container binauthz policy export
    ```

    Salida por defecto ilustrativa:

    ```yaml
    defaultAdmissionRule:
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
      evaluationMode: ALWAYS_ALLOW
    globalPolicyEvaluationMode: ENABLE
    name: projects/example-proj/policy
    ```

    Leé el valor por defecto con honestidad: `evaluationMode: ALWAYS_ALLOW` significa que cualquier imagen de cualquier lado se despliega. Este es el estado en el que está la mayoría de las organizaciones.

2. Endurecela para exigir una attestation — una declaración criptográfica de que una imagen específica pasó una compuerta específica:

    ```bash
    gcloud container binauthz policy export > /tmp/policy.yaml
    cat > /tmp/policy.yaml <<EOF
    name: projects/${PROJECT_ID}/policy
    globalPolicyEvaluationMode: ENABLE
    admissionWhitelistPatterns:
    - namePattern: gcr.io/google-containers/*
    - namePattern: gke.gcr.io/*
    defaultAdmissionRule:
      evaluationMode: REQUIRE_ATTESTATION
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
      requireAttestationsBy:
      - projects/${PROJECT_ID}/attestors/built-by-cloud-build
    EOF
    gcloud container binauthz policy import /tmp/policy.yaml
    ```

3. Escaneá una imagen en busca de CVEs conocidos antes de que siquiera llegue a la compuerta de política, usando Artifact Analysis:

    ```bash
    gcloud artifacts docker images list "${REGION}-docker.pkg.dev/${PROJECT_ID}/my-repo" \
      --show-occurrences --occurrence-filter='kind="VULNERABILITY"' \
      --format="table(package, version, vulnerability.effectiveSeverity)" 2>/dev/null \
      || echo "No Artifact Registry repo yet — read the reference and continue."
    ```

4. Razoná sobre las tres garantías ahora apiladas sobre una misma imagen de contenedor, y notá que cada una responde una pregunta distinta:

    | Control | Pregunta que responde |
    |---|---|
    | **Assured OSS** | ¿Las dependencias open source son las que el propio Google construye, escanea y firma en su propio pipeline? |
    | **Artifact Analysis** | ¿Esta imagen contiene un CVE conocido? |
    | **Binary Authorization** | ¿Esta imagen exacta fue construida por nuestro pipeline y pasó nuestras compuertas? |

5. Restaurá la política permisiva para no bloquear tus propios despliegues futuros:

    ```bash
    cat > /tmp/policy-open.yaml <<EOF
    name: projects/${PROJECT_ID}/policy
    globalPolicyEvaluationMode: ENABLE
    defaultAdmissionRule:
      evaluationMode: ALWAYS_ALLOW
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
    EOF
    gcloud container binauthz policy import /tmp/policy-open.yaml
    ```

Referencias: [Binary Authorization](https://cloud.google.com/binary-authorization/docs/overview), [Assured Open Source Software](https://cloud.google.com/assured-open-source-software/docs/overview), [Software Supply Chain Security](https://cloud.google.com/software-supply-chain-security/docs/overview).

### Verificá tu comprensión

**Q7.1** Un escáner de vulnerabilidades ya reporta CVEs en tus imágenes. ¿Qué clase de ataque detiene Binary Authorization que el escáner no puede ver en absoluto?

**Q7.2** Assured OSS entrega los *mismos* paquetes open source que están gratis en los registries públicos. En una frase, enunciá con precisión qué está pagando el cliente, y nombrá la unidad de negocio con más probabilidad de firmar el cheque.

**Q7.3** Ubicá estos tres controles en la línea temporal **build → deploy → run**, y explicá por qué la defensa en profundidad requiere un control en cada punto en lugar del control más fuerte posible en uno solo.

---

## Ejercicio 8 — La capa del operador: limitar al propio Google

**Capa:** transparencia del proveedor y computación confidencial
**Pregunta de negocio:** la objeción más filosa a la adopción de la nube es "el propio personal del proveedor puede ver nuestros datos" — ¿cuál es la respuesta auditable?

### Pasos

1. Inscribí el proyecto en **Access Approval**, que exige *tu* aprobación explícita antes de que un empleado de Google pueda acceder a tus datos por un caso de soporte:

    ```bash
    gcloud services enable accessapproval.googleapis.com
    gcloud access-approval settings update \
      --project="$PROJECT_ID" \
      --notification_emails='security@example.com' \
      --enrolled_services=all
    gcloud access-approval settings get --project="$PROJECT_ID"
    ```

    Salida ilustrativa:

    ```yaml
    enrolledServices:
    - cloudProduct: all
      enrollmentLevel: BLOCK_ALL
    name: projects/example-proj/accessApprovalSettings
    notificationEmails:
    - security@example.com
    ```

2. Leé el flujo de logs de **Access Transparency** — entradas casi en tiempo real que registran cuándo el personal de Google accedió a tu contenido, y el ticket de justificación:

    ```bash
    gcloud logging read \
      'logName:"logs/cloudaudit.googleapis.com%2Faccess_transparency"' \
      --project="$PROJECT_ID" --limit=5 --format=json
    ```

    Un resultado vacío es el desenlace esperado y deseable. El valor no está en las entradas — está en la existencia del flujo: un rastro de auditoría del proveedor, generado por el proveedor, que vos poseés.

3. Cerrá la última brecha — datos **en uso**, en memoria, donde los dos estados de cifrado anteriores no llegan. Creá una Confidential VM (**facturable — eliminala en el paso 5**):

    ```bash
    gcloud compute instances create conf-vm \
      --zone="$ZONE" \
      --machine-type=n2d-standard-2 \
      --min-cpu-platform="AMD Milan" \
      --confidential-compute-type=SEV \
      --maintenance-policy=TERMINATE \
      --image-family=ubuntu-2204-lts \
      --image-project=ubuntu-os-cloud \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
    ```

4. Verificá desde adentro del guest que el cifrado de memoria está activo:

    ```bash
    gcloud compute ssh conf-vm --zone="$ZONE" --command="sudo dmesg | grep -i -E 'sev|memory encryption'"
    ```

    Salida ilustrativa:

    ```
    [    0.000000] AMD Memory Encryption Features active: SEV
    [    0.223401] SEV is active, SME is not
    ```

    El hypervisor — el propio código de Google — no puede leer la memoria de esta VM. La clave de cifrado vive en el AMD Secure Processor, no en software que Google opera.

5. **Eliminá la VM ahora:**

    ```bash
    gcloud compute instances delete conf-vm --zone="$ZONE" --quiet
    ```

Referencias: [Access Transparency](https://cloud.google.com/logging/docs/audit/access-transparency-overview), [Access Approval](https://cloud.google.com/assured-workloads/access-approval/docs/overview), [Confidential VM](https://cloud.google.com/confidential-computing/confidential-vm/docs/confidential-vm-overview), [Key Access Justifications](https://cloud.google.com/assured-workloads/key-access-justifications/docs/overview).

### Verificá tu comprensión

**Q8.1** Distinguí **Access Transparency** de **Access Approval** en una frase cada uno, y decí cuál de los dos es un control *detectivo* y cuál es *preventivo*.

**Q8.2** ¿Cuál de los tres estados de datos cerró la Computación Confidencial? Nombrá una carga de trabajo industrial específica donde ese estado sea la razón entera por la que la adopción de la nube estaba bloqueada.

**Q8.3** **Key Access Justifications** permite a un cliente ver el motivo declarado de cada solicitud de acceso a claves y denegarla programáticamente. Combinado con Cloud EKM, describí la garantía de soberanía que esto produce, y nombrá a la única parte en la que todavía hay que confiar.

**Q8.4** Un prospecto dice: "La nube significa renunciar al control." Usando solo el ejercicio 8, dá una refutación en tres puntos en el orden transparencia → aprobación → imposibilidad técnica.

---

## Ejercicio 9 — Cumplimiento, soberanía y transferencia del riesgo

**Capa:** gobernanza, aseguramiento y riesgo financiero
**Pregunta de negocio:** el cumplimiento es un centro de costos y una compuerta de time-to-market. ¿Qué cambia realmente heredar las certificaciones de un proveedor?

### Pasos

1. Abrí el [Compliance Reports Manager](https://cloud.google.com/security/compliance/compliance-reports-manager) y descargá el informe **SOC 2 Type II** vigente y el certificado **ISO/IEC 27001**. Notá dos cosas: el tiempo transcurrido (minutos) y la cantidad de personal de Google Cloud involucrado (cero).

2. Compará eso con el esfuerzo interno que esos artefactos representan — un SOC 2 Type II cubre una ventana de observación de varios meses, una firma auditora externa y recolección de evidencia en toda la infraestructura. Tu organización hereda la porción de *infraestructura* de ese alcance y audita solo lo que construyó encima.

3. **`[ORG]`** Inspeccioná la superficie de Assured Workloads — una carpeta ligada a un régimen de cumplimiento donde Google aplica residencia de datos, controles de personal y restricciones de acceso de soporte como comportamiento de la plataforma en lugar de como documentos de política:

    ```bash
    gcloud services enable assuredworkloads.googleapis.com
    gcloud assured workloads list \
      --organization="$ORG_ID" --location="$REGION" \
      --format="table(displayName, complianceRegime, resources)"
    ```

    Una lista vacía es lo esperado. Leé en cambio los regímenes disponibles:

    ```bash
    gcloud assured workloads create --help | grep -A 30 'compliance-regime'
    ```

    Vas a encontrar regímenes que incluyen `FEDRAMP_MODERATE`, `FEDRAMP_HIGH`, `IL4`, `CJIS`, `HIPAA`, `ITAR`, `EU_REGIONS_AND_SUPPORT` y `ASSURED_WORKLOADS_FOR_PARTNERS`.

4. Aplicá residencia de datos de forma independiente de Assured Workloads, con una sola restricción de org policy:

    ```bash
    cat > /tmp/residency.yaml <<EOF
    name: organizations/${ORG_ID}/policies/gcp.resourceLocations
    spec:
      rules:
      - values:
          allowedValues:
          - in:eu-locations
    EOF
    gcloud org-policies set-policy /tmp/residency.yaml
    ```

    Probala y observá el rechazo:

    ```bash
    gcloud storage buckets create "gs://${PROJECT_ID}-us-test" --location=us-central1
    ```

    Salida ilustrativa:

    ```
    ERROR: (gcloud.storage.buckets.create) HTTPError 412: Constraint constraints/gcp.resourceLocations
    violated for projects/example-proj. us-central1 violates constraint.
    ```

    Limpiá:

    ```bash
    gcloud org-policies delete constraints/gcp.resourceLocations --organization="$ORG_ID"
    ```

5. Leé el [Risk Protection Program](https://cloud.google.com/security/risk-protection-program). Esta es la capa que más se pasa por alto en el examen: Google se asocia con **Munich Re** y **Allianz** para ofrecer *Cloud Protection +*, un seguro cibernético cuyo precio se calcula usando los datos de postura de Security Command Center del cliente. Las aseguradoras suscriben contra la postura medida en lugar de contra un cuestionario.

6. Enunciá la relevancia en una línea antes de seguir: una aseguradora que acepta la telemetría de Google como evidencia de suscripción es un tercero independiente, respaldado financieramente, afirmando que este modelo de seguridad reduce la pérdida. Eso convierte "nuestra seguridad es buena" de una afirmación en un instrumento con precio.

7. Distinguí los dos modelos que enmarcan todo este documento:

    | Modelo | Postura de Google | Experiencia del cliente |
    |---|---|---|
    | **Responsabilidad compartida** | Acá está la línea. Arriba de ella es tuyo. | Un contrato. Correcto, y frío. |
    | **Destino compartido** | Acá tenés blueprints seguros por defecto, guardrails, landing zones, telemetría de postura y un camino hacia el seguro. Cargamos el riesgo con vos. | Una asociación con la piel en el juego. |

    Ver [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate).

### Verificá tu comprensión

**Q9.1** Para cada uno de IaaS, PaaS y SaaS, decí quién parchea el sistema operativo invitado, y dá una consecuencia de negocio de esa diferencia para una empresa con un equipo de plataforma pequeño.

**Q9.2** Explicá, en el lenguaje de un CFO, por qué "heredar cumplimiento" acorta el tiempo hasta el ingreso, no solo el tiempo hasta la auditoría. Usá un ejemplo concreto (un acuerdo de salud o del sector público).

**Q9.3** Enunciá la diferencia entre **responsabilidad compartida** y **destino compartido** en una frase cada una, y después nombrá el artefacto de este documento que es la evidencia más clara de destino compartido.

**Q9.4** Un cliente del sector público europeo exige que los datos nunca salgan de la UE y que el personal de soporte resida en la UE. ¿Qué dos mecanismos de este ejercicio abordan qué mitad de ese requisito, y por qué la org policy por sí sola es insuficiente?

---

## Ejercicio 10 — Síntesis: el memo de una página

No se te pide configurar nada. Se te pide hacer el trabajo real del Digital Leader.

### Pasos

1. Escribí un memo de una página para un directorio que aprobó una migración a la nube pero está nervioso por la seguridad. Estructuralo en exactamente cuatro secciones:
    - **Qué dejamos de pagar** — capacidades que se convierten en características de la plataforma (enumerá cinco, tomadas de los ejercicios 1, 5, 6, 7).
    - **Qué seguimos siendo dueños** — tu lado de la línea de responsabilidad compartida (enumerá cinco).
    - **Cómo lo demostramos** — los artefactos que un auditor acepta, y cuánto tarda producir cada uno (ejercicios 6 y 9).
    - **Qué pasa cuando falla igual** — detección, respuesta y transferencia financiera (ejercicios 6 y 9).

2. Limitate a **un nombre de producto por sección**. Si una sección necesita tres nombres de producto para transmitir su punto, el punto todavía no es un argumento de negocio.

3. Contrastá el memo con el fraseo del examen. El objetivo dice *"making Google part of an organization's security team."* Si tu memo se lee como "compramos herramientas de seguridad", reescribilo. Si se lee como "capacidades que antes requerían plantilla, capital y tiempo de calendario ahora se heredan, se miden y se aseguran", está correcto.

### Verificá tu comprensión

**Q10.1** En una frase, sin ningún nombre de producto, enunciá el valor de negocio de la defensa en profundidad.

**Q10.2** Nombrá la capa de los ejercicios 1–9 que implementarías **primero** en una startup de 50 personas sin personal de seguridad, y defendé la elección por costo-beneficio, no por completitud.

**Q10.3** Un ejecutivo dice: "La defensa en profundidad es solo redundancia, y la redundancia es desperdicio." Refutalo usando una cadena de fallos concreta de estos ejercicios donde exactamente una capa aguantó.

---

<details>
<summary><strong>Respuestas</strong> — intentá responder cada pregunta antes de abrir</summary>

### Ejercicio 1 — Infraestructura y criptografía

**A1.1** El campo `default_kms_key` / `encryption` registra únicamente si hay configurada una clave **gestionada por el cliente** (CMEK); su ausencia significa que el objeto está cifrado con **claves gestionadas por Google**, que es el valor por defecto de la plataforma y no se puede desactivar. El campo describe la custodia de la clave, no la presencia de cifrado.

**A1.2** Dos de:
- **Costo marginal cero y superficie operativa cero.** No hay producto de cifrado que licenciar, desplegar, monitorear, parchear o que falle. El cifrado no puede desactivarse accidentalmente por una mala configuración, así que toda una clase de hallazgo de auditoría no existe.
- **Reducción del alcance de auditoría.** "Los datos en reposo están cifrados" queda satisfecho por un control heredado de la plataforma respaldado por los informes SOC 2 / ISO 27001 de Google, en lugar de por evidencia que tu equipo debe recolectar por sistema, por ciclo de auditoría.
- **Uniformidad.** On-premises, la cobertura de cifrado es por sistema y se desvía. Acá es invariante en todos los servicios, todas las regiones y todo recurso nuevo, incluidos los creados por equipos que nunca leyeron la política de seguridad.

**A1.3** En reposo, en tránsito y en uso. **En uso** — datos descifrados en la memoria de una máquina durante el procesamiento — *no* está cubierto por los valores por defecto; eso requiere Computación Confidencial (ejercicio 8).

**A1.4** (1) La tecnología: **ALTS** (Application Layer Transport Security), el cifrado con autenticación mutua de Google para RPC interno, más el cifrado del tráfico en la WAN privada entre centros de datos. (2) La clase de documento: los informes de auditoría de terceros y los whitepapers de Google — el whitepaper *Encryption in Transit in Google Cloud* y el informe SOC 2 Type II del Compliance Reports Manager. Ninguno requiere acceso a tu proyecto, porque el control es de Google, no tuyo.

### Ejercicio 2 — Gobernanza

**A2.1** (a) **preventivo**, (b) **detectivo**, (c) **correctivo**. El control **preventivo** tiene el menor TCO: el detectivo requiere que alguien clasifique y actúe sobre cada hallazgo, y el correctivo es código que hay que escribir, probar, asegurar, al que hay que otorgar privilegios y mantener — y actúa solo *después* de una ventana de exposición durante la cual el riesgo fue real. El control preventivo no tiene ventana de exposición ni trabajo continuo; la API simplemente se niega.

**A2.2** El modo dry-run evalúa la política contra tráfico real y registra toda acción que *habría* sido bloqueada, mientras permite que todas tengan éxito. Convierte un mandato de seguridad de una apuesta en una medición: ves la lista exacta de equipos y cargas de trabajo que se romperían, cuantificás la remediación y la planificás — antes de que alguien reciba una alerta. El resultado de seguridad no cambia; solo se elimina el riesgo del despliegue.

**A2.3** Las excepciones son visibles, pocas y revisables. Si la política estricta está en el nodo de organización, el valor por defecto para todo proyecto actual y futuro — incluidos los que nadie creó todavía — es seguro, y el equipo de seguridad audita una lista corta de excepciones deliberadas. Si la política se fija por proyecto, el valor por defecto de un proyecto nuevo es *nada*, la seguridad depende de que alguien se acuerde, y la pregunta auditable cambia de "¿cuáles son nuestras excepciones?" (respondible) a "¿alguien se olvidó?" (no respondible a escala).

**A2.4** Mové los 400 proyectos adquiridos bajo una sola carpeta, aplicá los guardrails de la organización a esa carpeta en **modo dry-run**, y leé el log de violaciones para obtener una lista de remediación precisa, completa y priorizada. Después aplicá las restricciones por orden de severidad: un único cambio de política corrige una clase de mala configuración en los 400 proyectos simultáneamente, así que el trabajo escala con la cantidad de *políticas*, no con la cantidad de proyectos.

### Ejercicio 3 — Identidad

**A3.1** La **autenticación** demuestra quién o qué está haciendo la petición (identidad); la **autorización** decide si esa identidad puede realizar esta acción sobre este recurso. La autenticación la maneja **Cloud Identity** (con Google Workspace, federación con un IdP externo, o Workload Identity para servicios); la autorización la maneja **Cloud IAM**.

**A3.2** Actuar sobre una ventana parcial arriesga revocar un permiso usado por un proceso real pero **poco frecuente** — cierre trimestral, prueba anual de DR, batch de fin de mes, pico estacional. La falla aparece en el peor momento, y el daño de negocio cae sobre el equipo que impulsó la mejora de seguridad, lo que envenena la siguiente. A un comité de dirección: *"Estamos reduciendo accesos con base en el uso observado. Si actuamos antes de haber observado un ciclo de negocio completo, vamos a romper algo que solo corre una vez por trimestre, y lo vamos a romper en el día más importante de ese trimestre."*

**A3.3** Las cuentas VPN tienen costo por asiento, trabajo de aprovisionamiento y desaprovisionamiento, una carga de mesa de ayuda que se dispara justo cuando la dotación es más escasa, y un riesgo residual que se concentra en el paso de desaprovisionamiento — una cuenta VPN no revocada es acceso a nivel de red. El modelo zero-trust no tiene capacidad de appliance por asiento que dimensionar para el pico de noviembre, evalúa la confianza por petición a partir de la identidad y la postura del dispositivo, y la revocación es un único cambio de identidad que surte efecto en la próxima petición en todos lados a la vez. Financieramente: el pico estacional de capacidad deja de ser un problema de planificación de capital.

**A3.4** **(b), la recomendación de IAM.** (a) y (c) son superficies de configuración — potentes, pero solo hacen lo que les decís, que es la definición de una herramienta. (b) es Google realizando análisis continuo de tu entorno específico y devolviendo un hallazgo que no pediste y que no habrías podido producir sin dedicarle un ingeniero; eso es la salida de un colega, no de una herramienta. (Una defensa de (c) también es válida si argumenta que las señales de postura de dispositivo y de amenazas de Google son las que hacen posible la decisión.)

### Ejercicio 4 — Protección de datos

**A4.1** De menor a mayor control: **cifrado por defecto gestionado por Google → CMEK → Cloud EKM → CSEK**.

| Escalón | Gana | Asume |
|---|---|---|
| Por defecto → **CMEK** | Control sobre el ciclo de vida de la clave, la política de rotación y la capacidad de deshabilitar/destruir (crypto-shredding); el uso de la clave aparece en tus audit logs | Facturación del key ring/clave, IAM sobre la clave, y el riesgo de que deshabilitar una clave tire producción abajo |
| CMEK → **EKM** | Las claves viven fuera de Google, en tu propio key manager o el de un partner; Google no puede acceder al material de clave | La disponibilidad de tu key manager se vuelve una dependencia dura de la disponibilidad de tus datos; latencia y carga operativa |
| EKM → **CSEK** | La clave se suministra en cada petición y Google nunca la almacena | Tenés que transmitir y gestionar la clave por petición, sin recuperación si se pierde; soporte limitado de servicios (legacy — preferí CMEK/EKM) |

**A4.2** Dos de:
- **Derecho al olvido / Artículo 17 del GDPR a escala.** Demostrar la eliminación de cada backup, réplica y copia archivada de un dataset es difícil; destruir la clave que hace legibles todas las copias es demostrable e instantáneo.
- **Offboarding de un tenant, joint venture o unidad de negocio desinvertida.** El acceso termina en una marca temporal conocida con un evento auditable, sin un proyecto de migración de datos.
- **Contención de incidentes.** Ante evidencia de compromiso de credenciales, deshabilitar una clave detiene a todos los lectores del dataset afectado en segundos, incluidos los lectores que todavía no identificaste.
- **Salida contractual.** A un cliente o a un regulador se le puede mostrar un mecanismo, no una promesa, para terminar la capacidad del proveedor de servir sus datos.

**A4.3** **Cloud External Key Manager (Cloud EKM)** más **Key Access Justifications**, idealmente dentro de una frontera de **Assured Workloads**. El material de clave permanece en un key manager externo fuera del control de Google, así que Google no puede descifrar sin una llamada de desenvoltura de clave que el cliente puede denegar. La limitación honesta: esto protege los datos **en reposo**. Los datos igual deben descifrarse en memoria para ser procesados, así que la garantía solo es completa combinada con **Computación Confidencial** — e incluso entonces el cliente confía en la raíz de confianza de hardware del fabricante de la CPU y en la corrección del reporte de justificación de solicitudes de clave de Google.

**A4.4** Un número de tarjeta de pago en un bucket de logging general arrastra ese bucket — y todo lo alcanzable desde él, y todo sistema que le envía logs — al alcance de **PCI DSS**, lo que significa controles, evidencia y auditoría para todo el camino. El descubrimiento más la desidentificación invierte esto: aprendés exactamente dónde viven los datos regulados (acotado), los enmascarás o tokenizás en la ingesta para que el flujo de logs no lleve datos de titular de tarjeta, y el alcance de auditoría se reduce al sistema pequeño y deliberadamente diseñado que sí los contiene. El alcance ilimitado es lo que hace caro el cumplimiento; la reducción de alcance *es* el retorno de la inversión.

### Ejercicio 5 — Red y perímetro

**A5.1** **Cloud Armor** filtra tráfico **entrante** en el edge de Google: DDoS volumétrico L3/L4, y ataques de aplicación L7 (SQLi, XSS, RCE, LFI) mediante reglas WAF. **VPC Service Controls** restringe el acceso **saliente** y a través de fronteras hacia las APIs de Google: define un perímetro del que los datos no pueden salir, independientemente de IAM. Solo Cloud Armor detiene una inyección SQL desde internet; solo VPC Service Controls detiene a un usuario autorizado copiando una tabla de BigQuery a un proyecto personal.

**A5.2** On-premises, la protección contra DDoS se compra como **capacidad que hay que poseer por adelantado** — appliances de scrubbing, ancho de banda aguas arriba y un contrato con un proveedor dimensionado para un ataque que puede no llegar nunca. Eso es gasto de capital y una pérdida permanente de utilización. En Google Cloud, la absorción ocurre en infraestructura de edge global compartida y dimensionada para el propio tráfico de Google; consumís una *capacidad*, no capacidad reservada, y el tráfico de ataque descartado en el edge nunca se convierte en tu factura de egreso. La forma cambia de *costo fijo por capacidad pico* a *costo variable por servicio real*.

**A5.3** IAM responde "¿puede esta identidad realizar esta acción?" — y en el escenario de exfiltración la respuesta es legítimamente *sí*, porque la credencial tiene `storage.objects.get` por una razón de negocio. Una credencial comprometida, un insider malicioso o una service account key filtrada pasan por lo tanto todas las comprobaciones de IAM en el camino de salida. VPC Service Controls hace una pregunta distinta — "¿puede este dato cruzar esta frontera?" — y rechaza la copia a un proyecto externo aunque la identidad esté plenamente autorizada, que es exactamente la brecha que IAM estructuralmente no puede cerrar.

**A5.4** En orden: **(1)** absorción de DDoS volumétrico en el edge / GFE de Google → **(2)** WAF de Cloud Armor y evaluación de reglas (SQLi, XSS, geo, rate limiting) → **(3)** Cloud Load Balancing y terminación TLS con un certificado gestionado → **(4)** reglas de firewall de VPC / Cloud NGFW y red privada (sin IP externa, por org policy) → **(5)** autenticación y autorización IAM de la identidad que llama → **(6)** evaluación del perímetro de VPC Service Controls en la llamada a la API de BigQuery → **(7)** políticas de acceso a nivel de columna y cifrado en reposo con CMEK → **(8)** detección: Event Threat Detection y audit logs registrando todo el camino. Que falle una sola capa no produce una brecha.

### Ejercicio 6 — Detección

**A6.1** Un hallazgo de **mala configuración** dice que un recurso está en un *estado* riesgoso — un bucket público, sin MFA, una service account con privilegios excesivos — sin evidencia de que alguien lo haya explotado; **Security Health Analytics** los produce. Un hallazgo de **amenaza** dice que algo *ocurrió* — otorgamientos IAM anómalos, comportamiento de criptominería, conexiones a infraestructura maliciosa conocida; los producen **Event Threat Detection**, **Container Threat Detection** y **VM Threat Detection**. Ambos son necesarios porque corregir malas configuraciones reduce la superficie de ataque pero no puede detectar a un atacante usando credenciales legítimas, y la detección de amenazas atrapa la intrusión en vivo pero llega después de la exposición que creó la mala configuración.

**A6.2** Cerrar un hallazgo afirma que fue **remediado**; silenciarlo afirma que fue **revisado y aceptado como riesgo conocido**, con un filtro, un responsable y un motivo declarado, y el hallazgo sigue siendo consultable. A un auditor le importa porque son resultados de control distintos: el riesgo aceptado debe estar documentado, atribuido y revisado periódicamente, mientras que un hallazgo cerrado-pero-no-corregido es una excepción indocumentada que esconde una exposición real y se ve idéntica a una remediación genuina en las métricas.

**A6.3**
*Solo el analista aporta:* contexto de negocio (qué sistema importa realmente, qué hallazgo "crítico" está sobre un servicio dado de baja); criterio en casos ambiguos y la autoridad para tomar la decisión; relaciones con los equipos de ingeniería que hacen que los hallazgos efectivamente se corrijan; coordinación de respuesta a incidentes con humanos en el circuito; redacción de políticas y decisiones de aceptación de riesgo.
*Solo Premium aporta:* cobertura 24/7/365 sin fatiga, vacaciones ni rotación; cobertura completa y continua de cada recurso en cada proyecto, incluidos los que nadie le contó al analista; contenido de detección escrito a partir de la visibilidad global de amenazas de Google y de Mandiant; simulación de rutas de ataque en todo el parque; mapeo continuo de cumplimiento a CIS/PCI DSS/NIST/ISO.
La conclusión correcta es que son **complementarios, no sustitutos** — Premium es lo que hace que un solo analista sea efectivo a una escala que de otro modo requeriría un equipo.

**A6.4** *"Mandiant trabaja las mayores brechas del mundo, y desde que Google la adquirió, lo que aprenden en esa primera línea se convierte en detección corriendo en nuestro entorno — así que nos defiende inteligencia proveniente de incidentes de los que nunca fuimos parte."*

### Ejercicio 7 — Cadena de suministro

**A7.1** Un escáner detecta vulnerabilidades **conocidas** en el artefacto que se le entrega. Binary Authorization detiene una **imagen de apariencia legítima, sin CVEs, que tu pipeline no construyó** — una imagen sustituida o con backdoor subida con una credencial de registry comprometida, un desarrollador saltándose CI, o un atacante con acceso de despliegue. No hay CVE que encontrar, porque el código malicioso no es una vulnerabilidad conocida en un paquete público; la única propiedad detectable es que la imagen carece de una attestation de tu sistema de build.

**A7.2** El cliente paga por **procedencia y aseguramiento** — paquetes construidos, escaneados, fuzzeados y firmados dentro del propio pipeline de Google con procedencia de build SLSA y un SBOM, respaldados por el enriquecimiento de vulnerabilidades de Google — no por el código en sí, que sigue siendo open source. El cheque lo firma quien sea dueño de los resultados de auditoría y regulatorios (CISO, riesgo o compliance), porque la compra es un artefacto de evidencia para auditores y clientes, no una característica para desarrolladores.

**A7.3** **Build:** Assured OSS y Artifact Analysis (¿los ingredientes y la imagen resultante están limpios?). **Deploy:** Binary Authorization (¿es este el artefacto que nuestro pipeline produjo y aprobó?). **Run:** Container Threat Detection, VPC Service Controls, IAM (¿se está comportando la carga de trabajo en ejecución, y puede alcanzar datos que no debería?). La profundidad es necesaria en cada punto porque cada control es ciego a los modos de falla de los otros: un escáner perfecto se elude sustituyendo la imagen después del escaneo; una compuerta de despliegue perfecta no puede ver un contenedor comprometido en runtime por un zero-day; y la detección en runtime por sí sola atrapa el ataque solo cuando ya se está ejecutando en producción.

### Ejercicio 8 — Capa del operador

**A8.1** **Access Transparency** produce logs casi en tiempo real que registran cuándo el personal de Google accedió a tu contenido y por qué — es **detectivo**. **Access Approval** exige tu aprobación explícita antes de que ese acceso pueda ocurrir — es **preventivo**.

**A8.2** Datos **en uso** (en memoria durante el procesamiento). Ejemplos: analítica multiparte entre bancos o aseguradoras competidores sobre datos de fraude mancomunados; investigación genómica y clínica donde datos de pacientes de múltiples instituciones deben analizarse conjuntamente; cargas de trabajo soberanas o de defensa donde el operador debe ser demostrablemente incapaz de observar el procesamiento; y modelado financiero confidencial bajo restricciones de M&A. En cada caso, el bloqueo no era el almacenamiento ni el transporte — ambos ya estaban resueltos — sino el momento del cómputo.

**A8.3** Con Cloud EKM el material de clave vive fuera de Google; con Key Access Justifications, cada solicitud de desenvoltura llega con un código de motivo legible por máquina que el key manager del cliente puede aprobar automáticamente o **denegar**. La garantía es que la capacidad de Google de descifrar no está meramente restringida por política, sino técnicamente condicionada a una aprobación que el cliente controla y registra, dándole al cliente un veto unilateral y auditable. La parte en la que todavía hay que confiar es el **fabricante de la CPU/hardware** cuyo procesador seguro y atestación sustentan la Computación Confidencial — más, en rigor, la implementación correcta por parte de Google del reporte de justificaciones.

**A8.4** *"Primero, transparencia: obtenemos un log de cada acceso del personal del proveedor, con el motivo y el ticket — algo que ningún centro de datos on-premises nos da sobre nuestros propios contratistas. Segundo, aprobación: nada ocurre sin nuestra autorización explícita, por solicitud, aplicada por la plataforma. Tercero, imposibilidad técnica: con Computación Confidencial y gestión externa de claves, el personal del proveedor no puede leer los datos aunque quisiera, porque la memoria está cifrada por la CPU y la clave la tenemos nosotros."*

### Ejercicio 9 — Cumplimiento y riesgo

**A9.1**
- **IaaS** — el **cliente** parchea el SO invitado. Máximo control, y una carga operativa permanente y no diferenciadora: ciclos de parcheo, ventanas de mantenimiento, seguimiento de CVEs, y un equipo de plataforma pequeño gastando una porción significativa de su capacidad en trabajo no diferenciado.
- **PaaS** — **Google** parchea el SO y el runtime; el cliente es dueño del código de la aplicación, de sus datos y de sus accesos. El equipo pequeño redirige esa capacidad al producto.
- **SaaS** — **Google** es dueño de todo hasta la aplicación; el cliente es dueño solo de los datos, los usuarios, los accesos y la configuración. Máximo apalancamiento por ingeniero, mínimo control sobre el stack.
La consecuencia de negocio: para un equipo de plataforma pequeño, subir por esta escalera es la diferencia entre plantilla gastada en mantenimiento y plantilla gastada en ingresos.

**A9.2** Las certificaciones de cumplimiento suelen ser **compuertas de venta**, no solo obligaciones de auditoría. Un comprador del sector salud no firma hasta que puedas evidenciar controles alineados con HIPAA; un comprador del sector público no firma sin FedRAMP. Construir esa evidencia desde cero significa una ventana de observación de varios meses antes de que exista el primer informe — así que el acuerdo no se pierde, se *pospone más allá del ejercicio fiscal*. Heredar la infraestructura certificada de Google y acotar tu propia auditoría a la capa de aplicación comprime esa ventana, lo que adelanta el ingreso reconocido. A un CFO: *el cumplimiento acá no es una línea de costo, es una fecha en el pronóstico de ingresos.*

**A9.3** **Responsabilidad compartida:** una división contractual de deberes — Google asegura la infraestructura *de* la nube, el cliente asegura lo que construye *en* la nube. **Destino compartido:** Google toma una participación activa en el éxito del cliente aportando configuraciones seguras por defecto, blueprints y landing zones, guardrails, telemetría continua de postura y un camino para transferir el riesgo residual. La evidencia más clara de destino compartido es el **Risk Protection Program** — los partners de Google, Munich Re y Allianz, suscriben seguro cibernético con precio basado en los datos de postura de Security Command Center, lo que significa que un tercero pone dinero detrás de la efectividad del modelo.

**A9.4** **`constraints/gcp.resourceLocations`** aborda la mitad de *residencia de datos* — impide que se creen recursos fuera de las regiones permitidas. **Assured Workloads** (régimen `EU_REGIONS_AND_SUPPORT`) aborda la mitad de *personal* — restringe qué personal de soporte de Google, en qué jurisdicciones, puede acceder a la carga de trabajo, y aplica la garantía de residencia como una propiedad de la carpeta. La org policy por sí sola es insuficiente porque gobierna **dónde viven los recursos**, no **quién en Google puede tocarlos**; residencia sin controles de personal no satisface un requisito de soberanía.

### Ejercicio 10 — Síntesis

**A10.1** La defensa en profundidad significa que la falla de un solo control no se convierte en una brecha, de modo que el resultado de seguridad de la organización ya no depende de que un control, proveedor, configuración o persona en particular sea perfecto.

**A10.2** La **capa de gobernanza (ejercicio 2): las restricciones de organization policy.** Es gratuita, lleva horas en lugar de meses, no requiere personal de seguridad para operarla porque la API la aplica, se aplica retroactivamente a todo proyecto y prospectivamente a todo proyecto aún no creado, y elimina las malas configuraciones que explican la mayoría de los incidentes en la nube. Todas las demás capas necesitan que alguien las mire; esta no. Una respuesta alternativa defendible es **Security Command Center Standard**, con el argumento de que no podés priorizar lo que no podés ver — pero el argumento de costo-beneficio favorece la prevención cuando no hay nadie para clasificar hallazgos.

**A10.3** Cadena de ejemplo: un desarrollador sube una service account key a un repositorio público (capa 1 — higiene de secretos — falla); un atacante la encuentra en minutos y se autentica con éxito (capa 2 — IAM — otorga acceso, porque la credencial es válida y los permisos son reales); el atacante intenta copiar el dataset de BigQuery a un proyecto que controla, y el **perímetro de VPC Service Controls rechaza el egreso** (la capa 3 aguanta); el intento escribe un audit log, Event Threat Detection levanta un hallazgo de acceso anómalo, y la clave se revoca dentro de la hora (la capa 4 responde). Dos capas fallaron por completo y una — un perímetro que no cuesta nada por petición y que nadie miraba — convirtió una brecha en un ticket. Eso no es redundancia; cada capa es una *pregunta distinta*, y al atacante le bastó con equivocarse una vez.

</details>

---

## Fuentes

- Google Cloud, *Cloud Digital Leader Certification Exam Guide* — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Google Cloud, *Google infrastructure security design overview* — https://cloud.google.com/docs/security/infrastructure/design
- Google Cloud, *Default encryption at rest* — https://cloud.google.com/docs/security/encryption/default-encryption
- Google Cloud, *Encryption in transit in Google Cloud* — https://cloud.google.com/docs/security/encryption-in-transit
- Google Cloud, *Organization Policy Service overview* — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Google Cloud, *Role recommendations overview* — https://cloud.google.com/policy-intelligence/docs/role-recommendations-overview
- Google Cloud, *Chrome Enterprise Premium documentation* — https://cloud.google.com/chrome-enterprise-premium/docs
- Google Cloud, *BeyondCorp: zero trust* — https://cloud.google.com/beyondcorp
- Google Cloud, *Cloud Key Management Service documentation* — https://cloud.google.com/kms/docs
- Google Cloud, *Cloud KMS Autokey overview* — https://cloud.google.com/kms/docs/autokey/overview
- Google Cloud, *Sensitive Data Protection documentation* — https://cloud.google.com/sensitive-data-protection/docs
- Google Cloud, *Cloud Armor security policy overview* — https://cloud.google.com/armor/docs/security-policy-overview
- Google Cloud, *VPC Service Controls overview* — https://cloud.google.com/vpc-service-controls/docs/overview
- Google Cloud, *Security Command Center overview* — https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Google Cloud, *Google Security Operations* — https://cloud.google.com/security/products/security-operations
- Google Cloud, *Google Threat Intelligence* — https://cloud.google.com/security/products/threat-intelligence
- Google Cloud, *Binary Authorization overview* — https://cloud.google.com/binary-authorization/docs/overview
- Google Cloud, *Assured Open Source Software overview* — https://cloud.google.com/assured-open-source-software/docs/overview
- Google Cloud, *Software supply chain security* — https://cloud.google.com/software-supply-chain-security/docs/overview
- Google Cloud, *Access Transparency overview* — https://cloud.google.com/logging/docs/audit/access-transparency-overview
- Google Cloud, *Access Approval overview* — https://cloud.google.com/assured-workloads/access-approval/docs/overview
- Google Cloud, *Key Access Justifications overview* — https://cloud.google.com/assured-workloads/key-access-justifications/docs/overview
- Google Cloud, *Confidential VM overview* — https://cloud.google.com/confidential-computing/confidential-vm/docs/confidential-vm-overview
- Google Cloud, *Assured Workloads overview* — https://cloud.google.com/assured-workloads/docs/overview
- Google Cloud, *Compliance Reports Manager* — https://cloud.google.com/security/compliance/compliance-reports-manager
- Google Cloud, *Risk Protection Program* — https://cloud.google.com/security/risk-protection-program
- Google Cloud Architecture Framework, *Shared responsibility and shared fate* — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate