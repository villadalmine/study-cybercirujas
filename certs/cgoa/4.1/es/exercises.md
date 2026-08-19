# Tema 4.1 — Seguridad y Observabilidad en GitOps

## Ejercicios Guiados

> **Qué construís.** Un clúster `kind` con el registro de auditoría del API server habilitado, ejecutando **tanto** Flux como Argo CD, más Kyverno y un stack de Prometheus. Sobre eso ejercitás los siete controles de seguridad y observabilidad que una plataforma GitOps de producción debe tener: reconciliación con mínimo privilegio, secretos cifrados, verificación de la cadena de suministro, políticas de admisión, detección de drift, telemetría de reconciliación y respuesta a incidentes.
>
> **Por qué estos son ejercicios de *seguridad* y no solo de operaciones.** Los cuatro principios de OpenGitOps — declarativo, versionado e inmutable, extraído automáticamente (pull) y reconciliado continuamente ([opengitops.dev](https://opengitops.dev/)) — cada uno te compra una propiedad de seguridad, y cada uno falla de una manera específica:
>
> | Principio | Propiedad de seguridad que compra | Cómo falla |
> |---|---|---|
> | Declarativo | El estado deseado es texto auditable, no el efecto secundario de un script | El templating / `ignoreDifferences` oculta el estado real |
> | Versionado e inmutable | Todo cambio tiene un autor, una marca de tiempo y una firma | Commits sin firmar, force-push, tags mutables |
> | Extraído automáticamente (pull) | Ninguna credencial de CI tiene nunca cluster admin | El propio reconciliador se vuelve cluster admin |
> | Reconciliado continuamente | Los cambios fuera de banda se detectan y se revierten | Reconciliación suspendida, degradada o sin monitorear |
>
> La columna derecha *es* el temario de este tema.
>
> **Tiempo:** ~4 horas. **Costo:** cero (todo local; `ttl.sh` es un registry efímero anónimo y gratuito).

---

## Ejercicio 0 — Construir el laboratorio (con un rastro de auditoría desde el minuto uno)

Habilitás el registro de auditoría del API server *ahora*, porque el Ejercicio 5 pregunta "¿quién cambió esto fuera de Git?" y esa pregunta no se puede responder retroactivamente.

### Pasos

1. Verificá las herramientas. Instalá lo que falte antes de continuar.

```bash
for b in kind kubectl helm flux argocd sops age age-keygen cosign jq; do
  printf '%-12s %s\n' "$b" "$(command -v "$b" || echo 'MISSING')"
done
```

2. Creá un directorio de trabajo y la política de auditoría que cargará el API server.

```bash
mkdir -p ~/gitops-sec && cd ~/gitops-sec
cat > audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
# The RequestReceived stage doubles every event for no analytical value.
omitStages:
  - RequestReceived
rules:
  # Control-plane chatter would drown the signal we care about.
  - level: None
    users:
      - system:kube-scheduler
      - system:kube-controller-manager
      - system:apiserver
  - level: None
    userGroups: ["system:nodes"]
  # Reads are noise for change attribution.
  - level: None
    verbs: ["get", "list", "watch"]
  # Full request+response for the objects a GitOps attacker cares about.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "serviceaccounts"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  # Everything else that mutates: who, what, when.
  - level: Metadata
EOF
```

3. Creá el clúster con la política montada en el nodo del plano de control.

```bash
cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: gitops-sec
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit.log
            audit-log-maxage: "2"
            audit-log-maxbackup: "2"
          extraVolumes:
            - name: audit-policies
              hostPath: /etc/kubernetes/policies
              mountPath: /etc/kubernetes/policies
              readOnly: true
              pathType: DirectoryOrCreate
            - name: audit-logs
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
    extraMounts:
      - hostPath: ./audit-policy.yaml
        containerPath: /etc/kubernetes/policies/audit-policy.yaml
        readOnly: true
EOF

kind create cluster --config kind-config.yaml
kubectl cluster-info --context kind-gitops-sec
```

4. Confirmá que el log de auditoría se está escribiendo realmente. Si este archivo está vacío, pará y arreglalo — el Ejercicio 5 depende de él.

```bash
docker exec gitops-sec-control-plane sh -c 'wc -l /var/log/kubernetes/audit.log'
```

Esperado (el conteo de líneas será distinto):

```
1834 /var/log/kubernetes/audit.log
```

5. Instalá Flux (sin bootstrap — este laboratorio maneja Flux desde artefactos OCI, así que no hace falta ningún repositorio Git hospedado).

```bash
flux check --pre
flux install
flux check
```

Cola representativa de `flux check`:

```
► checking prerequisites
✔ Kubernetes 1.31.2 >=1.30.0-0
► checking version in cluster
✔ distribution: flux-v2.4.0
✔ bootstrapped: false
► checking controllers
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
► checking crds
✔ all checks passed
```

6. Instalá Argo CD e iniciá sesión con la CLI.

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &
sleep 3
ARGO_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGO_PW" --insecure
```

7. Instalá Kyverno y el stack de Prometheus.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
```

Los tres flags `...NilUsesHelmValues=false` importan: por defecto el Prometheus Operator solo descubre objetos `PodMonitor`/`ServiceMonitor`/`PrometheusRule` que llevan la etiqueta de release del propio chart. Cada monitor que escribas en el Ejercicio 6 sería ignorado silenciosamente.

8. Chequeo de sanidad.

```bash
kubectl get pods -A --field-selector=status.phase!=Running
```

Un resultado vacío (o solo jobs `Completed`) significa que el laboratorio está levantado.

### Preguntas de control — bloque 0

- **Q0.1** — La política de auditoría pone `level: None` para `get`, `list` y `watch`. Nombrá un ataque relevante para GitOps ante el cual esto te deja ciego, e indicá qué cambiarías para detectarlo.
- **Q0.2** — ¿Por qué se usa `RequestResponse` para `secrets` pero solo `Metadata` para la regla general? ¿Cuál es el riesgo de `RequestResponse` sobre secrets?
- **Q0.3** — Este laboratorio instala Flux con `flux install` en lugar de `flux bootstrap`. ¿Qué principio de OpenGitOps *no* queda satisfecho solo con `flux install`, y qué agrega bootstrap?

---

## Ejercicio 1 — Mínimo privilegio: el reconciliador es la identidad más poderosa del clúster

En una configuración GitOps basada en pull nadie tiene credenciales del clúster en CI — pero el agente dentro del clúster las tiene permanentemente. Por defecto `kustomize-controller` corre como `system:serviceaccount:flux-system:kustomize-controller`, vinculado a `cluster-admin`. Eso significa que **cualquiera con permisos de merge sobre cualquier ruta observada tiene cluster-admin**, transitivamente. La solución es la *impersonación*: el controlador aplica cada `Kustomization` como una ServiceAccount que vos elegís.

### Pasos

1. Confirmá el radio de impacto por defecto.

```bash
kubectl get clusterrolebinding cluster-reconciler-flux-system \
  -o jsonpath='{.roleRef.name}{"\n"}{range .subjects[*]}{.namespace}/{.name}{"\n"}{end}'
```

Esperado:

```
cluster-admin
flux-system/kustomize-controller
flux-system/helm-controller
```

2. Creá un namespace de tenant con una ServiceAccount deliberadamente acotada.

```bash
kubectl create namespace tenant-a

cat > tenant-a-rbac.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-a-reconciler
  namespace: tenant-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-a-reconciler
  namespace: tenant-a
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["configmaps", "services", "deployments", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-reconciler
  namespace: tenant-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tenant-a-reconciler
subjects:
  - kind: ServiceAccount
    name: tenant-a-reconciler
    namespace: tenant-a
EOF

kubectl apply -f tenant-a-rbac.yaml
```

3. Enumerá exactamente qué puede hacer esa identidad. Este comando, no el YAML, es la respuesta autoritativa.

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:tenant-a:tenant-a-reconciler -n tenant-a
```

Salida representativa (recortada):

```
Resources                    Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io  []     []               [create]
configmaps                   []                  []               [get list watch create update patch delete]
services                     []                  []               [get list watch create update patch delete]
deployments.apps             []                  []               [get list watch create update patch delete]
ingresses.networking.k8s.io  []                  []               [get list watch create update patch delete]
```

4. Probá el negativo — la identidad *no* debe poder escalar:

```bash
kubectl auth can-i create clusterrolebindings \
  --as=system:serviceaccount:tenant-a:tenant-a-reconciler
kubectl auth can-i get secrets -n tenant-a \
  --as=system:serviceaccount:tenant-a:tenant-a-reconciler
```

Ambos deben imprimir `no`.

5. Construí una carga útil de tenant que contenga un recurso legítimo y un intento de escalada de privilegios, y publicala como artefacto OCI. (Usar OCI acá mantiene el laboratorio autocontenido; un `GitRepository` se comporta idénticamente.)

```bash
mkdir -p tenant-a-config
cat > tenant-a-config/app.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: tenant-a
  labels:
    app: podinfo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.7.1
          ports:
            - name: http
              containerPort: 9898
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { memory: 64Mi }
EOF

# The escalation attempt: a tenant granting itself cluster-admin.
cat > tenant-a-config/escalate.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tenant-a-owns-the-cluster
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tenant-a-reconciler
    namespace: tenant-a
EOF

REPO="ttl.sh/gitops-sec-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)"
echo "REPO=$REPO" | tee repo.env
flux push artifact "oci://${REPO}/tenant-a:v1" \
  --path=./tenant-a-config \
  --source="lab" \
  --revision="v1/$(date +%s)"
```

6. Conectalo **con impersonación** y mirá cómo falla la escalada.

```bash
source repo.env
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: tenant-a
  namespace: tenant-a
spec:
  interval: 1m
  url: oci://${REPO}/tenant-a
  ref:
    tag: v1
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tenant-a
  namespace: tenant-a
spec:
  interval: 1m
  retryInterval: 30s
  prune: true
  sourceRef:
    kind: OCIRepository
    name: tenant-a
  path: ./
  targetNamespace: tenant-a
  serviceAccountName: tenant-a-reconciler   # <-- the whole point
EOF

sleep 20
flux get kustomizations -n tenant-a
```

Esperado:

```
NAME      REVISION   SUSPENDED  READY  MESSAGE
tenant-a             False      False  Kustomization/tenant-a/tenant-a dry-run failed: clusterrolebindings.rbac.authorization.k8s.io "tenant-a-owns-the-cluster" is forbidden: User "system:serviceaccount:tenant-a:tenant-a-reconciler" cannot create resource "clusterrolebindings" in API group "rbac.authorization.k8s.io" at the cluster scope
```

Notá **`dry-run failed`**: kustomize-controller hace un dry-run del lado del servidor sobre todo el conjunto antes de aplicar. La aplicación es atómica en intención — el Deployment legítimo *tampoco* se crea.

7. Quitá la escalada y confirmá que el tenant reconcilia limpiamente.

```bash
rm tenant-a-config/escalate.yaml
source repo.env
flux push artifact "oci://${REPO}/tenant-a:v1" \
  --path=./tenant-a-config --source="lab" --revision="v2/$(date +%s)"
flux reconcile kustomization tenant-a -n tenant-a --with-source
kubectl -n tenant-a get deploy podinfo
```

8. Hacé que la impersonación sea el comportamiento por defecto, para que un `serviceAccountName` olvidado falle cerrado en lugar de abierto:

```bash
kubectl -n flux-system patch deployment kustomize-controller --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-",
   "value":"--default-service-account=flux-default"}
]'
kubectl -n flux-system rollout status deploy/kustomize-controller
```

Ahora cualquier `Kustomization` sin un `serviceAccountName` explícito se aplica como `flux-default` en su propio namespace — una ServiceAccount que no existe, así que se le deniega todo.

9. Hacé el equivalente del lado de Argo CD con un `AppProject` — el límite de tenancy y de radio de impacto de Argo CD.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-b
  namespace: argocd
spec:
  description: Tenant B — namespaced workloads only
  sourceRepos:
    - https://github.com/argoproj/argocd-example-apps.git
  destinations:
    - namespace: tenant-b
      server: https://kubernetes.default.svc
  # Empty whitelist => no cluster-scoped resource may ever be created.
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: Role
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: deployer
      description: May sync, may not delete or edit the Application
      policies:
        - p, proj:tenant-b:deployer, applications, get, tenant-b/*, allow
        - p, proj:tenant-b:deployer, applications, sync, tenant-b/*, allow
        - p, proj:tenant-b:deployer, applications, delete, tenant-b/*, deny
      groups:
        - my-org:tenant-b-devs
EOF
```

