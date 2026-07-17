# CKS 1.2 – Usar el CIS Benchmark para revisar la configuración de seguridad de los componentes de Kubernetes (etcd, kubelet, kube-dns, kube-apiserver)

**Fuentes de referencia:**
- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- kube-bench (Aqua Security): https://github.com/aquasecurity/kube-bench
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- Kubelet configuration reference: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/

En estos ejercicios asumimos un cluster desplegado con `kubeadm`, con acceso `ssh`/`sudo` al control plane node y a un worker node. Los nombres de host usados (`controlplane`, `node01`) son genéricos: reemplazalos por los de tu entorno.

---

## Ejercicio 1: Instalar `kube-bench` y correr el escaneo inicial

1. Conectate al control plane node.
2. Corré `kube-bench` como contenedor, montando `/etc` y `/var` de solo lectura para que pueda leer manifests, kubeconfigs y el data directory de `etcd`:
   ```bash
   docker run --pid=host \
     -v /etc:/etc:ro \
     -v /var:/var:ro \
     -t aquasec/kube-bench:latest \
     run --targets master,etcd
   ```
3. En un worker node, corré el target `node`:
   ```bash
   docker run --pid=host \
     -v /etc:/etc:ro \
     -v /var:/var:ro \
     -t aquasec/kube-bench:latest \
     run --targets node
   ```
4. Guardá un snapshot en JSON de esta primera corrida para comparar más adelante:
   ```bash
   docker run --pid=host -v /etc:/etc:ro -v /var:/var:ro \
     -t aquasec/kube-bench:latest run --targets master,etcd \
     --json > before-fix.json
   ```

**Preguntas:**
1. ¿Por qué `kube-bench` necesita montar `/etc` y `/var` como volúmenes de solo lectura en lugar de ejecutarse directamente instalado en el host?
2. ¿Qué determina que `kube-bench` elija automáticamente el perfil de CIS Benchmark a aplicar contra tu cluster?

---

## Ejercicio 2: Interpretar los resultados y ubicar controles específicos

1. Filtrá solo los resultados `[FAIL]` de la corrida del control plane:
   ```bash
   docker run --pid=host -v /etc:/etc:ro -v /var:/var:ro \
     -t aquasec/kube-bench:latest run --targets master \
     | grep -B1 -A2 '\[FAIL\]'
   ```
2. Anotá el ID de control de cada `FAIL` (formato `N.N.N`, por ejemplo `1.2.20`).
3. Consultá la descripción completa y la remediación sugerida para un control puntual:
   ```bash
   docker run --pid=host -v /etc:/etc:ro -v /var:/var:ro \
     -t aquasec/kube-bench:latest run --targets master --check "1.2.20"
   ```
4. Contá cuántos resultados son `WARN` en vez de `FAIL` o `PASS`.

**Preguntas:**
1. ¿Qué diferencia hay entre un resultado `WARN` y uno `FAIL` en `kube-bench`?
2. ¿Por qué algunos controles del CIS Benchmark están marcados como de verificación manual en lugar de evaluarse automáticamente?

---

## Ejercicio 3: Auditar y remediar un control del `kube-apiserver`

1. Inspeccioná el static pod manifest del API server:
   ```bash
   sudo grep -- '--anonymous-auth' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```
2. Si el flag no aparece, el valor por defecto habilita el acceso anónimo (`system:anonymous`), lo cual es señalado como hallazgo por el control correspondiente de la sección "API Server" del benchmark.
3. Editá el manifest y agregá el flag explícitamente:
   ```bash
   sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```
   ```yaml
   - --anonymous-auth=false
   ```
4. Verificá que el kubelet haya recreado el static pod:
   ```bash
   watch crictl ps --name kube-apiserver
   ```
5. Confirmá que el `kubectl` sigue respondiendo (si rompiste algo, revertí el cambio) y volvé a correr el check puntual con `kube-bench --check`.

**Preguntas:**
1. ¿Por qué alcanza con editar el archivo en `/etc/kubernetes/manifests/` para que el cambio se aplique, sin necesidad de `kubectl apply`?
2. ¿Qué riesgo concreto de seguridad introduce dejar `--anonymous-auth=true` en un cluster donde existen `ClusterRoleBinding` amplios?

---

## Ejercicio 4: Auditar la sección `etcd`

1. Revisá los flags de TLS del static pod de `etcd`:
   ```bash
   sudo grep -E -- '--cert-file|--key-file|--client-cert-auth|--peer-cert-file|--peer-key-file|--peer-client-cert-auth|--auto-tls|--peer-auto-tls' \
     /etc/kubernetes/manifests/etcd.yaml
   ```
2. Confirmá que `--client-cert-auth=true` y `--peer-client-cert-auth=true` estén presentes (evitan que `etcd` acepte conexiones sin certificado de cliente).
3. Revisá permisos del data directory:
   ```bash
   sudo stat -c "%a %U:%G" /var/lib/etcd
   ```
4. Revisá permisos de la clave privada del servidor `etcd`:
   ```bash
   sudo stat -c "%a %U:%G" /etc/kubernetes/pki/etcd/server.key
   ```
