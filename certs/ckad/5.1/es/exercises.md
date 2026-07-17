# Ejercicios guiados — 5.1 NetworkPolicies (CKAD v1.35)

> **Requisitos previos:** un cluster con un CNI plugin que soporte NetworkPolicies (Calico, Cilium, etc.). En minikube podés arrancar con `minikube start --cni=calico`. Si tu CNI no las soporta, los objetos NetworkPolicy se crean igual pero **no tienen ningún efecto** — tenelo en cuenta al validar los resultados.

---

## Ejercicio 1 — Comportamiento por defecto: todo permitido

Antes de restringir tráfico, comprobá qué pasa cuando **no existe ninguna NetworkPolicy**.

1. Creá un namespace de trabajo:

   ```bash
   kubectl create namespace netpol-lab
   ```

2. Desplegá un pod `backend` que sirva HTTP en el puerto 80, con el label `app=backend`:

   ```bash
   kubectl run backend --image=nginx --labels=app=backend -n netpol-lab
   ```

3. Exponelo con un Service:

   ```bash
   kubectl expose pod backend --port=80 -n netpol-lab
   ```

4. Desplegá un pod cliente `frontend` con el label `app=frontend`:

   ```bash
   kubectl run frontend --image=busybox --labels=app=frontend -n netpol-lab -- sleep 3600
   ```

5. Verificá que ambos pods estén `Running`:

   ```bash
   kubectl get pods -n netpol-lab -o wide --show-labels
   ```

6. Probá la conectividad desde `frontend` hacia `backend`:

   ```bash
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

   Deberías ver el HTML de bienvenida de nginx.

**Pregunta 1.1** — Si no existe ninguna NetworkPolicy que seleccione a un pod, ¿qué tráfico de entrada (ingress) y de salida (egress) se le permite?

**Pregunta 1.2** — ¿Las NetworkPolicies son un recurso *namespaced* o *cluster-scoped*? ¿Cómo lo verificarías con `kubectl`?

---

## Ejercicio 2 — Default deny: bloquear todo el ingress

Ahora aplicá la política más común como punto de partida: denegar todo el tráfico entrante del namespace.

1. Creá el archivo `deny-all-ingress.yaml`:

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

2. Aplicalo:

   ```bash
   kubectl apply -f deny-all-ingress.yaml
   ```

3. Repetí la prueba de conectividad:

   ```bash
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

   Esta vez el comando debería **fallar con timeout**.

4. Inspeccioná la política y a qué pods afecta:

   ```bash
   kubectl describe networkpolicy default-deny-ingress -n netpol-lab
   ```

**Pregunta 2.1** — ¿Qué significa `podSelector: {}` (vacío) en el `spec` de la política?

**Pregunta 2.2** — La política solo declara `policyTypes: [Ingress]` y no tiene sección `ingress:`. ¿Por qué eso resulta en "denegar todo el ingress" en lugar de "permitir todo"?

**Pregunta 2.3** — Con esta política aplicada, ¿el pod `frontend` puede seguir **iniciando** conexiones hacia fuera del namespace? ¿Por qué?

---

## Ejercicio 3 — Permitir tráfico selectivo con podSelector

Las NetworkPolicies son **aditivas**: sobre el default deny, agregá una política que permita solo el tráfico de `frontend` a `backend`.

1. Creá el archivo `allow-frontend.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-backend
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 app: frontend
         ports:
           - protocol: TCP
             port: 80
   ```

