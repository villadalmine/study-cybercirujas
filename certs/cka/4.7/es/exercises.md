# CKA 4.7 — Understand CRDs, install and configure operators

## Parte 1: Explorar las CRDs existentes en el cluster

1. Listá todas las `CustomResourceDefinitions` registradas en el cluster:
   ```bash
   kubectl get crds
   ```
2. Elegí una CRD de la lista (por ejemplo, alguna instalada por tu CNI o por un componente de almacenamiento) e inspeccioná su definición completa:
   ```bash
   kubectl get crd <nombre-de-la-crd> -o yaml
   ```
3. Fijate qué `group`, `versions` y `scope` (`Namespaced` o `Cluster`) tiene, y buscá el bloque `spec.versions[].schema.openAPIV3Schema`.
4. Verificá que el recurso que define esa CRD aparece como un tipo más de la API:
   ```bash
   kubectl api-resources | grep <plural-de-la-crd>
   ```

**Preguntas de comprensión:**
1. ¿Qué objeto de Kubernetes "enseña" al API server a reconocer un nuevo tipo de recurso, y en qué se diferencia de un recurso built-in como `Pod`?
2. ¿Para qué sirve el campo `scope` de una CRD, y qué pasa si lo definís como `Cluster` en vez de `Namespaced`?

---

## Parte 2: Crear una CRD propia

1. Creá el archivo `backuppolicy-crd.yaml` con el siguiente contenido:
   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: backuppolicies.training.example.com
   spec:
     group: training.example.com
     names:
       kind: BackupPolicy
       listKind: BackupPolicyList
       plural: backuppolicies
       singular: backuppolicy
       shortNames:
         - bkp
     scope: Namespaced
     versions:
       - name: v1
         served: true
         storage: true
         subresources:
           status: {}
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 required:
                   - schedule
                   - targetPVC
                 properties:
                   schedule:
                     type: string
                   retentionDays:
                     type: integer
                     minimum: 1
                   targetPVC:
                     type: string
         additionalPrinterColumns:
           - name: Schedule
             type: string
             jsonPath: .spec.schedule
           - name: Retention
             type: integer
             jsonPath: .spec.retentionDays
   ```
2. Aplicala:
   ```bash
   kubectl apply -f backuppolicy-crd.yaml
   ```
3. Confirmá que el nuevo tipo de recurso está disponible:
   ```bash
   kubectl get bkp
   ```
4. Describí la CRD y ubicá el `status.conditions` con `type: Established`:
   ```bash
   kubectl describe crd backuppolicies.training.example.com
   ```

**Preguntas de comprensión:**
1. ¿Qué valida el bloque `openAPIV3Schema` cuando alguien intenta crear un Custom Resource de tipo `BackupPolicy`?
2. ¿Para qué sirve `subresources.status` en una CRD, y qué controller es responsable de escribir ese campo en las instancias del recurso?
3. ¿Qué significa que la `condition` `Established` esté en `True` en el status de la CRD?

---

## Parte 3: Crear Custom Resources (instancias)

1. Creá `nightly-backup.yaml`:
   ```yaml
   apiVersion: training.example.com/v1
   kind: BackupPolicy
   metadata:
     name: nightly-backup
   spec:
     schedule: "0 2 * * *"
     retentionDays: 7
     targetPVC: data-pvc
   ```
2. Aplicalo y verificá que aparece con las columnas personalizadas que definiste en la CRD:
   ```bash
   kubectl apply -f nightly-backup.yaml
   kubectl get backuppolicies
   ```
3. Ahora intentá crear una instancia inválida, sin el campo requerido `targetPVC`:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: training.example.com/v1
   kind: BackupPolicy
   metadata:
     name: invalid-backup
   spec:
     schedule: "0 3 * * *"
   EOF
   ```

**Preguntas de comprensión:**
1. ¿Por qué el paso 3 falla, y en qué componente ocurre la validación (API server vs. algún controller externo)?
2. Si en vez de crear la CRD del paso anterior no existiera, ¿qué error devolvería `kubectl apply` sobre `nightly-backup.yaml`?

