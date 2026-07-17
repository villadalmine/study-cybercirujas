# Ejercicios guiados: Kustomize (CKAD 5.4)

**Fuentes de referencia:**
- CNCF, *CKAD Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes docs, *Declarative Management of Kubernetes Objects Using Kustomize* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/

Requisitos: `kubectl` >= 1.14 (Kustomize viene integrado) y acceso a un cluster (minikube, kind, etc.).

---

## Ejercicio 1: kustomization.yaml básico con `resources`

1. Creá la estructura de trabajo:
   ```bash
   mkdir -p ~/kustomize-demo/base && cd ~/kustomize-demo/base
   ```
2. Creá `deployment.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: nginx
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: nginx
     template:
       metadata:
         labels:
           app: nginx
       spec:
         containers:
           - name: nginx
             image: nginx:1.25
             ports:
               - containerPort: 80
   ```
3. Creá `service.yaml`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: nginx
   spec:
     selector:
       app: nginx
     ports:
       - port: 80
         targetPort: 80
   ```
4. Creá `kustomization.yaml` referenciando ambos archivos:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   ```
5. Renderizá el manifest sin aplicarlo:
   ```bash
   kubectl kustomize .
   ```
6. Aplicalo al cluster:
   ```bash
   kubectl apply -k .
   ```

**Preguntas de comprensión:**
- ¿Qué diferencia hay entre `kubectl apply -k .` y `kubectl apply -f .`?
- ¿Qué hace `kubectl kustomize .` y por qué conviene correrlo antes de un `apply -k`?

---

## Ejercicio 2: `commonLabels`, `commonAnnotations`, `namePrefix`/`nameSuffix`

1. Agregá estos campos al `kustomization.yaml` del `base`:
   ```yaml
   namePrefix: dev-
   nameSuffix: "-v1"
   commonLabels:
     env: dev
   commonAnnotations:
     managed-by: kustomize
   ```
2. Volvé a renderizar:
   ```bash
   kubectl kustomize .
   ```
3. Observá que el `Deployment` y el `Service` ahora se llaman `dev-nginx-v1`, y que `env: dev` aparece tanto en `metadata.labels` como en `spec.selector.matchLabels` (Deployment) y `spec.selector` (Service).

**Preguntas de comprensión:**
- ¿Por qué `commonLabels` modifica también los `selectors`, y no solo `metadata.labels`?
- Si este `Deployment` ya estuviera corriendo en el cluster, ¿qué problema podría causar aplicar `commonLabels` sobre él? (pensá en qué campos de un Deployment son inmutables).

---

## Ejercicio 3: `configMapGenerator` y el hash de nombre

1. Volvé al directorio `base` y creá `app.properties`:
   ```bash
   cat > app.properties <<EOF
   GREETING=hello
   LOG_LEVEL=info
   EOF
   ```
2. Agregá el generator en `kustomization.yaml`:
   ```yaml
   configMapGenerator:
     - name: app-config
       files:
         - app.properties
   ```
3. Referenciá el ConfigMap desde el Deployment agregando en el container:
   ```yaml
           envFrom:
             - configMapRef:
                 name: app-config
   ```
4. Renderizá y observá el nombre generado:
   ```bash
   kubectl kustomize . | grep -A2 "kind: ConfigMap"
   ```
   Vas a ver algo como `name: app-config-9m9df2b8k5`, y que el `envFrom` del Deployment también quedó apuntando a ese mismo nombre con hash.
5. Agregá `disableNameSuffixHash: true` al generator y volvé a renderizar para comparar.

**Preguntas de comprensión:**
- ¿Para qué sirve el sufijo hash que Kustomize agrega al nombre del ConfigMap generado?
- ¿Qué ventaja se pierde si usás `disableNameSuffixHash: true` en un flujo de CI/CD?

---

## Ejercicio 4: overlays (`base` + `overlays/dev` + `overlays/prod`)

1. Desde `~/kustomize-demo`, creá los overlays:
   ```bash
   mkdir -p overlays/dev overlays/prod
   ```
2. Creá `overlays/dev/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../base
   patches:
     - target:
         kind: Deployment
         name: nginx
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 1
   ```
3. Creá `overlays/prod/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../base
   patchesStrategicMerge:
     - patch-resources.yaml
   ```