10. Configurá la política RBAC global y probala sin un navegador.

```bash
kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p '{
  "data": {
    "policy.default": "role:readonly",
    "scopes": "[groups, email]",
    "policy.csv": "p, role:tenant-b-dev, applications, sync, tenant-b/*, allow\np, role:tenant-b-dev, applications, get, tenant-b/*, allow\np, role:tenant-b-dev, applications, delete, */*, deny\ng, my-org:tenant-b-devs, role:tenant-b-dev\n"
  }
}'

argocd account can-i sync applications 'tenant-b/guestbook'
argocd account can-i delete applications 'tenant-b/guestbook'
```

(Como `admin` ambos devuelven `yes` — admin saltea `policy.csv`. El punto del ejercicio es el paso 11.)

11. Verificá la política *como el tenant*, no como admin. Argo CD trae un linter exactamente para esto:

```bash
kubectl -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' > policy.csv
argocd admin settings rbac can my-org:tenant-b-devs sync applications 'tenant-b/guestbook' --policy-file policy.csv
argocd admin settings rbac can my-org:tenant-b-devs delete applications 'tenant-b/guestbook' --policy-file policy.csv
argocd admin settings rbac validate --policy-file policy.csv
```

Esperado:

```
Yes
No
Policy is valid.
```

### Preguntas de control — bloque 1

- **Q1.1** — En el paso 6 la escalada falló con `dry-run failed`. Explicá por qué el `Deployment` que sí cumplía, en el mismo artefacto, *tampoco* se aplicó, y por qué ese comportamiento es deseable para la seguridad.
- **Q1.2** — Un colega argumenta que la impersonación es innecesaria porque "solo los revisores pueden hacer merge a `main`". Dá dos formas concretas en las que cluster-admin sigue siendo alcanzable en ese modelo.
- **Q1.3** — `--default-service-account=flux-default` apunta a una ServiceAccount que no existe. ¿Por qué una SA *inexistente* es mejor valor por defecto que una de solo lectura?
- **Q1.4** — `clusterResourceWhitelist: []` y `namespaceResourceBlacklist` aparecen ambos en el `AppProject`. ¿Cuál de los dos falla cerrado, y qué implica eso sobre cuál deberías usar para un tenant hostil?
- **Q1.5** — ¿Por qué `argocd account can-i` como `admin` no prueba nada sobre los permisos del tenant, y qué comando lo prueba realmente?

---

## Ejercicio 2 — Secretos: la única cosa que nunca debe estar en texto plano en Git

Git es un log replicado, permanente y ampliamente replicado en mirrors. Un secreto commiteado una vez está comprometido incluso después de un force-push, porque sobrevive en cada clon, cada caché de CI y cada mirror. GitOps necesita entonces un esquema donde el *texto cifrado* sea el artefacto declarativo. Vas a implementar SOPS + age con Flux, y después compararlo contra los otros dos patrones mayoritarios.

### Pasos

1. Generá un par de claves age y cargá la clave **privada** en el clúster.

```bash
cd ~/gitops-sec
age-keygen -o age.agekey
export AGE_PUB=$(grep -oP 'public key: \K(.*)' age.agekey)
echo "$AGE_PUB"

kubectl -n tenant-a create secret generic sops-age \
  --from-file=age.agekey=./age.agekey
```

El nombre del archivo dentro del Secret importa: kustomize-controller busca claves con el sufijo `.agekey`.

2. Declará una regla de cifrado para que nadie tenga que acordarse de los flags.

```bash
cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: '^(data|stringData)$'
    age: ${AGE_PUB}
EOF
```

`encrypted_regex` es la línea clave: cifra *solo los valores*, dejando `apiVersion`, `kind`, `metadata` y `type` en texto claro. El diff de un secreto rotado se mantiene entonces revisable, y las herramientas con forma de `kubectl` siguen pudiendo parsear el archivo.

3. Escribí el secreto y cifralo in situ.

```bash
cat > tenant-a-config/db-credentials.sops.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: tenant-a
type: Opaque
stringData:
  username: podinfo
  password: "c0rrect-h0rse-battery-staple"
  dsn: "postgres://podinfo:c0rrect-h0rse-battery-staple@db.tenant-a.svc:5432/app"
EOF

sops --encrypt --in-place tenant-a-config/db-credentials.sops.yaml
head -20 tenant-a-config/db-credentials.sops.yaml
```

Salida representativa:

```yaml
apiVersion: v1
kind: Secret
metadata:
    name: db-credentials
    namespace: tenant-a
type: Opaque
stringData:
    username: ENC[AES256_GCM,data:vQ9lZg==,iv:9pB...,tag:1kQ...,type:str]
    password: ENC[AES256_GCM,data:xR2m...,iv:Uk7...,tag:Hh4...,type:str]
    dsn: ENC[AES256_GCM,data:Lp8t...,iv:aQ0...,tag:9dZ...,type:str]
sops:
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
    lastmodified: "2026-08-18T14:02:11Z"
    mac: ENC[AES256_GCM,data:...]
    version: 3.9.1
```

4. Probá que el texto plano desapareció del archivo antes de que llegue siquiera a un remoto:

```bash
grep -c 'battery-staple' tenant-a-config/db-credentials.sops.yaml || echo "clean"
```

Debe imprimir `clean` (grep sale con 1 cuando hay cero coincidencias).

5. Decile al `Kustomization` cómo descifrar, y volvé a publicar.

```bash
kubectl -n tenant-a patch kustomization tenant-a --type merge -p '{
  "spec": {"decryption": {"provider": "sops", "secretRef": {"name": "sops-age"}}}
}'

source repo.env
flux push artifact "oci://${REPO}/tenant-a:v1" \
  --path=./tenant-a-config --source="lab" --revision="v3/$(date +%s)"
flux reconcile kustomization tenant-a -n tenant-a --with-source
```

6. Verificá que el descifrado ocurrió dentro del clúster:

```bash
kubectl -n tenant-a get secret db-credentials \
  -o jsonpath='{.data.username}' | base64 -d; echo
```

Esperado: `podinfo`

7. Ahora el chequeo que la mayoría de los equipos saltea — **¿se filtró el texto plano a logs o eventos?**

```bash
kubectl -n flux-system logs deploy/kustomize-controller --tail=500 \
  | grep -i 'battery-staple' || echo "no plaintext in controller logs"

kubectl -n tenant-a get events --field-selector involvedObject.kind=Kustomization \
  -o json | grep -i 'battery-staple' || echo "no plaintext in events"

kubectl -n tenant-a get kustomization tenant-a -o yaml \
  | grep -i 'battery-staple' || echo "no plaintext in status"
```

8. Observá el modo de falla. Rompé el descifrado y leé el error con atención:

```bash
kubectl -n tenant-a patch kustomization tenant-a --type merge \
  -p '{"spec":{"decryption":{"secretRef":{"name":"sops-age-wrong"}}}}'
flux reconcile kustomization tenant-a -n tenant-a
flux get kustomizations -n tenant-a
```

Representativo:

```
NAME      REVISION       SUSPENDED  READY  MESSAGE
tenant-a  v3/1755523... False      False  decryption failed: cannot get decryption Secret 'tenant-a/sops-age-wrong': Secret "sops-age-wrong" not found
```

Restauralo:

```bash
kubectl -n tenant-a patch kustomization tenant-a --type merge \
  -p '{"spec":{"decryption":{"secretRef":{"name":"sops-age"}}}}'
flux reconcile kustomization tenant-a -n tenant-a
```

9. Rotá el *valor* y confirmá que el diff es legible:

```bash
cp tenant-a-config/db-credentials.sops.yaml /tmp/before.yaml
sops set tenant-a-config/db-credentials.sops.yaml '["stringData"]["password"]' '"n3w-r0tated-secret"'
diff <(grep -E '^(apiVersion|kind|type)|^    (name|namespace):' /tmp/before.yaml) \
     <(grep -E '^(apiVersion|kind|type)|^    (name|namespace):' tenant-a-config/db-credentials.sops.yaml) \
  && echo "structure unchanged; only ciphertext moved"
```

10. Compará los tres patrones mayoritarios. Leé la tabla y después respondé Q2.4.

| | **SOPS (+age/KMS)** | **Sealed Secrets** | **External Secrets Operator** |
|---|---|---|---|
| Qué hay en Git | Texto cifrado del secreto real | Texto cifrado, atado a la clave del controlador de *este* clúster | Una *referencia* — nada de material secreto |
| Dónde ocurre el descifrado | En kustomize-controller | En el controlador de sealed-secrets | Nunca; ESO lo trae de Vault/ASM/GSM |
| Funciona offline / air-gapped | Sí (age) | Sí | No — depende de la alcanzabilidad del almacén externo |
| Rotación de la clave de datos | Recifrar cada archivo (`sops updatekeys`) | El controlador vuelve a sellar; los sealed secrets existentes siguen funcionando | Gratis — rotás en el almacén y ESO resincroniza |
| Radio de impacto si Git se filtra | Solo texto cifrado | Solo texto cifrado | Nada |
| Radio de impacto si el clúster se compromete | Todos los secretos que ese clúster puede descifrar | Igual | Igual, más las credenciales del almacén |
| Recuperación ante desastres | Necesitás la clave age/KMS | Necesitás el backup de la clave privada del controlador — una causa clásica de caída | Reconstruís el clúster, los secretos se resincronizan solos |
| Auditoría del *acceso* al secreto | Ninguna (es la lectura de un archivo) | Ninguna | Sí — el almacén externo registra cada lectura |
| Costo / dependencia | Cero | Cero | Corrés y pagás un gestor de secretos |

11. Guarda de limpieza — nunca dejes que la clave privada llegue al repo:

```bash
cat >> .gitignore <<'EOF'
*.agekey
age.agekey
EOF
```

### Preguntas de control — bloque 2

- **Q2.1** — `encrypted_regex: '^(data|stringData)$'` deja `metadata.name` y `metadata.namespace` legibles. Indicá un beneficio de seguridad y un riesgo de divulgación de información de esa decisión.
- **Q2.2** — El paso 7 hace grep sobre los logs del controlador, los eventos *y* `.status`. ¿Por qué no alcanza con revisar solo los logs, y cuál es el campo de Flux que históricamente es el peligroso acá?
- **Q2.3** — El clúster guarda la clave privada age como un `Secret` común en `tenant-a`. ¿Quién puede leerla, y qué único chequeo de RBAC correrías para averiguarlo? ¿Por qué esto hace que SOPS-en-el-clúster sea más débil de lo que parece?
- **Q2.4** — Un cliente regulado exige un registro de auditoría de *cada lectura* de la contraseña de una base de datos de producción. ¿Cuál de los tres patrones de la tabla puede satisfacerlo, y por qué los otros dos no?
- **Q2.5** — Sealed Secrets cifra contra una clave de controlador que es por clúster. Explicá por qué esto convierte la reconstrucción del clúster en un incidente *tanto* de seguridad *como* de disponibilidad, y cuál es el modo de falla correspondiente en SOPS.

---

## Ejercicio 3 — Cadena de suministro: verificá el artefacto, no solo la URL

Un `OCIRepository` que apunta a `ttl.sh/whatever:latest` confía en (a) el registry, (b) DNS, (c) quien sea que pueda hacer push a ese tag. Los tags son mutables. La verificación con Sigstore convierte "traje algo de un lugar" en "traje una cosa que una identidad específica firmó".

### Pasos

1. Generá un par de claves cosign (keyless es la respuesta de producción; las claves mantienen el laboratorio offline y determinista).

```bash
cd ~/gitops-sec
COSIGN_PASSWORD="" cosign generate-key-pair
ls cosign.key cosign.pub
```

2. Publicá un artefacto nuevo y capturá su digest inmutable.

```bash
source repo.env
flux push artifact "oci://${REPO}/tenant-a:v2" \
  --path=./tenant-a-config --source="lab" --revision="v4/$(date +%s)" \
  --output json | tee push.json
DIGEST=$(jq -r '.digest' push.json)
echo "DIGEST=$DIGEST" | tee -a repo.env
```

3. Firmá el artefacto **por digest**, nunca por tag.

```bash
source repo.env
COSIGN_PASSWORD="" cosign sign --key cosign.key --yes "${REPO}/tenant-a@${DIGEST}"
cosign verify --key cosign.pub "${REPO}/tenant-a@${DIGEST}" | jq '.[0].critical'
```

Representativo:

```json
{
  "identity": { "docker-reference": "ttl.sh/gitops-sec-4f2a1c9b/tenant-a" },
  "image": { "docker-manifest-digest": "sha256:9c1f...b3e2" },
  "type": "cosign container image signature"
}
```