---

## Parte 4: Instalar un Operator real (cert-manager)

1. Instalá cert-manager, un Operator ampliamente usado para gestionar certificados TLS, aplicando su manifiesto de release:
   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
   ```
2. Verificá que se crearon nuevas CRDs (`Certificate`, `Issuer`, `ClusterIssuer`, etc.):
   ```bash
   kubectl get crds | grep cert-manager.io
   ```
3. Verificá que el namespace `cert-manager` tiene sus Deployments y Pods en estado `Running`:
   ```bash
   kubectl get pods -n cert-manager
   kubectl get deployments -n cert-manager
   ```

**Preguntas de comprensión:**
1. ¿En qué se diferencia "instalar un Operator" de simplemente "crear una CRD"? ¿Qué pieza adicional aporta el Operator?
2. Los Pods que viste en el namespace `cert-manager`, ¿qué patrón de Kubernetes implementan para reaccionar ante cambios en los Custom Resources (control loop / reconciliation)?

---

## Parte 5: Configurar el Operator mediante Custom Resources

1. Creá un `ClusterIssuer` self-signed, que le indica al Operator cómo emitir certificados:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: selfsigned-issuer
   spec:
     selfSigned: {}
   ```
   ```bash
   kubectl apply -f selfsigned-issuer.yaml
   kubectl get clusterissuer selfsigned-issuer
   ```