4. Creá `overlays/prod/patch-resources.yaml` (strategic merge patch):
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: nginx
   spec:
     replicas: 5
     template:
       spec:
         containers:
           - name: nginx
             resources:
               limits:
                 cpu: "500m"
                 memory: "256Mi"
   ```
5. Compará ambos entornos:
   ```bash
   kubectl kustomize overlays/dev
   kubectl kustomize overlays/prod
   ```

**Preguntas de comprensión:**
- ¿Qué ventaja tiene mantener un `base` común con overlays por entorno, en vez de duplicar los manifests completos para dev y prod?
- Un strategic merge patch (como `patch-resources.yaml`) fusiona campos por nombre de container (`name: nginx`) en vez de por índice de array. ¿Por qué eso es más seguro que referenciar `containers/0`?

---

## Ejercicio 5: patch JSON 6902 para cambiar la imagen en prod

1. En `overlays/prod`, creá `patch-image.yaml`:
   ```yaml
   - op: replace
     path: /spec/template/spec/containers/0/image
     value: nginx:1.27
   ```
2. Agregalo a `overlays/prod/kustomization.yaml` bajo `patches`:
   ```yaml
   patches:
     - target:
         kind: Deployment
         name: nginx
       path: patch-image.yaml
   ```
3. Renderizá de nuevo y confirmá que solo prod usa `nginx:1.27` mientras `base` sigue en `nginx:1.25`:
   ```bash
   kubectl kustomize overlays/prod | grep image:
   kubectl kustomize overlays/dev | grep image:
   ```

**Preguntas de comprensión:**
- ¿Cuándo conviene usar un patch JSON 6902 (`op`/`path`/`value`) en lugar de un strategic merge patch?
- ¿Qué pasaría si el `path` del patch JSON 6902 apuntara a un índice de array que no existe en el recurso `target`?

---

## Ejercicio 6: transformers `images` y `replicas`

1. En `overlays/prod/kustomization.yaml`, quitá el patch JSON 6902 del ejercicio anterior y reemplazalo por el transformer `images`:
   ```yaml
   images:
     - name: nginx
       newTag: "1.27"
   ```
2. Reemplazá también el `patchesStrategicMerge` de réplicas por el transformer `replicas`:
   ```yaml
   replicas:
     - name: nginx
       count: 5
   ```
3. Renderizá y confirmá que el resultado es equivalente al de los ejercicios 4 y 5:
   ```bash
   kubectl kustomize overlays/prod
   ```
4. Aplicá el overlay de prod al cluster y verificá los Pods:
   ```bash
   kubectl apply -k overlays/prod
   kubectl get deploy,pods -l env=dev
   ```
5. Limpiá los recursos:
   ```bash
   kubectl delete -k overlays/prod
   ```

**Preguntas de comprensión:**
- ¿Qué ventaja tienen los transformers dedicados (`images`, `replicas`) frente a escribir un patch a mano para el mismo cambio?
- En el examen, si necesitás cambiar solamente el tag de una imagen en un overlay, ¿qué mecanismo de Kustomize es el más directo?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
- `kubectl apply -k .` primero ejecuta el pipeline de Kustomize (lee `kustomization.yaml`, aplica generators/transformers/patches) y genera el manifest final antes de enviarlo al API server; `kubectl apply -f .` aplica los archivos YAML tal cual están, sin ningún procesamiento de Kustomize.
- `kubectl kustomize .` solo renderiza y muestra por stdout el YAML resultante, sin tocar el cluster. Sirve para revisar el resultado (y detectar errores de sintaxis o de merge) antes de aplicarlo.

**Ejercicio 2**
- Kustomize aplica `commonLabels` de forma consistente a todos los campos relacionados con labels de un recurso, incluyendo `selector.matchLabels` del Deployment y `spec.selector` del Service, precisamente para que el selector y las labels del template nunca queden desincronizados (si solo tocara `metadata.labels`, el Deployment dejaría de encontrar sus propios Pods).
- `spec.selector.matchLabels` de un Deployment es **inmutable** una vez creado. Si el Deployment ya existe en el cluster y el patch de `commonLabels` cambia el selector, `kubectl apply` va a fallar con un error de campo inmutable; hay que borrar y recrear el Deployment (o evitar cambiar el selector después del primer deploy).

**Ejercicio 3**
- El hash sufijo asegura que cada vez que cambia el contenido del ConfigMap (por ejemplo `app.properties`), se genera un nombre distinto. Esto obliga a que los Pods que lo referencian se recreen (rolling update), evitando el problema clásico de que un ConfigMap se actualice pero los Pods sigan usando el valor viejo en memoria/volumen montado.
- Con `disableNameSuffixHash: true` se pierde ese disparador automático de rollout: si cambiás el ConfigMap pero el nombre no cambia, los Pods existentes no se reinician solos y pueden seguir corriendo con la configuración vieja hasta que algo más fuerce un rollout.

**Ejercicio 4**
- Mantener un `base` único evita duplicar YAML por entorno (menos drift, un solo lugar para corregir bugs de manifest) y los overlays solo describen las *diferencias* (réplicas, límites de recursos, imagen), lo que hace explícito qué cambia entre dev y prod.
- Un strategic merge patch fusiona por clave semántica (`name: nginx` dentro de la lista de containers), así que si el orden de los containers cambia en el `base`, el patch sigue apuntando al container correcto. Un patch por índice (`containers/0`) se rompería silenciosamente si alguien reordena o agrega containers antes de esa posición.

**Ejercicio 5**
- Un patch JSON 6902 conviene cuando el campo a modificar es un valor puntual y simple (un string, un número) y querés una operación explícita (`replace`, `add`, `remove`) sin depender de cómo Kustomize decida fusionar objetos completos; también es la única opción si necesitás `remove` un campo, algo que un strategic merge patch no puede expresar.
- Si el `path` apunta a un índice de array inexistente, Kustomize falla al renderizar (`kubectl kustomize` devuelve error), porque la operación `replace` requiere que el path ya exista en el documento.

**Ejercicio 6**
- Los transformers dedicados son declarativos y no requieren conocer la ruta exacta (`path`) dentro del recurso: alcanza con decir "cambiá el tag de la imagen `nginx`" o "poné 5 réplicas al Deployment `nginx`", y Kustomize localiza el campo correcto. Esto es menos frágil ante cambios de estructura del manifest base y más legible que un patch JSON 6902 equivalente.
- El mecanismo más directo para cambiar solo el tag de una imagen en un overlay es el transformer `images` (`images: - name: ... newTag: ...`), no un patch.

</details>