4. Cargá la clave **pública** en el clúster y hacé que Flux exija la verificación.

```bash
kubectl -n tenant-a create secret generic cosign-pub --from-file=cosign.pub=./cosign.pub

source repo.env
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: tenant-a
  namespace: tenant-a
spec:
  interval: 1m
  url: oci://${REPO}/tenant-a
  ref:
    tag: v2
  verify:
    provider: cosign
    secretRef:
      name: cosign-pub
EOF

sleep 15
flux get sources oci -n tenant-a
```

Esperado:

```
NAME      REVISION            SUSPENDED  READY  MESSAGE
tenant-a  v2@sha256:9c1f...   False      True   stored artifact for digest 'v2@sha256:9c1f...'
```

Y la condición de verificación:

```bash
kubectl -n tenant-a get ocirepository tenant-a \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} :: {.message}{"\n"}{end}'
```

```
Ready=True :: stored artifact for digest 'v2@sha256:9c1f...b3e2'
ArtifactInStorage=True :: stored artifact for digest 'v2@sha256:9c1f...b3e2'
SourceVerified=True :: verified signature of revision v2@sha256:9c1f...b3e2
```

5. Ahora simulá un secuestro de tag — hacé push de contenido *sin firmar* sobre el mismo tag.

```bash
source repo.env
echo '# injected by an attacker who can push to the registry' >> tenant-a-config/app.yaml
flux push artifact "oci://${REPO}/tenant-a:v2" \
  --path=./tenant-a-config --source="lab" --revision="evil/$(date +%s)"
flux reconcile source oci tenant-a -n tenant-a
flux get sources oci -n tenant-a
```

Esperado:

```
NAME      REVISION  SUSPENDED  READY  MESSAGE
tenant-a            False      False  failed to verify the signature using provider 'cosign': no matching signatures were found for 'ttl.sh/gitops-sec-4f2a1c9b/tenant-a'
```

El `Kustomization` sigue corriendo contra el último artefacto **verificado**. La falla de verificación es fail-closed en la fuente, no en el momento de aplicar.

6. Fijá por digest para que ni siquiera un tag firmado-pero-equivocado pueda moverse debajo tuyo:

```bash
source repo.env
kubectl -n tenant-a patch ocirepository tenant-a --type merge -p "{
  \"spec\": {\"ref\": {\"digest\": \"${DIGEST}\"}}
}"
flux reconcile source oci tenant-a -n tenant-a
flux get sources oci -n tenant-a
```

7. La forma de producción — vinculación de identidad keyless. No apliques esto (necesita una firma emitida por un OIDC real); leelo y respondé Q3.4.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/my-org/platform-config
  ref:
    semver: ">=1.0.0 <2.0.0"
  verify:
    provider: cosign
    matchOIDCIdentity:
      # Anchored regexes. An unanchored `subject` is a common, silent bypass.
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/my-org/platform-config/\\.github/workflows/release\\.yaml@refs/tags/v.*$"
```

8. Cerrá la otra mitad de la cadena de suministro: Flux verificó la *configuración*; todavía nada verifica las *imágenes de contenedor* que esa configuración referencia. Agregá una política de verificación de imágenes de Kyverno.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-tenant-images
spec:
  webhookTimeoutSeconds: 25
  failurePolicy: Fail
  rules:
    - name: verify-signed-images
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a]
      verifyImages:
        - imageReferences:
            - "ghcr.io/stefanprodan/podinfo*"
          mutateDigest: true      # rewrite tag -> digest on admission
          required: true
          verifyDigest: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/stefanprodan/podinfo/.github/workflows/release.yml@refs/tags/*"
                    rekor:
                      url: https://rekor.sigstore.dev
EOF
```

9. Observá el resultado y el *costo* de este control:

```bash
kubectl -n tenant-a rollout restart deploy/podinfo
sleep 20
kubectl -n tenant-a get pods
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n tenant-a get pod -l app=podinfo -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

Si el laboratorio tiene salida hacia `rekor.sigstore.dev` y la firma coincide, el Pod corre y su referencia de imagen fue **mutada a un digest** mientras el Deployment sigue diciendo `:6.7.1`. Si la salida está bloqueada, vas a ver en cambio que la admisión falla:

```
Error creating: admission webhook "mutate.kyverno.svc-fail" denied the request:
failed to verify image ghcr.io/stefanprodan/podinfo:6.7.1: .../rekor.sigstore.dev: dial tcp: i/o timeout
```

Esa falla no es un bug — es `failurePolicy: Fail` haciendo su trabajo, y es el trade-off que tenés que ser capaz de articular.

### Preguntas de control — bloque 3

- **Q3.1** — El paso 3 firma `@sha256:...` en lugar de `:v2`. Explicá con precisión qué puede hacer un atacante con acceso de push al registry si firmás y verificás por tag.
- **Q3.2** — En el paso 5 la verificación falló, y sin embargo `kubectl -n tenant-a get deploy podinfo` sigue mostrando un Deployment sano. ¿Qué principio de GitOps explica eso, y es el comportamiento correcto?
- **Q3.3** — Flux verificó el artefacto y Kyverno verificó la imagen. Nombrá un tercer artefacto de la cadena de suministro que sigue sin verificar en este laboratorio y el mecanismo que lo cubriría.
- **Q3.4** — La regex de `matchOIDCIdentity.subject` del paso 7 está anclada con `^...$`. Escribí el exploit que se vuelve posible con `"https://github.com/my-org/"` sin anclar.
- **Q3.5** — `mutateDigest: true` reescribe el tag a digest en la admisión. Dá un beneficio de seguridad y una consecuencia operativa para un equipo que depende de `imagePullPolicy: Always` con un tag flotante.
- **Q3.6** — `failurePolicy: Fail` sobre una política que llama a `rekor.sigstore.dev` acopla la admisión del clúster a la alcanzabilidad de internet. Indicá el riesgo de disponibilidad y una mitigación de producción que preserve la propiedad de seguridad.

---

## Ejercicio 4 — Política como código: dos compuertas, no una

Un error común es pensar que "todo pasa por Git, así que la revisión es el control". La revisión es *un* control; no es uno que imponga nada. El control de admisión sí impone. Necesitás ambos y — esta es la parte relevante para el examen — necesitás saber qué amenazas cubre cada uno.

### Pasos

1. Escribí una política base de endurecimiento en `Audit` primero. Nunca lances una política nueva en `Enforce`.

```bash
cat > policy-baseline.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-baseline
  annotations:
    policies.kyverno.io/title: Tenant workload baseline
    policies.kyverno.io/severity: high
spec:
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a, tenant-b]
      validate:
        failureAction: Audit          # Kyverno >= 1.13; older: spec.validationFailureAction
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(privileged): "false"
                  =(allowPrivilegeEscalation): "false"
    - name: no-host-namespaces
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a, tenant-b]
      validate:
        failureAction: Audit
        message: "hostNetwork, hostPID and hostIPC are not allowed."
        pattern:
          spec:
            =(hostNetwork): "false"
            =(hostPID): "false"
            =(hostIPC): "false"
    - name: allowed-registries-only
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a, tenant-b]
      validate:
        failureAction: Audit
        message: "Images must come from ghcr.io/stefanprodan or the internal registry."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: NotEquals
                    value: "ghcr.io/stefanprodan/*"
EOF
kubectl apply -f policy-baseline.yaml
```

2. Desplegá una carga de trabajo deliberadamente no conforme y leé el *reporte* en lugar de un error.

```bash
cat > bad-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: intruder
  namespace: tenant-a
spec:
  hostNetwork: true
  hostPID: true
  containers:
    - name: shell
      image: docker.io/library/busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
EOF
kubectl apply -f bad-pod.yaml

sleep 5
kubectl -n tenant-a get policyreport -o wide
kubectl -n tenant-a get policyreport -o json \
  | jq -r '.items[].results[] | select(.result=="fail") | "\(.policy)/\(.rule): \(.message)"'
```

Representativo:

```
tenant-baseline/no-privileged-containers: validation error: Privileged containers are not allowed. rule no-privileged-containers failed at path /spec/containers/0/securityContext/privileged/
tenant-baseline/no-host-namespaces: validation error: hostNetwork, hostPID and hostIPC are not allowed. rule no-host-namespaces failed at path /spec/hostNetwork/
tenant-baseline/allowed-registries-only: Images must come from ghcr.io/stefanprodan or the internal registry.
```

Este es el orden correcto de despliegue: medí la tasa de violaciones contra tráfico real **antes** de poder romperle algo a alguien.

3. Promové a `Enforce` y confirmá que la compuerta se cierra.

```bash
kubectl delete pod intruder -n tenant-a
sed -i 's/failureAction: Audit/failureAction: Enforce/g' policy-baseline.yaml
kubectl apply -f policy-baseline.yaml
sleep 5
kubectl apply -f bad-pod.yaml
```

Esperado:

```
Error from server: error when creating "bad-pod.yaml": admission webhook "validate.kyverno.svc-fail"
denied the request:

resource Pod/tenant-a/intruder was blocked due to the following policies

tenant-baseline:
  no-privileged-containers: 'validation error: Privileged containers are not allowed. ...'
  no-host-namespaces: 'validation error: hostNetwork, hostPID and hostIPC are not allowed. ...'
```

4. Corré la misma política más a la izquierda, para que el desarrollador la vea en CI y no a las 3 de la mañana.

```bash
kubectl krew install kyverno 2>/dev/null || echo "install the kyverno CLI: https://kyverno.io/docs/kyverno-cli/"
kyverno apply policy-baseline.yaml --resource bad-pod.yaml
kyverno apply policy-baseline.yaml --resource tenant-a-config/app.yaml
```

Representativo:

```
Applying 3 policy rule(s) to 1 resource(s)...

policy tenant-baseline -> resource tenant-a/Pod/intruder failed:
1. no-privileged-containers: validation error: Privileged containers are not allowed.
2. no-host-namespaces: validation error: hostNetwork, hostPID and hostIPC are not allowed.

pass: 0, fail: 2, warn: 0, error: 0, skip: 1
```

5. Conectala como compuerta de merge (este es el artefacto que el examen espera que sepas describir):

```yaml
# .github/workflows/policy.yaml
name: policy
on:
  pull_request:
    paths: ["clusters/**", "tenants/**"]
permissions:
  contents: read          # the CI job needs NO cluster credential — that is the point
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Render manifests
        run: kustomize build tenants/tenant-a > /tmp/rendered.yaml
      - name: Schema validation
        run: kubeconform -strict -summary -schema-location default /tmp/rendered.yaml
      - name: Policy validation
        run: kyverno apply policies/ --resource /tmp/rendered.yaml --detailed-results
```

6. Demostrá por qué la compuerta de Git sola no alcanza. Salteate Git por completo:

```bash
kubectl -n tenant-a set image deploy/podinfo podinfo=docker.io/library/nginx:1.27
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

La imagen cambió. Sin pull request, sin revisión, sin CI. Notá además que la regla de *registry* de Kyverno matcheaba `Pod`, así que la edición del `Deployment` pasó y solo se evalúa el Pod resultante.

### Preguntas de control — bloque 4

- **Q4.1** — El paso 6 cambió una carga de trabajo en ejecución sin ninguna intervención de Git. ¿Cuáles *dos* controles de este laboratorio son capaces de notarlo, y cuál es capaz de *deshacerlo*?
- **Q4.2** — La política matchea `kinds: [Pod]`. Explicá por qué la edición del `Deployment` del paso 6 produjo un resultado confuso, y qué cambiarías para darle al desarrollador un buen mensaje de error.
- **Q4.3** — El paso 1 sale en `Audit`, el paso 3 promueve a `Enforce`. Describí el incidente de producción específico que causa el orden inverso en un clúster con cargas de trabajo existentes.
- **Q4.4** — El workflow de CI declara `permissions: contents: read`. Relacioná esa única línea con el argumento de seguridad pull-vs-push de GitOps.
- **Q4.5** — Dá una clase de violación que el `kyverno apply` del lado de CI puede detectar pero el webhook de admisión no, y una que el webhook detecta y CI estructuralmente no puede.

---

## Ejercicio 5 — Detección de drift y auto-reparación, y atribución del drift

La reconciliación continua es el control que convierte "alguien cambió producción" de un compromiso permanente en una ventana acotada. Acá medís esa ventana y después atribuís el cambio usando el log de auditoría que habilitaste en el Ejercicio 0.

### Pasos

1. Desplegá una `Application` de Argo CD con la auto-reparación deliberadamente **apagada**, para poder ver primero el estado sin reparar.

