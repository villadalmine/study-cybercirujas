# Cloud Provider and Infrastructure Security (KCSA — Topic 1.2)

> **Dominio:** Overview of Cloud Native Security · **Peso en el examen:** 2.33
> **Formato:** Labs prácticos y guiados. Ejecutá cada paso numerado, luego respondé las preguntas de checkpoint antes de continuar. Las respuestas consolidadas están en la sección colapsable al final.

Este tema se ubica en los anillos de **Cloud** y **Cluster** del modelo *4C* (**C**loud → **C**luster → **C**ontainer → **C**ode). El principio rector es la defensa en profundidad (defense-in-depth): cada anillo exterior es el límite de confianza (trust boundary) para el anillo interior. Un Pod protegido (hardened) en un node cuyo rol de IAM en la cloud es sobreprivilegiado, o cuyo Instance Metadata Service es alcanzable desde los workloads, no es seguro — el anillo exterior tiene fugas.

Referencias oficiales utilizadas a lo largo de este documento:
- CNCF KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes — Overview of Cloud Native Security (4C) — https://kubernetes.io/docs/concepts/security/overview/
- Kubernetes — Securing a Cluster — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/

**Prerrequisitos del lab:** un cluster propio (kubeadm en una VM, `kind`, o un cluster de EKS/GKE descartable), `kubectl` con cluster-admin y — para los Ejercicios 3 y 4 — acceso SSH/root en un node de control-plane. Nunca ejecutes los pasos ofensivos contra infraestructura que no sea de tu propiedad.

---

## Exercise 1 — The Instance Metadata Service (IMDS) as a credential-theft vector

El compromiso de infraestructura cloud-native más común es un Server-Side Request Forgery (SSRF) o un Pod comprometido que alcanza el **link-local metadata endpoint** `169.254.169.254` del node y roba las credenciales de cloud IAM del node. Esas credenciales a menudo contienen el *instance profile* del node — frecuentemente mucho más amplio de lo que cualquier workload debería tener.

### Steps

1. Inspeccioná qué expone el metadata endpoint desde el *interior* de un workload. En AWS (IMDSv1, el modo inseguro de solicitud única):

   ```bash
   kubectl run imds-probe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/'
   ```

   Output esperado — el nombre del rol de instance-profile adjunto al node:

   ```
   eks-node-instance-role
   ```

2. Ahora obtené las credenciales reales para ese rol:

   ```bash
   kubectl run imds-probe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-instance-role'
   ```

   Output esperado (credenciales temporales de STS que el atacante ahora puede exportar y usar):

   ```json
   {
     "Code": "Success",
     "AccessKeyId": "ASIA...EXAMPLE",
     "SecretAccessKey": "wJalr...EXAMPLE",
     "Token": "IQoJb3...EXAMPLE",
     "Expiration": "2026-08-06T18:44:12Z"
   }
   ```

3. Contrastá con **IMDSv2**, el cual requiere un PUT orientado a sesión para obtener un token antes de cualquier GET, y aplica un TTL. Un SSRF puro (que por lo general solo puede emitir un GET) queda neutralizado:

   ```bash
   # This fails on IMDSv2 — GET without a token is rejected with 401
   curl -s http://169.254.169.254/latest/meta-data/   # -> 401 Unauthorized

   # IMDSv2 flow: PUT to mint a token, then GET with the token header
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/
   ```

**Checkpoint**
- **Q1.** ¿Por qué un instance profile de *node* sobreprivilegiado convierte un solo Pod comprometido en un compromiso de toda la cuenta?
- **Q2.** IMDSv2 requiere un `PUT` antes de cualquier `GET`. ¿Por qué este requisito neutraliza la mayoría de los exploits de SSRF pero *no* un Pod totalmente comprometido con acceso a shell?

### Steps (mitigation)

4. En AWS, forzá IMDSv2 **y** configurá el response hop limit en `1`. Los paquetes desde un Pod cruzan un salto de red adicional (el bridge/veth del node), por lo que un hop limit de 1 hace que el metadata endpoint sea inalcanzable desde los network namespaces del Pod, mientras que el propio node (hop 0) sigue funcionando:

   ```bash
   aws ec2 modify-instance-metadata-options \
     --instance-id i-0abc123def456 \
     --http-tokens required \
     --http-put-response-hop-limit 1 \
     --http-endpoint enabled
   ```