2. Pedile al Operator que emita un certificado creando un recurso `Certificate`:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: demo-cert
     namespace: default
   spec:
     secretName: demo-cert-tls
     issuerRef:
       name: selfsigned-issuer
       kind: ClusterIssuer
     dnsNames:
       - demo.example.local
   ```
   ```bash
   kubectl apply -f demo-cert.yaml
   ```
3. Verificá que el Operator reconcilió el recurso y generó el Secret con el certificado:
   ```bash
   kubectl get certificate demo-cert
   kubectl describe certificate demo-cert
   kubectl get secret demo-cert-tls
   ```

**Preguntas de comprensión:**
1. Nunca ejecutaste ningún comando para generar el certificado en sí. ¿Qué componente lo generó, y cómo se enteró de que debía hacerlo?
2. En el `describe` del `Certificate`, ¿qué condición (`type`) indica que el certificado se emitió correctamente?
3. ¿Qué pasaría con el Secret `demo-cert-tls` si borraras el recurso `Certificate` con `kubectl delete certificate demo-cert`?

---

## Parte 6: Troubleshooting básico de un Operator

1. Revisá los logs del controller de cert-manager para ver el proceso de reconciliation:
   ```bash
   kubectl logs -n cert-manager deploy/cert-manager --tail=50
   ```
2. Buscá eventos relacionados al `Certificate` que creaste:
   ```bash
   kubectl get events --field-selector involvedObject.kind=Certificate --sort-by=.lastTimestamp
   ```
3. Provocá un fallo intencional: editá el `Certificate` y cambiá `issuerRef.name` a un Issuer que no existe (`issuer-inexistente`), aplicá el cambio, y volvé a describir el recurso.

**Preguntas de comprensión:**
1. ¿Dónde esperás encontrar la causa raíz de un fallo de reconciliation: en los logs del Operator, en el `status.conditions` del CR, o en ambos? Justificá.
2. Después del paso 3, ¿el recurso `Certificate` queda en estado de error inmediatamente y de forma permanente, o el Operator reintenta? ¿Qué patrón de Kubernetes explica ese comportamiento?

---

## Respuestas

<details>
<summary>Mostrar respuestas</summary>

**Parte 1**
1. La `CustomResourceDefinition` (CRD) le enseña al API server a reconocer un nuevo tipo de recurso. A diferencia de un recurso built-in como `Pod`, que está compilado en el binario del `kube-apiserver`, un recurso definido por una CRD se registra dinámicamente en tiempo de ejecución, sin necesidad de recompilar ni reiniciar el API server.
2. `scope` define si las instancias del recurso viven dentro de un namespace (`Namespaced`) o son globales al cluster (`Cluster`), igual que ocurre con `Pod` vs `Node`. Si lo definís como `Cluster`, las instancias no tendrán namespace y serán visibles/accesibles desde cualquier namespace, sin aislamiento multi-tenant.

**Parte 2**
1. Valida que el `spec` de cada instancia de `BackupPolicy` cumpla el schema declarado: que `schedule` y `targetPVC` sean strings presentes (son `required`), y que `retentionDays`, si está, sea un entero mayor o igual a 1. Si no se cumple, el API server rechaza el `kubectl apply` con un error de validación antes de persistir el objeto en etcd.
2. `subresources.status` habilita un subrecurso `/status` separado del resto del objeto, de forma que un controller pueda actualizar el estado del recurso (`status`) sin necesidad de permisos de escritura sobre el `spec`, y sin pisar cambios que otro cliente haya hecho al `spec`. Quien escribe ese campo es el controller/Operator asociado al recurso (en la Parte 2 no hay ninguno corriendo todavía, por eso `status` queda vacío).
3. Que `Established: True` significa que el API server terminó de registrar la CRD y ya acepta operaciones sobre el recurso `BackupPolicy` (el tipo está disponible en la API).

**Parte 3**
1. Falla porque `targetPVC` está marcado como `required` en el `openAPIV3Schema` de la CRD. La validación ocurre en el `kube-apiserver`, usando el schema OpenAPI v3 definido en la CRD — no depende de ningún controller externo.
2. Devolvería un error indicando que el servidor no reconoce el `kind: BackupPolicy` en el `apiVersion: training.example.com/v1` (algo como `no matches for kind "BackupPolicy" in version "training.example.com/v1"`), porque sin la CRD el API server no tiene registrado ese tipo.

**Parte 4**
1. Una CRD solo agrega el tipo de dato a la API (define la "forma" del recurso); por sí sola no hace nada con las instancias que crees. Un Operator agrega, además, uno o más controllers corriendo como Pods que observan esos Custom Resources y ejecutan acciones reales (crear Secrets, certificados, configurar infraestructura, etc.) para llevar el estado real al estado deseado.
2. Implementan el patrón de control loop / reconciliation: el controller hace `watch` sobre los Custom Resources, compara el estado deseado (`spec`) contra el estado actual, y ejecuta las acciones necesarias para converger, actualizando luego el `status`.

**Parte 5**
1. Lo generó el controller de cert-manager (el Operator). Se enteró porque tiene un `watch` activo sobre el tipo `Certificate`; al ver la creación del objeto `demo-cert`, su reconciliation loop leyó el `spec`, usó el `ClusterIssuer` referenciado para emitir el certificado, y escribió el resultado en el Secret indicado por `secretName`.
2. La condición `type: Ready` con `status: "True"` indica que el certificado se emitió correctamente y el Secret está disponible.
3. cert-manager, por defecto, también borra el Secret asociado cuando se elimina el `Certificate` (a menos que se configure lo contrario), porque el Operator trata el Secret como un recurso derivado del `Certificate` y lo mantiene sincronizado con su ciclo de vida.

**Parte 6**
1. En ambos lugares, pero con propósitos distintos: el `status.conditions` del CR da el resumen del estado actual desde la perspectiva del recurso (útil para un vistazo rápido con `kubectl describe`), mientras que los logs del Operator dan el detalle del proceso de reconciliation y el motivo específico del error (por ejemplo, un Issuer no encontrado).
2. El Operator reintenta: no queda en error permanente de forma pasiva. El controller vuelve a ejecutar su reconciliation loop (con backoff) y actualiza las conditions del `Certificate` reflejando el error (por ejemplo `Ready: False` con una razón como `IssuerNotFound`), reintentando periódicamente hasta que la referencia sea válida o el recurso se corrija.

</details>

---

**Fuentes de referencia:**
- CNCF, *CKA Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes docs, *Custom Resources* — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- cert-manager docs, *Installation* — https://cert-manager.io/docs/installation/
- cert-manager docs, *Issuing Certificates* — https://cert-manager.io/docs/usage/certificate/