2. Aplicalo y verificá que ahora `frontend` sí llega a `backend`:

   ```bash
   kubectl apply -f allow-frontend.yaml
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

3. Creá un tercer pod `intruso` **sin** el label `app=frontend` y comprobá que sigue bloqueado:

   ```bash
   kubectl run intruso --image=busybox --labels=app=intruso -n netpol-lab -- sleep 3600
   kubectl exec -n netpol-lab intruso -- wget -qO- --timeout=2 http://backend
   ```

   El segundo comando debe fallar con timeout.

4. Como en el examen el tiempo cuenta: probá cambiar el label de `intruso` en caliente y repetir el test:

   ```bash
   kubectl label pod intruso app=frontend --overwrite -n netpol-lab
   kubectl exec -n netpol-lab intruso -- wget -qO- --timeout=2 http://backend
   ```

   Ahora debería funcionar.

**Pregunta 3.1** — En esta política hay dos `podSelector` distintos. ¿Qué rol cumple cada uno?

**Pregunta 3.2** — El paso 4 demostró que el acceso cambió al instante al re-etiquetar el pod. ¿Qué te dice esto sobre cómo evalúan las NetworkPolicies la identidad de un pod?

**Pregunta 3.3** — Si `backend` escuchara también en el puerto 8080, ¿el `frontend` podría alcanzar ese puerto con esta política aplicada?

---

## Ejercicio 4 — namespaceSelector y la trampa del AND vs OR

Este es el punto que más se evalúa conceptualmente: la diferencia entre **dos elementos en la lista `from`** (OR) y **dos selectores en el mismo elemento** (AND).

1. Creá un segundo namespace con un label, y un pod cliente adentro:

   ```bash
   kubectl create namespace externo
   kubectl label namespace externo team=qa
   kubectl run cliente-qa --image=busybox --labels=app=frontend -n externo -- sleep 3600
   ```

2. Probá el acceso desde ese namespace al backend (usá el DNS name completo del Service):

   ```bash
   kubectl exec -n externo cliente-qa -- wget -qO- --timeout=2 http://backend.netpol-lab
   ```

   Debe fallar: la política del Ejercicio 3 usa un `podSelector` solo, que **únicamente selecciona pods del mismo namespace** de la política.

3. Reemplazá la política con esta variante — fijate que `namespaceSelector` y `podSelector` están en el **mismo** elemento de la lista (un solo `-`):

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-backend
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 team: qa
             podSelector:
               matchLabels:
                 app: frontend
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f allow-frontend.yaml
   ```

4. Verificá los dos orígenes:

   ```bash
   # desde el namespace externo (team=qa, app=frontend): debe FUNCIONAR
   kubectl exec -n externo cliente-qa -- wget -qO- --timeout=2 http://backend.netpol-lab

   # desde netpol-lab (app=frontend, pero el namespace no tiene team=qa): debe FALLAR
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

**Pregunta 4.1** — En el YAML del paso 3, ¿qué condición debe cumplir una conexión entrante para ser aceptada?

**Pregunta 4.2** — Si movieras el `podSelector` a un elemento separado de la lista (agregando un `-` delante), ¿cómo cambiaría el significado de la regla? ¿Quién tendría acceso entonces?

**Pregunta 4.3** — ¿Por qué en el paso 2 falló el acceso desde `externo`, si el pod `cliente-qa` tiene exactamente el label `app=frontend` que pedía la política del Ejercicio 3?

---

## Ejercicio 5 — Egress: controlar el tráfico de salida

Ahora restringí lo que `frontend` puede **iniciar** hacia afuera.

1. Aplicá un default deny de egress solo para los pods `app=frontend`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-frontend-egress
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: frontend
     policyTypes:
       - Egress
   ```

2. Probá resolver un nombre desde `frontend`:

   ```bash
   kubectl exec -n netpol-lab frontend -- nslookup backend.netpol-lab.svc.cluster.local
   ```

   Falla: el egress bloqueado incluye las consultas DNS hacia CoreDNS.