5. Agregá una `NetworkPolicy` de respaldo (belt-and-suspenders) que bloquee el egress hacia el rango link-local desde los namespaces de aplicación. **Esto solo tiene efecto con un CNI que aplique políticas (Calico, Cilium); el `kubenet`/AWS-VPC-CNI predeterminado sin add-on de políticas lo ignorará silenciosamente.**

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-imds-egress
     namespace: apps
   spec:
     podSelector: {}          # every Pod in the namespace
     policyTypes:
       - Egress
     egress:
       - to:
           - ipBlock:
               cidr: 0.0.0.0/0
               except:
                 - 169.254.169.254/32   # AWS/GCP/Azure IMDS
                 - 169.254.170.2/32     # AWS ECS task-metadata / IRSA agent
   ```

   Aplicá y verificá el bloqueo:

   ```bash
   kubectl apply -f deny-imds-egress.yaml
   kubectl run imds-probe -n apps --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s --max-time 5 http://169.254.169.254/latest/meta-data/ || echo BLOCKED'
   ```

   Output esperado una vez que la aplicación esté activa:

   ```
   BLOCKED
   ```

**Checkpoint**
- **Q3.** ¿Por qué un hop limit de `1` es un control a nivel de infraestructura que funciona *incluso para un CNI que no aplica NetworkPolicy*?
- **Q4.** La NetworkPolicy anterior usa `ipBlock` con un `except`. Nombra una razón por la cual este control por sí solo es insuficiente y debe combinarse con la configuración del lado de la cloud del paso 4.

Referencia — AWS IMDS hardening: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html · Kubernetes NetworkPolicy: https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

## Exercise 2 — Workload Identity: give the Pod its own scoped cloud identity, not the node's

La solución correcta para el Ejercicio 1 no es solo bloquear el IMDS, sino evitar que los workloads *necesiten* en absoluto el rol del node. La identidad de workload federada (**IRSA** en EKS, **Workload Identity** en GKE, **Workload Identity Federation** en AKS) emite a cada ServiceAccount un token proyectado firmado por OIDC y de corta duración, el cual el IAM de la cloud intercambia por credenciales acotadas estrictamente — sin claves estáticas, privilegio mínimo por workload.

### Steps

1. Inspeccioná el token proyectado de ServiceAccount que Kubernetes ya monta. Es un JWT firmado con un audience y una expiración — la materia prima de la federación de identidad de workloads:

   ```bash
   kubectl run tokdump --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token' | \
     cut -d. -f2 | base64 -d 2>/dev/null
   ```

   Claims decodificados esperados (notá el `exp` corto y el audience):

   ```json
   {
     "aud": ["https://kubernetes.default.svc"],
     "exp": 1785000000,
     "iss": "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B",
     "kubernetes.io": { "namespace": "apps", "serviceaccount": { "name": "checkout" } },
     "sub": "system:serviceaccount:apps:checkout"
   }
   ```

2. Vinculá un ServiceAccount a un rol cloud. En EKS, anotá el SA con el ARN del rol de IAM; el mutating admission webhook luego inyecta el token audience correcto y las variables de entorno `AWS_ROLE_ARN`/`AWS_WEB_IDENTITY_TOKEN_FILE`:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: checkout
     namespace: apps
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/checkout-s3-readonly
   ```

