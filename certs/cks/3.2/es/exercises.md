# CKS 3.2 — Exercise caution in using service accounts

> **Fuente de referencia:** [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)
> Los comandos se probaron sobre un cluster con `kubectl` configurado contra un contexto con permisos de administrador. Reemplazá `<ns>` por el namespace que estés usando.

---

## Ejercicio 1: Inspeccionar el ServiceAccount `default` y su automount de token

El `ServiceAccount` `default` existe en todo namespace y se asigna automáticamente a cualquier Pod que no especifique uno propio. Por defecto, Kubernetes monta el token de ese SA dentro del Pod, lo que da acceso al API server a cualquier proceso corriendo ahí — incluso si nadie lo necesita.

1. Creá un namespace de prueba:
   ```bash
   kubectl create namespace sa-lab
   ```
2. Inspeccioná el ServiceAccount `default` que Kubernetes crea automáticamente:
   ```bash
   kubectl get serviceaccount default -n sa-lab -o yaml
   ```
3. Corré un Pod sin indicar `serviceAccountName`:
   ```bash
   kubectl run probe --image=nginx -n sa-lab
   ```
4. Entrá al Pod y revisá qué se montó:
   ```bash
   kubectl exec -n sa-lab probe -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   kubectl exec -n sa-lab probe -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
   ```
5. Confirmá que ese token es válido contra el API server:
   ```bash
   kubectl exec -n sa-lab probe -- \
     curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $(kubectl exec -n sa-lab probe -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
     https://kubernetes.default.svc/api/v1/namespaces/sa-lab/pods
   ```

**Preguntas de comprensión:**
- ¿Por qué representa un riesgo que un Pod que no necesita hablar con el API server tenga igual un token montado?
- Desde la versión 1.24 de Kubernetes, ¿los tokens de ServiceAccount ya no se crean como `Secret` automáticamente. ¿Eso significa que el automount también dejó de ser el comportamiento por defecto?

---

## Ejercicio 2: Deshabilitar el automount de token (a nivel ServiceAccount y a nivel Pod)

`automountServiceAccountToken` se puede setear tanto en el `ServiceAccount` como en el `spec` del Pod. El valor del Pod tiene precedencia sobre el del SA.

1. Deshabilitá el automount en el ServiceAccount `default` del namespace:
   ```bash
   kubectl patch serviceaccount default -n sa-lab -p '{"automountServiceAccountToken": false}'
   ```
2. Corré un Pod nuevo y verificá que ya no tiene el volumen del token:
   ```bash
   kubectl run probe2 --image=nginx -n sa-lab
   kubectl exec -n sa-lab probe2 -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
3. Ahora probá el caso donde un Pod específico necesita **forzar** el automount aunque el SA lo tenga deshabilitado, definiéndolo en el manifiesto:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe3
     namespace: sa-lab
   spec:
     automountServiceAccountToken: true
     containers:
     - name: app
       image: nginx
   ```
   ```bash
   kubectl apply -f probe3.yaml
   kubectl exec -n sa-lab probe3 -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

**Preguntas de comprensión:**
- Si `automountServiceAccountToken: false` está en el ServiceAccount y `true` en el `spec` del Pod, ¿cuál gana?
- ¿Qué workloads son buenos candidatos para deshabilitar el automount por completo (pensá en Pods que solo sirven tráfico HTTP y nunca llaman al API server)?

---

## Ejercicio 3: Crear un ServiceAccount dedicado con permisos mínimos

En vez de reutilizar `default`, cada workload que sí necesite hablar con el API server debería tener su propio ServiceAccount con un `Role`/`RoleBinding` acotado exactamente a lo que necesita (least privilege).

1. Creá un ServiceAccount dedicado:
   ```bash
   kubectl create serviceaccount pod-reader-sa -n sa-lab
   ```
2. Definí un `Role` que solo permita `get`/`list` sobre `pods` en ese namespace:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader-role
     namespace: sa-lab
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list"]
   ```
3. Enlazá el Role al ServiceAccount con un `RoleBinding`:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: pod-reader-binding
     namespace: sa-lab
   subjects:
   - kind: ServiceAccount
     name: pod-reader-sa
     namespace: sa-lab
   roleRef:
     kind: Role
     name: pod-reader-role
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f role.yaml -f rolebinding.yaml
   ```
4. Asigná el ServiceAccount al Pod que efectivamente necesita ese acceso:
   ```bash
   kubectl run reader --image=bitnami/kubectl -n sa-lab \
     --overrides='{"spec":{"serviceAccountName":"pod-reader-sa"}}' \
     --command -- sleep 3600
   ```
5. Validá los permisos efectivos sin ejecutar nada en el Pod, usando `--as`:
   ```bash
   kubectl auth can-i list pods -n sa-lab --as=system:serviceaccount:sa-lab:pod-reader-sa
   kubectl auth can-i delete pods -n sa-lab --as=system:serviceaccount:sa-lab:pod-reader-sa
   kubectl auth can-i list secrets -n sa-lab --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

**Preguntas de comprensión:**
- ¿Por qué es mejor tener un ServiceAccount por workload en lugar de compartir uno entre varias aplicaciones distintas?
- ¿Qué ventaja tiene usar `kubectl auth can-i --as=...` en vez de entrar al Pod para probar el token manualmente?

---

## Ejercicio 4: Auditar bindings existentes para detectar ServiceAccounts sobre-privilegiados

