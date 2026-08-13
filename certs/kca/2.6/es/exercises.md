# Actualización de Kyverno — Ejercicios Guiados

> **Objetivo de examen 2.6 — Actualización de Kyverno** (peso 3.0). Estos labs asumen un clúster de Kubernetes en ejecución (kind, minikube o un clúster gestionado) con una instalación de Kyverno existente y `kubectl` + `helm` v3 configurados contra él. Los comandos se muestran con salida representativa; tus versiones exactas y los hashes de los pods diferirán. Nada aquí muta producción — ejecutalo contra un clúster descartable.

Las actualizaciones de Kyverno tienen tres propiedades que las hacen diferentes de actualizar una carga de trabajo sin estado, y cada ejercicio de abajo vuelve a una de ellas:

1. **Los CRDs cargan los datos.** Tus objetos `ClusterPolicy`, `Policy`, `PolicyException` y los `PolicyReport` generados viven dentro de CRDs que la actualización reescribe. El manejo nativo de CRDs de Helm y `kubectl apply` tienen ambos aristas filosas acá.
2. **Las versiones menores son escalones, no puntos de paso.** Kyverno prueba y soporta actualizar **una versión menor a la vez**. Saltear versiones menores no está soportado.
3. **No hay downgrade soportado.** Tu plan de rollback es *restaurar desde backup*, no `helm rollback` a un esquema en el que los nuevos datos ya no encajan.

---

## Ejercicio 1 — Establecer una línea base y planificar la ruta de actualización

**Escenario:** el clúster está corriendo Kyverno **v1.11.4** (chart de Helm `3.1.4`) y te pidieron llevarlo a **v1.13.4** (chart `3.3.4`).

**Pasos**

1. Confirmá cómo se instaló Kyverno. Un release gestionado por Helm aparece acá; un resultado vacío significa que se instaló desde manifests crudos:

   ```bash
   helm list -n kyverno
   ```
   ```
   NAME     NAMESPACE  REVISION  UPDATED                  STATUS    CHART          APP VERSION
   kyverno  kyverno    1         2026-06-01 10:14:22 UTC  deployed  kyverno-3.1.4  v1.11.4
   ```

