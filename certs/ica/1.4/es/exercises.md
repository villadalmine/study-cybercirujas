# Ejercicios guiados — Tema 1.4: Upgrading Istio (Canary, In-Place)

> **Objetivo de aprendizaje.** Al terminar estos ejercicios vas a poder ejecutar los dos flujos de actualización que soporta oficialmente Istio —*canary* (con revisions y revision tags) e *in-place*— entendiendo qué toca cada uno del control plane y del data plane, cómo verificar que la migración realmente ocurrió proxy por proxy, y cómo hacer rollback sin cortar tráfico.
>
> **Prerrequisitos.** Un cluster Kubernetes con Istio ya instalado (asumimos una base **1.23.0** instalada con el profile `default`), `kubectl` y `istioctl` en el `PATH`, y una app de ejemplo (`bookinfo`) desplegada. Trabajamos la ruta de upgrade soportada **1.23 → 1.24** (Istio solo soporta saltar **una** minor version por vez).
>
> **Fuente base del temario:** ICA Curriculum — <https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf>
> **Documentación oficial de referencia usada en cada paso:**
> - Canary upgrades — <https://istio.io/latest/docs/setup/upgrade/canary/>
> - In-place upgrades — <https://istio.io/latest/docs/setup/upgrade/in-place/>
> - Overview de upgrades — <https://istio.io/latest/docs/setup/upgrade/>
> - Revisions y revision tags — <https://istio.io/latest/docs/setup/upgrade/canary/#stable-revision-labels>
> - Referencia `istioctl` — <https://istio.io/latest/docs/reference/commands/istioctl/>

---

## Ejercicio 0 — Fotografía del punto de partida

Antes de tocar nada, todo upgrade empieza por saber exactamente qué versión corre en el **control plane** y qué versión corre en cada **proxy del data plane**. Son dos números distintos y esa distinción es el corazón de todo el tema.

**Pasos:**

1. Verificá la versión del cliente `istioctl` y del control plane/data plane instalados:

   ```bash
   istioctl version
   ```

   Salida esperada (base 1.23.0):

   ```
   client version: 1.23.0
   control plane version: 1.23.0
   data plane version: 1.23.0 (14 proxies)
   ```

2. Mirá cómo está instalado el control plane y qué **revision** tiene (fijate en la label `istio.io/rev`):

   ```bash
   kubectl get pods -n istio-system -l app=istiod --show-labels
   ```

   Salida esperada:

   ```
   NAME                      READY   STATUS    RESTARTS   AGE   LABELS
   istiod-7c9b8d6f5b-2xk4p   1/1     Running   0          9d    app=istiod,istio.io/rev=default,...
   ```

3. Verificá qué namespaces están habilitados para injection y con qué mecanismo:

   ```bash
   kubectl get namespace -L istio-injection -L istio.io/rev
   ```

   Salida esperada:

   ```
   NAME            STATUS   AGE   ISTIO-INJECTION   ISTIO.IO/REV
   default         Active   9d
   istio-system    Active   9d
   bookinfo        Active   9d    enabled
   ```

4. Registrá el estado de sincronización de todos los proxies (esta es tu línea base para comparar después del upgrade):

   ```bash
   istioctl proxy-status
   ```

   Salida esperada (resumida):

   ```
   NAME                                    CLUSTER   CDS   LDS   EDS   RDS   ECDS   ISTIOD                    VERSION
   productpage-v1-...bookinfo               Kubernetes SYNCED SYNCED SYNCED SYNCED IGNORED istiod-7c9b8d6f5b-2xk4p  1.23.0
   reviews-v1-...bookinfo                   Kubernetes SYNCED SYNCED SYNCED SYNCED IGNORED istiod-7c9b8d6f5b-2xk4p  1.23.0
   ...
   ```

**Preguntas de comprensión (bloque 0):**

- **0.a** — ¿Qué significa exactamente que `istioctl version` muestre `control plane version` y `data plane version` como dos líneas separadas? ¿Cuándo pueden diferir legítimamente?
- **0.b** — El namespace `bookinfo` usa la label `istio-injection=enabled`, no `istio.io/rev`. ¿A qué control plane se le pide el sidecar cuando esa es la única label presente?
- **0.c** — ¿Por qué guardar la salida de `istioctl proxy-status` *antes* de empezar es un paso de seguridad y no burocracia?

