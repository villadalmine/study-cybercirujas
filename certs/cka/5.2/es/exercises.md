# Ejercicios guiados: Define and enforce Network Policies (CKA 1.35 — 5.2)

> Peso en el examen: 3.33%
> Fuente de referencia: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

> **Nota previa:** los `NetworkPolicy` solo se enforcean si el CNI del cluster los soporta (Calico, Cilium, Weave Net, etc.). Flannel "puro" no los aplica. Si tu cluster no enforcea policies, los `kubectl apply` van a funcionar igual (el objeto se crea), pero el tráfico no se va a bloquear realmente. Verificalo antes de empezar.

---

## Ejercicio 1 — Preparar el entorno de pruebas

1. Creá un namespace dedicado para los ejercicios:

   ```bash
   kubectl create namespace netpol-lab
   ```

2. Desplegá un pod que va a actuar como servidor, con label `role=backend`:

   ```bash
   kubectl run backend --image=nginx --labels="role=backend" --namespace=netpol-lab --port=80
   ```

3. Exponelo con un Service ClusterIP:

   ```bash
   kubectl expose pod backend --namespace=netpol-lab --port=80 --name=backend-svc
   ```

4. Desplegá dos pods cliente para probar conectividad, uno "autorizado" y otro "no autorizado":

   ```bash
   kubectl run client-a --image=busybox --labels="role=frontend" --namespace=netpol-lab -- sleep 3600
   kubectl run client-b --image=busybox --labels="role=other" --namespace=netpol-lab -- sleep 3600
   ```

5. Confirmá que, sin ninguna `NetworkPolicy` todavía, ambos clientes pueden llegar al backend:

   ```bash
   kubectl exec -n netpol-lab client-a -- wget -qO- --timeout=2 backend-svc
   kubectl exec -n netpol-lab client-b -- wget -qO- --timeout=2 backend-svc
   ```

**Preguntas:**

1. ¿Qué determina si un objeto `NetworkPolicy` aplicado tiene efecto real sobre el tráfico del cluster?
2. Sin ninguna `NetworkPolicy` en un namespace, ¿cuál es el comportamiento por defecto respecto al tráfico ingress y egress de los pods?

---

## Ejercicio 2 — Default deny all ingress

1. Creá el archivo `default-deny-ingress.yaml` con una policy que selecciona todos los pods del namespace y no permite ningún ingress:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: netpol-lab
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
   ```

2. Aplicala:

   ```bash
   kubectl apply -f default-deny-ingress.yaml
   ```

3. Repetí las pruebas de conectividad del paso 5 del Ejercicio 1:

   ```bash
   kubectl exec -n netpol-lab client-a -- wget -qO- --timeout=2 backend-svc
   kubectl exec -n netpol-lab client-b -- wget -qO- --timeout=2 backend-svc
   ```

4. Listá las policies del namespace y describí la que acabás de crear:

   ```bash
   kubectl get networkpolicy -n netpol-lab
   kubectl describe networkpolicy default-deny-ingress -n netpol-lab
   ```

**Preguntas:**

1. ¿Por qué un `podSelector: {}` vacío selecciona a *todos* los pods del namespace, incluido `backend`?
2. Con esta policy aplicada, ¿qué pasa con el tráfico egress de `backend`? ¿Por qué no cambia respecto al Ejercicio 1?

---

## Ejercicio 3 — Permitir ingress solo desde pods con un label específico

1. Creá `allow-frontend.yaml`, que permite ingress hacia `backend` únicamente desde pods con label `role=frontend`, dentro del mismo namespace:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend
     namespace: netpol-lab
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
         ports:
           - protocol: TCP
             port: 80
   ```

2. Aplicala junto con la del Ejercicio 2 (ambas coexisten):

   ```bash
   kubectl apply -f allow-frontend.yaml
   ```

3. Probá de nuevo la conectividad desde ambos clientes:

   ```bash
   kubectl exec -n netpol-lab client-a -- wget -qO- --timeout=2 backend-svc
   kubectl exec -n netpol-lab client-b -- wget -qO- --timeout=2 backend-svc
   ```

4. Cambiá el label de `client-b` a `role=frontend` y repetí la prueba:

   ```bash
   kubectl label pod client-b role=frontend --overwrite -n netpol-lab
   kubectl exec -n netpol-lab client-b -- wget -qO- --timeout=2 backend-svc
   ```