3. La **trust policy** del rol de IAM es el límite que fija la credencial exactamente a este SA — notá la condición `sub` que la acota a `apps:checkout`, no a todo el cluster:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::111122223333:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B:sub": "system:serviceaccount:apps:checkout",
           "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B:aud": "sts.amazonaws.com"
         }
       }
     }]
   }
   ```

4. Verificá que el Pod ahora asume el *rol*, no el profile del node:

   ```bash
   kubectl run whoami -n apps --serviceaccount=checkout \
     --image=amazon/aws-cli --rm -it --restart=Never -- sts get-caller-identity
   ```

   Output esperado — el ARN del rol asumido, acotado a `checkout`:

   ```json
   {
     "UserId": "AROA...:botocore-session-1785000000",
     "Account": "111122223333",
     "Arn": "arn:aws:sts::111122223333:assumed-role/checkout-s3-readonly/botocore-session-1785000000"
   }
   ```

**Checkpoint**
- **Q5.** Workload Identity se basa en que el cluster actúe como un **OIDC provider**. ¿A qué dos claims de token se fija la trust policy de cloud IAM, y por qué se requieren *ambos* para evitar que un SA diferente asuma el rol?
- **Q6.** ¿Por qué un token proyectado con un `exp` a unos pocos miles de segundos de distancia es sustancialmente más seguro que una clave de acceso cloud de larga duración almacenada en un Secret de Kubernetes?

Referencia — IRSA: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html · GKE Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity

---

## Exercise 3 — Infrastructure at rest: encrypting etcd

etcd contiene cada Secret, ConfigMap y objeto en el cluster. Por defecto, kube-apiserver escribe Secrets en etcd **sin cifrar** — cualquiera con un snapshot de disco, un backup de etcd o acceso al filesystem de un node del control-plane los lee en texto plano. Este ejercicio lo demuestra y luego lo soluciona.

### Steps

1. Creá un Secret y leelo directamente desde etcd para probar que está en texto plano (ejecutá en un node de control-plane con los certificados de cliente de etcd):

   ```bash
   kubectl create secret generic canary -n default --from-literal=password=Sup3rS3cret

   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/default/canary | hexdump -C | grep -a Sup3r
   ```

   Output esperado — el valor de tu secret, al descubierto:

   ```
   ...  53 75 70 33 72 53 33 63  72 65 74            |Sup3rS3cret|
   ```

2. Creá una `EncryptionConfiguration`. Generá primero una clave de 32 bytes:

   ```bash
   head -c 32 /dev/urandom | base64
   # -> e.g. k7Gg...=  (use YOUR output below)
   ```

   ```yaml
   # /etc/kubernetes/enc/enc.yaml
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources:
         - secrets
       providers:
         - aescbc:                     # or aesgcm (faster, KMS-recommended)
             keys:
               - name: key1
                 secret: k7Gg...=      # your 32-byte base64 key
         - identity: {}                # fallback so existing plaintext still reads
   ```

   > **El orden importa.** El *primer* provider listado se usa para **escribir**; todos los providers listados se prueban en orden para **leer**. Colocar `identity: {}` primero seguiría escribiendo silenciosamente en texto plano.

3. Conéctalo al API server. En kubeadm, editá el manifest del Pod estático — kubelet reinicia el API server automáticamente cuando el manifest cambia:

   ```yaml
   # /etc/kubernetes/manifests/kube-apiserver.yaml (spec.containers[0])
   command:
     - kube-apiserver
     - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
   # ...plus a hostPath volume+mount for /etc/kubernetes/enc
   ```

4. Volvé a cifrar el objeto en reposo — el cifrado es perezoso (lazy); solo las *escrituras* se cifran, así que forzá una reescritura de cada Secret:

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

5. Volvé a ejecutar la lectura de etcd del paso 1. El output esperado ahora muestra el prefijo de la envolvente de cifrado (encryption envelope) en lugar del valor:

   ```
   00000000  2f 72 65 67 ... 6b 38 73 3a 65 6e 63 3a 61 65 73  |...k8s:enc:aes|
   00000010  63 62 63 3a 76 31 3a 6b 65 79 31 3a ...           |cbc:v1:key1:..|
   ```

   `grep -a Sup3r` ahora no debería devolver nada.

**Checkpoint**
- **Q7.** Después del paso 3 pero *antes* del paso 4, ¿están protegidos en disco tus Secrets existentes? Explicá precisamente qué significa "el cifrado en reposo es lazy" para un operador que realiza una auditoría de cumplimiento.
- **Q8.** ¿Cuál es el riesgo operativo del provider `aescbc`/`aesgcm` con una clave `secret:` almacenada localmente, y qué cambia en el modelo de amenazas al pasar a un **KMS provider** (cifrado de envolvente / envelope encryption)?

Referencia — Cifrado de datos confidenciales en reposo: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/

---

## Exercise 4 — Node and control-plane surface: kubelet, ports, and CIS benchmarking

El kubelet es el daemon más sensible del node: su API puede hacer exec dentro de cualquier Pod en el node. Un kubelet mal configurado (autenticación anónima activada, autorización `AlwaysAllow`, puerto de solo lectura abierto) le entrega el node a un atacante. Este ejercicio audita y refuerza esa superficie y luego automatiza la auditoría con el CIS Benchmark.

### Steps

1. Sondeá el **puerto de solo lectura** del kubelet (`10255`, no autenticado por diseño) y el puerto de API autenticado (`10250`) desde un Pod:

   ```bash
   # Read-only port — if this returns data, it is a finding
   kubectl run kprobe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s --max-time 5 http://$NODE_IP:10255/pods | head -c 200'

   # Authenticated port with anonymous auth — should be 401/403 on a hardened node
   kubectl run kprobe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -sk --max-time 5 https://$NODE_IP:10250/pods -o /dev/null -w "%{http_code}\n"'
   ```

   Output esperado en un node **reforzado (hardened)**:

   ```
   # 10255: connection refused (port disabled)
   # 10250: 401
   ```

2. Inspeccioná la configuración en ejecución del kubelet y confirmá los tres ajustes críticos:

   ```bash
   # On the node
   sudo cat /var/lib/kubelet/config.yaml | grep -E 'anonymous|authorization|readOnlyPort' -A2
   ```

   Valores objetivo reforzados:

   ```yaml
   authentication:
     anonymous:
       enabled: false          # no unauthenticated API access
   authorization:
     mode: Webhook             # delegate authz to the API server (RBAC), never AlwaysAllow
   readOnlyPort: 0             # disable the unauthenticated 10255 port
   ```

3. Verificá desde el control plane que el propio API server no acepte solicitudes anónimas a rutas privilegiadas:

   ```bash
   curl -sk https://<apiserver>:6443/api/v1/namespaces/kube-system/secrets \
     -o /dev/null -w "%{http_code}\n"
   ```

   Esperado en un API server reforzado (`--anonymous-auth=false` o `system:anonymous` denegado por RBAC):

   ```
   403
   ```

4. Automatizá toda la auditoría de nodes y control-plane con **kube-bench**, que mapea las comprobaciones directamente con el CIS Kubernetes Benchmark:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
   kubectl logs -l app=kube-bench --tail=-1 | grep -E '\[FAIL\]|\[WARN\]' | head
   ```

   Ejemplo de hallazgos esperados a remediar:

   ```
   [FAIL] 4.2.1 Ensure that the --anonymous-auth argument is set to false
   [FAIL] 4.2.4 Ensure that the --read-only-port argument is set to 0
   [WARN] 1.2.6 Ensure that the --kubelet-certificate-authority argument is set as appropriate
   ```