---

## Ejercicio 1 — Precheck: nunca actualices a ciegas

Los dos flujos (canary e in-place) empiezan igual: descargar el `istioctl` de la versión destino y correr el analizador de compatibilidad. Un precheck que falla es una parada dura, no una advertencia opcional.

**Pasos:**

1. Descargá el binario de la versión destino en un directorio aislado (no pises tu `istioctl` actual todavía):

   ```bash
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.0 sh -
   cd istio-1.24.0
   export PATH="$PWD/bin:$PATH"
   ```

2. Confirmá que ahora el **cliente** es 1.24.0 pero el control plane sigue en 1.23.0:

   ```bash
   istioctl version
   ```

   Salida esperada:

   ```
   client version: 1.24.0
   control plane version: 1.23.0
   data plane version: 1.23.0 (14 proxies)
   ```

3. Corré el precheck contra el cluster:

   ```bash
   istioctl x precheck
   ```

   Salida esperada en un cluster sano:

   ```
   ✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
   ```

4. (Opcional pero recomendado en producción) Analizá la configuración existente en busca de recursos deprecados que la nueva versión podría rechazar:

   ```bash
   istioctl analyze --all-namespaces
   ```

**Preguntas de comprensión (bloque 1):**

- **1.a** — ¿Por qué el flujo recomienda descargar el `istioctl` nuevo *sin* pisar el viejo hasta después del precheck?
- **1.b** — Intentás actualizar de 1.22 directo a 1.24. ¿Qué te va a decir Istio y por qué existe esa restricción de una minor por vez?
- **1.c** — ¿Qué clase de problema detecta `istioctl x precheck` que `istioctl version` jamás mostraría?

---

## Ejercicio 2 — Canary upgrade: instalar un segundo control plane con `--revision`

La idea del canary upgrade es que el control plane viejo y el nuevo **coexisten**. Instalás 1.24 con una *revision*, lo que crea un `istiod` paralelo sin tocar el existente. Ningún workload cambia todavía.

**Pasos:**

1. Instalá el nuevo control plane con una revision derivada de la versión (usá guiones, no puntos: `istio.io/rev` es una label y los puntos no son válidos):

   ```bash
   istioctl install --set revision=1-24-0 -y
   ```

   Salida esperada:

   ```
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Installation complete
   ```

2. Verificá que ahora hay **dos** deployments de `istiod`, cada uno con su revision:

   ```bash
   kubectl get pods -n istio-system -l app=istiod --show-labels
   ```

   Salida esperada:

   ```
   NAME                            READY   STATUS    RESTARTS   AGE   LABELS
   istiod-7c9b8d6f5b-2xk4p         1/1     Running   0          9d    ...istio.io/rev=default...
   istiod-1-24-0-8f6c7d9a4-lpz2m   1/1     Running   0          40s   ...istio.io/rev=1-24-0...
   ```

3. Listá las revisions que el cluster conoce ahora:

   ```bash
   istioctl x revision list
   ```

   Salida esperada:

   ```
   REVISION   TAG   ISTIOD                    IN USE   K8S GATEWAYS
   default          istiod                    yes      ...
   1-24-0           istiod-1-24-0             no       ...
   ```

4. Confirmá que **ningún proxy migró todavía** — el data plane sigue enteramente en 1.23.0:

   ```bash
   istioctl version
   ```

   Salida esperada:

   ```
   client version: 1.24.0
   control plane version: 1.23.0, 1.24.0
   data plane version: 1.23.0 (14 proxies)
   ```

**Preguntas de comprensión (bloque 2):**

- **2.a** — Después del paso 1, ¿cuántos control planes hay corriendo y cuántos proxies apuntan al nuevo? Justificá con la salida del paso 4.
- **2.b** — ¿Por qué la revision se escribe `1-24-0` y no `1.24.0`?
- **2.c** — En la salida de `istioctl x revision list`, la revision `1-24-0` figura `IN USE = no`. ¿Qué tendría que pasar para que cambie a `yes`?

---

## Ejercicio 3 — Migrar el data plane: relabelar el namespace y reiniciar workloads

Instalar el control plane nuevo no mueve nada. La migración del data plane es un acto **explícito**: cambiás la label del namespace a la nueva revision y reiniciás los pods para que reinyecten el sidecar nuevo. Como es un rolling restart, podés hacerlo namespace por namespace.

