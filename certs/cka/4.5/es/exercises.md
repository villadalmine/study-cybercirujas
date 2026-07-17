# Ejercicios guiados — Tema 4.5: Use Helm and Kustomize to install cluster components

> Fuente de referencia: CNCF, *CKA Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf

Requisitos previos: un cluster funcional con acceso vía `kubectl`, y el binario `helm` (v3) instalado. `kustomize` no requiere instalación aparte: está integrado en `kubectl` mediante la flag `-k`.

---

## Ejercicio 1 — Instalar un componente del cluster con Helm

1. Verificá la versión de Helm instalada:
   ```bash
   helm version --short
   ```
2. Agregá el repositorio del chart `ingress-nginx`:
   ```bash
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   ```
3. Actualizá el índice local de repos:
   ```bash
   helm repo update
   ```
4. Buscá el chart en el repo agregado:
   ```bash
   helm search repo ingress-nginx
   ```
5. Creá un namespace dedicado para el componente:
   ```bash
   kubectl create namespace ingress-nginx
   ```
6. Instalá el chart, dándole un nombre de release:
   ```bash
   helm install ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx
   ```
7. Verificá que el release quedó registrado y sus recursos están corriendo:
   ```bash
   helm list --namespace ingress-nginx
   kubectl get pods --namespace ingress-nginx
   ```

**Preguntas de comprobación:**

1. ¿Qué diferencia hay entre `helm repo add` y `helm install`? ¿Por qué ambos pasos son necesarios?
2. Si corrés `helm install` sin haber creado el namespace `ingress-nginx` de antemano, ¿qué pasa?
3. `helm list` solo muestra releases del namespace indicado por default. ¿Qué flag usarías para ver releases de todos los namespaces?

---

## Ejercicio 2 — Personalizar valores de un chart

1. Inspeccioná los valores por defecto del chart antes de instalarlo:
   ```bash
   helm show values ingress-nginx/ingress-nginx | less
   ```
2. Creá un archivo `values-custom.yaml` que sobrescriba la cantidad de réplicas y el tipo de Service:
   ```yaml
   controller:
     replicaCount: 2
     service:
       type: ClusterIP
   ```
3. Aplicá esos valores sobre el release existente con un upgrade:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     -f values-custom.yaml
   ```
4. Sobrescribí además un único valor puntual desde la línea de comandos, sin tocar el archivo:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     -f values-custom.yaml \
     --set controller.replicaCount=3
   ```
5. Revisá el historial de revisiones del release:
   ```bash
   helm history ingress-nginx --namespace ingress-nginx
   ```

**Preguntas de comprobación:**

1. En el paso 4, combinaste `-f` y `--set`. ¿Cuál de los dos tiene precedencia si definen el mismo valor?
2. ¿Qué comando usarías para ver, sin aplicar nada, el manifiesto YAML final que Helm generaría con `values-custom.yaml`?
3. ¿Por qué cada `helm upgrade` genera una nueva entrada en `helm history` en vez de sobrescribir la anterior?

---

## Ejercicio 3 — Rollback y desinstalación