**Checkpoint**
- **Q9.** Explicá la diferencia práctica entre el puerto de solo lectura `10255` del kubelet y el puerto autenticado `10250`, y por qué `readOnlyPort: 0` es un requisito estricto en lugar de algo deseable.
- **Q10.** kube-bench reporta contra el CIS Benchmark. En un control plane **administrado** (EKS/GKE/AKS), ¿por qué las comprobaciones `1.x` (control-plane/master) en su mayoría no se aplican a vos, y qué grupo de comprobaciones *sí* sigue siendo tu responsabilidad? Vinculá esto con el modelo de responsabilidad compartida.

Referencia — Kubelet authn/authz: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/ · kube-bench / CIS: https://github.com/aquasecurity/kube-bench

---

## Answers

<details>
<summary><strong>Mostrar respuestas (Q1–Q10)</strong></summary>

**Q1.** El instance profile del node se adjunta a nivel de VM y es compartido por *cada* Pod programado allí, porque todos atraviesan el mismo network namespace del host para alcanzar `169.254.169.254`. Los roles de node suelen ser amplios (pull desde ECR, escribir logs en CloudWatch, adjuntar volúmenes EBS, describir/modificar EC2, a veces `iam:PassRole`). Un solo Pod comprometido que lea esas credenciales lo hereda todo: movimiento lateral, escalación de privilegios y, a menudo, la capacidad de alcanzar recursos cloud no relacionados — por lo que el escape de un Pod se convierte en un incidente a nivel de toda la cuenta. La defensa es el privilegio mínimo *por workload* (Ejercicio 2), no por node.