```bash
kubectl create namespace tenant-b
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: tenant-b
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
EOF

argocd app wait guestbook --health --timeout 180
argocd app get guestbook
```

2. Introducí drift y observá la detección sin corrección.

```bash
kubectl -n tenant-b scale deploy guestbook-ui --replicas=5
sleep 15
argocd app get guestbook | head -20
argocd app diff guestbook || true
```

Representativo:

```
Name:               argocd/guestbook
Project:            tenant-b
Sync Status:        OutOfSync from HEAD (53e28ff)
Health Status:      Healthy
```

```diff
===== apps/Deployment tenant-b/guestbook-ui ======
26c26
<   replicas: 5
---
>   replicas: 1
```

Detectado en segundos. Corregido: nunca. `OutOfSync` por sí solo es un *tablero*, no un control.

3. Encendé la auto-reparación y medí la ventana de corrección.

```bash
argocd app set guestbook --self-heal --auto-prune

kubectl -n tenant-b scale deploy guestbook-ui --replicas=7
date -u +%H:%M:%S
watch -n 1 'kubectl -n tenant-b get deploy guestbook-ui -o jsonpath="{.spec.replicas}"; echo'
```

El valor vuelve a `1`. Anotá el tiempo transcurrido — esa es tu ventana de drift, y está acotada por el intervalo de reconciliación más la cola del controlador, no por ninguna alerta.

4. Hacé lo mismo del lado de Flux y observá el modo de falla más nítido:

```bash
kubectl -n tenant-a set image deploy/podinfo podinfo=docker.io/library/nginx:1.27
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
flux reconcile kustomization tenant-a -n tenant-a
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Flux revierte porque kustomize-controller usa server-side apply consigo mismo como field manager: el campo que sufrió el drift le pertenece a Flux, así que el siguiente apply lo recupera.

5. Ahora demostrá el *anti*-patrón. Suprimí el drift y mirá cómo el control desaparece silenciosamente:

```bash
argocd app set guestbook --ignore-normal-diffs 2>/dev/null || true
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: tenant-b
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
        - /spec/template/spec/containers/0/image   # <-- this is the dangerous one
EOF

kubectl -n tenant-b set image deploy/guestbook-ui guestbook-ui=docker.io/library/nginx:1.27
sleep 40
argocd app get guestbook | grep 'Sync Status'
kubectl -n tenant-b get deploy guestbook-ui -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

`Synced`, y la imagen es `nginx`. Tenés un tablero en verde sobre una carga de trabajo comprometida. `ignoreDifferences` sobre `/spec/replicas` es legítimo cuando un HPA es dueño de ese campo; sobre `image` es un agujero en la cadena de suministro con un nombre simpático.

6. Revertí el anti-patrón:

```bash
kubectl -n argocd patch application guestbook --type json \
  -p='[{"op":"remove","path":"/spec/ignoreDifferences"}]'
argocd app sync guestbook
```

7. Atribuí el drift. Esta es la pregunta que realmente hace una revisión de incidente:

```bash
docker exec gitops-sec-control-plane sh -c \
  'cat /var/log/kubernetes/audit.log' \
  | jq -r 'select(.objectRef.resource=="deployments"
           and (.verb=="patch" or .verb=="update")
           and .objectRef.name=="guestbook-ui")
           | "\(.requestReceivedTimestamp)  \(.verb)  \(.user.username)  \(.userAgent // "-")"' \
  | tail -20
```

Representativo:

```
2026-08-18T14:41:02.118Z  patch   kubernetes-admin        kubectl/v1.31.2 (linux/amd64)
2026-08-18T14:41:44.905Z  update  system:serviceaccount:argocd:argocd-application-controller  argocd-application-controller/v0.0.0
```

Dos líneas, dos historias: un humano con `kubectl` hizo el cambio; el controlador lo recuperó 42 segundos después. Esa es la ventana de drift, medida, con el actor nombrado.

8. Construí la consulta reutilizable — "toda mutación de un recurso gestionado por GitOps que **no** vino de un reconciliador":

```bash
docker exec gitops-sec-control-plane sh -c 'cat /var/log/kubernetes/audit.log' \
  | jq -r 'select(.verb | test("^(create|update|patch|delete)$"))
           | select(.user.username | test("argocd|flux|kyverno|system:") | not)
           | "\(.requestReceivedTimestamp) \(.user.username) \(.verb) \(.objectRef.namespace)/\(.objectRef.resource)/\(.objectRef.name)"' \
  | sort | tail -30
```

En producción esta consulta vive en tu pipeline de logs como una alerta permanente, no en una shell.

### Preguntas de control — bloque 5

- **Q5.1** — En el paso 2 la aplicación estaba `OutOfSync` *y* `Healthy` simultáneamente. Explicá la diferencia entre ambos estados y por qué alertar solo sobre `Healthy` es una brecha de seguridad.
- **Q5.2** — El paso 5 produjo `Synced` mientras corría la imagen equivocada. Escribí la regla que aplicarías al revisar un PR que agrega una entrada de `ignoreDifferences`.
- **Q5.3** — La auto-reparación revierte el drift automáticamente. Nombrá un escenario donde la reversión automática empeora un incidente, y el mecanismo que las herramientas GitOps te dan para pausarla deliberadamente.
- **Q5.4** — Flux revirtió el drift del paso 4 gracias a la propiedad de campos de server-side apply. ¿Qué pasa con un campo que Flux *no* gestiona (digamos, una anotación agregada por un webhook mutante), y por qué ese es el diseño correcto?
- **Q5.5** — ¿Por qué el historial de Git por sí solo no puede responder "¿quién cambió el Deployment en ejecución a las 14:41?", y cuál es la fuente de datos adicional mínima requerida?

---

## Ejercicio 6 — Observabilidad: qué significa realmente "la reconciliación está sana"

No podés alertar sobre "GitOps está funcionando" sin decidir cómo se ve la falla. Los dos errores son alertar sobre la señal equivocada (`Ready=False`, que se dispara con cada hipo transitorio de red) y olvidar las fallas *silenciosas*: un `Kustomization` suspendido y una reconciliación exitosa-pero-vieja son ambos invisibles para una consulta ingenua.

### Pasos

1. Scrapeá los controladores de Flux a mano para aprender las formas de las métricas antes de escribir ninguna regla.

```bash
kubectl -n flux-system port-forward deploy/kustomize-controller 8081:8080 >/dev/null 2>&1 &
sleep 3
curl -s localhost:8081/metrics | grep -E '^gotk_(reconcile_condition|suspend_status)' | head -20
```

Representativo:

```
gotk_reconcile_condition{kind="Kustomization",name="tenant-a",namespace="tenant-a",type="Ready",status="True"} 1
gotk_reconcile_condition{kind="Kustomization",name="tenant-a",namespace="tenant-a",type="Ready",status="False"} 0
gotk_reconcile_condition{kind="Kustomization",name="tenant-a",namespace="tenant-a",type="Ready",status="Deleted"} 0
gotk_suspend_status{kind="Kustomization",name="tenant-a",namespace="tenant-a"} 0
```

La codificación es el detalle importante: **una serie temporal por cada estado de condición**, cada una un gauge 0/1. Las reglas deben seleccionar sobre la etiqueta `status`, no sobre el valor solo.

2. Hacé lo mismo con Argo CD.

```bash
kubectl -n argocd port-forward svc/argocd-metrics 8082:8082 >/dev/null 2>&1 &
sleep 3
curl -s localhost:8082/metrics | grep -E '^argocd_app_info' | head
curl -s localhost:8082/metrics | grep -E '^argocd_app_sync_total' | head
```

Representativo:

```
argocd_app_info{dest_namespace="tenant-b",dest_server="https://kubernetes.default.svc",health_status="Healthy",name="guestbook",namespace="argocd",operation="",project="tenant-b",repo="https://github.com/argoproj/argocd-example-apps",sync_status="Synced"} 1
argocd_app_sync_total{dest_server="...",name="guestbook",namespace="argocd",phase="Succeeded",project="tenant-b"} 4
```

3. Registrá ambos con Prometheus.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: flux-system
  namespace: flux-system
spec:
  namespaceSelector:
    matchNames: [flux-system]
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - helm-controller
          - source-controller
          - kustomize-controller
          - notification-controller
  podMetricsEndpoints:
    - port: http-prom
      relabelings:
        - action: replace
          sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-server-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server-metrics
  endpoints:
    - port: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-repo-server-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  endpoints:
    - port: metrics
EOF
```

4. Confirmá que los targets están realmente arriba — un `PodMonitor` que no matchea nada falla silenciosamente.

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 4
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("controller|argocd"))
           | "\(.labels.job)\t\(.health)\t\(.lastError)"' | sort -u
```

Cada fila debe decir `up`.

5. Corré las cuatro consultas que importan. Pegá cada una en `localhost:9090/graph`.

```promql
# 1. Anything Flux-managed that is failing, ignoring resources you deliberately suspended.
max by (exported_namespace, name, kind) (
  gotk_reconcile_condition{status="False", type="Ready"}
)
* on (exported_namespace, name, kind) group_left
max by (exported_namespace, name, kind) (gotk_suspend_status == 0)
== 1
```

```promql
# 2. Silent failure #1 — suspended reconciliation. A suspended Kustomization is
#    NOT failing and NOT drifting: it has simply stopped enforcing anything.
gotk_suspend_status == 1
```

```promql
# 3. Argo CD applications out of sync or degraded.
sum by (name, project, dest_namespace) (
  argocd_app_info{sync_status!="Synced"}
) > 0
or
sum by (name, project, dest_namespace) (
  argocd_app_info{health_status=~"Degraded|Missing|Unknown"}
) > 0
```

```promql
# 4. Reconciliation latency — the p99 of how long an apply takes.
histogram_quantile(0.99,
  sum by (le, kind) (rate(gotk_reconcile_duration_seconds_bucket[10m]))
)
```

6. Convertí las consultas 1–3 en alertas. Notá las duraciones de `for:` — codifican "transitorio vs. real".

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-alerts
  namespace: monitoring
spec:
  groups:
    - name: gitops.reconciliation
      rules:
        - alert: FluxReconciliationFailure
          expr: |
            max by (exported_namespace, name, kind) (
              gotk_reconcile_condition{status="False", type="Ready"}
            )
            * on (exported_namespace, name, kind) group_left
            max by (exported_namespace, name, kind) (gotk_suspend_status == 0)
            == 1
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.kind }}/{{ $labels.exported_namespace }}/{{ $labels.name }} has not reconciled for 10m"
            runbook: "flux get all -A --status-selector=ready=false"

        - alert: FluxReconciliationSuspended
          expr: gotk_suspend_status == 1
          for: 1h
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.kind }}/{{ $labels.name }} suspended >1h — drift is no longer corrected"

        - alert: ArgoAppOutOfSync
          expr: argocd_app_info{sync_status!="Synced"} == 1
          for: 15m
          labels: { severity: warning }
          annotations:
            summary: "Application {{ $labels.name }} out of sync for 15m — cluster state differs from Git"

        - alert: ArgoAppDegraded
          expr: argocd_app_info{health_status=~"Degraded|Missing"} == 1
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "Application {{ $labels.name }} is {{ $labels.health_status }}"

        - alert: GitOpsControllerAbsent
          expr: |
            absent(gotk_reconcile_condition{kind="Kustomization"})
            or absent(argocd_app_info)
          for: 10m
          labels: { severity: critical }
          annotations:
            summary: "GitOps telemetry has disappeared — the reconciler may be down or unmonitored"
EOF
```

7. Probá que cada alerta se dispara. No confíes en una regla que no viste ponerse en rojo.

```bash
# Trip FluxReconciliationFailure
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p '{"spec":{"url":"oci://ttl.sh/does-not-exist-4f2a/tenant-a"}}'

# Trip FluxReconciliationSuspended
flux suspend kustomization tenant-a -n tenant-a

sleep 90
curl -s localhost:9090/api/v1/alerts \
  | jq -r '.data.alerts[] | "\(.labels.alertname)\t\(.state)\t\(.labels.name // "-")"'