2. Leé la versión de la **aplicación** desde el admission controller en ejecución, no solo desde los metadatos de Helm (pueden divergir si alguien editó el deployment a mano):

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```
   ```
   ghcr.io/kyverno/kyverno:v1.11.4
   ```

3. Enumerá los cuatro controladores introducidos por la división de arquitectura de 1.10, para saber cómo se ve una instalación sana *antes* de tocarla:

   ```bash
   kubectl get pods -n kyverno
   ```
   ```
   NAME                                             READY   STATUS    RESTARTS   AGE
   kyverno-admission-controller-7c9f8d6b4c-abcde    1/1     Running   0          31d
   kyverno-background-controller-6d5f7c8b9d-fghij   1/1     Running   0          31d
   kyverno-cleanup-controller-5b6c7d8e9f-klmno      1/1     Running   0          31d
   kyverno-reports-controller-4a5b6c7d8e-pqrst      1/1     Running   0          31d
   ```

4. Leé las notas de release de **cada** versión menor entre tu versión actual y la de destino — 1.11 → 1.12 → 1.13 — buscando específicamente cambios de esquema de CRD y campos removidos/renombrados:

   ```bash
   # Browse https://github.com/kyverno/kyverno/releases and the migration
   # notes at https://kyverno.io/docs/installation/upgrading/
   ```

5. Anotá la ruta concreta. Estás en `1.11`, el destino es `1.13`, así que el plan son **dos saltos**: `1.11 → 1.12`, luego `1.12 → 1.13`. **No** podés saltar directo a `1.13`.

**Verificación de comprensión**

- **Q1.1** ¿Por qué `helm list -n kyverno` es el primer comando en lugar de revisar el tag de la imagen primero?
- **Q1.2** La salida de `helm list` muestra `CHART kyverno-3.1.4` y `APP VERSION v1.11.4`. ¿Cuál de esos dos números pasás a `--version` en `helm upgrade`, y por qué importa la distinción?
- **Q1.3** Tu destino es `v1.13.4` y estás en `v1.11.4`. Escribí la secuencia exacta de versiones de la aplicación por las que vas a pasar, y enunciá qué regla prohíbe un salto directo `1.11.4 → 1.13.4`.
- **Q1.4** El reports controller muestra `Running`, pero ¿por qué vale la pena capturar un inventario *pre-actualización* de los cuatro controladores en lugar de confiar en que "Kyverno está arriba"?

---

## Ejercicio 2 — Respaldar políticas y recursos personalizados

La actualización reescribe los CRDs. Como el downgrade no está soportado, tu única red de seguridad real es una exportación de los recursos personalizados *antes* de que el esquema cambie bajo ellos.

**Pasos**

1. Exportá los objetos de política — de alcance de clúster y de namespace — más las excepciones:

   ```bash
   kubectl get clusterpolicies.kyverno.io -o yaml > backup-cpol.yaml
   kubectl get policies.kyverno.io -A -o yaml       > backup-pol.yaml
   kubectl get policyexceptions.kyverno.io -A -o yaml > backup-polex.yaml
   ```

2. Exportá las definiciones de CRD en sí, para poder inspeccionar exactamente qué `storedVersions` tiene hoy el API server:

   ```bash
   kubectl get crds -o name | grep -E 'kyverno.io|wgpolicyk8s.io' \
     | xargs -I{} kubectl get {} -o yaml > backup-kyverno-crds.yaml

   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{.status.storedVersions}{"\n"}'
   ```
   ```
   ["v1"]
   ```

3. Capturá los values de Helm que produjeron el release actual, para que la actualización no descarte silenciosamente tus personalizaciones:

   ```bash
   helm get values kyverno -n kyverno -o yaml > backup-values.yaml
   cat backup-values.yaml
   ```
   ```
   USER-SUPPLIED VALUES:
   admissionController:
     replicas: 3
   backgroundController:
     resources:
       limits:
         memory: 384Mi
   ```

4. (Opcional) Tomá una instantánea de los reports actuales para comparar después de la actualización. Estos se regeneran, así que esto es para *diffear*, no para restaurar:

   ```bash
   kubectl get policyreports.wgpolicyk8s.io -A -o yaml > backup-polr.yaml
   kubectl get clusterpolicyreports.wgpolicyk8s.io -o yaml > backup-cpolr.yaml
   ```

**Verificación de comprensión**

- **Q2.1** ¿Por qué respaldar los objetos `ClusterPolicy`/`Policy` es esencial, mientras que respaldar los objetos `PolicyReport` es solo "está bueno tenerlo"?
- **Q2.2** ¿Cuál es el propósito práctico de registrar `.status.storedVersions` en el CRD antes de actualizar?
- **Q2.3** Ejecutás la actualización, descubrís que una política se comporta distinto, y querés volver a `v1.11.4`. ¿Por qué "restaurar desde `backup-*.yaml` sobre una instalación 1.11 fresca" es la recuperación correcta, y `helm rollback kyverno` la incorrecta?
- **Q2.4** ¿Qué se rompe más tarde si salteás el paso 3 (`helm get values`) y simplemente ejecutás `helm upgrade kyverno kyverno/kyverno`?

---

## Ejercicio 3 — Actualizar con Helm, una versión menor a la vez

**Pasos**

1. Refrescá el índice del repositorio para que Helm pueda ver las nuevas versiones de chart:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/   # no-op if already added
   helm repo update
   ```

