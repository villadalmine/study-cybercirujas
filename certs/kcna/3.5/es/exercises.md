# Tema 3.5: Security — Ejercicios guiados (KCNA)

> Fuente de referencia: [KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf) (CNCF). El contenido de este material es original y desarrollado a partir de esa fuente, no una transcripción de la misma.

Estos ejercicios asumen que tenés acceso a un cluster de Kubernetes (`kind`, `minikube` o similar) con `kubectl` configurado contra ese cluster.

---

## Ejercicio 1 — El modelo 4C's de cloud native security

El modelo 4C's organiza la seguridad en capas concéntricas: **Cloud** (infraestructura), **Cluster** (Kubernetes), **Container** (imagen y runtime) y **Code** (tu aplicación). Cada capa depende de que las capas que la rodean estén aseguradas.

1. Anotá en una hoja las cuatro capas del modelo 4C's, de la más externa a la más interna.
2. Para cada una de las siguientes prácticas, indicá a qué capa pertenece principalmente:
   - Habilitar RBAC en el API server.
   - Escanear una imagen en busca de CVEs antes de publicarla en el registry.
   - Restringir el acceso de red al proveedor cloud (security groups / firewall).
   - Validar y sanitizar los inputs de un endpoint HTTP en tu aplicación.
   - Usar `NetworkPolicy` para aislar el tráfico entre namespaces.
3. Escribí una frase que explique por qué asegurar solo el Code sin asegurar el Cluster no alcanza (pensá en qué pasaría si alguien obtiene acceso directo al API server).

**Preguntas de verificación:**
- ¿En qué orden, de afuera hacia adentro, se ubican las cuatro capas del modelo 4C's?
- ¿Por qué se dice que la seguridad de cada capa "hereda" la responsabilidad de las capas exteriores?

---

## Ejercicio 2 — RBAC: crear un usuario con permisos limitados

Vas a crear un `ServiceAccount` que solo pueda leer Pods en un namespace, y vas a verificar sus permisos con `kubectl auth can-i`.

1. Creá un namespace de prueba:
   ```
   kubectl create namespace security-lab
   ```
2. Creá un `ServiceAccount` llamado `pod-reader-sa`:
   ```
   kubectl create serviceaccount pod-reader-sa -n security-lab
   ```
3. Creá un archivo `role.yaml` con un `Role` que solo permita `get` y `list` sobre `pods`:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: security-lab
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list"]
   ```
   Aplicalo:
   ```
   kubectl apply -f role.yaml
   ```
4. Creá el `RoleBinding` que une el `ServiceAccount` con el `Role`:
   ```
   kubectl create rolebinding pod-reader-binding \
     --role=pod-reader \
     --serviceaccount=security-lab:pod-reader-sa \
     -n security-lab
   ```
5. Verificá los permisos usando `kubectl auth can-i` impersonando al `ServiceAccount`:
   ```
   kubectl auth can-i list pods \
     --as=system:serviceaccount:security-lab:pod-reader-sa \
     -n security-lab

   kubectl auth can-i delete pods \
     --as=system:serviceaccount:security-lab:pod-reader-sa \
     -n security-lab
   ```

**Preguntas de verificación:**
- ¿Qué devolvió cada uno de los dos comandos `kubectl auth can-i` del paso 5, y por qué difieren?
- ¿Qué diferencia hay entre un `Role` y un `ClusterRole`? ¿Cuál usarías si necesitaras dar permisos sobre `nodes` (un recurso sin namespace)?
- Si en vez de un `RoleBinding` hubieras creado un `ClusterRoleBinding` apuntando al mismo `Role`, ¿qué cambiaría?

---

## Ejercicio 3 — Pod Security Admission (Pod Security Standards)

Kubernetes define tres niveles de Pod Security Standards: `privileged`, `baseline` y `restricted`. Pod Security Admission los aplica mediante labels en el namespace.

1. Etiquetá el namespace `security-lab` para forzar (`enforce`) el nivel `restricted`:
   ```
   kubectl label namespace security-lab \
     pod-security.kubernetes.io/enforce=restricted
   ```
2. Intentá crear un Pod privilegiado (`privileged.yaml`):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: privileged-pod
     namespace: security-lab
   spec:
     containers:
     - name: app
       image: nginx
       securityContext:
         privileged: true
   ```
   ```
   kubectl apply -f privileged.yaml
   ```