**Q2.** IMDSv2 hace que la obtención de credenciales sea un flujo de dos pasos con estado: un `PUT /latest/api/token` (que también debe llevar el encabezado TTL) para generar un token de sesión, y luego un `GET` que lleva `X-aws-ec2-metadata-token`. Las primitivas de SSRF clásicas (un extractor de URL vulnerable, una librería de procesamiento de imágenes, un redireccionamiento) por lo general solo pueden forzar un `GET` con una URL controlada por el atacante — no pueden emitir el `PUT` requerido con encabezados personalizados, por lo que el flujo se rompe. Sin embargo, un **Pod totalmente comprometido con acceso a shell** puede ejecutar `curl` arbitrario y realizar el handshake completo PUT→GET; IMDSv2 no lo detiene. Es por eso que IMDSv2 debe combinarse con el hop-limit de 1 y/o un bloqueo de egress de NetworkPolicy, y en última instancia con workload identity para que las credenciales no valgan nada.

**Q3.** El servicio de metadatos aplica el hop limit al TTL de IP / conteo de saltos de sus respuestas en la capa de *infraestructura* — es aplicado por la pila de virtualización/red de la cloud, no por Kubernetes o el CNI. Los paquetes de un Pod salen del network namespace del Pod y cruzan un salto adicional (veth → node bridge → host stack) antes de alcanzar el metadata endpoint, por lo que las respuestas limitadas a un solo salto expiran antes de regresar al Pod. Los propios procesos del node (hop 0) no se ven afectados. Como se ubica por debajo de Kubernetes, funciona independientemente de si el CNI aplica NetworkPolicy o no — razón exacta por la cual es el más robusto de los dos controles.

**Q4.** El egress de NetworkPolicy solo se aplica si el CNI instalado implementa políticas (Calico, Cilium, etc.); con un CNI que no las aplique, el API server acepta el objeto pero silenciosamente no hace nada — una falsa sensación de seguridad peligrosa. Además, solo rige el tráfico de la red del Pod, puede ser anulado por un namespace sin la política, y no protege al propio node ni a los Pods con `hostNetwork: true` (que comparten el namespace del node y eluden las reglas de egress a nivel de Pod). La configuración del hop-limit/IMDSv2 del lado de la cloud del paso 4 se aplica por debajo de Kubernetes y cubre esos huecos, por lo que ambos juntos constituyen defensa en profundidad en lugar de un punto único de falla.

**Q5.** Workload Identity se basa en que el cluster actúe como un **OIDC provider**. La trust policy de cloud IAM se fija en el claim **`sub`** de OIDC (`system:serviceaccount:<namespace>:<name>`) y en el claim **`aud`** (`sts.amazonaws.com` para IRSA). `sub` acota el rol asumible a exactamente una ServiceAccount en un namespace, de modo que un SA diferente —incluso uno que también pueda emitir un token proyectado desde el mismo emisor OIDC del cluster— no cumple con la condición `StringEquals`. `aud` garantiza que el token haya sido emitido *específicamente para STS* (a través de la `--audience` inyectada) y no, por ejemplo, que sea el token predeterminado del API server `kubernetes.default.svc` reutilizado en la cloud. Fijar solo `sub` permitiría que un token destinado a otro audience sea reutilizado; fijar solo `aud` permitiría que cualquier SA del cluster asuma el rol. Ambos juntos otorgan el privilegio mínimo por workload.

**Q6.** Un token proyectado es de corta duración (el kubelet lo rota automáticamente, `exp` típicamente ~1 hora o menos), está limitado por audience y nunca se almacena — vive en un montaje `tmpfs` y se intercambia a demanda por credenciales STS igualmente de corta duración. Una clave de acceso cloud de larga duración en un Secret es estática, válida hasta que se rote manualmente, legible por cualquiera con RBAC de `get secrets` (o un snapshot de etcd si el cifrado en reposo está desactivado — ver Ejercicio 3), y frecuentemente se filtra en logs, volcados de entorno o Git. Si un token proyectado se filtra, queda inútil en minutos y solo para un audience; si una clave estática se filtra, es una credencial duradera y de alto valor. Las credenciales de corta duración, acotadas y no persistidas colapsan la ventana de explotación.

