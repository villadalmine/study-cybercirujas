# Ejercicios Guiados — Tema 3.3: Generación de Audit Trails y Enforcement de Compliance

> **Contexto del examen (CNPE, peso 3).** Estos ejercicios cubren la cadena completa de evidencia de una plataforma cloud-native: generar el *Software Bill of Materials* (SBOM), firmarlo y atestiguarlo, transformar los hallazgos de seguridad en *compliance reports* consumibles, capturar el *audit trail* del API server, y hacer *enforcement* de políticas con reportes agregados. El hilo conductor es siempre el mismo: **una afirmación de compliance solo vale lo que vale la evidencia que la respalda**.
>
> **Fuente de referencia:** [CNPE Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

**Prerrequisitos.** Un cluster Kubernetes ≥ 1.28 (kind/minikube sirve, pero para el Lab 4 de audit logging necesitás acceso a los flags del API server, es decir kind o un cluster con control plane accesible), `kubectl`, y las CLIs `syft`, `grype`, `cosign`, `trivy`, `kube-bench` y `helm`. Todos los comandos asumen `bash`. Las salidas están recortadas con `[...]` donde el volumen no aporta.

---

## Lab 1 — Generar un SBOM y derivar un vulnerability report

Un SBOM es el inventario firmable de *qué hay dentro* de un artefacto. Es el insumo, no el veredicto: primero se genera el inventario (Syft), después se lo evalúa contra una base de vulnerabilidades (Grype). Separar ambos pasos es lo que permite re-escanear un SBOM viejo cuando aparece un CVE nuevo, **sin volver a tener la imagen**.

### Pasos

1. Elegí una imagen concreta y anclada por digest (nunca `latest` en evidencia de compliance) y generá el SBOM en formato **CycloneDX JSON**:

   ```bash
   IMG="nginx:1.27.3"
   syft "$IMG" -o cyclonedx-json=sbom-nginx.cdx.json
   ```

   Salida esperada (a `stderr`):

   ```
    ✔ Loaded image                nginx:1.27.3
    ✔ Parsed image                sha256:3b25b682ea82b2db3cc4fd48db818be788ee3f902ac7378090cf2624ec2442df
    ✔ Cataloged contents          sha256:0a4be2d[...]
      ├── ✔ Packages                    [156 packages]
      ├── ✔ File digests                [2 files]
      └── ✔ Executables                 [712 executables]
   ```

2. Inspeccioná la cabecera del SBOM y contá los componentes. Fijate en el `bom-ref` y en que cada componente lleve su `purl` (package URL):

   ```bash
   jq '{format:.bomFormat, spec:.specVersion, serial:.serialNumber, componentes:(.components|length)}' sbom-nginx.cdx.json
   jq -r '.components[] | select(.name=="openssl") | .purl' sbom-nginx.cdx.json
   ```

   Salida esperada:

   ```
   {
     "format": "CycloneDX",
     "spec": "1.6",
     "serial": "urn:uuid:8f2a1c4e-5b6d-4e3a-9f10-2c3d4e5f6a7b",
     "componentes": 156
   }
   pkg:deb/debian/openssl@3.0.15-1~deb12u1?arch=amd64&distro=debian-12
   ```

3. Ahora evaluá **ese mismo SBOM** contra la base de datos de Grype. Notá que Grype consume el archivo, no la imagen:

   ```bash
   grype sbom:sbom-nginx.cdx.json -o table
   ```

   Salida esperada (recortada):

   ```
    ✔ Vulnerability DB            [updated]
    ✔ Scanned for vulnerabilities [43 vulnerability matches]
      ├── by severity: 2 critical, 8 high, 19 medium, 14 low, 0 negligible
      └── by status:   0 fixed, 43 not-fixed
   NAME     INSTALLED         FIXED-IN  TYPE  VULNERABILITY   SEVERITY
   libc6    2.36-9+deb12u9              deb   CVE-2025-xxxxx  High
   openssl  3.0.15-1~deb12u1           deb   CVE-2024-xxxxx  Medium
   [...]
   ```

4. Generá el reporte en un formato consumible por máquina para el pipeline de compliance y filtrá por severidad accionable:

   ```bash
   grype sbom:sbom-nginx.cdx.json -o json > vulns-nginx.json
   jq '[.matches[] | select(.vulnerability.severity=="Critical" or .vulnerability.severity=="High")] | length' vulns-nginx.json
   ```

5. Volvé a escanear el SBOM **una semana después** (simulado con `grype db update`) para demostrar el desacople: aparecen CVEs nuevos sin tocar la imagen.

   ```bash
   grype db update && grype sbom:sbom-nginx.cdx.json -o table | head -3
   ```

### Preguntas de comprensión

- **1.1** ¿Por qué se genera el SBOM en un paso y el vulnerability scan en otro, en lugar de correr `grype nginx:1.27.3` directamente?
- **1.2** ¿Qué información codifica el `purl` `pkg:deb/debian/openssl@3.0.15-1~deb12u1?arch=amd64&distro=debian-12` y por qué es más robusta que el par `(nombre, versión)` a secas para el matching de CVEs?
- **1.3** El reporte dice `by status: 0 fixed, 43 not-fixed`. ¿Qué decisión de política tomarías distinta ante un CVE `High` con `FIXED-IN` poblado versus uno `not-fixed`?
- **1.4** ¿Por qué anclar la imagen por digest (`@sha256:...`) es un requisito y no una recomendación para un SBOM que va a servir como evidencia de auditoría?

---

## Lab 2 — Firmar y atestiguar el SBOM (cadena de custodia)

Un SBOM sin firma es un archivo de texto que cualquiera puede editar. El valor de compliance aparece cuando el SBOM se convierte en una **attestation**: una afirmación firmada, ligada criptográficamente al digest de la imagen, verificable por un tercero. Usamos `cosign` con **keyless signing** (OIDC + transparency log Rekor), que es lo que subyace a SLSA.

### Pasos

1. Generá un par de claves de cosign para el ejercicio (en producción preferirías keyless):

   ```bash
   cosign generate-key-pair
   # genera cosign.key (privada, protegida por passphrase) y cosign.pub
   ```

2. Firmá la imagen por su digest. **Nunca firmes por tag**, porque el tag es mutable:

   ```bash
   IMG_DIGEST="ghcr.io/miorg/api@sha256:9c3e2b1a0f4d5e6c7b8a9f0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a7f8e9d0c"
   cosign sign --key cosign.key "$IMG_DIGEST"
   ```

   Salida esperada:

   ```
   Pushing signature to: ghcr.io/miorg/api
   tlog entry created with index: 148372910
   ```

3. Adjuntá el SBOM del Lab 1 como una **attestation** de tipo CycloneDX, ligada al digest:

   ```bash
   cosign attest --key cosign.key \
     --predicate sbom-nginx.cdx.json \
     --type cyclonedx \
     "$IMG_DIGEST"
   ```

4. Verificá la firma y la attestation como lo haría un admission controller en el cluster:

   ```bash
   cosign verify --key cosign.pub "$IMG_DIGEST"
   cosign verify-attestation --key cosign.pub --type cyclonedx "$IMG_DIGEST" \
     | jq -r '.payload' | base64 -d | jq '.predicateType'
   ```

   Salida esperada del `verify-attestation`:

   ```
   "https://cyclonedx.org/bom"
   ```

5. Demostrá la propiedad de *tamper-evidence*: alterá una copia del SBOM y verificá que la attestation firmada ya no coincide.

   ```bash
   jq '.metadata.timestamp = "1970-01-01T00:00:00Z"' sbom-nginx.cdx.json > sbom-tampered.json
   # La attestation en el registry sigue firmando el SBOM original;
   # verify-attestation compara contra lo firmado, no contra el archivo local.
   ```

### Preguntas de comprensión

- **2.1** ¿Cuál es la diferencia funcional entre `cosign sign` y `cosign attest`? ¿Qué afirma cada uno?
- **2.2** En keyless signing no hay claves de larga vida. ¿Qué rol cumple el transparency log **Rekor** y por qué su `tlog entry` es central para el no-repudio?
- **2.3** Firmar por tag (`ghcr.io/miorg/api:v1.2.0`) en lugar de por digest abre una clase entera de ataques. Describí uno.
- **2.4** ¿En qué nivel de SLSA (Supply-chain Levels for Software Artifacts) empieza a ser obligatorio que la *provenance* sea generada por un builder aislado y no falsificable por el desarrollador?

---

## Lab 3 — Enforcement de política en admisión con Kyverno + Policy Reports

El SBOM y las firmas no sirven de nada si el cluster admite igual una imagen sin firmar. Acá cerramos el lazo: una policy de admisión que **rechaza** lo no conforme, y un **PolicyReport** (la API estándar de `wg-policy` de Kubernetes) que deja el audit trail de lo que ya está corriendo.

### Pasos

1. Instalá Kyverno:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   kubectl -n kyverno get pods
   ```

2. Aplicá una policy en modo `Audit` primero (observar antes de bloquear) que exige que toda imagen venga de un registry aprobado:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-image-registries
   spec:
     validationFailureAction: Audit          # observar, todavía no bloquear
     background: true                          # también evalúa recursos ya existentes
     rules:
       - name: validate-registry
         match:
           any:
             - resources:
                 kinds: [Pod]
         validate:
           message: "Las imágenes deben venir de ghcr.io/miorg o registry.k8s.io"
           pattern:
             spec:
               containers:
                 - image: "ghcr.io/miorg/* | registry.k8s.io/*"
   ```

   ```bash
   kubectl apply -f restrict-registries.yaml
   ```

3. Desplegá un pod violatorio y observá que **se admite** (estamos en `Audit`), pero queda registrado:

   ```bash
   kubectl run rogue --image=docker.io/library/redis:7
   kubectl get policyreport -A
   ```

   Salida esperada:

   ```
   NAMESPACE   NAME                                  PASS   FAIL   WARN   ERROR   SKIP   AGE
   default     pol-ns-default                        4      1      0      0       0      30s
   ```

4. Leé el detalle del audit trail que generó la policy:

   ```bash
   kubectl get policyreport -n default -o json \
     | jq -r '.items[].results[] | select(.result=="fail") | "\(.policy)/\(.rule): \(.resources[0].name) → \(.message)"'
   ```

   Salida esperada:

   ```
   restrict-image-registries/validate-registry: rogue → validation error: Las imágenes deben venir de ghcr.io/miorg o registry.k8s.io
   ```

5. Endurecé la política: cambiá a `Enforce` y comprobá que el mismo pod ahora **es rechazado en admisión**:

   ```bash
   kubectl patch clusterpolicy restrict-image-registries \
     --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
   kubectl run rogue2 --image=docker.io/library/redis:7
   ```

   Salida esperada:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/rogue2 was blocked due to the following policies:

   restrict-image-registries:
     validate-registry: 'Las imágenes deben venir de ghcr.io/miorg o registry.k8s.io'
   ```

6. (Opcional, cierra el lazo con el Lab 2) Sumá una policy `verifyImages` que exige que la firma cosign valide contra `cosign.pub` antes de admitir:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-signed-images
   spec:
     validationFailureAction: Enforce
     webhookTimeoutSeconds: 30
     rules:
       - name: verify-signature
         match:
           any:
             - resources:
                 kinds: [Pod]
         verifyImages:
           - imageReferences:
               - "ghcr.io/miorg/*"
             attestors:
               - entries:
                   - keys:
                       publicKeys: |-
                         -----BEGIN PUBLIC KEY-----
                         MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcD[...]
                         -----END PUBLIC KEY-----
   ```

### Preguntas de comprensión

- **3.1** ¿Por qué la práctica recomendada es desplegar una policy nueva en `Audit` (`validationFailureAction: Audit`) antes de `Enforce`? ¿Qué te muestra el PolicyReport en esa fase que un cambio directo a `Enforce` te ocultaría?
- **3.2** El campo `background: true` cambia el alcance de la evaluación. ¿Qué recursos evalúa una policy con `background: true` que una con `background: false` no toca, y por qué importa para el audit trail?
- **3.3** `PolicyReport` es un recurso namespaced y `ClusterPolicyReport` es cluster-scoped. ¿Qué gana la organización al que estos reportes sean una **CRD estándar de la Kubernetes Policy Working Group** en vez de un formato propietario de Kyverno?
- **3.4** La policy `verifyImages` del paso 6 falla-cerrado si el registry de firmas está caído. Discutí el trade-off de `webhookTimeoutSeconds` y `failurePolicy` frente a la disponibilidad del cluster.

---

## Lab 4 — Audit trail del API server (quién hizo qué, cuándo)

El audit log de Kubernetes es la fuente de verdad forense a nivel control plane: registra cada request al API server, quién la hizo, sobre qué recurso y con qué resultado. A diferencia de los logs de aplicación, **no es opcional para un cluster regulado**. Configurar la `audit-policy` es decidir qué se graba y a qué nivel de detalle.

### Pasos

1. Escribí una **audit policy** con niveles diferenciados. La regla de oro: `RequestResponse` para lo sensible (secrets, RBAC), `Metadata` para lo ruidoso, y descartar el ruido de health checks:

   ```yaml
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages:
     - RequestReceived            # no duplicar cada request en su etapa inicial
   rules:
     # No auditar los reads de baja sensibilidad de los propios componentes
     - level: None
       users: ["system:kube-proxy"]
       verbs: ["watch"]
       resources:
         - group: ""
           resources: ["endpoints", "services"]
     # Descartar los probes de salud
     - level: None
       nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/metrics"]
     # Máximo detalle para secrets y configmaps: cuerpo de request y response
     - level: RequestResponse
       resources:
         - group: ""
           resources: ["secrets", "configmaps"]
     # RBAC: quién cambió permisos, con cuerpo completo
     - level: RequestResponse
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
     # Todo lo demás, metadata (quién, qué, cuándo, resultado — sin payload)
     - level: Metadata
   ```

2. En kind, montá la policy y activá el audit log editando la config del cluster (`kind-audit.yaml`):

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   nodes:
     - role: control-plane
       extraMounts:
         - hostPath: ./audit-policy.yaml
           containerPath: /etc/kubernetes/audit-policy.yaml
         - hostPath: ./audit-logs
           containerPath: /var/log/kubernetes
       kubeadmConfigPatches:
         - |
           kind: ClusterConfiguration
           apiServer:
             extraArgs:
               audit-policy-file: /etc/kubernetes/audit-policy.yaml
               audit-log-path: /var/log/kubernetes/audit.log
               audit-log-maxage: "30"
               audit-log-maxbackup: "10"
               audit-log-maxsize: "100"
             extraVolumes:
               - name: audit-policy
                 hostPath: /etc/kubernetes/audit-policy.yaml
                 mountPath: /etc/kubernetes/audit-policy.yaml
                 readOnly: true
                 pathType: File
               - name: audit-logs
                 hostPath: /var/log/kubernetes
                 mountPath: /var/log/kubernetes
                 pathType: DirectoryOrCreate
   ```

   ```bash
   kind create cluster --config kind-audit.yaml
   ```

3. Generá actividad auditable: creá un secret y borralo.

   ```bash
   kubectl create secret generic db-cred --from-literal=password=s3cr3t
   kubectl delete secret db-cred
   ```

4. Extraé del audit log **quién creó el secret**, filtrando por verbo y recurso:

   ```bash
   jq -c 'select(.objectRef.resource=="secrets" and .verb=="create")
          | {user:.user.username, verb, resource:.objectRef.name, ts:.requestReceivedTimestamp, code:.responseStatus.code}' \
     audit-logs/audit.log
   ```

   Salida esperada:

   ```json
   {"user":"kubernetes-admin","verb":"create","resource":"db-cred","ts":"2026-08-07T14:22:31.004Z","code":201}
   ```

5. Verificá la propiedad clave de tu policy: que **el valor del secret NO quede grabado en texto plano** aun con `level: RequestResponse`.

   ```bash
   grep -o 's3cr3t' audit-logs/audit.log | head -1 || echo "OK: el payload del secret no está en el log"
   ```

### Preguntas de comprensión

- **4.1** Enumerá los cuatro niveles de audit (`None`, `Metadata`, `Request`, `RequestResponse`) y qué captura exactamente cada uno.
- **4.2** ¿Por qué la primera regla que matchea en una audit policy es la que gana? ¿Qué pasaría si pusieras `- level: Metadata` (el catch-all) como **primera** regla en vez de última?
- **4.3** En el paso 5 esperamos que el valor `s3cr3t` **no** aparezca aunque el nivel sea `RequestResponse`. ¿Por qué el API server igual redacta el `data` de un Secret en el audit log? ¿Qué implica esto para tu confianza en el log como evidencia?
- **4.4** ¿Por qué `omitStages: [RequestReceived]` es una optimización sensata y no una pérdida de evidencia forense relevante?

---

## Lab 5 — CIS Benchmark del cluster con kube-bench

Los *compliance reports* del control plane suelen expresarse contra un benchmark reconocido. El **CIS Kubernetes Benchmark** es el de facto, y `kube-bench` lo automatiza: corre como un Job en el cluster y produce un reporte con `PASS`/`FAIL`/`WARN` mapeado a cada control.

### Pasos

1. Corré kube-bench como Job (imagen oficial de Aqua Security):

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
   kubectl wait --for=condition=complete job/kube-bench --timeout=120s
   ```

2. Leé el reporte:

   ```bash
   kubectl logs job/kube-bench
   ```

   Salida esperada (recortada):

   ```
   [INFO] 1 Control Plane Security Configuration
   [INFO] 1.2 API Server
   [PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
   [FAIL] 1.2.5 Ensure that the --kubelet-certificate-authority argument is set as appropriate
   [WARN] 1.2.15 Ensure that the --profiling argument is set to false
   [...]
   == Summary total ==
   52 checks PASS
   9 checks FAIL
   11 checks WARN
   0 checks INFO
   ```

3. Generá el reporte en JSON para ingestarlo en un dashboard de compliance:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: kube-bench-json
   spec:
     template:
       spec:
         hostPID: true
         containers:
           - name: kube-bench
             image: docker.io/aquasec/kube-bench:latest
             command: ["kube-bench", "--json"]
             volumeMounts:
               - { name: var-lib-etcd, mountPath: /var/lib/etcd, readOnly: true }
               - { name: etc-kubernetes, mountPath: /etc/kubernetes, readOnly: true }
         restartPolicy: Never
         volumes:
           - { name: var-lib-etcd, hostPath: { path: /var/lib/etcd } }
           - { name: etc-kubernetes, hostPath: { path: /etc/kubernetes } }
   EOF
   kubectl logs job/kube-bench-json | jq '[.Totals]'
   ```

4. Extraé únicamente los `FAIL` con su remediación, que es lo accionable del reporte:

   ```bash
   kubectl logs job/kube-bench-json \
     | jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | "\(.test_number)  \(.test_desc)\n   → \(.remediation)"'
   ```

   Salida esperada (recortada):

   ```
   1.2.5  Ensure that the --kubelet-certificate-authority argument is set as appropriate
      → Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
        and set --kubelet-certificate-authority to the location of the CA cert file.
   ```

### Preguntas de comprensión

- **5.1** ¿Cuál es la diferencia semántica entre un `FAIL` y un `WARN` en kube-bench, y por qué muchos controles de tipo "manual" caen en `WARN`?
- **5.2** kube-bench necesita `hostPID: true` y montar `/etc/kubernetes` y `/var/lib/etcd`. ¿Por qué? ¿Qué implicancia de seguridad tiene correr un Job con esos privilegios y cómo lo justificás en el reporte de compliance?
- **5.3** El benchmark tiene secciones separadas para *control plane* (`master`) y *worker nodes* (`node`). En un cluster gestionado (EKS/GKE/AKS) no tenés acceso al control plane. ¿Qué subconjunto del benchmark seguís siendo responsable de cumplir y cuál delega el proveedor?
- **5.4** Un control `PASS` de kube-bench, ¿prueba que el cluster es seguro? Relacioná tu respuesta con la tabla de "qué está probado y qué se asume" del método de verificación.

---

## Lab 6 — Agregar todo: Trivy Operator + Policy Reporter como panel de compliance

Los labs anteriores producen evidencia dispersa (SBOMs, PolicyReports, benchmark JSON). El último paso de plataforma es **agregarla continuamente**. El **Trivy Operator** escanea de forma permanente todo lo que corre en el cluster y publica los hallazgos como CRDs (`VulnerabilityReport`, `ConfigAuditReport`, `ClusterComplianceReport`), reusando el mismo estándar `PolicyReport` del Lab 3.

### Pasos

1. Instalá el Trivy Operator:

   ```bash
   helm repo add aqua https://aquasecurity.github.io/helm-charts/ && helm repo update
   helm install trivy-operator aqua/trivy-operator \
     -n trivy-system --create-namespace \
     --set="trivy.ignoreUnfixed=true"
   ```

2. Desplegá una app de prueba y dejá que el operator la escanee automáticamente (crea un Job por workload):

   ```bash
   kubectl create deployment demo --image=nginx:1.27.3
   kubectl get vulnerabilityreports -A -w    # Ctrl-C cuando aparezca la fila
   ```

   Salida esperada:

   ```
   NAMESPACE   NAME                                REPOSITORY      TAG      CRITICAL  HIGH  MEDIUM  LOW
   default     replicaset-demo-7d9c-nginx          library/nginx   1.27.3   2         8     19      14
   ```

3. Consultá el **ClusterComplianceReport** contra el estándar NSA/CISA "Kubernetes Hardening Guidance", que el operator trae precargado:

   ```bash
   kubectl get clustercompliancereport nsa -o json \
     | jq '.status.summary'
   ```

   Salida esperada:

   ```json
   {
     "passCount": 34,
     "failCount": 7
   }
   ```

4. Instalá **Policy Reporter** para tener UI y métricas Prometheus sobre todos los `PolicyReport` (los de Kyverno del Lab 3 y los de Trivy conviven en la misma API):

   ```bash
   helm repo add policy-reporter https://kyverno.github.io/policy-reporter && helm repo update
   helm install policy-reporter policy-reporter/policy-reporter \
     -n policy-reporter --create-namespace \
     --set ui.enabled=true --set metrics.enabled=true
   kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
   ```

5. Verificá que la métrica agregada de compliance esté expuesta para alerting:

   ```bash
   kubectl -n policy-reporter port-forward svc/policy-reporter 8080:8080 &
   curl -s localhost:8080/metrics | grep -E 'policy_report_result{.*status="fail"'
   ```

   Salida esperada:

   ```
   policy_report_result{namespace="default",policy="restrict-image-registries",rule="validate-registry",status="fail"} 1
   ```

### Preguntas de comprensión

- **6.1** El Trivy Operator y Kyverno publican ambos en la CRD `PolicyReport`. ¿Qué ventaja arquitectónica concreta obtiene Policy Reporter de ese estándar común?
- **6.2** Se instaló con `trivy.ignoreUnfixed=true`. ¿Qué esconde ese flag del reporte de compliance y en qué situación regulatoria sería inaceptable activarlo?
- **6.3** El `ClusterComplianceReport nsa` te da `passCount: 34, failCount: 7`. ¿Por qué ese número por sí solo es un **indicador engañoso** de postura de seguridad, y qué agregarías al reporte para hacerlo honesto?
- **6.4** Un scan continuo del operator versus un scan en el CI/CD pipeline (shift-left): ¿son redundantes o complementarios? Justificá con un CVE que aparece *después* del deploy.

---

## Síntesis — La cadena de evidencia completa

Cada lab produjo un eslabón. Ordenados, forman el audit trail defendible que pide el tema:

1. **SBOM** (Lab 1) — el inventario de qué hay adentro.
2. **Attestation firmada** (Lab 2) — el inventario, ligado criptográficamente al artefacto y no repudiable.
3. **Admission policy** (Lab 3) — nada no-conforme entra al cluster; lo que ya está queda en `PolicyReport`.
4. **Audit log del API server** (Lab 4) — quién hizo qué a nivel control plane.
5. **CIS Benchmark** (Lab 5) — la configuración del cluster contra un estándar reconocido.
6. **Agregación continua** (Lab 6) — todo lo anterior, vivo y consultable en una sola API.

> **Pregunta integradora (6.5):** Un auditor externo te pregunta: *"Probame que el pod `api-7f9c` que corre en producción no contiene la librería vulnerable a CVE-2024-XXXX y que nadie lo modificó desde el deploy."* Encadená los eslabones de los seis labs para responderle **con evidencia**, no con memoria.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Lab 1

**1.1** Porque el SBOM y la evaluación de vulnerabilidades tienen ciclos de vida distintos. El SBOM describe *qué contiene* el artefacto y no cambia mientras el artefacto no cambie; la base de vulnerabilidades cambia todos los días. Desacoplarlos permite: (a) re-escanear un artefacto histórico cuando aparece un CVE nuevo sin necesidad de conservar la imagen — a veces ni existe ya; (b) firmar el SBOM una sola vez (Lab 2) y re-evaluarlo cuantas veces haga falta; (c) auditar el inventario aunque el scanner esté offline. Correr `grype nginx:1.27.3` directo acopla ambos pasos y ata la evidencia a la disponibilidad de la imagen.

**1.2** El `purl` codifica *type* (`deb`), *namespace* (`debian`), *nombre* (`openssl`), *versión* (`3.0.15-1~deb12u1`) y *qualifiers* (`arch=amd64`, `distro=debian-12`). Es más robusto que `(nombre, versión)` porque el matching de CVEs depende del ecosistema y de la distro: el mismo `openssl 3.0.15` tiene distinto set de parches en Debian 12 que en Alpine o que upstream. Sin el `distro` qualifier, el scanner produce falsos positivos (reporta CVEs ya parcheados por el backport de la distro) o falsos negativos.

**1.3** Un CVE `High` con `FIXED-IN` poblado es accionable *ya*: existe una versión parcheada, la remediación es actualizar. Ese debería fallar la policy y bloquear el release. Un CVE `not-fixed` no tiene parche disponible upstream; bloquear el release no lo resuelve y solo frena la entrega. Ahí la política razonable es documentar una excepción con expiración (VEX — Vulnerability Exploitability eXchange), aplicar mitigaciones de runtime (network policy, seccomp) y monitorear hasta que aparezca el fix. Tratar ambos casos igual o bloquea entregas sin ganancia, o deja pasar deuda accionable.

**1.4** Porque un tag es un puntero mutable: `nginx:1.27.3` puede reapuntar a otra imagen mañana. Si el SBOM dice "esto es lo que había en `nginx:1.27.3`" pero el tag ya movió, la evidencia describe un artefacto que ya no existe en ese nombre y es indefendible ante un auditor. El digest `@sha256:...` es content-addressable: identifica *exactamente y para siempre* los bytes que se inventariaron. La evidencia de auditoría debe ser inmutable, y solo el digest lo garantiza.

### Lab 2

**2.1** `cosign sign` produce una **firma** sobre el digest de la imagen: afirma "yo, poseedor de esta clave, doy fe de este artefacto" — es identidad/integridad, sin contenido semántico. `cosign attest` produce una **attestation**: una firma sobre un *predicate* (un documento estructurado — un SBOM, un resultado de scan, una provenance SLSA) ligado al digest. Afirma "doy fe de que *esta afirmación específica* es verdadera sobre este artefacto". La firma dice "confío en esto"; la attestation dice "esto es verdad, y acá está la prueba".

**2.2** Rekor es un transparency log append-only y públicamente auditable. En keyless signing el certificado que emite Fulcio vive minutos (ligado a la identidad OIDC del firmante), así que la firma sola no se podría verificar después de que el cert expira. Rekor graba una entrada inmutable con timestamp que prueba *que la firma existió mientras el cert era válido*. Eso da no-repudio: el firmante no puede negar después haber firmado, y cualquiera puede verificar la inclusión (`tlog entry index`) contra un log que nadie puede reescribir sin que se note.

**2.3** *Tag confusion / mutable tag attack*: firmás `ghcr.io/miorg/api:v1.2.0` cuando apunta a un digest benigno. Después un atacante (o incluso un rebuild legítimo comprometido) reapunta el tag `v1.2.0` a una imagen maliciosa. La firma sigue "válida para el tag" en la percepción del operador, pero ya no cubre el digest que efectivamente corre. Firmar por digest lo elimina de raíz: la firma cubre bytes específicos, y el admission controller debe resolver el tag a digest y verificar *ese* digest.

**2.4** En **SLSA Build L3 (Nivel 3)**. L1 solo pide que exista provenance; L2 pide que sea firmada por un servicio de build hospedado; L3 exige un builder *aislado y endurecido* donde la provenance sea inforjable — el desarrollador no puede inyectar ni falsificar los campos, porque los genera el sistema de build, no el usuario. Ahí la provenance pasa de "declarativa" a "no repudiable".

### Lab 3

**3.1** Porque una policy en `Enforce` desde el minuto cero puede bloquear workloads legítimos que nadie sabía que violaban la regla, provocando un incidente de disponibilidad. En `Audit` la policy *evalúa y reporta* sin bloquear: el `PolicyReport` te muestra el conjunto real de recursos existentes que fallarían (`FAIL`) si pasaras a `Enforce`. Un salto directo a `Enforce` te oculta ese universo — te enterás de las violaciones una por una, a medida que rompen despliegues en producción. `Audit` primero convierte una sorpresa operativa en una lista de trabajo conocida.

**3.2** `background: true` evalúa también los **recursos que ya existen** en el cluster (mediante un scan periódico), no solo los que pasan por el admission webhook en el momento de crearse/modificarse. Con `background: false` la policy solo actúa en admisión: los recursos creados *antes* de la policy nunca se evalúan. Para el audit trail importa porque el compliance no es solo "qué rechazamos al entrar" sino "qué está corriendo ahora mismo que no cumple" — y eso requiere `background: true`.

**3.3** Al ser una CRD estándar de la Kubernetes Policy Working Group (`wgpolicyk8s.io`), múltiples productores (Kyverno, Trivy Operator, kube-bench-wrappers, Falco) escriben el **mismo** `PolicyReport`/`ClusterPolicyReport`, y múltiples consumidores (Policy Reporter, dashboards, alerting) lo leen sin acoplarse a ningún vendor. La organización evita lock-in: podés cambiar el motor de policy sin reescribir los dashboards, y agregás la evidencia de herramientas distintas en una sola vista (exactamente lo que explota el Lab 6).

**3.4** `failurePolicy: Fail` (fallar-cerrado) hace que, si el webhook de Kyverno no responde en `webhookTimeoutSeconds`, la admisión se *rechace*. Eso maximiza seguridad (nada entra sin verificar) pero acopla la disponibilidad del cluster a la del registry de firmas y del propio Kyverno: si Rekor/el registry están caídos, no podés desplegar *nada* que matchee la regla. `failurePolicy: Ignore` (fallar-abierto) prioriza disponibilidad pero abre una ventana donde imágenes sin verificar entran durante un outage del webhook. El trade-off correcto depende del blast radius: fallar-cerrado en clusters regulados/producción crítica de seguridad, con `webhookTimeoutSeconds` generoso y alta disponibilidad del propio Kyverno; fallar-abierto solo si un outage de admisión es peor que una ventana de imágenes sin verificar.

### Lab 4

**4.1**
- `None`: no genera ningún evento para los requests que matchean la regla (se usa para descartar ruido).
- `Metadata`: registra metadata del request — usuario, verbo, recurso, namespace, timestamp, código de respuesta — **sin** el cuerpo del request ni de la respuesta.
- `Request`: metadata **más** el cuerpo del request (qué se intentó crear/cambiar), sin el cuerpo de la respuesta.
- `RequestResponse`: metadata más el cuerpo del request **y** de la respuesta (el estado completo antes/después). Es el más caro en volumen y el más forense.

**4.2** Las reglas se evalúan en orden y **la primera que matchea define el nivel**; no se sigue evaluando. Si pusieras el catch-all `- level: Metadata` como primera regla, *todo* matchearía ahí y las reglas específicas de abajo (`RequestResponse` para secrets, `None` para health checks) nunca se aplicarían: perderías el detalle forense de los secrets y llenarías el log de ruido de probes. El catch-all debe ir **último**, precisamente porque es el que atrapa lo que ninguna regla específica capturó.

**4.3** Porque el API server **redacta** deliberadamente el campo `data`/`stringData` de los objetos Secret en el audit log, aun con `level: RequestResponse` — lo reemplaza por un marcador. Es una salvaguarda intencional: el propósito del audit log es registrar *quién tocó qué*, no convertirse en un depósito de secretos en texto plano (que sería un objetivo de robo). Implica que confiás en el log para el *quién/cuándo/qué recurso*, pero **no** debés esperar que contenga el valor del secreto, y —correctamente— no lo hace. Si vieras `s3cr3t` en el log, eso sí sería un hallazgo de seguridad grave.

**4.4** El ciclo de vida de un audit event tiene etapas (`RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`). `RequestReceived` se emite apenas llega el request, antes de saber el resultado; `ResponseComplete` ya trae el resultado final (código, latencia). Omitir `RequestReceived` elimina un evento duplicado por request sin perder nada forense: el evento `ResponseComplete` ya contiene el usuario, el verbo, el recurso y ahora *además* el resultado. Reducís el volumen del log a la mitad reteniendo el evento más informativo.

### Lab 5

**5.1** Un `FAIL` es un control *automatizable* que el benchmark pudo verificar y que **no cumple** el estado esperado (ej.: un flag mal seteado). Un `WARN` típicamente corresponde a controles *manuales* o dependientes de contexto que kube-bench no puede evaluar programáticamente (requieren juicio humano: "asegurate de que las políticas de red sean apropiadas para tu entorno"). El `WARN` no dice "está mal", dice "esto requiere que un humano lo verifique y documente". Un reporte de compliance honesto trata los `WARN` como trabajo pendiente de revisión manual, no como aprobados.

**5.2** kube-bench audita la configuración del **host** y del control plane: necesita leer los manifiestos estáticos en `/etc/kubernetes/manifests`, la config de etcd en `/var/lib/etcd`, y `hostPID` para inspeccionar los flags con que arrancaron los procesos del control plane. Correr un Job con esos montajes y `hostPID` es de por sí una operación privilegiada (podría leer secretos del control plane); se justifica porque es de *solo lectura* (`readOnly: true`), efímero (`restartPolicy: Never`), y su propósito es precisamente auditar. En el reporte de compliance se documenta como una excepción controlada y auditada, no como un privilegio permanente.

**5.3** En un cluster gestionado, el proveedor es responsable de la sección *control plane* (API server, controller-manager, scheduler, etcd) — vos no ves ni podés cambiar esos flags. Seguís siendo responsable de la sección **node/worker** (configuración del kubelet, permisos de archivos de config del nodo), de las **policies** (RBAC, Pod Security, Network Policies) y de las configuraciones de workload. El benchmark de EKS/GKE/AKS de CIS refleja justamente esa división: kube-bench tiene targets específicos (`--benchmark eks-1.x`) que omiten los controles que el proveedor cubre bajo el modelo de responsabilidad compartida.

**5.4** No, un `PASS` no prueba que el cluster sea seguro. kube-bench prueba que *ciertas configuraciones conocidas* están seteadas como el benchmark recomienda — es la rung "¿la configuración cumple el estándar?", no "¿el sistema es seguro?". No detecta un CVE en un workload, ni una policy de RBAC demasiado permisiva pero sintácticamente válida, ni un secreto expuesto, ni una lógica de aplicación vulnerable. Es exactamente la distinción de la tabla de verificación: "cumple el benchmark" y "es seguro" son afirmaciones sobre rungs distintas de la escalera; la primera es barata y automatizable, la segunda no la prueba ninguna herramienta sola.

### Lab 6

**6.1** Como Kyverno (config/admisión) y Trivy Operator (vulnerabilidades) escriben ambos en la CRD estándar `PolicyReport`, Policy Reporter los consume con **un solo integrador**: no necesita un parser por producto. Una única UI, un único set de métricas Prometheus y un único punto de alerting cubren admisión *y* vulnerabilidades *y* config-audit. Agregar una herramienta nueva que también hable `PolicyReport` no requiere tocar Policy Reporter. Es el pago concreto del estándar común: composición sin integración a medida.

**6.2** `ignoreUnfixed=true` **oculta del reporte los CVEs que todavía no tienen parche disponible** (`not-fixed`). Es pragmático para reducir ruido accionable, pero esconde riesgo real: un CVE crítico sin fix upstream sigue siendo explotable aunque no puedas parchearlo. Es inaceptable en contextos regulados (PCI-DSS, FedRAMP, entornos con obligación de *disclosure* completo) donde debés reportar *toda* la exposición conocida y documentar mitigaciones compensatorias, no simplemente omitir lo que no podés arreglar. En esos casos el flag debe estar en `false` y las excepciones se gestionan con VEX documentado.

**6.3** `passCount: 34, failCount: 7` es un ratio sin peso ni contexto: trata todos los controles como equivalentes. Un solo `fail` en un control crítico (ej.: "no permitir contenedores privilegiados") pesa infinitamente más que siete `pass` en controles cosméticos. Además no dice *cuáles* fallaron, ni su severidad, ni si están mitigados por otro control. Para hacerlo honesto agregaría: severidad por control fallido, el detalle de *qué* controles son los 7 fails, el estado de remediación/excepción de cada uno, y la tendencia en el tiempo (¿mejora o empeora?). El número agregado sirve como métrica de tendencia, nunca como veredicto de postura.

**6.4** Son **complementarios**, no redundantes. El scan de CI/CD (shift-left) verifica el artefacto *antes* del deploy y bloquea lo malo conocido en ese momento. Pero un CVE nuevo puede publicarse *después* de que el artefacto ya está corriendo: la imagen pasó el CI limpia hace tres semanas, y hoy aparece un crítico en una de sus librerías. El scan de CI no lo va a re-detectar porque ya se ejecutó y pasó. El scan continuo del operator re-evalúa contra la base actualizada lo que *está corriendo ahora*, y lo levanta. CI atrapa el riesgo en el tiempo del build; el operator atrapa el riesgo que emerge en runtime. Necesitás ambos.

**6.5 (integradora)** La respuesta al auditor encadena los seis eslabones **con evidencia verificable**, sin apelar a memoria:

1. Resolvés el pod `api-7f9c` a su **digest** exacto (`kubectl get pod api-7f9c -o jsonpath='{.status.containerStatuses[0].imageID}'`) — así hablás del artefacto real, no de un tag.
2. `cosign verify` contra ese digest (Lab 2): prueba que la imagen fue firmada por tu organización y, vía la entrada en **Rekor**, que la firma existió y no se repudia. Eso responde "nadie lo modificó desde el deploy": si el digest corriendo no coincide con el firmado, la verificación falla.
3. `cosign verify-attestation --type cyclonedx` recupera el **SBOM firmado** ligado a ese digest (Labs 1+2): es el inventario atestiguado de qué contiene la imagen. Buscás la librería en cuestión en ese SBOM.
4. Re-escaneás ese SBOM con la base actual (Lab 1 / Trivy Operator del Lab 6) y mostrás el `VulnerabilityReport` vivo del cluster: prueba que CVE-2024-XXXX no está presente *o* que la versión de la librería no es la vulnerable.
5. La **admission policy** de Kyverno (Lab 3) demuestra que el cluster *no podría* haber admitido una imagen sin firma o de registry no aprobado — es evidencia de control preventivo, no solo detectivo.
6. El **audit log del API server** (Lab 4) muestra quién creó/actualizó el deployment y cuándo, cerrando el "nadie lo modificó" con la traza de control plane; el **Policy Reporter** (Lab 6) da la vista agregada y las métricas que prueban continuidad del monitoreo.

El punto pedagógico central del tema: cada afirmación se responde con un artefacto verificable y ligado criptográficamente al digest, no con una aseveración de confianza. Esa es la diferencia entre *decir* que se cumple compliance y *probarlo*.

</details>