3. Observá el mensaje de rechazo del admission controller.
4. Corregí el manifiesto para que cumpla el nivel `restricted` (`compliant.yaml`):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: compliant-pod
     namespace: security-lab
   spec:
     containers:
     - name: app
       image: nginx
       securityContext:
         runAsNonRoot: true
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
         seccompProfile:
           type: RuntimeDefault
   ```
   ```
   kubectl apply -f compliant.yaml
   ```

**Preguntas de verificación:**
- ¿Qué campo específico de `privileged.yaml` provocó el rechazo en el paso 3?
- Nombrá al menos tres requisitos que un Pod debe cumplir para pasar el nivel `restricted` (mirá los campos usados en `compliant.yaml`).
- ¿Qué diferencia hay entre los modos `enforce`, `audit` y `warn` de Pod Security Admission?

---

## Ejercicio 4 — Aislar tráfico entre Pods con NetworkPolicy

Por defecto, en Kubernetes todos los Pods pueden comunicarse entre sí sin restricciones. Vas a crear una `NetworkPolicy` que cambie ese comportamiento.

1. Creá dos Pods de prueba en `security-lab`:
   ```
   kubectl run frontend --image=busybox -n security-lab --labels=role=frontend -- sleep 3600
   kubectl run backend --image=busybox -n security-lab --labels=role=backend -- sleep 3600
   ```
2. Verificá que `frontend` puede alcanzar a `backend` (deberías ver un timeout o respuesta, no un rechazo inmediato):
   ```
   kubectl exec -n security-lab frontend -- wget -qO- --timeout=2 backend
   ```
3. Aplicá una `NetworkPolicy` (`deny-backend.yaml`) que solo permita tráfico entrante a `backend` desde Pods con label `role=frontend`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-only
     namespace: security-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             role: frontend
   ```
   ```
   kubectl apply -f deny-backend.yaml
   ```
4. Creá un tercer Pod sin el label `frontend` e intentá el mismo acceso:
   ```
   kubectl run intruder --image=busybox -n security-lab -- sleep 3600
   kubectl exec -n security-lab intruder -- wget -qO- --timeout=2 backend
   ```

**Preguntas de verificación:**
- ¿Por qué el paso 4 se comporta distinto al paso 2, si ambos son solicitudes al mismo Pod `backend`?
- Una `NetworkPolicy` con `podSelector: {}` y sin reglas de `ingress` ¿qué efecto tiene sobre el tráfico entrante al namespace?
- ¿Qué necesita tener instalado el cluster para que las `NetworkPolicy` realmente se apliquen?

---

## Ejercicio 5 — Secrets: qué protegen y qué no

Los `Secret` de Kubernetes no están encriptados por defecto: solo están codificados en base64.

1. Creá un Secret con una credencial ficticia:
   ```
   kubectl create secret generic db-creds \
     --from-literal=username=admin \
     --from-literal=password=SuperSecreto123 \
     -n security-lab
   ```
2. Obtené el Secret en formato YAML y observá el campo `data`:
   ```
   kubectl get secret db-creds -n security-lab -o yaml
   ```
3. Decodificá manualmente el valor de `password` para confirmar que es reversible:
   ```
   echo "<valor-copiado-de-data.password>" | base64 -d
   ```