Una mala configuración común (y buscada en el examen) es encontrar un `ClusterRoleBinding` que otorgue `cluster-admin` (u otro rol amplio) al ServiceAccount `default`, o a todos los ServiceAccounts de un namespace.

1. Listá todos los `ClusterRoleBinding` del cluster:
   ```bash
   kubectl get clusterrolebindings -o json > crbs.json
   ```
2. Filtrá los que referencian ServiceAccounts llamados `default`:
   ```bash
   jq -r '.items[] | select(.subjects[]?.kind=="ServiceAccount" and .subjects[]?.name=="default") | .metadata.name' crbs.json
   ```
3. Filtrá los que otorgan el rol `cluster-admin`:
   ```bash
   jq -r '.items[] | select(.roleRef.name=="cluster-admin") | {name: .metadata.name, subjects: .subjects}' crbs.json
   ```
4. Simulá el hallazgo del examen: creá deliberadamente un binding inseguro y después detectalo con el mismo método:
   ```bash
   kubectl create clusterrolebinding risky-binding \
     --clusterrole=cluster-admin \
     --serviceaccount=sa-lab:default
   ```
   ```bash
   kubectl get clusterrolebindings -o json | \
     jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
   ```
5. Remediá eliminando el binding inseguro:
   ```bash
   kubectl delete clusterrolebinding risky-binding
   ```

**Preguntas de comprensión:**
- ¿Por qué un `ClusterRoleBinding` que asocia `default` con `cluster-admin` es mucho más peligroso que un `RoleBinding` equivalente dentro de un solo namespace?
- ¿Qué comando usarías para auditar de forma continua (por ejemplo, en un pipeline) si algún ServiceAccount tiene un binding a `cluster-admin`?

---

## Ejercicio 5: Confirmar que un ServiceAccount de mínimo privilegio no permite escalar

Cerramos el ciclo verificando, desde dentro del propio Pod, que el token entregado respeta el principio de mínimo privilegio configurado en los ejercicios anteriores.

1. Entrá al Pod `reader` creado en el Ejercicio 3:
   ```bash
   kubectl exec -it -n sa-lab reader -- sh
   ```
2. Dentro del Pod, armá las variables de autenticación contra el API server:
   ```bash
   TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
   CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
   ```
3. Probá una operación permitida (`list pods`):
   ```bash
   curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/sa-lab/pods
   ```
4. Probá una operación que debería estar prohibida (`list secrets` o `delete pods`):
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/sa-lab/secrets
   ```
5. Salí del Pod y limpiá el namespace de laboratorio:
   ```bash
   exit
   kubectl delete namespace sa-lab
   ```

**Preguntas de comprensión:**
- ¿Qué código HTTP esperás recibir en el paso 4, y qué significa en términos de RBAC?
- Los tokens de ServiceAccount "bound" (feature estable desde Kubernetes 1.22+) incluyen `audience`, `expiration` y están ligados al Pod. ¿Qué problema de los tokens legacy (montados como `Secret` de larga duración) resuelve esto?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- Es riesgoso porque, si un atacante compromete el proceso dentro del Pod (por ejemplo vía una vulnerabilidad en la app), automáticamente hereda credenciales válidas contra el API server aunque la aplicación nunca las necesitó — es superficie de ataque innecesaria.
- No. Desde 1.24 cambió *cómo* se generan los tokens (vía TokenRequest API, con expiración y ya no como `Secret` persistente), pero el **automount** de ese token en el Pod sigue siendo `true` por defecto salvo que se deshabilite explícitamente.

**Ejercicio 2**
- Gana el valor definido en el `spec` del Pod: siempre tiene precedencia sobre lo configurado en el ServiceAccount.
- Cualquier Pod que no llame al API server: proxies, servidores web estáticos, workers que solo consumen colas externas, sidecars que no necesitan la Kubernetes API, etc.

**Ejercicio 3**
- Porque limita el "blast radius": si se compromete un workload, el atacante solo hereda los permisos estrictamente necesarios para esa aplicación, no los de todas las apps que compartirían un SA común.
- `kubectl auth can-i --as=` simula la decisión de RBAC sin necesidad de tener el token a mano ni ejecutar código dentro del Pod, lo que es más rápido, no requiere acceso shell y no expone el token en la sesión de la terminal.

**Ejercicio 4**
- Un `ClusterRoleBinding` aplica a nivel de todo el cluster: cualquier Pod en cualquier namespace que use el SA `default` local hereda `cluster-admin` a nivel global, mientras que un `RoleBinding` limita ese privilegio a un namespace puntual.
- Un comando tipo `kubectl get clusterrolebindings -o json | jq '.items[] | select(.roleRef.name=="cluster-admin")'` (o herramientas de auditoría como `kubectl-who-can` / policies de admission control) integradas en CI/CD o corridas periódicas contra el cluster.

**Ejercicio 5**
- Se espera `403 Forbidden`, porque el Role solo otorga `get`/`list` sobre `pods`, no sobre `secrets` ni operaciones de escritura — RBAC deniega por defecto (deny-by-default) todo lo que no está explícitamente permitido.
- Resuelve que un token robado (por ejemplo filtrado en un log o extraído del filesystem) sea utilizable indefinidamente: los tokens "bound" expiran, están atados a la audiencia (`audience`) del API server y al Pod específico, por lo que dejan de ser válidos si el Pod es eliminado o el token vence.

</details>