**Pasos:**

1. Reemplazá la label de injection del namespace `bookinfo` para apuntar a la revision nueva. Ojo: `istio-injection=enabled` y `istio.io/rev` son mutuamente excluyentes, así que hay que **sacar la vieja**:

   ```bash
   kubectl label namespace bookinfo istio-injection- istio.io/rev=1-24-0 --overwrite
   ```

2. Confirmá el estado de las labels del namespace:

   ```bash
   kubectl get namespace bookinfo -L istio-injection -L istio.io/rev
   ```

   Salida esperada:

   ```
   NAME       STATUS   AGE   ISTIO-INJECTION   ISTIO.IO/REV
   bookinfo   Active   9d                      1-24-0
   ```

3. **Nada cambió aún en los pods vivos** — el relabel solo afecta a pods *nuevos*. Forzá la reinyección con un rolling restart:

   ```bash
   kubectl rollout restart deployment -n bookinfo
   ```

4. Esperá a que termine el rollout:

   ```bash
   kubectl rollout status deployment/productpage-v1 -n bookinfo
   ```

5. Verificá que los proxies de `bookinfo` ahora están gestionados por el `istiod` de la revision 1-24-0:

   ```bash
   istioctl proxy-status
   ```

   Salida esperada (fijate en la columna ISTIOD y VERSION):

   ```
   NAME                          ...   ISTIOD                          VERSION
   productpage-v1-...bookinfo     ...   istiod-1-24-0-8f6c7d9a4-lpz2m   1.24.0
   reviews-v1-...bookinfo         ...   istiod-1-24-0-8f6c7d9a4-lpz2m   1.24.0
   ...
   ```

6. Confirmá la migración parcial a nivel versión:

   ```bash
   istioctl version
   ```

   Salida esperada (data plane mixto):

   ```
   client version: 1.24.0
   control plane version: 1.23.0, 1.24.0
   data plane version: 1.23.0 (8 proxies), 1.24.0 (6 proxies)
   ```

**Preguntas de comprensión (bloque 3):**

- **3.a** — Si te olvidás del paso 3 (`rollout restart`) pero ya relabelaste el namespace, ¿qué versión de sidecar corren los pods de `bookinfo`? ¿Por qué?
- **3.b** — ¿Por qué el comando del paso 1 incluye `istio-injection-` (con el guión final) además de setear `istio.io/rev`? ¿Qué pasa si dejás las dos labels puestas?
- **3.c** — La salida del paso 6 muestra `data plane version: 1.23.0 (8 proxies), 1.24.0 (6 proxies)`. Explicá qué representa cada grupo y por qué este estado mixto es seguro/esperable durante un canary.

---

## Ejercicio 4 — Revision tags: desacoplar los namespaces de la revision concreta

El problema del Ejercicio 3 es que cada upgrade te obliga a relabelar **todos** los namespaces. Los *revision tags* resuelven esto: son un alias estable (típicamente `default`) que apunta a una revision. Los namespaces usan la label del tag y en el próximo upgrade solo movés el tag, sin tocar namespaces.

**Pasos:**

1. Creá (o reapuntá) el tag `default` hacia la nueva revision:

   ```bash
   istioctl tag set default --revision 1-24-0 --overwrite -y
   ```

   Salida esperada:

   ```
   Revision tag "default" created, referencing control plane revision "1-24-0".
   To enable injection using this revision tag, use 'istio.io/rev=default' instead of 'istio-injection=enabled'
   ```

2. Listá los tags para confirmar el mapeo:

   ```bash
   istioctl tag list
   ```

   Salida esperada:

   ```
   TAG       REVISION   NAMESPACES
   default   1-24-0     bookinfo
   ```

3. Ahora un namespace etiquetado `istio.io/rev=default` (o el histórico `istio-injection=enabled`, que Istio mapea al tag `default`) usa 1-24-0 sin nombrarlo. Reetiquetá `bookinfo` para usar el tag estable en vez de la revision cruda:

   ```bash
   kubectl label namespace bookinfo istio.io/rev=default --overwrite
   ```

4. Reiniciá para que la reinyección tome el tag (aunque hoy apunte a la misma revision, esto valida el flujo):

   ```bash
   kubectl rollout restart deployment -n bookinfo
   ```