**Q7.** No — los Secrets existentes *no* están protegidos inmediatamente. Habilitar `--encryption-provider-config` solo hace que el API server me cifre en la siguiente **escritura** de cada objeto; todo lo que ya esté en etcd permanece en la forma en que se escribió por última vez (texto plano). "El cifrado en reposo es lazy" significa que debés forzar activamente una reescritura de cada recurso afectado (`kubectl get secrets -A -o json | kubectl replace -f -`) antes de poder afirmar que están cifrados. Para una auditoría de cumplimiento esto es crítico: activar la función y ver los nuevos Secrets cifrados *no* prueba que el corpus histórico esté cifrado — debés verificar leyendo objetos antiguos representativos directamente desde etcd y confirmando el prefijo de envolvente `k8s:enc:...`.

**Q8.** Con `aescbc`/`aesgcm`, la clave de cifrado de datos reside en texto plano dentro del archivo `EncryptionConfiguration` en el filesystem del node del control-plane, justo al lado de etcd. Cualquiera que pueda leer ese node (root, un compromiso del control-plane, un backup desprotegido de `/etc/kubernetes`) obtiene tanto el texto cifrado como la clave, por lo que el cifrado solo defiende contra *datos robados de etcd en solitario* (un snapshot de disco aislado o un backup de etcd), no contra un compromiso del node. Un **KMS provider** implementa cifrado de envolvente (envelope encryption): el API server cifra cada objeto con una clave de datos, y esa clave de datos está a su vez envuelta por una clave guardada en un KMS/HSM externo que nunca toca el node. Ahora, comprometer el filesystem del node es insuficiente — el atacante también debe estar autorizado para llamar a `Decrypt` en el KMS, lo cual se registra por separado y es revocable. Esto traslada la raíz de confianza fuera del host y te brinda una custodia de claves auditable y rotable.

**Q9.** El puerto `10255` es el puerto HTTP de **solo lectura** del kubelet: sin TLS, sin autenticación, sin autorización. Expone `/pods`, `/metrics`, `/spec` y más — lo suficiente para que un atacante enumere cada Pod, contenedor, etiqueta de node y a menudo metadatos de entorno en el node sin ninguna credencial. El puerto `10250` es la API HTTPS completa del kubelet y, cuando está reinforced, requiere autenticación de certificado de cliente TLS o token bearer, más autorización de Webhook delegada al RBAC del API server; es lo que legítimamente sirve `exec`, `logs` y `attach`. Debido a que `10255` otorga reconocimiento no autenticado (y históricamente filtraba tokens/entorno), dejarlo abierto es un vector constante de divulgación de información y planificación de ataques sin ninguna necesidad legítima en los clusters modernos — por lo tanto, `readOnlyPort: 0` es obligatorio, no opcional. Las métricas que antes lo justificaban ahora se sirven autenticadas a través de `10250/metrics`.

**Q10.** El grupo `1.x` de kube-bench audita los flags de componentes del master/control-plane (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`) y sus archivos de configuración en disco. En una oferta administrada, el proveedor opera el control plane —no tenés acceso a esos manifests ni hosts— por lo que el modelo de responsabilidad compartida ubica a `1.x` (y el hardening de etcd/control-plane) del lado del *proveedor*; kube-bench los reportará como no aplicables o omitidos. Lo que sigue siendo tu responsabilidad es el grupo **`4.x` de worker-node / kubelet** (flags de kubelet, permisos de archivos, `readOnlyPort`, autenticación anónima) más los grupos de políticas (`5.x` — RBAC, Pod Security, políticas de red), porque sos dueño de los nodes y de los workloads. Esta es la esencia de la responsabilidad compartida: el proveedor asegura el control plane administrado; vos asegurás los nodes, la configuración de los workloads y todo en los anillos de Container y Code.

</details>