3. Reemplazá la política para permitir DNS y el acceso al backend:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-frontend-egress
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: frontend
     policyTypes:
       - Egress
     egress:
       - to:
           - podSelector:
               matchLabels:
                 app: backend
         ports:
           - protocol: TCP
             port: 80
       - ports:
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
   ```

4. Verificá que DNS y el acceso al backend funcionan, pero salir a Internet no:

   ```bash
   kubectl exec -n netpol-lab frontend -- nslookup backend.netpol-lab.svc.cluster.local
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://example.com
   ```

   Los dos primeros comandos deben funcionar; el tercero debe fallar.

5. Limpieza:

   ```bash
   kubectl delete namespace netpol-lab externo
   ```

**Pregunta 5.1** — ¿Por qué al bloquear el egress "se rompió el DNS", si el estudiante solo quería impedir conexiones HTTP salientes?

**Pregunta 5.2** — En la regla de DNS del paso 3, el elemento `egress` tiene `ports` pero no tiene `to`. ¿Qué destino permite entonces?

**Pregunta 5.3** — Un pod `A` tiene una política de egress que le permite conectarse a `B`, pero `B` tiene un default deny de ingress sin excepciones. ¿La conexión de `A` a `B` funciona? ¿Qué regla general aplica cuando hay políticas de ambos lados?

---

<details>
<summary><strong>Respuestas</strong></summary>

**1.1** — Todo el tráfico está permitido en ambas direcciones. Kubernetes es *non-isolated* por defecto: un pod solo queda aislado cuando al menos una NetworkPolicy lo selecciona, y solo en la dirección (`Ingress`/`Egress`) que esa política declare.

**1.2** — Son *namespaced*: se crean dentro de un namespace y sus `podSelector` solo seleccionan pods de ese namespace (salvo que se use `namespaceSelector`). Se verifica con `kubectl api-resources | grep networkpolic` — la columna `NAMESPACED` dice `true`.

**2.1** — Un `podSelector` vacío selecciona **todos los pods del namespace** de la política. Es decir, todos los pods de `netpol-lab` quedan aislados para ingress.

**2.2** — Al declarar `Ingress` en `policyTypes`, los pods seleccionados pasan a estar *aislados* para esa dirección: solo se permite el tráfico que alguna regla `ingress` autorice explícitamente. Como la lista `ingress` está ausente (vacía), no hay ninguna excepción, y el resultado es denegar todo.

**2.3** — Sí. La política solo declara `policyTypes: [Ingress]`, así que el egress de todos los pods sigue sin restricciones. Ojo: las respuestas a conexiones permitidas siempre vuelven — las NetworkPolicies operan sobre conexiones, no sobre paquetes individuales.

**3.1** — El `podSelector` del `spec` define a **quién protege** la política (los targets: pods con `app=backend`). El `podSelector` dentro de `ingress.from` define **desde quién se acepta** tráfico (los orígenes: pods con `app=frontend` del mismo namespace).

**3.2** — Las políticas se evalúan dinámicamente contra los **labels actuales** del pod, no contra su nombre ni su identidad en el momento de crear la política. Cualquier pod que adquiera el label correcto gana el acceso inmediatamente — por eso el control de quién puede editar labels también es parte de la seguridad.

**3.3** — No. La regla lista explícitamente `port: 80/TCP`, así que solo ese puerto queda permitido desde `frontend`; el 8080 seguiría bloqueado por el default deny. Si la regla no tuviera sección `ports`, se permitirían todos los puertos.

**4.1** — Es una condición **AND**: la conexión debe venir de un pod que tenga el label `app=frontend` **y** que además esté en un namespace con el label `team=qa`. Ambas condiciones en el mismo elemento de la lista `from` se combinan.

**4.2** — Con un `-` delante, pasan a ser **dos elementos independientes** de la lista `from`, que se evalúan como **OR**: tendría acceso (a) cualquier pod de cualquier namespace con label `team=qa` —sin importar sus labels de pod— y (b) cualquier pod con `app=frontend` del namespace `netpol-lab`. Es la trampa clásica del examen: un solo carácter cambia por completo el alcance de la regla.

**4.3** — Porque un `podSelector` usado solo (sin `namespaceSelector`) en `from` únicamente matchea pods del **mismo namespace donde vive la política** (`netpol-lab`). Los labels del pod `cliente-qa` eran correctos, pero estaba en el namespace equivocado.

**5.1** — Un default deny de egress bloquea **todas** las conexiones salientes del pod, incluidas las consultas UDP/TCP al puerto 53 de CoreDNS (que corre en `kube-system`, otro namespace). Sin DNS, incluso los destinos "permitidos" se vuelven inalcanzables por nombre. Por eso toda política de egress restrictiva debe permitir explícitamente el puerto 53.

**5.2** — Un elemento de `egress` sin `to` no restringe el destino: permite tráfico hacia **cualquier destino** (cualquier pod, namespace o IP), pero solo en los puertos listados (53 UDP/TCP). Es la forma habitual de permitir DNS sin importar dónde corra el resolver.

**5.3** — No funciona. Para que una conexión se establezca deben permitirla **ambos extremos**: la política de egress del origen **y** la política de ingress del destino. Como `B` está aislado para ingress sin excepciones, rechaza la conexión aunque `A` tenga permitido salir.

</details>

---

**Fuentes de referencia:**

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes Documentation — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Documentation — Declare Network Policy (tutorial): https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/