5. Verificá que el webhook de injection asociado al tag existe:

   ```bash
   kubectl get mutatingwebhookconfiguration -l istio.io/tag=default
   ```

   Salida esperada:

   ```
   NAME                                       WEBHOOKS   AGE
   istio-revision-tag-default                 2          30s
   ```

**Preguntas de comprensión (bloque 4):**

- **4.a** — Explicá con tus palabras la diferencia entre una *revision* (`1-24-0`) y un *revision tag* (`default`). ¿Cuál cambia en cada upgrade y cuál queda fijo?
- **4.b** — Con el tag `default → 1-24-0` en su lugar, describí en qué se simplifica el próximo upgrade a 1.25 respecto de lo que hiciste en el Ejercicio 3.
- **4.c** — Un namespace tiene `istio-injection=enabled` (label histórica) en un cluster donde definiste el tag `default`. ¿De qué control plane recibe el sidecar y por qué?

---

## Ejercicio 5 — Completar el canary: desinstalar el control plane viejo

Una vez que **todos** los workloads migraron y validaste la app, el control plane 1.23.0 sobra. Recién ahí se desinstala.

**Pasos:**

1. Confirmá que ya no queda ningún proxy hablando con la revision `default`/1.23.0 vieja. Este chequeo es la puerta de salida del canary:

   ```bash
   istioctl proxy-status | grep -v 1.24.0
   ```

   Salida esperada (solo el header, ninguna fila de proxy 1.23):

   ```
   NAME   CLUSTER   CDS   LDS   EDS   RDS   ECDS   ISTIOD   VERSION
   ```

2. Desinstalá específicamente el control plane de la revision vieja (la que instalaste originalmente con el profile default, sin revision explícita):

   ```bash
   istioctl uninstall --revision default -y
   ```

   > Nota: si tu instalación base de 1.23 no tenía revision explícita, se la referencia como revision `default`. Si la habías instalado con `revision=1-23-0`, usá ese valor.

3. Verificá que solo queda un `istiod`:

   ```bash
   kubectl get pods -n istio-system -l app=istiod
   ```

   Salida esperada:

   ```
   NAME                            READY   STATUS    RESTARTS   AGE
   istiod-1-24-0-8f6c7d9a4-lpz2m   1/1     Running   0          25m
   ```

4. Confirmá la convergencia total de versiones:

   ```bash
   istioctl version
   ```

   Salida esperada:

   ```
   client version: 1.24.0
   control plane version: 1.24.0
   data plane version: 1.24.0 (14 proxies)
   ```

**Preguntas de comprensión (bloque 5):**

- **5.a** — ¿Por qué el paso 1 (verificar que ningún proxy sigue en 1.23) es un requisito *duro* antes de desinstalar? ¿Qué le pasa a un proxy cuyo control plane desaparece?
- **5.b** — ¿Qué diferencia hay entre `istioctl uninstall --revision default` y `istioctl uninstall --purge`? ¿Cuándo NO querés `--purge`?
- **5.c** — Un sidecar Envoy ya sincronizado sigue proxyeando tráfico un rato aunque su `istiod` no esté disponible. ¿Qué propiedad de Envoy explica esto y por qué igual no es una situación en la que quieras quedarte?

---

## Ejercicio 6 — In-place upgrade: reemplazar el control plane sin revisions

El in-place upgrade es el flujo simple: corrés `istioctl upgrade` (o `istioctl install` de la versión nueva **con la misma revision/sin revision**) y el control plane existente se reemplaza. Es más rápido y usa menos recursos, pero no hay coexistencia: el rollback es reinstalar la versión anterior, y la migración del data plane sigue necesitando un restart.

> Para este ejercicio partí de nuevo de una base **1.23.0 in-place** (sin revisions), simulando un cluster que nunca adoptó canary.

**Pasos:**

1. Con el `istioctl` 1.24.0 en el `PATH` y el precheck ya pasado (Ejercicio 1), aplicá el upgrade in-place:

   ```bash
   istioctl upgrade -y
   ```

   Salida esperada (te confirma versiones origen/destino):

   ```
   This will install the Istio 1.24.0 profile "default" into the cluster. Proceed? (y/N)
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Ingress gateways installed
   ✔ Installation complete
   ```