1. Simulá un upgrade problemático, apuntando a un tag de imagen que no existe:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     --set controller.image.tag=no-existe-este-tag
   ```
2. Confirmá que los pods quedan en estado de error (`ImagePullBackOff` o similar):
   ```bash
   kubectl get pods --namespace ingress-nginx
   ```
3. Volvé a la revisión anterior conocida como buena:
   ```bash
   helm rollback ingress-nginx --namespace ingress-nginx
   ```
4. Verificá que los pods vuelven a estado `Running`:
   ```bash
   kubectl get pods --namespace ingress-nginx
   ```
5. Desinstalá el release por completo:
   ```bash
   helm uninstall ingress-nginx --namespace ingress-nginx
   ```
6. Confirmá que Helm ya no lista el release, pero repetí el comando con `--keep-history` en una segunda prueba (si tuvieras otro release) para comparar el comportamiento:
   ```bash
   helm list --namespace ingress-nginx --all
   ```

**Preguntas de comprobación:**

1. `helm rollback ingress-nginx` sin número de revisión, ¿a qué revisión vuelve?
2. ¿`helm uninstall` elimina también el namespace `ingress-nginx`? Justificá.
3. ¿Qué hace la flag `--keep-history` de `helm uninstall`, y para qué serviría conservarla?

---

## Ejercicio 4 — Kustomize: estructura base + overlays

1. Creá la siguiente estructura de directorios:
   ```
   app/
     base/
       deployment.yaml
       service.yaml
       kustomization.yaml
     overlays/
       dev/
         kustomization.yaml
       prod/
         kustomization.yaml
   ```
2. En `base/deployment.yaml`, definí un Deployment simple de una sola réplica (imagen `nginx:1.25`, 1 contenedor, puerto 80).
3. En `base/service.yaml`, definí un Service `ClusterIP` que apunte a ese Deployment.
4. En `base/kustomization.yaml`, listá ambos manifiestos como `resources`:
   ```yaml
   resources:
     - deployment.yaml
     - service.yaml
   ```
5. En `overlays/prod/kustomization.yaml`, referenciá la base y agregá un patch que suba las réplicas a 3:
   ```yaml
   resources:
     - ../../base
   patches:
     - target:
         kind: Deployment
         name: nginx
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 3
   ```
6. Generá el manifiesto final para `dev` (sin patch de réplicas, usa la base tal cual) y revisá la salida:
   ```bash
   kustomize build app/overlays/dev
   ```
7. Generá el manifiesto final para `prod` y compará la cantidad de réplicas contra `dev`:
   ```bash
   kustomize build app/overlays/prod
   ```
8. Aplicá el overlay de `prod` directamente al cluster:
   ```bash
   kubectl apply -k app/overlays/prod
   ```

**Preguntas de comprobación:**

1. ¿Qué comando de `kubectl` invoca a Kustomize internamente sin necesitar el binario `kustomize` por separado?
2. `overlays/dev/kustomization.yaml` solo tiene `resources: [../../base]`, sin patches. ¿Qué manifiesto genera `kustomize build` en ese caso?
3. El patch del paso 5 usa formato JSON 6902 (`op`/`path`/`value`). ¿Qué otra forma soporta Kustomize para expresar el mismo cambio de forma declarativa (strategic merge)?

---

## Ejercicio 5 — Generators y transformers de Kustomize

1. Agregá un `configMapGenerator` en `overlays/prod/kustomization.yaml` que genere una ConfigMap con un literal:
   ```yaml
   configMapGenerator:
     - name: app-config
       literals:
         - LOG_LEVEL=info
   ```
2. Agregá un `secretGenerator` con un literal sensible:
   ```yaml
   secretGenerator:
     - name: app-secret
       literals:
         - API_KEY=cambia-este-valor
   ```
3. Generá el manifiesto y observá el nombre real que Kustomize le asignó a la ConfigMap y al Secret:
   ```bash
   kustomize build app/overlays/prod | grep -E "name: app-config|name: app-secret"
   ```
4. Agregá `commonLabels` y `namePrefix` al mismo `kustomization.yaml`:
   ```yaml
   namePrefix: prod-
   commonLabels:
     env: prod
   ```
5. Cambiá el tag de la imagen del Deployment sin tocar `base/deployment.yaml`, usando el transformer `images`:
   ```yaml
   images:
     - name: nginx
       newTag: "1.27"
   ```
6. Volvé a correr `kustomize build app/overlays/prod` y confirmá los tres cambios (nombre generado con hash, prefijo, label y tag de imagen).

**Preguntas de comprobación:**

1. ¿Por qué el nombre de la ConfigMap generada no es literalmente `app-config`, sino algo como `app-config-<hash>`?
2. Si un Deployment referencia `app-config` como `envFrom` y volvés a correr `kustomize build` luego de cambiar el literal `LOG_LEVEL`, ¿qué efecto tiene el cambio de hash sobre un rollout ya aplicado?
3. ¿Qué ventaja tiene usar el transformer `images` en el overlay en vez de editar directamente la imagen en `base/deployment.yaml`?

---

## Ejercicio 6 — Combinar Helm y Kustomize

1. Renderizá el chart de `ingress-nginx` a manifiestos estáticos sin instalarlo, usando los valores custom del Ejercicio 2:
   ```bash
   helm template ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     -f values-custom.yaml \
     --output-dir rendered/
   ```
2. Creá un `kustomization.yaml` en un directorio nuevo que use la salida renderizada como `resources` y agregue un `commonAnnotations`:
   ```yaml
   resources:
     - rendered/ingress-nginx/templates
   commonAnnotations:
     managed-by: kustomize-over-helm
   ```
3. Generá el resultado combinado:
   ```bash
   kustomize build .
   ```
4. Como alternativa al flujo manual anterior, Helm soporta post-renderers: creá un script ejecutable `kustomize-postrender.sh` que reciba el YAML de Helm por stdin, lo escriba como recurso de un `kustomization.yaml` temporal, y corra `kustomize build` sobre él.
5. Instalá (o actualizá) el release pasando ese script como post-renderer:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     -f values-custom.yaml \
     --post-renderer ./kustomize-postrender.sh
   ```