4. Montá el Secret como variables de entorno en un Pod (`secret-pod.yaml`):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: secret-consumer
     namespace: security-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sleep", "3600"]
       envFrom:
       - secretRef:
           name: db-creds
   ```
   ```
   kubectl apply -f secret-pod.yaml
   kubectl exec -n security-lab secret-consumer -- env | grep -i password
   ```

**Preguntas de verificación:**
- ¿Por qué el paso 3 demuestra que un Secret **no** equivale a "encriptado"?
- Mencioná al menos una medida adicional (fuera del propio objeto `Secret`) para proteger credenciales sensibles en un cluster (pensá en encryption at rest, un external secrets manager, o restricciones de RBAC sobre el recurso `secrets`).
- ¿Qué riesgo tiene exponer un Secret como variable de entorno en comparación con montarlo como volumen?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
- Orden de afuera hacia adentro: **Cloud → Cluster → Container → Code**.
- Clasificación:
  - RBAC en el API server → **Cluster**.
  - Escaneo de imágenes por CVEs → **Container**.
  - Firewall/security groups del proveedor → **Cloud**.
  - Validar inputs de un endpoint HTTP → **Code**.
  - `NetworkPolicy` entre namespaces → **Cluster**.
- Si el Cluster no está asegurado (por ejemplo, el API server es accesible sin autenticación), un atacante puede crear, modificar o eliminar cualquier recurso —incluyendo tu aplicación— sin que la seguridad del Code importe en absoluto. Cada capa protege el perímetro de la capa que envuelve; una brecha en una capa exterior anula las protecciones de las interiores.

**Ejercicio 2**
- `kubectl auth can-i list pods ...` devuelve `yes` (el `Role` lo permite explícitamente). `kubectl auth can-i delete pods ...` devuelve `no`, porque el `Role` solo otorga los verbos `get` y `list`, y RBAC deniega todo lo que no está explícitamente permitido (modelo *deny by default*).
- Un `Role` aplica solo dentro de un namespace y solo puede otorgar permisos sobre recursos de ese namespace. Un `ClusterRole` aplica a nivel de cluster y es obligatorio para recursos sin namespace, como `nodes`, `persistentvolumes` o `namespaces` mismos.
- Un `ClusterRoleBinding` habría otorgado esos mismos permisos (`get`/`list` de pods) en **todos** los namespaces del cluster, no solo en `security-lab` — un alcance mucho más amplio del que se pretendía.

**Ejercicio 3**
- El campo `securityContext.privileged: true` es el que provoca el rechazo: el nivel `restricted` prohíbe explícitamente contenedores privilegiados.
- Requisitos visibles en `compliant.yaml` (cualquiera de estos tres, entre otros): `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` (y también se exige un `seccompProfile` definido).
- `enforce` rechaza la creación/actualización de Pods que violen el estándar; `audit` permite la operación pero registra una entrada en el audit log; `warn` permite la operación pero devuelve una advertencia visible al usuario. Los tres modos pueden combinarse y aplicarse a distintos niveles simultáneamente.

**Ejercicio 4**
- En el paso 2 no existe ninguna `NetworkPolicy` en el namespace, así que el comportamiento por defecto de Kubernetes (todo el tráfico permitido) aplica y `frontend` alcanza a `backend`. En el paso 4 ya existe una `NetworkPolicy` que selecciona a `backend` y solo permite ingress desde Pods con label `role=frontend`; como `intruder` no tiene ese label, su tráfico es bloqueado.
- Un `podSelector: {}` selecciona **todos** los Pods del namespace. Si no se listan reglas de `ingress`, el efecto es "deny all ingress" para esos Pods — se convierte en una política de negación total.
- El cluster necesita un **CNI plugin que soporte NetworkPolicy** (por ejemplo Calico, Cilium o Weave Net). Si el CNI no lo soporta (como el `kindnet` por defecto de `kind` sin configuración adicional), el objeto `NetworkPolicy` se crea pero no tiene ningún efecto real.

**Ejercicio 5**
- Porque `base64` es una codificación reversible sin ninguna clave secreta: cualquiera con acceso de lectura al objeto `Secret` (o al etcd subyacente sin encryption at rest) puede recuperar el valor original en texto plano con un simple `base64 -d`. No hay cifrado criptográfico involucrado.
- Medidas adicionales: habilitar **encryption at rest** para Secrets en etcd, usar un **external secrets manager** (Vault, AWS Secrets Manager, etc.) integrado vía External Secrets Operator, y restringir con RBAC quién puede hacer `get`/`list` sobre el recurso `secrets`.
- Las variables de entorno quedan expuestas más fácilmente: aparecen en `kubectl exec ... env`, en logs de crash dumps, y pueden heredarse por procesos hijos del contenedor. Montar el Secret como volumen (archivo) reduce esa superficie, ya que el valor solo es accesible leyendo el archivo específico, y algunos mecanismos permiten rotarlo sin reiniciar el Pod.

</details>