**Preguntas:**

1. Cuando existen varias `NetworkPolicy` que seleccionan el mismo pod vía `podSelector` en su `spec`, ¿cómo se combinan sus reglas de ingress: con AND o con OR?
2. ¿Por qué `client-b` pasó a tener acceso después del paso 4, sin haber modificado ninguna `NetworkPolicy`?

---

## Ejercicio 4 — Permitir ingress desde otro namespace

1. Creá un segundo namespace y un cliente ahí:

   ```bash
   kubectl create namespace partner-ns
   kubectl label namespace partner-ns team=partner
   kubectl run client-c --image=busybox --namespace=partner-ns -- sleep 3600
   ```

2. Probá la conectividad cross-namespace hacia `backend` (usando el nombre FQDN del Service):

   ```bash
   kubectl exec -n partner-ns client-c -- wget -qO- --timeout=2 backend-svc.netpol-lab.svc.cluster.local
   ```

3. Editá (o creá) una policy `allow-partner-ns.yaml` que permita ingress hacia `backend` desde cualquier pod del namespace con label `team=partner`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-partner-ns
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 team: partner
         ports:
           - protocol: TCP
             port: 80
   ```

4. Aplicala y repetí la prueba del paso 2.

**Preguntas:**

1. ¿Por qué es necesario que el namespace `partner-ns` tenga el label `team=partner`, y no alcanza con que lo tenga el pod `client-c`?
2. Si dentro de un mismo bloque `from` combinás `namespaceSelector` y `podSelector` (como dos campos del mismo item de la lista, no como dos items separados), ¿qué relación lógica se establece entre ambos selectores?

---

## Ejercicio 5 — Restringir egress y permitir DNS

1. Creá `restrict-backend-egress.yaml`, que aplica a `backend` y bloquea todo egress salvo DNS (puerto 53 UDP/TCP hacia `kube-dns`) y tráfico HTTPS saliente:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: restrict-backend-egress
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
       - Egress
     egress:
       - to:
           - namespaceSelector: {}
             podSelector:
               matchLabels:
                 k8s-app: kube-dns
         ports:
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
       - ports:
           - protocol: TCP
             port: 443
   ```

2. Aplicala:

   ```bash
   kubectl apply -f restrict-backend-egress.yaml
   ```

3. Desde `backend`, probá resolver DNS y hacer una request HTTPS saliente, y luego una request HTTP saliente (puerto 80) que debería fallar:

   ```bash
   kubectl exec -n netpol-lab backend -- curl -sk --max-time 2 https://kubernetes.default.svc.cluster.local
   kubectl exec -n netpol-lab backend -- wget -qO- --timeout=2 http://example.com
   ```

4. Revertí el egress restrictivo para no romper el resto de los ejercicios:

   ```bash
   kubectl delete -f restrict-backend-egress.yaml
   ```

**Preguntas:**

1. Si no hubieras incluido la regla que permite el puerto 53 hacia `kube-dns`, ¿qué síntoma verías al intentar cualquier request saliente que dependa de resolución de nombres, aunque el puerto de destino esté permitido?
2. El segundo item de la lista `egress` no tiene ningún campo `to`. ¿Qué significa la ausencia de `to` en un item de `ingress`/`egress`?

---

## Ejercicio 6 — Combinar ipBlock con except