```

Representativo:

```
FluxReconciliationFailure   pending   tenant-a
FluxReconciliationSuspended pending   tenant-a
```

(`pending` pasa a `firing` una vez transcurrida la duración de `for:`.)

8. Restaurá:

```bash
source repo.env
flux resume kustomization tenant-a -n tenant-a
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p "{\"spec\":{\"url\":\"oci://${REPO}/tenant-a\"}}"
flux reconcile kustomization tenant-a -n tenant-a --with-source
```

### Preguntas de control — bloque 6

- **Q6.1** — La alerta 1 multiplica por `gotk_suspend_status == 0`. ¿Qué falla operativa previene ese filtro, y qué punto ciego *nuevo* crea, que la alerta 2 existe para cubrir?
- **Q6.2** — `GitOpsControllerAbsent` usa `absent()`. Explicá por qué una regla basada en `== 1` o `> 0` no puede detectar un controlador muerto.
- **Q6.3** — `ArgoAppOutOfSync` tiene `for: 15m` mientras que `ArgoAppDegraded` tiene `for: 5m`. Justificá la asimetría en términos de lo que significa cada condición.
- **Q6.4** — `argocd_app_info` lleva `sync_status` como **etiqueta**. Describí el problema de cardinalidad y de obsolescencia (staleness) que eso crea cuando el estado de una aplicación cambia repetidamente, y cómo puede producir una alerta trabada.
- **Q6.5** — Todas las métricas de acá miden al *reconciliador*. Nombrá la magnitud de punta a punta que **no** miden — la que un SLO de plataforma debería medir realmente — y esbozá cómo la medirías.

---

## Ejercicio 7 — Notificaciones, respuesta a incidentes y rollback

El último control es el bucle humano: un cambio falla, alguien se entera, y la remediación preserva a Git como fuente de verdad.

### Pasos

1. Levantá un receptor de webhooks para que las notificaciones sean observables localmente.

```bash
kubectl create namespace tooling
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-sink
  namespace: tooling
spec:
  replicas: 1
  selector: { matchLabels: { app: webhook-sink } }
  template:
    metadata: { labels: { app: webhook-sink } }
    spec:
      containers:
        - name: sink
          image: docker.io/mendhak/http-https-echo:34
          env:
            - name: HTTP_PORT
              value: "8080"
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-sink
  namespace: tooling
spec:
  selector: { app: webhook-sink }
  ports: [{ port: 80, targetPort: 8080 }]
EOF
kubectl -n tooling rollout status deploy/webhook-sink
```

2. Configurá las notificaciones de Flux.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: sink
  namespace: tenant-a
spec:
  type: generic
  address: http://webhook-sink.tooling.svc/flux
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: tenant-a-alerts
  namespace: tenant-a
spec:
  providerRef:
    name: sink
  eventSeverity: info          # 'error' for failures only; 'info' includes successes
  eventSources:
    - kind: Kustomization
      name: '*'
    - kind: OCIRepository
      name: '*'
EOF
```

3. Provocá una falla y leé la notificación como lo haría un ingeniero de guardia.

```bash
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p '{"spec":{"ref":{"tag":"nope"}}}'
sleep 25
kubectl -n tooling logs deploy/webhook-sink --tail=200 \
  | grep -o '"body":.*' | tail -2
```

Payload representativo:

```json
{
  "involvedObject": {"kind":"OCIRepository","namespace":"tenant-a","name":"tenant-a"},
  "severity": "error",
  "timestamp": "2026-08-18T15:22:41Z",
  "reason": "OCIArtifactPullFailed",
  "message": "failed to pull artifact from 'oci://ttl.sh/gitops-sec-4f2a1c9b/tenant-a:nope': nope: not found",
  "reportingController": "source-controller"
}
```

4. Lo mismo, del lado de Argo CD.

```bash
kubectl -n argocd patch configmap argocd-notifications-cm --type merge -p '{
  "data": {
    "service.webhook.sink": "url: http://webhook-sink.tooling.svc/argocd\nheaders:\n- name: Content-Type\n  value: application/json\n",
    "template.app-sync-failed": "webhook:\n  sink:\n    method: POST\n    body: |\n      {\"app\":\"{{.app.metadata.name}}\",\"status\":\"{{.app.status.sync.status}}\",\"health\":\"{{.app.status.health.status}}\",\"revision\":\"{{.app.status.sync.revision}}\"}\n",
    "trigger.on-sync-failed": "- when: app.status.operationState.phase in [\"Error\", \"Failed\"]\n  send: [app-sync-failed]\n",
    "trigger.on-health-degraded": "- when: app.status.health.status == \"Degraded\"\n  send: [app-sync-failed]\n"
  }
}'

kubectl -n argocd annotate application guestbook \
  notifications.argoproj.io/subscribe.on-sync-failed.sink="" \
  notifications.argoproj.io/subscribe.on-health-degraded.sink="" --overwrite
```

5. Triage de una reconciliación que falla con el ejercicio de tres comandos. Aprendé esta secuencia:

```bash
flux get all -A --status-selector ready=false
flux events --for OCIRepository/tenant-a -n tenant-a
kubectl -n flux-system logs deploy/source-controller --tail=50 | grep -i tenant-a
```

Salida representativa de `flux events`:

```
LAST SEEN  TYPE     REASON                  OBJECT                       MESSAGE
2m         Warning  OCIArtifactPullFailed   OCIRepository/tenant-a       failed to pull artifact ... nope: not found
14m        Normal   NewArtifact             OCIRepository/tenant-a       stored artifact for digest 'v2@sha256:9c1f...'
```

El equivalente en Argo CD:

```bash
argocd app get guestbook --show-operation
argocd app history guestbook
kubectl -n argocd logs deploy/argocd-application-controller --tail=50 | grep guestbook
```

```
ID  DATE                           REVISION
0   2026-08-18 14:31:07 +0000 UTC  HEAD (53e28ff)
1   2026-08-18 14:47:52 +0000 UTC  HEAD (53e28ff)
2   2026-08-18 15:10:33 +0000 UTC  HEAD (53e28ff)
```

6. Rollback — la forma correcta y la equivocada, lado a lado.

**Equivocada (rollback imperativo):**

```bash
argocd app rollback guestbook 1
argocd app get guestbook | grep 'Sync Status'
```

La carga de trabajo revierte, y la aplicación pasa inmediatamente a `OutOfSync` contra Git — o, con la auto-reparación encendida, es llevada *hacia adelante* de nuevo dentro de un intervalo. Creaste drift para arreglar drift.

**Correcta (rollback declarativo):**

```bash
# git revert <bad-commit>   # in the config repository
# git push
# the reconciler applies the revert; the rollback is itself a reviewed, signed commit
```

En este laboratorio, el equivalente OCI de un revert es reapuntar al último digest verificado:

```bash
source repo.env
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p "{\"spec\":{\"ref\":{\"digest\":\"${DIGEST}\",\"tag\":\"\"}}}"
flux reconcile kustomization tenant-a -n tenant-a --with-source
flux get sources oci -n tenant-a
```

7. Break-glass, hecho como corresponde. Cuando tenés que actuar fuera de Git, hacé que la desviación sea *visible y con vencimiento*:

```bash
flux suspend kustomization tenant-a -n tenant-a \
  --reason="INC-4471: manual mitigation, expires 2026-08-18T18:00Z, owner @dalmine"
kubectl -n tenant-a get kustomization tenant-a \
  -o jsonpath='{.spec.suspend}{"\t"}{.metadata.annotations}{"\n"}'
```

La suspensión dispara `FluxReconciliationSuspended` del Ejercicio 6 después de una hora, así que el break-glass no puede volverse el estado permanente por accidente. Esa alerta es el sentido entero de la disciplina de anotar.

```bash
flux resume kustomization tenant-a -n tenant-a
```

8. Armá la línea de tiempo del incidente con las cuatro fuentes — este es el entregable de una revisión de seguridad GitOps:

```bash
echo "== Git / artifact provenance =="; cat push.json | jq '{digest, url: .repository}'
echo "== Reconciler events =="; flux events --for Kustomization/tenant-a -n tenant-a | tail -5
echo "== Notifications delivered =="; kubectl -n tooling logs deploy/webhook-sink --tail=5 | grep -o '"reason":"[^"]*"' | tail -5
echo "== Out-of-band API mutations =="
docker exec gitops-sec-control-plane sh -c 'cat /var/log/kubernetes/audit.log' \
  | jq -r 'select(.verb|test("^(create|update|patch|delete)$"))
           | select(.user.username|test("argocd|flux|kyverno|system:")|not)
           | "\(.requestReceivedTimestamp) \(.user.username) \(.verb) \(.objectRef.namespace)/\(.objectRef.name)"' \
  | tail -5
```

### Preguntas de control — bloque 7

- **Q7.1** — El `Alert` de Flux usa `eventSeverity: info`. Indicá el trade-off contra `error`, y cuál corresponde en un canal de guardia de producción.
- **Q7.2** — `argocd app rollback` revirtió la carga de trabajo y después esta sufrió drift o fue llevada hacia adelante. Explicá el mecanismo, y nombrá el *único* rollback que es estable bajo reconciliación continua.
- **Q7.3** — El paso de break-glass registra un motivo y un responsable en un flag `--reason`. Nombrá los dos controles independientes que hacen que esa anotación sea más que un comentario.
- **Q7.4** — Los payloads de notificación llevan `message` textual desde el controlador. ¿Cuál es el riesgo de exfiltración de datos de enrutar las notificaciones de Flux/Argo CD a un servicio de chat de terceros, y qué harías al respecto?
- **Q7.5** — El paso 8 correlaciona cuatro fuentes: procedencia del artefacto, eventos del reconciliador, notificaciones, log de auditoría. ¿Cuál única de estas *no* es reconstruible después del hecho si no la configuraste de antemano, y por qué eso la convierte en lo primero que hay que montar?

---

## Limpieza

```bash
kill %1 %2 %3 %4 2>/dev/null
kind delete cluster --name gitops-sec
cd ~ && rm -rf ~/gitops-sec   # contains cosign.key and age.agekey — do not leave these around
```

---

## Respuestas

<details>
<summary><strong>Clic para expandir — respuestas a todas las preguntas de control</strong></summary>

### Bloque 0 — Laboratorio y auditoría

**Q0.1** — `level: None` sobre las lecturas te deja ciego ante la **exfiltración de secretos**: un atacante (o una ServiceAccount demasiado amplia) haciendo `kubectl get secret -A -o yaml` lee todas las credenciales del clúster y no deja ningún registro de auditoría. También oculta el reconocimiento — un `list` sobre todos los namespaces es el primer movimiento de la mayoría de los ataques dentro del clúster. La solución es una regla dirigida *arriba* de la regla general `None`, ya que las reglas de auditoría se evalúan de arriba hacia abajo y gana la primera coincidencia:

```yaml
- level: Metadata
  verbs: ["get", "list"]
  resources:
    - group: ""
      resources: ["secrets"]
```

Mantenela en `Metadata`, no en `RequestResponse` — ver Q0.2.

**Q0.2** — `RequestResponse` registra el cuerpo completo del objeto. Para `secrets` eso es exactamente lo que lo vuelve valioso durante un incidente (podés ver *qué* credencial se escribió, y si fue una rotación o un reemplazo) y exactamente lo que lo vuelve peligroso: **el log de auditoría ahora contiene material secreto en texto plano**. Base64 no es cifrado. El log de auditoría se convierte en un artefacto de nivel secreto que requiere el mismo cifrado en reposo, límites de retención y control de acceso que el almacén de etcd, y típicamente se envía a un agregador de logs con controles mucho más débiles. La mayoría de las políticas de producción usan `Metadata` para `secrets` por esta razón, y solo habilitan `RequestResponse` temporalmente durante una investigación forense. El laboratorio lo usa para que *veas* el peligro.

**Q0.3** — `flux install` no satisface **"extraído automáticamente (pull)"** para el propio Flux. Los controladores están corriendo, pero fueron instalados imperativamente; sus propios manifiestos no están en Git, así que actualizar o reconfigurar Flux es un `kubectl apply` manual, el drift en el despliegue de Flux no se detecta, y no hay rastro de auditoría de los cambios al reconciliador — el componente más privilegiado del clúster. `flux bootstrap` commitea los manifiestos de Flux al repositorio y crea un `Kustomization` que reconcilia `flux-system` contra ellos, volviendo a Flux auto-gestionado: el drift de Flux se detecta y se corrige como el de cualquier otra carga de trabajo, y cada actualización de controlador es un commit revisado.

### Bloque 1 — Mínimo privilegio

**Q1.1** — kustomize-controller realiza un **dry-run de apply del lado del servidor sobre todo el conjunto de recursos** antes de comprometer ningún cambio, y trata al conjunto como una unidad. Si algún objeto del conjunto es rechazado, todo el `Kustomization` se marca como no-listo y no se aplica nada. Desde el punto de vista de la seguridad esto es lo que querés: hace imposible la aplicación parcial, así que un atacante no puede colar un cambio emparejándolo con un objeto que *sabe* que va a fallar — no existe un estado donde la "mitad buena" aterrizó. También significa que la falla es ruidosa y atómica en lugar de una configuración a medio aplicar que no es ni el estado viejo ni el nuevo.