2. Listá las versiones de chart disponibles **con sus versiones de aplicación** y armá el mapeo chart→app para tu ruta:

   ```bash
   helm search repo kyverno/kyverno --versions | head
   ```
   ```
   NAME             CHART VERSION   APP VERSION   DESCRIPTION
   kyverno/kyverno  3.3.4           v1.13.4       Kubernetes Native Policy Management
   kyverno/kyverno  3.2.6           v1.12.6       Kubernetes Native Policy Management
   kyverno/kyverno  3.1.4           v1.11.4       Kubernetes Native Policy Management
   ```
   Tus dos saltos son, por lo tanto: **chart `3.2.6`** (app `1.12.6`), luego **chart `3.3.4`** (app `1.13.4`).

3. Realizá el **primer** salto. Pasá tus values guardados, fijá la versión del chart explícitamente, y usá `--atomic` para que un rollout fallido se auto-revierta en lugar de dejarte a medio actualizar:

   ```bash
   helm upgrade kyverno kyverno/kyverno \
     --namespace kyverno \
     --version 3.2.6 \
     -f backup-values.yaml \
     --atomic --timeout 5m
   ```
   ```
   Release "kyverno" has been upgraded. Happy Helming!
   NAME: kyverno
   LAST DEPLOYED: 2026-08-13 12:02:10 ...
   NAMESPACE: kyverno
   STATUS: deployed
   REVISION: 2
   ```

4. Observá que el rollout termine y confirmá que los CRDs fueron actualizados por el chart (el chart de Kyverno envía los CRDs como **templates**, condicionados por `crds.install=true`, precisamente para que `helm upgrade` los actualice — a diferencia del directorio nativo `crds/` de Helm, que es solo de instalación):

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-version}{"\n"}' 2>/dev/null
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```
   ```
   deployment "kyverno-admission-controller" successfully rolled out
   ghcr.io/kyverno/kyverno:v1.12.6
   ```

5. Solo una vez que `1.12.6` esté sano, realizá el **segundo** salto de la misma manera:

   ```bash
   helm upgrade kyverno kyverno/kyverno \
     --namespace kyverno \
     --version 3.3.4 \
     -f backup-values.yaml \
     --atomic --timeout 5m
   ```

6. Si también gestionás las políticas de Pod Security mediante el chart complementario, actualizalo **por separado** — es un release distinto con su propio flujo de versiones:

   ```bash
   helm upgrade kyverno-policies kyverno/kyverno-policies \
     --namespace kyverno --version 3.3.4
   ```

**Verificación de comprensión**

- **Q3.1** ¿Por qué se prefiere `-f backup-values.yaml` sobre `--reuse-values` al actualizar a través de una versión menor?
- **Q3.2** Explicá, en términos de *dónde* se almacenan los CRDs dentro del chart, por qué `helm upgrade` sobre el chart de Kyverno *sí* actualiza los CRDs aunque "Helm nunca actualiza CRDs" sea una regla ampliamente repetida.
- **Q3.3** ¿Qué hace `--atomic` si los pods del admission controller no logran quedar Ready dentro de `--timeout`, y por qué es eso más seguro acá que un `helm upgrade` simple?
- **Q3.4** Ejecutaste `helm upgrade ... --version 3.3.4` directamente desde el chart `3.1.4` de una sola vez. Ambas revisiones muestran `deployed`. ¿Qué límite soportado acabás de violar, y cuál es el riesgo aunque nada haya dado error?

---

## Ejercicio 4 — Actualizaciones por manifest, la trampa de la anotación de CRD, y verificación

No toda instalación es gestionada por Helm. Este ejercicio cubre la ruta de manifest crudo, su falla característica, y cómo verificar cualquier actualización independientemente del método.

**Pasos**

1. Intentá la actualización ingenua por manifest con `kubectl apply`:

   ```bash
   kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.4/install.yaml
   ```
   ```
   The CustomResourceDefinition "clusterpolicies.kyverno.io" is invalid:
   metadata.annotations: Too long: must have at most 262144 bytes
   ```
   Los CRDs de Kyverno son grandes; el apply del lado del cliente mete el objeto
   entero dentro de la anotación `kubectl.kubernetes.io/last-applied-configuration`,
   que desborda el límite de 256 KiB por anotación.

2. Usá **server-side apply**, que almacena la propiedad de campos en managed-fields en lugar de esa anotación, y resolvé los conflictos de propiedad:

   ```bash
   kubectl apply --server-side --force-conflicts \
     -f https://github.com/kyverno/kyverno/releases/download/v1.13.4/install.yaml
   ```
   ```
   customresourcedefinition.apiextensions.k8s.io/clusterpolicies.kyverno.io serverside-applied
   ...
   deployment.apps/kyverno-admission-controller serverside-applied
   ```

3. Verificá las versiones en ejecución de los cuatro controladores de una sola vez:

   ```bash
   kubectl -n kyverno get deploy \
     -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
   ```
   ```
   NAME                            IMAGE
   kyverno-admission-controller    ghcr.io/kyverno/kyverno:v1.13.4
   kyverno-background-controller   ghcr.io/kyverno/kyverno:v1.13.4
   kyverno-cleanup-controller      ghcr.io/kyverno/kyverno:v1.13.4
   kyverno-reports-controller      ghcr.io/kyverno/kyverno:v1.13.4
   ```

4. Confirmá que los admission webhooks fueron re-registrados y se están sirviendo (un webhook obsoleto o faltante tras la actualización detiene silenciosamente la aplicación):

   ```bash
   kubectl get validatingwebhookconfigurations | grep kyverno
   kubectl get mutatingwebhookconfigurations   | grep kyverno
   ```
   ```
   kyverno-policy-validating-webhook-cfg    1   32d
   kyverno-resource-validating-webhook-cfg  4   40s
   kyverno-resource-mutating-webhook-cfg    3   40s
   ```

5. Validá funcionalmente que las políticas siguen aplicando tras la actualización con un objeto conocido-como-malo:

   ```bash
   kubectl run nginx --image=nginx:latest --dry-run=server
   ```
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   ...
   require-image-tag: validation error: An image tag is required. ...
   ```