2. Verificá que el control plane ya es 1.24.0 pero el **data plane todavía no**:

   ```bash
   istioctl version
   ```

   Salida esperada:

   ```
   client version: 1.24.0
   control plane version: 1.24.0
   data plane version: 1.23.0 (14 proxies)
   ```

3. Este es el punto clave del in-place: los sidecars viejos siguen corriendo contra un control plane nuevo (skew de una versión, soportado, pero transitorio). Migrá el data plane reiniciando los workloads namespace por namespace:

   ```bash
   kubectl rollout restart deployment -n bookinfo
   ```

4. Confirmá la convergencia:

   ```bash
   istioctl version
   ```

   Salida esperada:

   ```
   client version: 1.24.0
   control plane version: 1.24.0
   data plane version: 1.24.0 (14 proxies)
   ```

**Preguntas de comprensión (bloque 6):**

- **6.a** — Enumerá **tres** diferencias concretas entre el canary upgrade (Ej. 2–5) y el in-place upgrade (Ej. 6) en términos de recursos, granularidad de migración y facilidad de rollback.
- **6.b** — Tras el paso 1 del in-place, hay un control plane 1.24 sirviendo a proxies 1.23. ¿Qué garantiza Istio sobre este *version skew* y qué límite tiene?
- **6.c** — ¿Por qué incluso el in-place upgrade necesita un `rollout restart`? ¿Qué componente del data plane no se actualiza solo?

---

## Ejercicio 7 — Rollback en ambos modelos

Un upgrade que no sabés deshacer no es un upgrade, es una apuesta. Practicá el rollback de los dos flujos.

**Pasos (rollback de canary):**

1. Suponé que después del Ejercicio 3 (`bookinfo` migrado a `1-24-0`, control plane viejo **todavía presente**) detectás un problema. Reapuntá el namespace a la revision vieja:

   ```bash
   kubectl label namespace bookinfo istio.io/rev=default --overwrite
   ```

   (o `istio.io/rev=1-23-0` según cómo esté nombrada tu revision vieja)

2. Reiniciá para reinyectar el sidecar 1.23:

   ```bash
   kubectl rollout restart deployment -n bookinfo
   ```

3. Verificá que los proxies volvieron a 1.23.0:

   ```bash
   istioctl proxy-status | grep bookinfo
   ```

**Pasos (rollback de in-place):**

4. En el modelo in-place no hay control plane viejo al que volver: el rollback es **reinstalar** la versión anterior. Con el `istioctl` 1.23.0:

   ```bash
   # (con istio-1.23.0/bin en el PATH)
   istioctl upgrade -y
   ```

5. Reiniciá los workloads para bajar los sidecars a 1.23.0:

   ```bash
   kubectl rollout restart deployment -n bookinfo
   ```

**Preguntas de comprensión (bloque 7):**

- **7.a** — El rollback del canary es prácticamente instantáneo mientras que el del in-place implica reinstalar. ¿Por qué? ¿Qué característica del canary lo hace posible?
- **7.b** — ¿Por qué es una **mala idea** desinstalar el control plane viejo (Ejercicio 5) antes de haber validado la aplicación bajo la revision nueva?
- **7.c** — En un rollback de canary, ¿alcanza con reetiquetar el namespace, o también hace falta el `rollout restart`? Justificá con lo aprendido en el Ejercicio 3.

---

## Respuestas

<details>
<summary>Mostrar respuestas y explicaciones</summary>

### Bloque 0

- **0.a** — `control plane version` es la versión de los pods `istiod`; `data plane version` es la versión de los binarios de Envoy (`istio-proxy`) inyectados como sidecars. Difieren *legítimamente y por diseño* durante cualquier upgrade: primero se actualiza el control plane y los proxies recién toman la versión nueva cuando se reinicia el pod del workload. Istio soporta un skew de hasta **una minor version** entre control plane y data plane, que es exactamente la ventana en la que viven estos números distintos.

- **0.b** — La label histórica `istio-injection=enabled` mapea al control plane **sin revision** (o, si hay revision tags, al tag `default`). Es el mecanismo de injection "clásico"; el sidecar-injector default es el que atiende ese webhook. `istio.io/rev=<x>` es el mecanismo moderno que apunta a una revision concreta y es el que habilita canary upgrades.