**Q1.2** — Dos de varias:
1. **El repositorio no es la única entrada.** Un `Kustomization` puede referenciar bases remotas, un `HelmRelease` trae un chart arbitrario, un `OCIRepository` sigue un tag mutable. Ninguna de esas cosas pasa por tu revisión. Si el reconciliador es cluster-admin, quien controle ese upstream es cluster-admin.
2. **La revisión no es imposición.** La protección de ramas puede ser deshabilitada por un admin del repo, saltada por un merge de admin, o derrotada por una cuenta de bot / token de CI comprometido con acceso de escritura. El compromiso a nivel repositorio es común; el modelo de seguridad no debería convertirlo en root del clúster.
3. Además: cualquiera con `patch` sobre el objeto `Kustomization`/`Application` dentro del clúster puede reapuntar `spec.path` o `spec.source` a contenido que controla, salteándose Git por completo.

**Q1.3** — Una ServiceAccount de solo lectura otorga *algo*. Una inexistente no otorga *nada* — cada petición desde esa identidad se deniega porque no hay ningún binding para ella — y además produce un error inconfundible (`serviceaccounts "flux-default" not found` / un `forbidden` general) que le dice al operador "te olvidaste de `serviceAccountName`", en lugar de un éxito parcial sutil. La regla es: el valor por defecto debe ser un estado que nadie querría jamás dejar en su lugar. Un default de solo lectura falla en silencio y podría sobrevivir hasta producción; uno inexistente no puede.

**Q1.4** — `clusterResourceWhitelist: []` **falla cerrado**: es una lista de permitidos, así que todo lo que no esté enumerado se deniega, incluidos los tipos de recurso introducidos por un CRD que se instale el año que viene. `namespaceResourceBlacklist` **falla abierto**: solo deniega lo que se te ocurrió listar, así que cualquier tipo que no anticipaste está permitido. Para un tenant hostil o no confiable, apoyate en las listas de permitidos (`clusterResourceWhitelist`, `namespaceResourceWhitelist`, `sourceRepos`, `destinations`) y tratá a las listas negras solo como defensa en profundidad. Una lista negra que hay que actualizar cada vez que el ecosistema publica un CRD nuevo es una obligación de mantenimiento que vas a perder.

**Q1.5** — `argocd account can-i` evalúa la política **para la cuenta actualmente logueada**, y `admin` es un superusuario incorporado que saltea `policy.csv` por completo — devuelve `yes` para todo, así que no prueba nada sobre un tenant. El comando que sí evalúa la política para un sujeto arbitrario es:

```bash
argocd admin settings rbac can <subject> <action> <resource> <object> --policy-file policy.csv
```

que corre la evaluación de Casbin offline contra un sujeto/grupo dado. Combinalo con `argocd admin settings rbac validate` en CI para que un `policy.csv` mal formado se detecte antes de ser aplicado — un error de sintaxis en ese ConfigMap cae silenciosamente de vuelta a `policy.default`.

### Bloque 2 — Secretos

**Q2.1** — **Beneficio:** el diff de un secreto rotado muestra solo el blob de texto cifrado cambiado contra una estructura sin cambios y legible por humanos, así que un revisor puede confirmar "este PR rota la contraseña de `db-credentials` en `tenant-a`" sin descifrar nada. Cifrar el archivo entero convierte cada diff en un muro opaco de texto cifrado, y los revisores dejan de revisar. También permite que `kustomize`, los validadores de esquema y los motores de políticas parseen el archivo. **Riesgo:** los metadatos en claro son un inventario. `metadata.name`, `namespace` y los *nombres de las claves* bajo `stringData` divulgan tu arquitectura — `stripe-live-api-key`, `prod-root-db-password`, `okta-saml-signing-cert` le dicen a un atacante exactamente dónde apuntar, y el conjunto de namespaces mapea tu tenancy. En un repositorio público esto tiene valor real de reconocimiento; tratá el nombrado de claves como semipúblico.

**Q2.2** — Los logs son solo uno de varios lugares donde un controlador puede hacer eco de su entrada. El peligro histórico en Flux es **`.status`** — específicamente las condiciones de estado y los eventos derivados de ellas, donde un mensaje de error que embebe el objeto ofensor puede llevar contenido descifrado a un objeto legible por cualquiera con `get` sobre `Kustomization` (un grupo mucho más amplio que `get secrets`). Los objetos `Event` de Kubernetes son el mismo problema con más alcance: son legibles por namespace por defecto y suelen enviarse enteros a un backend de logging. Así que el chequeo debe cubrir logs **y** eventos **y** `.status`, y en producción también deberías confirmar que tu pipeline de logs no esté indexando el stdout del controlador en un sistema con acceso más amplio que el propio clúster.

**Q2.3** — Cualquiera con `get` sobre Secrets en `tenant-a`, más cualquiera con lectura de secretos a nivel clúster (`cluster-admin`, la mayoría de los agentes de monitoreo/backup, y cualquier carga de trabajo cuya ServiceAccount esté sobre-vinculada). Averigualo con:

```bash
kubectl auth can-i get secrets -n tenant-a --as=<subject>
# or, exhaustively:
kubectl get rolebindings,clusterrolebindings -A -o json \
  | jq '.items[] | select(.roleRef.name|test("admin|edit|cluster-admin")) | {kind, ns:.metadata.namespace, name:.metadata.name, subjects}'
```

Esta es la debilidad estructural de SOPS-en-el-clúster: **la clave de descifrado es un Secret de Kubernetes**, así que la seguridad de cada archivo cifrado colapsa a la seguridad de un Secret en un namespace, protegido por el mismo RBAC que estabas tratando de reforzar. Mitigaciones: poné la clave en un namespace que ningún tenant pueda alcanzar, usá un proveedor KMS (AWS/GCP/Azure KMS, Vault) para que la clave privada nunca exista dentro del clúster, y habilitá el cifrado de etcd en reposo. Pero notá que incluso con KMS, todo lo que el controlador pueda descifrar, un atacante con la identidad del controlador lo puede descifrar.

**Q2.4** — Solo **External Secrets Operator** (o cualquier patrón de traer-desde-un-gestor-de-secretos) puede satisfacerlo. El registro de auditoría tiene que existir en el momento del *acceso*, y con ESO cada recuperación es una llamada API autenticada a Vault/AWS Secrets Manager/GCP Secret Manager, que registra identidad del llamador, marca de tiempo y ruta del secreto. SOPS y Sealed Secrets no pueden: en ambos casos el material secreto se descifra de un archivo que el operador ya posee, y leer un archivo no es un evento auditable — no hay un tercero que lo registre. (Salvedad que vale la pena declarar en una respuesta de examen: ESO audita la *recuperación hacia el clúster*, no las lecturas posteriores del Secret de Kubernetes resultante. Para eso seguís necesitando la auditoría del API server sobre `secrets`, que es exactamente la regla de Q0.1.)

**Q2.5** — Sealed Secrets cifra contra una clave pública cuya mitad privada es generada por, y vive solo en, el controlador de sealed-secrets de ese clúster específico. Entonces:
- **Disponibilidad:** reconstruir el clúster genera un par de claves *nuevo*, y cada `SealedSecret` en Git se vuelve indescifrable. La recuperación requiere haber respaldado la clave privada del controlador — un paso que es fácil de saltear y que se descubre faltante durante un desastre, que es el peor momento posible. Esta es la caída más común de Sealed Secrets.
- **Seguridad:** ese backup es en sí mismo una clave maestra de todos los secretos del clúster, así que creaste un artefacto de alto valor que debe guardarse en algún lugar *distinto* del clúster, con su propio control de acceso e historia de rotación. Multiclúster lo empeora: o compartís una clave entre clústeres (destruyendo el radio de impacto por clúster que era la ventaja) o mantenés N copias cifradas de cada secreto.

El modo de falla correspondiente de **SOPS** es la imagen espejo: perder la clave privada age/KMS vuelve permanentemente indescifrable cada archivo cifrado del repositorio, y rotar destinatarios significa recifrar cada archivo (`sops updatekeys`) — un cambio de todo el repositorio que es fácil de aplicar incompletamente, dejando archivos que solo la clave *vieja* puede abrir.

### Bloque 3 — Cadena de suministro

**Q3.1** — Los tags son punteros mutables. Si firmás `:v2` y verificás `:v2`, la firma atestigua sobre el manifiesto al que ese tag apuntaba cuando firmaste — pero la verificación vuelve a resolver el tag en el momento del pull. Un atacante con acceso de push reapunta `:v2` a un manifiesto que controla; el verificador trae el digest nuevo y busca una firma sobre *él*. Con cosign la firma se almacena en un tag derivado del digest (`sha256-<digest>.sig`), así que el digest del atacante no tiene firma y la verificación falla — que es por qué firmar por digest y verificar por digest es seguro. Las variantes genuinamente peligrosas son (a) esquemas de verificación que chequean "¿existe *alguna* firma válida para esta referencia?" sin atarla al digest resuelto, y (b) **el propio flujo de trabajo del operador**: `cosign sign :v2` resuelve el tag en el momento de firmar, así que si el tag se movió entre tu revisión y tu firma, firmaste contenido que nunca revisaste. Firmar el digest que efectivamente inspeccionaste elimina la carrera por completo.

**Q3.2** — La **reconciliación continua** — específicamente, la reconciliación del *último estado conocido como bueno*. source-controller solo almacena un artefacto después de que la verificación tiene éxito, así que una falla de verificación deja en su lugar el artefacto previamente almacenado, y kustomize-controller lo sigue aplicando. Sí, esto es correcto: la alternativa — detener la imposición cuando la fuente no está disponible o no es confiable — significaría que cualquiera que pueda romper tu verificación de fuente también puede congelar tu clúster y dejar que el drift se acumule sin oposición. Fail-closed al *aceptar estado nuevo*, fail-static al *imponer estado conocido-bueno*. El corolario esencial es que esta falla es silenciosa desde el punto de vista de la carga de trabajo, así que **debe** alertarse (`FluxReconciliationFailure`, Ejercicio 6) — de lo contrario corrés indefinidamente sobre configuración vieja creyendo que estás al día.

**Q3.3** — Varias respuestas defendibles:
- **Los charts de Helm** traídos por `HelmRelease` — cubiertos por `HelmRepository`/`HelmChart` con `verify.provider: cosign` para charts hospedados en OCI, o archivos de procedencia (`.prov`) para repositorios clásicos.
- **Las propias imágenes de los controladores de Flux** — cubiertas verificando los releases firmados de Flux en el bootstrap, y con `flux install --image-pull-secret` / manifiestos fijados por digest.
- **Las imágenes base y las dependencias dentro de `podinfo`** — cubiertas por atestaciones de procedencia SLSA y atestaciones SBOM (`cosign attest --type slsaprovenance` / `--type cyclonedx`), verificadas con bloques `attestations:` de Kyverno en lugar de un chequeo de firma pelado. Una firma dice "esta identidad lo construyó"; una atestación dice "y acá está lo que entró en él".
- **Los commits de Git** — cubiertos por commits/tags firmados y `GitRepository.spec.verify`.

**Q3.4** — Con `subject: "https://github.com/my-org/"` (sin anclar, tratado como regex), el patrón matchea cualquier subject que *contenga* esa subcadena. Un atacante registra `https://github.com/my-org-evil/...`, o más simplemente hace push de una rama a *cualquier* repositorio bajo `my-org` que tenga un workflow con `id-token: write`, y obtiene una firma keyless de Sigstore cuyo subject es `https://github.com/my-org/some-unrelated-repo/.github/workflows/anything.yaml@refs/heads/attacker-branch`. Ese subject contiene la subcadena, así que la verificación pasa y Flux despliega su artefacto como si fuera la configuración de la plataforma. La versión anclada fija el repositorio exacto, el archivo de workflow exacto y `@refs/tags/v*` — así que solo una ejecución disparada por tag de un workflow específico en un repositorio específico produce una firma aceptada. **Anclá siempre, y fijá siempre la ruta del workflow y el tipo de ref, no solo la organización.**