6. Confirmá que los policy reports se repoblaron (comparalos contra `backup-polr.yaml` del Ejercicio 2) y revisá que los logs del controlador estén limpios:

   ```bash
   kubectl get policyreports.wgpolicyk8s.io -A
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 | grep -i error
   ```

**Verificación de comprensión**

- **Q4.1** Explicá la causa raíz del error `metadata.annotations: Too long` y por qué `--server-side` lo evita.
- **Q4.2** ¿Por qué `--force-conflicts` se vuelve necesario específicamente al mover una instalación existente aplicada del lado del cliente a server-side apply?
- **Q4.3** Tras un bump de imagen exitoso, la aplicación parece haberse detenido. ¿Cuál único comando del paso 4 explica eso más directamente, y qué buscarías en su salida?
- **Q4.4** El paso 5 usa `--dry-run=server`. ¿Por qué `server` y no `client` para validar que la aplicación de Kyverno sobrevivió a la actualización?
- **Q4.5** Necesitás pasar de `v1.13.4` de vuelta a `v1.12.6`. `kubectl apply --server-side` del manifest de 1.12 "tiene éxito". ¿Por qué esto sigue sin ser un downgrade soportado, y qué es lo que realmente protege tus datos?

---

## Respuestas

<details>
<summary>Mostrar respuestas</summary>

**Ejercicio 1**