1. Creá `allow-external-cidr.yaml`, que aplica a `backend` y permite ingress desde un rango de IPs externo, excluyendo una subred específica dentro de ese rango:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-external-cidr
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - ipBlock:
               cidr: 10.0.0.0/16
               except:
                 - 10.0.5.0/24
         ports:
           - protocol: TCP
             port: 80
   ```

2. Aplicala y usá `kubectl describe` para confirmar que el CIDR y el `except` quedaron registrados correctamente:

   ```bash
   kubectl apply -f allow-external-cidr.yaml
   kubectl describe networkpolicy allow-external-cidr -n netpol-lab
   ```

3. Limpiá todos los recursos del laboratorio:

   ```bash
   kubectl delete namespace netpol-lab partner-ns
   ```

**Preguntas:**

1. `ipBlock` se usa típicamente para tráfico que no proviene de pods del cluster (por ejemplo, un rango externo o de nodos). ¿Puede un `ipBlock` referirse a IPs de pods dentro del cluster también?
2. ¿Qué diferencia práctica hay entre usar `ipBlock` con `except` y simplemente no incluir esa subred en el `cidr` original?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

1. Que el CNI plugin instalado en el cluster implemente el enforcement de `NetworkPolicy` (por ejemplo Calico, Cilium, Weave Net). El objeto `NetworkPolicy` en sí es solo un recurso de la API; si el CNI no lo soporta, se acepta pero no tiene ningún efecto sobre el tráfico real.
2. Por defecto (sin ninguna `NetworkPolicy` aplicable), todo el tráfico ingress y egress está permitido hacia y desde cualquier pod — el modelo es "allow all" hasta que algo lo restrinja.

**Ejercicio 2**

1. Un `podSelector: {}` sin `matchLabels` ni `matchExpressions` es un selector vacío que hace match con todos los pods del namespace, sin excepción — no selecciona "ningún pod", selecciona "todos los pods" (a diferencia de un `from`/`to` vacío, que sí significa "nadie").
2. Porque esta policy solo declara `policyTypes: [Ingress]`. No tiene sección `egress` ni incluye `Egress` en `policyTypes`, así que no afecta el tráfico saliente de ningún pod; el egress sigue siendo "allow all" como en el Ejercicio 1.

**Ejercicio 3**

1. Se combinan con OR: si múltiples policies seleccionan al mismo pod vía su `spec.podSelector`, el pod termina permitiendo la unión de todas las reglas de ingress definidas en esas policies (además de seguir denegando por defecto todo lo que ninguna regla permita explícitamente).
2. Porque las `NetworkPolicy` de tipo ingress evalúan el estado *actual* de los labels del pod origen en tiempo real, no en el momento en que se creó la policy. Al cambiar el label de `client-b` a `role=frontend`, automáticamente empieza a hacer match con el `podSelector` de `allow-frontend`, sin necesidad de tocar la policy.

**Ejercicio 4**

1. Porque un item `from` con `namespaceSelector` evalúa los labels del **namespace** de origen del pod, no los labels del pod en sí. Un pod con label `team=partner` en un namespace sin ese label no haría match con esta regla.
2. Se combinan con AND: cuando `namespaceSelector` y `podSelector` están dentro del **mismo** item de la lista `from` (mismo `-`), el tráfico solo se permite si el pod de origen cumple ambos selectores simultáneamente (namespace con ese label Y pod con ese label). Si estuvieran como dos items separados de la lista, se combinarían con OR.

**Ejercicio 5**

1. Verías timeouts o errores de "could not resolve host" en cualquier request saliente que dependa de DNS, incluso si el puerto de destino final (443, 80, etc.) está explícitamente permitido — porque la resolución de nombres en sí (UDP/TCP 53 hacia el pod de `kube-dns`) sería bloqueada antes de poder siquiera intentar la conexión al destino real.
2. Significa "sin restricción de destino/origen para ese item": un item de `egress` sin `to` permite tráfico hacia cualquier destino (solo restringido por los `ports` indicados), y análogamente un item de `ingress` sin `from` permite tráfico desde cualquier origen.

**Ejercicio 6**

1. Sí. Nada impide que el CIDR de un `ipBlock` incluya IPs de pods del cluster — Kubernetes no distingue el origen de la IP, solo evalúa si la IP de origen del paquete cae dentro del `cidr` (y fuera del `except`). En la práctica se recomienda usar `podSelector`/`namespaceSelector` para tráfico intra-cluster porque las IPs de pods son efímeras, pero técnicamente `ipBlock` también puede matchear tráfico interno.
2. Son equivalentes en el resultado final (el rango excluido queda sin acceso en ambos casos), pero difieren en legibilidad e intención: `except` dentro de un `cidr` amplio deja explícito "permito esta red grande salvo esta subred puntual", mientras que definir el `cidr` sin esa subred desde el inicio requiere que quien lee la policy calcule mentalmente qué rangos quedan cubiertos. `except` también es más robusto si el rango excluido cambia, porque no obliga a recalcular el CIDR base.

</details>