**Q3.5** — **Beneficio:** el Pod en ejecución queda fijado a un digest inmutable, así que el contenido queda fijo en el momento de la admisión. Sin eso, el reinicio de un kubelet o el escalado de nodos vuelve a traer `:6.7.1`, y si ese tag fue reapuntado desde entonces, el nodo nuevo corre código distinto al viejo — el clásico "mismo tag, bits distintos a lo largo de la flota", y un mecanismo de persistencia para un atacante que pueda hacer push al registry. También hace que `kubectl describe pod` sea un registro exacto de lo que efectivamente está corriendo. **Consecuencia operativa:** el digest queda congelado en la admisión. Un equipo que depende de `imagePullPolicy: Always` con un tag flotante para levantar parches va a descubrir que los Pods ya no cambian de contenido al reiniciar; las actualizaciones ahora requieren que cambie el pod template del Deployment (que es el comportamiento correcto según GitOps, vía un controlador de automatización de imágenes que escribe el digest nuevo a Git, pero *es* un cambio de flujo de trabajo). El rollback y el análisis forense también pasan a referenciar digests en lugar de tags amigables.

**Q3.6** — **Riesgo:** `failurePolicy: Fail` significa que si el webhook no puede completarse — porque Rekor está inalcanzable, lento, limitando la tasa, o tu proxy de salida está caído — *toda* creación de Pod en el alcance matcheado se deniega. Eso convierte la disponibilidad de un servicio externo en la capacidad de tu clúster de agendar cargas de trabajo, y muerde más fuerte exactamente cuando lo necesitás (durante un incidente, cuando estás escalando o reemplazando nodos). También es una superficie de DoS autoinfligida. **Mitigaciones que preservan la propiedad de seguridad:**
- Corré un **mirror local de Sigstore / raíz TUF** y un Rekor interno, o usá verificación `--offline` contra una firma empaquetada para que no haga falta ninguna llamada de red en la admisión.
- Firmá con una **clave estática** cuya mitad pública esté guardada en el clúster (sin ida y vuelta al log de transparencia) para las cargas que nunca deben fallar al agendarse; dejá keyless+Rekor para el resto.
- Acotá la política estrechamente (namespaces específicos, excluí `kube-system` y el CNI) y poné un `webhookTimeoutSeconds` agresivo, para que un atasco degrade una porción y no el clúster.
- Verificá **en la admisión sobre la referencia de imagen ya resuelta por una compuerta previa de CI**, para que el chequeo de admisión sea una comparación barata de digest en lugar de una verificación remota completa.

Lo que *no* es una mitigación aceptable es pasar a `failurePolicy: Ignore`, que convierte el control en una sugerencia: un atacante que pueda degradar la conectividad con Rekor puede entonces desplegar cualquier cosa.

### Bloque 4 — Política como código

**Q4.1** — **Capaces de notarlo:** (a) la detección de drift del reconciliador — Argo CD marca la app como `OutOfSync`, Flux reporta un diff; y (b) el log de auditoría del API server, que registra el `patch` y su autor. Kyverno *no* lo nota, porque la edición del Deployment fue permitida y solo el Pod resultante es matcheado por la política. **Capaz de deshacerlo:** solo el reconciliador, y solo si la auto-reparación / reconciliación continua está habilitada — `syncPolicy.automated.selfHeal: true` en Argo CD, o el comportamiento por defecto de Flux de reaplicar en cada intervalo. El log de auditoría es un control detectivo sin poder correctivo. Este es el punto entero del ejercicio: detección, prevención y corrección son tres controles distintos, y GitOps solo aporta el tercero por defecto.

**Q4.2** — Matchear solo `Pod` significa que el `Deployment` fue aceptado, el ReplicaSet fue creado, y el *Pod* fue bloqueado (o, en este caso, permitido, ya que la regla de registry corrió contra un Pod que todavía no existía al momento de la edición). El `kubectl set image` del desarrollador devuelve éxito y la falla aparece después como un evento de ReplicaSet que nadie lee, con el Deployment mostrando `0/1 ready` y sin causa evidente. La solución es matchear también los **tipos de controlador**, para que el error se devuelva sincrónicamente a quien hizo el cambio:

```yaml
match:
  any:
    - resources:
        kinds: [Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet]
```

Kyverno autogenera reglas para controladores de pods cuando la regla matchea `Pod` (la anotación `pod-policies.kyverno.io/autogen-controllers` controla esto), pero deberías verificar que la autogeneración realmente produjo las reglas que esperás con `kubectl get clusterpolicy tenant-baseline -o yaml | grep autogen`, en lugar de asumirlo. Matchear explícitamente los tipos de controlador es lo que hace que el mensaje de error aterrice en el humano que lo causó.

**Q4.3** — Aplicar una política nueva directamente en `Enforce` sobre un clúster con cargas de trabajo existentes rompe **la próxima mutación de cada carga no conforme que ya está corriendo**. Los Pods en ejecución quedan intactos — la admisión solo evalúa peticiones nuevas — así que nada parece estar mal. Después se drena un nodo, un HPA escala, un Deployment rota, o se recrea un Pod en `CrashLoopBackOff`, y el Pod de reemplazo es denegado. Obtenés una caída parcial, demorada y aparentemente aleatoria que aparece horas o días después de que la política se mergeó, en cargas de trabajo no relacionadas con el cambio, y muchas veces durante un incidente no relacionado en el que el clúster ya está reacomodando Pods. `Audit` primero te da el inventario del `PolicyReport` de exactamente qué cargas se van a romper, así que las arreglás antes de tocar el interruptor — y la demora tipo `for:` entre ambos pasos es lo que hace que el despliegue sea revisable.

**Q4.4** — `permissions: contents: read` significa que el job de CI **no tiene ninguna credencial de clúster** — puede leer el repositorio y nada más. Ese es el argumento estructural de seguridad a favor de GitOps basado en pull: en un pipeline basado en push, CI debe tener un kubeconfig con acceso de escritura a producción, así que cada sistema de CI, cada acción de terceros, cada dependencia del build y cada contribuidor capaz de modificar un archivo de workflow se vuelven un camino hacia cluster-admin. GitOps basado en pull invierte la dirección de la confianza — el clúster sale a buscar a Git, las credenciales nunca salen del clúster, y la superficie de compromiso de CI se reduce a "puede proponer un cambio que un humano revisa y un reconciliador con mínimo privilegio aplica". CI valida; no despliega.

**Q4.5** — **Solo CI:** violaciones en configuración que nunca llega a la admisión — un overlay de `Kustomization` que no compila, un recurso para un namespace que no existe, una violación de política en un manifiesto para un clúster *distinto*, un secreto commiteado por accidente en texto plano, o un cambio que borraría un recurso (la admisión ve la petición de borrado, no el hecho de que "este PR elimina 40 objetos"). CI también detecta violaciones en recursos que serían podados o nunca creados, y puede hacer fallar el *pull request*, que es el único lugar donde hay un humano mirando. **Solo el webhook:** cualquier cosa que se saltee Git — `kubectl` desde una laptop, un controlador u operador creando objetos programáticamente, los hooks de un chart de Helm, un webhook mutante inyectando un sidecar después de que CI validó el manifiesto, o valores resueltos en tiempo de ejecución desde un ConfigMap. Estructuralmente, CI valida *texto fuente*; el webhook valida *la petición API real*, incluyendo todo lo que fue templado, defaulteado o mutado en el medio. Ninguno alcanza solo, y por eso la respuesta siempre es ambos.

### Bloque 5 — Drift y atribución

**Q5.1** — El **estado de sincronización** compara el estado vivo del clúster contra el estado deseado en Git — responde "¿es el clúster lo que declaramos?". El **estado de salud** es una evaluación a nivel aplicación de los recursos vivos — réplicas del Deployment disponibles, endpoints del Service listos — y responde "¿está la cosa corriendo bien?". Son ortogonales: un atacante que inyecta una imagen con backdoor produce una aplicación perfectamente `Healthy` que está `OutOfSync`, y una app legítimamente sincronizada puede estar `Degraded` por un tag de imagen malo en Git. Alertar solo sobre `Healthy` significa que cada cambio no autorizado exitoso es invisible, porque los cambios maliciosos suelen estar diseñados para mantener la carga funcionando. El estado de sincronización es la señal de seguridad; el de salud es la señal de disponibilidad. Paginá sobre `Degraded`; alertá sobre `OutOfSync` sostenido.

**Q5.2** — *Toda entrada de `ignoreDifferences` debe nombrar al controlador que legítimamente es dueño del campo, y no debe cubrir nada que determine qué código corre.* Concretamente: aceptable para campos de los que es dueño otro controlador dentro del clúster (`/spec/replicas` bajo un HPA, `caBundle` inyectado por cert-manager, `clusterIP` asignado por el API server, los `caBundle` de webhooks). Inaceptable para `image`, `command`, `args`, `env`, `securityContext`, `serviceAccountName`, reglas de RBAC, o cualquier cosa bajo `/spec/template/spec/containers/*` que no sean los campos de recursos gestionados por un VPA. Un PR que agrega uno de estos últimos debe tratarse como un pedido de deshabilitar un control de seguridad y revisarse como tal — incluyendo "¿qué alertas dejan de funcionar si mergeamos esto?". Preferí las alternativas más estrechas y autodocumentadas: `managedFieldsManagers` (ignorar solo lo que un field manager nombrado posee) por sobre un puntero JSON crudo, y `RespectIgnoreDifferences=true` para que la exclusión sea consistente entre el diff y el sync.

**Q5.3** — La reversión automática empeora un incidente cuando el drift *es* la mitigación. Casos clásicos: un ingeniero de guardia escala a cero un Deployment desbocado para que deje de inundar una base de datos, y la auto-reparación lo vuelve a escalar 30 segundos después; alguien parchea el selector de un Service para desviar tráfico de un release malo; se aplica una imagen de `hotfix` manual mientras el arreglo todavía está en revisión. La auto-reparación convierte cada uno de estos en una pelea que el humano pierde contra un cronómetro. Los mecanismos de pausa deliberada:
- Flux: `flux suspend kustomization <name>` (pone `spec.suspend: true`), `flux suspend helmrelease`, o `flux suspend source`.
- Argo CD: `argocd app set <app> --sync-policy none`, o las anotaciones `argocd.argoproj.io/sync-options: Prune=false` / por recurso `argocd.argoproj.io/compare-options: IgnoreExtraneous` para exclusiones más estrechas.

Ambos deben combinarse con la alerta de suspensión del Ejercicio 6, porque un reconciliador suspendido es un control de seguridad que fue apagado, y el modo de falla es que nadie lo vuelve a encender.

**Q5.4** — Un campo que Flux no gestiona **se deja en paz**. Server-side apply rastrea la propiedad campo por campo en `metadata.managedFields`; kustomize-controller envía solo los campos presentes en sus manifiestos, así que reclama la propiedad de esos y los recupera en el siguiente apply, mientras que los campos que pertenecen a otros managers (la anotación de sidecar inyectada por un webhook mutante, el `spec.replicas` de un HPA, los valores por defecto del API server) quedan intactos. Este es el diseño correcto porque Kubernetes es un sistema de múltiples escritores: varios controladores co-poseen legítimamente un objeto. Un reconciliador que impusiera igualdad *de objeto completo* pelearía contra cada webhook de admisión, cada autoescalador y cada defaulter en un bucle de apply interminable — exactamente el comportamiento que volvió inusable el GitOps con client-side-apply junto a los service meshes. Notá igual la consecuencia de seguridad: **Flux solo corrige el drift en los campos que declara.** Un campo que nunca escribiste en Git (digamos, un volumen `hostPath` agregado a un Deployment... que SSA *sí* detectaría como parte de la lista de containers, pero una etiqueta, anotación o entrada de tolerations agregada) es drift que la reconciliación no va a eliminar salvo que `spec.force` o una declaración explícita lo cubra. La detección de campos *agregados* es más débil que la corrección de los declarados que fueron *modificados*.

**Q5.5** — Git registra lo que fue *declarado* y por quién, y cuándo se mergeó. No tiene registro del clúster en ejecución: un `kubectl patch` fuera de banda nunca toca Git, así que desde el punto de vista de Git no pasó nada a las 14:41. Los eventos propios del reconciliador te dicen que *corrigió* algo y cuándo, pero no quién lo causó — el actor está del otro lado del API server. La fuente de datos adicional mínima es el **log de auditoría del API server** (o un equivalente que capture metadatos de peticiones autenticadas: un proxy / sidecar de auditoría, o un sensor de runtime estilo Falco/Tetragon observando el tráfico de la API). Es el único lugar que ata una *identidad* a una *mutación*. Por eso también el log de auditoría tuvo que habilitarse en el Ejercicio 0 — ver Q7.5.

### Bloque 6 — Observabilidad