5. Si encontrás permisos más laxos que `600` en la clave o `700` en el data directory, corregilos:
   ```bash
   sudo chmod 600 /etc/kubernetes/pki/etcd/server.key
   sudo chmod 700 /var/lib/etcd
   ```

**Preguntas:**
1. ¿Por qué el CIS Benchmark exige `client-cert-auth` en `etcd` en lugar de confiar únicamente en el aislamiento de red del cluster?
2. Si un atacante obtiene acceso de lectura directo al data directory de `etcd` sin pasar por el `kube-apiserver`, ¿qué tipo de información sensible podría extraer?

---

## Ejercicio 5: Auditar la sección `kubelet`

1. Ubicá el archivo de configuración del kubelet (path típico en clusters `kubeadm`):
   ```bash
   sudo cat /var/lib/kubelet/config.yaml
   ```
2. Verificá los siguientes campos:
   ```yaml
   authentication:
     anonymous:
       enabled: false
   authorization:
     mode: Webhook
   readOnlyPort: 0
   ```
3. Si `anonymous.enabled` está en `true` o falta `authorization.mode: Webhook`, corregí el archivo.
4. Reiniciá el servicio para aplicar el cambio:
   ```bash
   sudo systemctl restart kubelet
   ```
5. Verificá el estado del nodo tras el reinicio:
   ```bash
   kubectl get nodes
   ```

**Preguntas:**
1. ¿Qué diferencia práctica hay entre dejar `authorization.mode: AlwaysAllow` en el kubelet y configurar `Webhook`?
2. ¿Por qué el benchmark recomienda deshabilitar el read-only port (`10255`) del kubelet en lugar de dejarlo activo "por comodidad" para debugging?

---

## Ejercicio 6: Revisar manualmente la seguridad de CoreDNS/kube-dns

El CIS Kubernetes Benchmark no incluye, en general, una sección de controles automatizados dedicada a CoreDNS/kube-dns — a diferencia de `etcd`, `kubelet` y `kube-apiserver`. Por eso el curriculum de CKS espera que sepas revisarlo manualmente, aplicando los mismos criterios de hardening (RBAC de mínimo privilegio, `securityContext` restrictivo, límites de recursos) que el benchmark exige para otros componentes.

1. Revisá el `securityContext` del Deployment de CoreDNS:
   ```bash
   kubectl get deployment coredns -n kube-system -o yaml | grep -A6 securityContext
   ```
2. Confirmá `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` y `capabilities.drop: ["ALL"]` (salvo `NET_BIND_SERVICE` si escucha en puerto 53 directo).
3. Verificá que existan `resources.requests`/`limits` para prevenir agotamiento de recursos del nodo:
   ```bash
   kubectl get deployment coredns -n kube-system \
     -o jsonpath='{.spec.template.spec.containers[0].resources}'
   ```
4. Revisá el `ClusterRole` asociado a la ServiceAccount de CoreDNS, verificando que los verbs se limiten a lectura (`list`, `watch`, `get`):
   ```bash
   kubectl describe clusterrole system:coredns
   ```