- **0.c** — Porque `proxy-status` es tu inventario de "qué proxy habla con qué istiod y en qué versión está". Después del upgrade lo volvés a correr y comparás: cualquier proxy que quedó `STALE`, `NOT SENT`, o que no migró de versión salta a la vista. Sin la línea base no podés distinguir un proxy problemático de uno que "siempre estuvo así".

### Bloque 1

- **1.a** — Porque si el precheck falla, querés seguir teniendo tu `istioctl` viejo funcional para operar el cluster en su estado actual (analizar, hacer rollback, describir recursos). Pisar el binario antes de validar te deja operando la versión vieja con herramientas nuevas si algo sale mal. Aislarlo en `istio-1.24.0/bin` y anteponerlo al `PATH` es reversible con solo cerrar la shell.

- **1.b** — Istio **no soporta saltar minor versions**: solo se actualiza una minor por vez (1.22 → 1.23 → 1.24). El precheck/upgrade te lo va a rechazar. La razón es la garantía de compatibilidad: Istio solo prueba y soporta un skew de una minor entre versiones consecutivas (APIs de configuración, protocolo xDS entre istiod y Envoy, y compatibilidad del data plane). Saltar dos rompe esa garantía.

- **1.c** — `istioctl x precheck` valida condiciones del *cluster y de la configuración*: versión de Kubernetes soportada por la nueva Istio, CRDs/webhooks en conflicto, permisos RBAC, recursos deprecados que la versión destino ya no acepta. `istioctl version` solo te dice qué corre hoy, nunca si el upgrade es viable.

### Bloque 2

- **2.a** — Hay **dos** control planes (`istiod` default/1.23.0 e `istiod-1-24-0`) y **cero** proxies apuntando al nuevo. Lo prueba `data plane version: 1.23.0 (14 proxies)`: los 14 proxies siguen en 1.23.0. Instalar una revision nueva es una operación puramente aditiva sobre el control plane; el data plane no se entera hasta que relabelás y reiniciás.

- **2.b** — Porque el valor de la revision se usa como valor de la label de Kubernetes `istio.io/rev`, y los puntos (`.`) no son caracteres válidos en un *label value* de Kubernetes (solo alfanuméricos, `-`, `_`, `.` internos con restricciones… en la práctica Istio impone guiones). Por convención se transforma `1.24.0` → `1-24-0`.

- **2.c** — La revision pasa a `IN USE = yes` cuando al menos un namespace la referencia (vía `istio.io/rev=1-24-0` o vía un tag que la apunte) **y** hay pods con sidecars efectivamente gestionados por ese istiod. Es decir, recién después de la migración del data plane del Ejercicio 3.

### Bloque 3

- **3.a** — Siguen corriendo el sidecar **1.23.0**. El relabel del namespace solo cambia qué inyecta el webhook a partir de ese momento; los pods vivos no se reinyectan solos. El sidecar se elige en el momento de la creación del pod (admission), así que sin restart no hay pod nuevo y sin pod nuevo no hay reinyección.

- **3.b** — `istio-injection` y `istio.io/rev` son excluyentes: si dejás las dos, el comportamiento es ambiguo/roto y el injector puede no inyectar (Istio prioriza y puede terminar sin injection efectiva, o comportarse de forma indefinida entre versiones). Por eso el comando borra `istio-injection` (`istio-injection-`) en el mismo `kubectl label` en que setea `istio.io/rev`. Regla: **una sola** label de injection por namespace.

- **3.c** — `1.23.0 (8 proxies)` son los sidecars aún gestionados por el control plane viejo (namespaces no migrados todavía); `1.24.0 (6 proxies)` son los de `bookinfo`, ya reiniciados contra el istiod nuevo. Es seguro porque ambos control planes coexisten y cada uno programa correctamente a *sus* proxies; el skew entre planes es de una minor, dentro de lo soportado. Este estado mixto es precisamente lo que hace "canario" al upgrade: migrás y validás por partes.

### Bloque 4

- **4.a** — Una *revision* es el identificador inmutable de una instalación concreta del control plane (`1-24-0` = "el istiod de la versión 1.24.0"). Un *revision tag* es un alias mutable (típicamente `default`) que **apunta** a una revision. Los namespaces se etiquetan con el tag; el tag es lo que movés en cada upgrade, la revision queda fija atada a su versión.