**Preguntas de comprobación:**

1. ¿Cuál es la diferencia práctica entre el flujo del paso 1-3 (render manual + `kustomize build`) y el flujo del paso 4-5 (`--post-renderer`)?
2. En el flujo con `--post-renderer`, ¿Helm sigue teniendo el control del ciclo de vida del release (`helm upgrade`, `helm rollback`, `helm uninstall`)?
3. ¿Por qué tendría sentido usar Kustomize sobre la salida de un chart de Helm en vez de simplemente editar `values.yaml` para lograr el mismo cambio?

---

<details>
<summary>Ver respuestas</summary>

### Ejercicio 1

1. `helm repo add` registra la ubicación del repositorio de charts (el índice remoto) en la configuración local de Helm; no descarga ni instala nada. `helm install` toma un chart de un repo ya agregado (o local) y lo despliega en el cluster como un release. Sin el `repo add` previo, Helm no sabría dónde buscar el chart `ingress-nginx/ingress-nginx`.
2. Falla: Helm no crea el namespace automáticamente salvo que se agregue la flag `--create-namespace`. Sin ella, el comando devuelve un error porque el namespace `ingress-nginx` no existe.
3. `helm list --all-namespaces` (o `-A`).

### Ejercicio 2

1. `--set` tiene precedencia sobre `-f`: los valores pasados por línea de comandos se aplican después (y sobrescriben) los definidos en archivos `-f`, sin importar el orden en que aparezcan los flags.
2. `helm template ingress-nginx ingress-nginx/ingress-nginx -f values-custom.yaml` (o `helm upgrade ... --dry-run --debug`), que renderiza los manifiestos sin aplicarlos al cluster.
3. Porque Helm versiona cada cambio de estado del release como una revisión inmutable, lo que permite hacer rollback a cualquier punto anterior; sobrescribir perdería esa trazabilidad.

### Ejercicio 3

1. Vuelve a la revisión inmediatamente anterior a la actual (la penúltima revisión aplicada).
2. No. `helm uninstall` elimina los recursos que administra el release (Deployments, Services, etc.) pero no el namespace, salvo que ese namespace haya sido creado como parte del chart mismo (no es el caso acá, se creó manualmente con `kubectl create namespace`).
3. `--keep-history` conserva los registros de revisiones del release (Secrets internos de Helm) después de desinstalarlo, permitiendo auditar el historial o, en versiones que lo soporten, reinstalar con contexto previo, aunque los recursos del cluster ya no existan.

### Ejercicio 4

1. `kubectl apply -k <directorio>` (kustomize está embebido en `kubectl` desde la v1.14).
2. Genera el Deployment y el Service tal como están definidos en `base/`, sin ninguna modificación, porque el overlay `dev` no declara patches ni transformers adicionales.
3. El campo `patches` con `patch` en formato *strategic merge* (un fragmento YAML parcial del recurso, en vez de operaciones JSON 6902), o el campo legado `patchesStrategicMerge`.

### Ejercicio 5

1. Kustomize calcula un hash del contenido de la ConfigMap/Secret y lo agrega como sufijo al nombre para que cada cambio de contenido genere un nombre distinto.
2. Como el nombre generado cambia junto con el hash, cualquier recurso que referencie ese nombre (Kustomize actualiza automáticamente esas referencias en Deployments que usan `configMapRef`/`envFrom`) fuerza un nuevo rollout, porque el Deployment queda apuntando a un objeto distinto — es el mecanismo estándar de Kustomize para disparar actualizaciones cuando cambia la config.
3. Permite cambiar la imagen por ambiente (dev/prod) sin duplicar ni modificar el manifiesto base, manteniendo la base como fuente única de verdad y dejando la personalización aislada en el overlay.

### Ejercicio 6

1. El flujo manual (`helm template` + `kustomize build`) separa completamente el renderizado de Helm de la aplicación al cluster: el resultado se aplica con `kubectl apply -f`, fuera del control de releases de Helm. El flujo con `--post-renderer` intercala Kustomize dentro del propio ciclo `helm install`/`upgrade`, así que el resultado parcheado queda registrado como parte del release de Helm.
2. Sí. Aunque el manifiesto final pasó por Kustomize, Helm sigue trackeando el release completo (incluyendo el YAML ya parcheado) en su historial, por lo que `helm rollback` y `helm uninstall` siguen funcionando normalmente.
3. Porque hay cambios que `values.yaml` del chart no expone (por ejemplo, agregar una annotation o un label que el autor del chart no parametrizó). Kustomize permite aplicar ese tipo de ajustes estructurales sin necesitar forkear o modificar el chart original.

</details>