- **A1.1** El método de instalación dicta *todo* el procedimiento de actualización. Un release gestionado por Helm debe actualizarse con `helm upgrade` (para que los metadatos de release, las anotaciones de propiedad y los values de Helm se mantengan consistentes); una instalación por manifest debe actualizarse con `kubectl apply`. Mezclarlos — por ejemplo, `kubectl apply` sobre un release de Helm — corrompe el seguimiento de propiedad de Helm y causa conflictos en la próxima operación de `helm`. Decidís el método antes de decidir cualquier otra cosa.
- **A1.2** Pasás la **versión del chart** (`3.1.4`) a `--version`; Helm no tiene un flag `--app-version` para actualizaciones. La distinción importa porque son flujos de versión independientes: el chart `3.1.x` envía la app de Kyverno `v1.11.x`, `3.2.x` envía `v1.12.x`, `3.3.x` envía `v1.13.x`. Para aterrizar en una versión específica de Kyverno tenés que buscar la versión de chart que la lleva mediante `helm search repo kyverno/kyverno --versions` y fijar *esa*.
- **A1.3** Ruta: `v1.11.4 → v1.12.6 → v1.13.4` (el último patch de cada menor intermedia está bien). La regla: Kyverno solo soporta/prueba actualizar **una versión menor a la vez**; saltear una menor (`1.11 → 1.13` directo) no está soportado porque las conversiones de CRD y las migraciones de controlador están validadas solo para el paso N→N+1.
- **A1.4** Porque "Kyverno está arriba" no es lo mismo que "los cuatro controladores están arriba". Cada controlador posee una función distinta — admission (aplicación), background (mutar/generar sobre recursos existentes), reports (generación de PolicyReport), cleanup (políticas de TTL/limpieza). Si uno falla silenciosamente en su rollout tras la actualización, solo su función se rompe, y sin un inventario pre-actualización no tenés línea base para notar la regresión.

**Ejercicio 2**

- **A2.1** Los objetos `ClusterPolicy`/`Policy`/`PolicyException` son *estado autorado* — si la actualización los corrompe o tenés que reconstruir la instalación, son la fuente de verdad y no pueden regenerarse. Los objetos `PolicyReport` son *estado derivado*: el reports controller los reconstruye reevaluando las políticas contra el clúster, así que perderlos cuesta un re-escaneo, no datos.
- **A2.2** `storedVersions` te dice como qué versiones de API están realmente persistidos los datos en etcd. Si un futuro release de Kyverno remueve una versión servida/almacenada, una actualización puede fallar o requerir primero una migración de versión de almacenamiento. Registrarlo pre-actualización te permite detectar y planificar eso en lugar de descubrirlo a mitad de la actualización.
- **A2.3** Kyverno no soporta downgrades: la instalación más nueva puede haber convertido/reescrito los datos de CR a un esquema que los CRDs y controladores de la versión más vieja no pueden leer. `helm rollback` revierte los *manifests* pero no la *migración de datos*, dejando a los controladores apuntados a datos que no pueden parsear. Restaurar tu YAML exportado sobre una instalación `1.11` limpia reconstruye objetos conocidos-como-buenos contra CRDs conocidos-como-buenos — la única recuperación confiable.
- **A2.4** `helm upgrade` sin `-f` (y sin `--reuse-values`) revierte todos los values a los *defaults del nuevo chart*, descartando silenciosamente tu `admissionController.replicas: 3`, límites de recursos personalizados, etc. La actualización "tiene éxito" mientras reconfigura silenciosamente tu instalación.

**Ejercicio 3**