**Q6.1** — La multiplicación por `gotk_suspend_status == 0` previene la **fatiga de alertas por suspensiones deliberadas**: un `Kustomization` suspendido para una migración o un break-glass no está fallando, y si le pagina al de guardia cada 10 minutos, el equipo aprende a ignorar la alerta — que es peor que no tenerla. El punto ciego que crea es exactamente lo que la suspensión *es*: un reconciliador que dejó de imponer nada. El drift ya no se corrige, los cambios no autorizados persisten indefinidamente, y la alerta de falla está silenciada por construcción. `FluxReconciliationSuspended` (`gotk_suspend_status == 1`, `for: 1h`) lo cierra convirtiendo "suspendido" de un estado invisible en uno acotado en el tiempo. El par codifica la política real: *la suspensión está permitida, la suspensión permanente no*.

**Q6.2** — `gotk_reconcile_condition` y `argocd_app_info` son exportadas *por los propios controladores*. Si un controlador se cae, se escala a cero, se borra, o su selector de `PodMonitor` deja de matchear tras un cambio de etiqueta, las series simplemente **dejan de producirse**. Prometheus las retiene brevemente (los marcadores de staleness hacen que desaparezcan en ~5 minutos) y después cualquier consulta de la forma `metric == 1` o `metric > 0` devuelve un *resultado vacío* — que para una regla de alerta significa "sin alerta". El silencio es indistinguible de la salud. `absent()` invierte esto: devuelve `1` precisamente cuando el selector no matchea nada, así que la desaparición de la telemetría se vuelve la señal. Cada stack de alertas que depende de una métrica exportada por una aplicación necesita un compañero `absent()` (o `up == 0`); sin eso estás monitoreando "el reconciliador dice que está bien", no "el reconciliador existe". Una versión de producción también alertaría sobre `up{job=~".*controller.*"} == 0` para distinguir "controlador caído" de "configuración de scrape rota".

**Q6.3** — `Degraded` significa que la carga de trabajo está fallando *ahora mismo* — Pods en crash-loop, sin endpoints listos, usuarios afectados. Eso es un incidente de disponibilidad y cinco minutos ya es generoso; el `for: 5m` existe solo para absorber una actualización progresiva normal. `OutOfSync` significa que el clúster difiere de Git, lo cual es rutinariamente transitorio: es el estado esperado durante los segundos-a-minutos entre un merge y la siguiente reconciliación, durante una operación de sync, y mientras se completa un rollout lento. Alertar a los 5 minutos se dispararía en cada despliegue. Quince minutos dice "esta divergencia sobrevivió a cualquier ventana legítima de despliegue, así que es o un sync trabado o un cambio no autorizado" — una señal de seguridad que merece investigación pero no una paginada a las 3 de la mañana. El principio general: poné el `for:` más largo que la duración *normal* más larga de la condición, y la severidad según lo que la condición significa una vez superada esa duración.

**Q6.4** — Como `sync_status` y `health_status` son etiquetas y no valores, **cada estado distinto produce una serie temporal distinta**. Una aplicación que oscila `Synced` → `OutOfSync` → `Synced` crea dos series, y la de `OutOfSync` no se va a cero cuando la app se recupera — se vuelve *stale*. Prometheus sigue devolviendo su último valor hasta 5 minutos después del último scrape que la contenía, así que `argocd_app_info{sync_status!="Synced"} == 1` puede seguir evaluando como verdadero varios minutos después de que la condición se despejó, y con un intervalo de scrape corto y una app que oscila podés acumular series para estados que ya no existen. Las fallas prácticas son (a) una alerta que se resuelve con varios minutos de retraso, y (b) con configuraciones inusuales de scrape/retención, una alerta que aparece trabada disparándose. La cardinalidad también crece con `name × project × dest_namespace × health_status × sync_status`, lo que en un clúster con miles de aplicaciones es un costo de memoria real. Mitigaciones: agregá con `max by (name) (...)` y compará contra el estado *actual* en lugar de seleccionar sobre la etiqueta, mantené la ventana de `for:` cómodamente más larga que la ventana de staleness, y usá reglas de grabación para colapsar las etiquetas de estado en un puntaje numérico de salud.

**Q6.5** — Ninguna de estas mide el **retraso de commit-a-vivo**: el tiempo de reloj desde que un cambio se mergea en Git hasta que ese cambio está observablemente corriendo en el clúster. `gotk_reconcile_duration_seconds` mide cuánto tardó *un apply*, no cuánto esperó el cambio en el intervalo de sondeo de la fuente, en el pipeline de CI, en el build de la imagen, o en el rollout. Ese número de punta a punta es el que debería llevar el SLO de la plataforma ("el 95% de los merges están vivos en 10 minutos"), porque es el único que un usuario de la plataforma experimenta, y también es el número relevante para la seguridad: acota cuánto tarda un *parche de seguridad* en llegar a producción y — leído al revés — cuánto sobrevive el cambio mergeado de un atacante antes de ser notado. Para medirlo: estampá cada commit en los manifiestos renderizados (una etiqueta o anotación con el SHA del commit y la marca de tiempo de su autor), y después exportá una métrica que compare la marca de tiempo del commit con el momento de observación de ese SHA en el clúster vivo. Flux expone `.status.lastAppliedRevision` en el `Kustomization` y Argo CD expone `.status.sync.revision` en la `Application`; un exportador chico (o una configuración de recursos personalizados de `kube-state-metrics`) puede convertir cualquiera de los dos en `gitops_commit_to_live_seconds`. Los canarios sintéticos — un job que commitea un archivo con marca de tiempo cada N minutos y mide cuándo aparece — son la versión barata y en general alcanzan.

### Bloque 7 — Notificaciones y respuesta

**Q7.1** — `eventSeverity: info` entrega *todos* los eventos, incluidas las reconciliaciones exitosas. Eso es valioso como un flujo de auditoría de bajo ruido en un canal de chat — "tenant-a reconcilió a v4 a las 14:02" le da al equipo conciencia ambiental de qué está cambiando, y su *ausencia* es en sí misma una señal. Pero es de alto volumen: con un intervalo de 1 minuto sobre decenas de recursos va a inundar un canal y, más importante, entrena a la gente a ignorar el canal. `eventSeverity: error` entrega solo las fallas. **La paginación de producción va a `error`**, ruteada al de guardia; el flujo `info`, si lo querés, va a un canal separado de baja prioridad o directo al pipeline de logs. La regla general: el canal que despierta a alguien debe tener una tasa de accionabilidad cercana al 100%, y ningún flujo que contenga éxitos rutinarios puede tenerla.

**Q7.2** — `argocd app rollback N` realiza un sync imperativo a una revisión previamente registrada. Cambia el *clúster* sin cambiar *Git*, así que en el momento en que termina, el estado vivo difiere del estado declarado. Con `selfHeal: false` la app queda `OutOfSync` (y tu alerta del Ejercicio 6 se dispara); con `selfHeal: true` el controlador de aplicaciones reaplica el estado deseado desde Git dentro de un intervalo y te lleva directo *hacia adelante* de vuelta a la revisión rota — muchas veces más rápido de lo que el ingeniero puede reaccionar, lo cual es un incidente genuinamente confuso de vivir. El único rollback que es estable bajo reconciliación continua es el que **cambia el estado declarado**: `git revert <bad-commit>` (o un commit que reapunte al digest/tag anterior), pusheado a la rama seguida. Es estable porque el reconciliador ahora coincide con él; también es revisable, firmado, atribuible, y deja el incidente visible en el historial en lugar de como una mutación no rastreable del clúster. `argocd app rollback` es una herramienta de break-glass para cuando Git o CI no están disponibles, y debería seguirse de un revert real ni bien se pueda.

**Q7.3** — (1) **La alerta de suspensión** — `gotk_suspend_status == 1` con `for: 1h` del Ejercicio 6. Sin ella, la anotación es una nota que nadie lee y la suspensión se vuelve permanente por desgaste; con ella, el break-glass tiene una conversación de vencimiento incorporada. (2) **El log de auditoría** — `kubectl patch`/`flux suspend` es una mutación autenticada del objeto `Kustomization`, registrada con la identidad y la marca de tiempo del actor, así que lo que afirma la cadena de `--reason` se puede contrastar contra quién lo hizo realmente y cuándo. Juntos hacen que la anotación sea *verificable y acotada en el tiempo* en lugar de decorativa. Un tercero, si tu configuración lo tiene: el flujo de notificaciones, ya que suspender emite un evento que aterriza en el canal de incidentes, poniendo la desviación frente al equipo en tiempo real en lugar de en un campo que alguien tiene que acordarse de mirar.

**Q7.4** — Los mensajes de los controladores embeben el contenido que los causó: rutas de campos que fallaron, extractos de objetos rechazados, cadenas de error del API server, URLs de repositorios, referencias de imágenes y, ocasionalmente, valores descifrados (ver Q2.2). Rutear eso a un servicio de chat o webhook de terceros **publica la arquitectura interna — y potencialmente material secreto — a un proveedor**, donde queda retenido, indexado, buscable por cualquiera del workspace, y muchas veces replicado a los propios sistemas de logging y soporte de ese proveedor. Los workspaces de chat suelen tener una membresía mucho más amplia que el RBAC del clúster, así que esto puede ser una divulgación mayor que otorgarle `get secrets` a toda la empresa. Qué hacer: tratá los payloads de notificación como confidenciales del clúster — preferí un receptor autohospedado o un proveedor `generic` apuntando a infraestructura que controlás; usá plantillas que emitan solo campos estructurados en lista de permitidos (`app`, `namespace`, `revision`, `status`) en lugar de pasar `message` textual; ruteá a un canal privado con membresía revisada como cualquier otro otorgamiento de acceso; y verificá el chequeo del paso 7 del Ejercicio 2 también contra el *receptor de notificaciones*, no solo contra los logs. Si tenés que usar un proveedor SaaS, mandá un identificador y hacé que el ingeniero busque el detalle en un sistema que lo autentique.

**Q7.5** — El **log de auditoría del API server**. La procedencia del artefacto se puede reconstruir después del hecho (el digest sigue en el registry, la firma sigue en el log de transparencia de Rekor, `push.json` o el manifiesto OCI se pueden releer). Los eventos del reconciliador y el estado de los objetos se pueden re-derivar hasta cierto punto de los logs del controlador, los campos `.status` y los propios objetos. Las notificaciones, si se pierden, son un duplicado de información que los controladores todavía tienen. Pero el log de auditoría es el **único** registro que ata una *identidad* a una *mutación*, existe solo si el API server fue configurado para escribirlo **antes** del evento, y no se puede reconstruir de ninguna otra cosa — la petición desaparece en el momento en que se sirve. Todo lo de este tema que responde "quién hizo esto, y cuándo" se derrumba sin él. Por eso pertenece al Ejercicio 0: es el único control cuya ausencia solo podés descubrir cuando ya es demasiado tarde para arreglarla.

</details>

---

## Fuentes

- CNCF GitOps Associate (CGOA) curriculum — <https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md>
- OpenGitOps Principles v1.0.0 — <https://opengitops.dev/>
- Flux security documentation — <https://fluxcd.io/flux/security/>
- Flux multi-tenancy and reconciler impersonation — <https://fluxcd.io/flux/installation/configuration/multitenancy/>
- Flux SOPS guide — <https://fluxcd.io/flux/guides/mozilla-sops/>
- Flux `OCIRepository` signature verification — <https://fluxcd.io/flux/components/source/ocirepositories/>
- Flux `GitRepository` verification — <https://fluxcd.io/flux/components/source/gitrepositories/>
- Flux monitoring and metrics — <https://fluxcd.io/flux/monitoring/metrics/>
- Flux notification controller — <https://fluxcd.io/flux/components/notification/>
- Argo CD RBAC — <https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/>
- Argo CD projects — <https://argo-cd.readthedocs.io/en/stable/user-guide/projects/>
- Argo CD metrics — <https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/>
- Argo CD notifications — <https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/>
- Argo CD secret management overview — <https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/>
- Argo CD sync options and `ignoreDifferences` — <https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/>
- SOPS — <https://github.com/getsops/sops>
- age — <https://github.com/FiloSottile/age>
- Sealed Secrets — <https://github.com/bitnami-labs/sealed-secrets>
- External Secrets Operator — <https://external-secrets.io/latest/>
- Sigstore / cosign documentation — <https://docs.sigstore.dev/>
- Kyverno writing policies — <https://kyverno.io/docs/writing-policies/>
- Kyverno image verification — <https://kyverno.io/docs/writing-policies/verify-images/>
- Kyverno CLI — <https://kyverno.io/docs/kyverno-cli/>
- Kubernetes auditing — <https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/>
- Kubernetes server-side apply and field management — <https://kubernetes.io/docs/reference/using-api/server-side-apply/>
- kind audit-logging configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- SLSA specification — <https://slsa.dev/spec/v1.0/levels>
- Prometheus alerting rules — <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>