5. Revisá el `ConfigMap` con el Corefile en busca de plugins riesgosos (por ejemplo, un `forward` sin restricción hacia resolvers externos, o `log` exponiendo queries internas en texto plano):
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml
   ```

**Preguntas:**
1. ¿Por qué el CIS Benchmark de Kubernetes generalmente no cubre controles automatizados específicos para CoreDNS/kube-dns?
2. ¿Qué riesgo de seguridad implica que el `ClusterRole system:coredns` tenga verbs de escritura (`update`, `patch`, `delete`) sobre `Services` o `Endpoints`, en lugar de solo `list`/`watch`/`get`?

---

## Ejercicio 7: Confirmar remediaciones y dejar evidencia de auditoría

1. Volvé a correr `kube-bench` sobre los tres targets remediados:
   ```bash
   docker run --pid=host -v /etc:/etc:ro -v /var:/var:ro \
     -t aquasec/kube-bench:latest run --targets master,etcd \
     --json > after-fix.json
   ```
2. Compará los totales antes/después usando `jq`:
   ```bash
   diff <(jq '.Totals' before-fix.json) <(jq '.Totals' after-fix.json)
   ```
3. Para los controles que sigan en `WARN` (verificación manual), documentá en tus notas de remediación quién los revisó y qué decisión se tomó.

**Preguntas:**
1. ¿Por qué es una buena práctica guardar snapshots JSON de antes y después de una remediación en un contexto de auditoría de seguridad?
2. Si un control queda en `WARN` porque requiere juicio humano (por ejemplo, revisar que el uso de `--audit-log-path` cumpla la política interna de retención), ¿por qué no tiene sentido que `kube-bench` lo marque como `FAIL` automáticamente?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
1. Porque los controles del benchmark verifican archivos concretos del sistema (manifests en `/etc/kubernetes/manifests`, kubeconfigs, certificados en `/etc/kubernetes/pki`, el data directory de `etcd` en `/var/lib/etcd`) sin necesitar modificarlos. Montarlos de solo lectura reduce la superficie de riesgo de la propia herramienta de auditoría y evita que un bug en `kube-bench` altere la configuración que está auditando.
2. `kube-bench` detecta la versión de Kubernetes que corre en el cluster (vía la API o los binarios) y la mapea contra el perfil de CIS Benchmark más cercano soportado en su archivo de configuración de perfiles (`cfg/config.yaml` del proyecto), sin que el operador tenga que indicarlo manualmente en la mayoría de los casos.

**Ejercicio 2**
1. `FAIL` indica que el control se pudo evaluar automáticamente (por ejemplo, leyendo un flag de un manifest o el permiso de un archivo) y el valor encontrado no cumple lo esperado. `WARN` indica que el control requiere una decisión o revisión humana porque depende de contexto operativo (por ejemplo, si cierto plugin de admisión debe estar habilitado según la política interna), y `kube-bench` no puede determinar automáticamente si el estado actual es aceptable.
2. Porque hay controles que dependen de decisiones de diseño propias de cada organización (política de auditoría, uso de admission controllers específicos, rotación de certificados) que no tienen un único valor "correcto" universal, así que el benchmark los deja para revisión manual en vez de forzar un criterio fijo.

**Ejercicio 3**
1. Porque el `kube-apiserver`, `etcd`, `kube-scheduler` y `kube-controller-manager` corren como *static pods*: el kubelet del control plane node vigila el directorio `/etc/kubernetes/manifests/` y recrea automáticamente cualquier pod cuyo manifest cambie, sin pasar por el `kube-apiserver` ni por `kubectl apply`.
2. Con `--anonymous-auth=true`, cualquier petición sin credenciales válidas se autentica igual como el usuario `system:anonymous`. Si existe algún `ClusterRoleBinding` (incluso por error de configuración) que otorgue permisos al grupo `system:unauthenticated`, un atacante sin ninguna credencial podría consultar o incluso modificar recursos del cluster.

**Ejercicio 4**
1. Porque el aislamiento de red (por ejemplo, que `etcd` solo escuche en la red interna del cluster) no protege contra un atacante que ya tiene presencia dentro de esa red (un pod comprometido, un nodo comprometido, un pivot lateral). Exigir certificado de cliente añade una capa de autenticación mutua que sigue protegiendo aún si el perímetro de red fue vulnerado.
2. `etcd` almacena el estado completo del cluster, incluyendo objetos `Secret` — que por defecto se guardan sin cifrar salvo que se configure `encryption-provider-config`. Un acceso de lectura directo al data directory permitiría reconstruir esos datos y extraer credenciales, tokens y cualquier otro secreto almacenado en el cluster.

**Ejercicio 5**
1. Con `AlwaysAllow`, el kubelet acepta cualquier petición autenticada sin evaluar si el llamante tiene permiso real para esa acción — es decir, autenticación sin autorización efectiva. Con `Webhook`, el kubelet delega la decisión de autorización al `kube-apiserver` (vía SubjectAccessReview), aplicando las mismas políticas RBAC que rigen el resto del cluster.
2. El puerto de solo lectura (`10255`) expone métricas y el estado de pods sin ningún tipo de autenticación ni autorización. Aunque parezca "solo lectura", puede filtrar información sensible sobre la carga de trabajo del nodo (nombres de pods, imágenes, variables de entorno visibles en specs) a cualquiera con acceso de red a ese puerto.

**Ejercicio 6**
1. Porque el benchmark de CIS está pensado para verificar la configuración de los componentes core de Kubernetes (control plane, `etcd`, `kubelet`), mientras que CoreDNS/kube-dns es técnicamente un *add-on* desplegado como Deployment normal dentro del cluster, con múltiples implementaciones y configuraciones posibles (Corefile personalizado, plugins de terceros), lo que hace impráctico definir un control universal automatizable.
2. Un `ClusterRole` con permisos de escritura sobre `Services` o `Endpoints` va contra el principio de mínimo privilegio: CoreDNS solo necesita *leer* esos recursos para resolver nombres DNS internos. Si ese `ClusterRole` es más permisivo de lo necesario y la ServiceAccount de CoreDNS (o su pod) se ve comprometida, un atacante podría usar esos permisos para manipular el `Service` discovery del cluster, por ejemplo redirigiendo tráfico interno.

**Ejercicio 7**
1. Porque permite demostrar, con evidencia objetiva y con timestamp, el estado de cumplimiento antes y después de una intervención — algo que suelen pedir auditorías de seguridad o certificaciones de compliance, y que además sirve como respaldo si una remediación necesita revertirse o revisarse más adelante.
2. Porque forzar un `FAIL` automático en un control que depende de contexto organizacional generaría falsos positivos sistemáticos: la herramienta no tiene forma de saber si, por ejemplo, la retención de audit logs configurada cumple o no la política interna de la empresa. Ese tipo de control necesita el criterio de la persona que audita, no una regla binaria.

</details>