- **A3.1** `--reuse-values` reutiliza solo los values de la revisión anterior y **no** fusiona las nuevas claves default introducidas por el chart más nuevo, así que los nuevos ajustes quedan sin setear/inconsistentes. Pasar tu propio `-f backup-values.yaml` superpone tus overrides explícitos sobre los defaults frescos del nuevo chart, dándote los nuevos defaults *más* tus personalizaciones — y mantiene los values en control de versiones.
- **A3.2** La regla "Helm nunca actualiza CRDs" aplica solo a los CRDs colocados en el directorio especial `crds/` del chart, que Helm instala una vez y nunca vuelve a tocar. El chart de Kyverno en cambio renderiza sus CRDs como **templates regulares** (condicionados por `crds.install=true`), así que son recursos ordinarios gestionados por el release que `helm upgrade` reconcilia como cualquier Deployment. Esa decisión de diseño es exactamente por lo que los CRDs se actualizan en el upgrade.
- **A3.3** `--atomic` marca la actualización para revertirse automáticamente a la revisión anterior si el release no alcanza un estado ready dentro de `--timeout`. Si los pods del admission controller nunca quedan Ready, terminás de vuelta en la revisión anterior que funcionaba en lugar de varado en un estado parcialmente aplicado y a medio romper donde la aplicación puede estar inconsistente.
- **A3.4** Salteaste la menor intermedia (`1.12`), violando el límite de soporte de una-menor-a-la-vez. No se espera error porque Helm simplemente aplica manifests — pero las conversiones de CRD y las migraciones de controlador para el paso `1.12 → 1.13` asumen que el clúster estuvo realmente en `1.12` primero. Saltearlo puede dejar CRs sin convertir o reports/estado inconsistentes de formas que emergen más tarde, no en el momento de la actualización.

**Ejercicio 4**

- **A4.1** El `kubectl apply` del lado del cliente escribe el objeto previo completo dentro de la anotación `kubectl.kubernetes.io/last-applied-configuration` para calcular diffs. Los CRDs de Kyverno son lo suficientemente grandes como para que esa anotación exceda el límite de 262144 bytes (256 KiB) por anotación de Kubernetes, así que el apply es rechazado. Server-side apply rastrea la propiedad de campos en `metadata.managedFields` en el servidor y nunca escribe esa anotación, así que el techo de tamaño nunca se alcanza.
- **A4.2** Los objetos existentes fueron creados por apply del lado del cliente, así que sus campos son propiedad del manager `kubectl-client-side-apply`. Cuando cambiás a server-side apply, la identidad del manager cambia y cada campo que intenta setear es un conflicto con el propietario viejo. `--force-conflicts` transfiere la propiedad al manager de server-side apply, permitiendo que el apply proceda en lugar de dar error en cada campo en disputa.
- **A4.3** `kubectl get validatingwebhookconfigurations | grep kyverno`. Mirá si el `kyverno-resource-validating-webhook-cfg` existe y cuántas reglas/webhooks carga (la columna de conteo) y su AGE. Si falta, está vacío (0 reglas), o el AGE no se reseteó cuando el admission controller reinició, Kyverno no está interceptando requests — el API server no tiene nada a lo que llamar, así que nada se aplica sin importar el pod que corra la nueva imagen.
- **A4.4** El dry-run del cliente nunca contacta al API server, así que nunca dispara los admission webhooks — un dry-run del cliente de un Pod malo parecería "pasar". El dry-run del servidor envía la request a través de la cadena de admission real (incluyendo el validating webhook de Kyverno) pero no persiste, así que una denegación prueba que la aplicación está realmente funcionando tras la actualización.
- **A4.5** El apply "tiene éxito" solo porque intercambia manifests e imágenes; no hace nada para convertir los datos de CR que la instalación 1.13 pudo haber reescrito de vuelta a una forma que 1.12 entienda. El downgrade no está soportado precisamente porque esa migración de datos es de una sola dirección. Lo que realmente te protege es el backup del Ejercicio 2 restaurado sobre una instalación 1.12 limpia — no el apply inverso.

</details>

---

### Fuentes

- Kyverno — *Upgrading Kyverno*: https://kyverno.io/docs/installation/upgrading/
- Kyverno — *Installation methods (Helm)*: https://kyverno.io/docs/installation/methods/
- Kyverno — *High Availability / controller architecture*: https://kyverno.io/docs/high-availability/
- Kyverno chart & release notes: https://github.com/kyverno/kyverno/releases and https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Helm — *Custom Resource Definitions* (why `crds/` is install-only): https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
- Kubernetes — *Server-Side Apply*: https://kubernetes.io/docs/reference/using-api/server-side-apply/