- **4.b** — Con tags, el upgrade a 1.25 es: instalar `revision=1-25-0`, reiniciar workloads *canary* de prueba, y cuando estás conforme, `istioctl tag set default --revision 1-25-0 --overwrite` + `rollout restart`. **No tocás ninguna label de namespace**: todos los que apuntan al tag `default` migran al mover un solo puntero. En el Ejercicio 3, en cambio, tuviste que relabelar cada namespace uno por uno.

- **4.c** — Del control plane al que apunta el tag `default` (en este punto, `1-24-0`). Istio trata la label histórica `istio-injection=enabled` como equivalente al tag `default` mediante el `MutatingWebhookConfiguration` `istio-revision-tag-default`. Por eso los tags también dan una ruta de migración transparente a los namespaces "viejos".

### Bloque 5

- **5.a** — Porque un proxy cuyo control plane desaparece deja de recibir actualizaciones de configuración (xDS): endpoints nuevos, cambios de routing, certificados rotados. Sigue proxyeando con su última config conocida, pero queda "congelado" y, cuando su cert expire o cambie la topología, empieza a fallar. Desinstalar con proxies todavía enganchados al viejo istiod los deja huérfanos.

- **5.b** — `--revision default` desinstala **solo** ese control plane, dejando intactos los demás (el `1-24-0`) y los CRDs/recursos compartidos. `--purge` borra **toda** la instalación de Istio del cluster, incluidos CRDs y recursos cluster-wide compartidos por todas las revisions. Durante un canary **nunca** querés `--purge`: te llevaría puesto también el control plane nuevo.

- **5.c** — Envoy funciona con un modelo de configuración *eventualmente consistente* y cachea la última config válida recibida por xDS; si el control plane cae, sigue enrutando con esa config ("fail static"/graceful degradation). No querés quedarte ahí porque perdés rotación de certificados, descubrimiento de endpoints y toda propagación de cambios: es un estado de supervivencia, no operativo.

### Bloque 6

- **6.a** — (1) **Recursos:** el canary corre dos control planes en paralelo (más CPU/memoria en `istio-system`); el in-place mantiene uno solo. (2) **Granularidad de migración:** el canary migra namespace por namespace y permite convivencia prolongada de versiones en el data plane; el in-place cambia el único control plane de golpe y todos los proxies quedan en skew hasta que los reinicies. (3) **Rollback:** en canary es reetiquetar+restart (el control plane viejo sigue ahí); en in-place hay que reinstalar la versión anterior.

- **6.b** — Istio garantiza compatibilidad con un *version skew* de **una** minor version entre control plane y data plane (control plane 1.24 sirviendo proxies 1.23 está soportado). El límite es justamente esa minor: por eso hay que migrar el data plane con `rollout restart` antes del próximo upgrade, para no acumular dos minors de diferencia.

- **6.c** — Porque el sidecar Envoy se inyecta en el pod en el momento de su creación y su binario/versión queda fijado ahí. Actualizar `istiod` no reemplaza los contenedores `istio-proxy` de los pods ya corriendo. El único componente que se actualiza "solo" es el control plane; el data plane (los sidecars) requiere recrear los pods, y eso lo hace el `rollout restart`.

### Bloque 7

- **7.a** — Porque en el canary el control plane viejo **nunca se fue** (mientras no lo desinstalaste en el Ej. 5): el rollback es reapuntar el namespace a la revision vieja y reiniciar. En in-place reemplazaste el único control plane, así que "volver" implica reinstalar la versión anterior del control plane y luego reiniciar el data plane. La coexistencia de control planes es lo que hace el rollback del canary casi instantáneo.

- **7.b** — Porque una vez desinstalado el control plane viejo perdés la ruta de rollback barata del canary: ya no hay revision anterior a la que reapuntar. Si el problema aparece después de desinstalar, el rollback se vuelve un in-place inverso (reinstalar la versión vieja), más lento y disruptivo. La regla es: **validar bajo la revision nueva → recién entonces desinstalar la vieja.**

- **7.c** — No alcanza con reetiquetar: hace falta el `rollout restart`. Igual que en la migración hacia adelante (Ej. 3), la label solo determina qué se inyecta a *pods nuevos*; los pods vivos conservan el sidecar que tenían. Sin restart, el rollback de la label no baja de versión a ningún proxy ya corriendo.

</details>