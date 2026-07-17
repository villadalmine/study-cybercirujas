# CKS 1.1 – Use Network security policies to restrict cluster level access

**Dominio:** Cluster Setup · **Peso en el examen:** 3
**Fuente de referencia:** [CNCF CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

## Objetivo

Practicar el uso del recurso `NetworkPolicy` de Kubernetes para restringir el tráfico de red a nivel de Pod y namespace, entendiendo el comportamiento por defecto del cluster, las reglas de `ingress`/`egress`, y las semánticas AND/OR de los selectores.

## Prerrequisitos

- Un cluster con un CNI que implemente `NetworkPolicy` (Calico, Cilium, Antrea, WeaveNet). CNIs como el `bridge`/`kindnet` básico **no** aplican estas políticas: los manifests se crean sin error pero el tráfico no se restringe.
- `kubectl` configurado contra el cluster.
- Permisos para crear namespaces y pods.

---

## Ejercicio 1: Comportamiento por defecto (allow-all)

1. Creá un namespace de trabajo y un pod servidor con su Service:
   ```bash
   kubectl create namespace netpol-lab
   kubectl run web --image=nginx:1.27 --port=80 -n netpol-lab --labels=app=web
   kubectl expose pod web --port=80 --name=web-svc -n netpol-lab
   ```
2. Creá un pod cliente sin ninguna etiqueta especial:
   ```bash
   kubectl run client --image=busybox:1.36 -n netpol-lab --labels=role=other --command -- sleep 3600
   ```
3. Verificá conectividad desde `client` hacia `web-svc`:
   ```bash
   kubectl exec -n netpol-lab client -- wget -qO- --timeout=2 web-svc
   ```
4. Confirmá que no existe ningún `NetworkPolicy` en el namespace:
   ```bash
   kubectl get networkpolicy -n netpol-lab
   ```

**Preguntas de comprobación:**
- ¿Qué devolvió el `wget` del paso 3 y por qué, dado que no hay ningún `NetworkPolicy` aplicado?
- Si el CNI del cluster no soporta `NetworkPolicy`, ¿qué pasaría en los ejercicios siguientes al aplicar las políticas de deny?

---

## Ejercicio 2: Default-deny de ingress

1. Aplicá una política que seleccione todos los pods del namespace y bloquee todo el ingress:
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
   ```bash
   kubectl apply -f default-deny-ingress.yaml
   ```
2. Repetí la prueba de conectividad:
   ```bash
   kubectl exec -n netpol-lab client -- wget -qO- --timeout=2 web-svc
   ```
3. Inspeccioná la política aplicada:
   ```bash
   kubectl describe networkpolicy default-deny-ingress -n netpol-lab
   ```

**Preguntas de comprobación:**
- ¿Qué significa `podSelector: {}` en `spec.podSelector`?
- ¿Por qué alcanza con declarar `policyTypes: [Ingress]` y no hace falta listar reglas de `ingress` para bloquear todo el tráfico entrante?

---

## Ejercicio 3: Permitir ingress solo desde pods con una label específica

1. Creá un pod "frontend" autorizado:
   ```bash
   kubectl run frontend --image=busybox:1.36 -n netpol-lab --labels=role=frontend --command -- sleep 3600
   ```
2. Aplicá una política que permita ingress a `web` únicamente desde pods con `role=frontend`, puerto 80:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-web
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: web
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
3. Probá desde ambos pods clientes:
   ```bash
   kubectl exec -n netpol-lab client -- wget -qO- --timeout=2 web-svc
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 web-svc
   ```

**Preguntas de comprobación:**
- ¿Por qué `client` sigue sin poder conectarse pero `frontend` sí, si ambas políticas (`default-deny-ingress` y `allow-frontend-to-web`) siguen activas al mismo tiempo?
- Si dos `NetworkPolicy` distintos seleccionan el mismo pod de destino con reglas de `ingress`, ¿cómo se combinan entre sí?

---

## Ejercicio 4: Restringir por namespace con `namespaceSelector` (AND vs OR)

1. Creá un segundo namespace etiquetado y un pod con la misma label `role=frontend`:
   ```bash
   kubectl create namespace partners
   kubectl label namespace partners team=partners
   kubectl run partner-client --image=busybox:1.36 -n partners --labels=role=frontend --command -- sleep 3600
   ```
2. Probá si `partner-client` puede llegar a `web-svc.netpol-lab`:
   ```bash
   kubectl exec -n partners partner-client -- wget -qO- --timeout=2 web-svc.netpol-lab.svc.cluster.local
   ```
3. Agregá una política que combine `namespaceSelector` y `podSelector` en la **misma** entrada de `from`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-partners-frontend
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
     - Ingress
     ingress:
     - from:
       - namespaceSelector:
           matchLabels:
             team: partners
         podSelector:
           matchLabels:
             role: frontend
       ports:
       - protocol: TCP
         port: 80
   ```
4. Repetí la prueba del paso 2.

**Preguntas de comprobación:**
- En el paso 2, antes de aplicar la nueva política, ¿por qué falla la conexión aunque `partner-client` tenga `role=frontend`, la misma label que `frontend` en el Ejercicio 3?
- En el YAML del paso 3, `namespaceSelector` y `podSelector` están dentro del mismo ítem de la lista `from`. ¿Qué diferencia de comportamiento habría si estuvieran en dos ítems separados de esa lista (uno con `- namespaceSelector: ...` y otro con `- podSelector: ...`)?

---

## Ejercicio 5: Default-deny de egress y permitir DNS

1. Bloqueá todo el tráfico saliente del namespace:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-egress
     namespace: netpol-lab
   spec:
     podSelector: {}
     policyTypes:
     - Egress
   ```
2. Verificá que incluso `frontend` (que ya tenía ingress permitido) deja de poder resolver DNS y conectarse:
   ```bash
   kubectl exec -n netpol-lab frontend -- nslookup web-svc
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 web-svc
   ```
3. Identificá las labels reales de CoreDNS en tu cluster y permitile egress DNS a todos los pods del namespace:
   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels
   ```
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns-egress
     namespace: netpol-lab
   spec:
     podSelector: {}
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
   ```
4. Permitile a `frontend` egress hacia `web` en el puerto 80:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-egress-to-web
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         role: frontend
     policyTypes:
     - Egress
     egress:
     - to:
       - podSelector:
           matchLabels:
             app: web
       ports:
       - protocol: TCP
         port: 80
   ```
5. Repetí las pruebas del paso 2.

**Preguntas de comprobación:**
- ¿Por qué `nslookup` falla en el paso 2 si nunca tocaste el ingress de CoreDNS, solo el egress de `frontend`?
- En la política `allow-dns-egress`, ¿por qué se usa `namespaceSelector: {}` combinado con `podSelector` en vez de solo `podSelector`?
- Después de aplicar los pasos 3 y 4, ¿puede `frontend` hacer un `wget` a una IP pública de internet? Justificá.

---

## Ejercicio 6: Auditoría y limpieza

1. Listá todas las políticas activas del namespace y revisá qué pods selecciona cada una:
   ```bash
   kubectl get networkpolicy -n netpol-lab -o wide
   kubectl get networkpolicy -n netpol-lab -o yaml
   ```
2. Confirmá con `kubectl describe pod` que las políticas efectivamente aplican a los pods esperados (columna de labels).
3. Eliminá los recursos del laboratorio:
   ```bash
   kubectl delete namespace netpol-lab partners
   ```

**Preguntas de comprobación:**
- Si el examen te pide "restringir el acceso a nivel de cluster" y no tenés certeza de que el CNI soporte `NetworkPolicy`, ¿qué comando o evidencia buscarías antes de invertir tiempo escribiendo políticas?
- ¿Qué diferencia práctica hay entre no tener ningún `NetworkPolicy` en un namespace y tener un `default-deny-ingress` sin ninguna regla `allow` adicional?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
- El `wget` devuelve el HTML de nginx (HTTP 200) porque, sin ningún `NetworkPolicy` presente, Kubernetes permite todo el tráfico por defecto (allow-all implícito), tanto de ingress como de egress.
- Si el CNI no implementa `NetworkPolicy`, los objetos se crean y quedan almacenados en `etcd` sin error, pero el plugin nunca instala las reglas de filtrado (iptables/eBPF), así que el tráfico seguiría permitido en todos los ejercicios siguientes pese a que `kubectl describe` muestre la política "aplicada".

**Ejercicio 2**
- `podSelector: {}` selecciona **todos** los pods del namespace (selector vacío = matchea todo), a diferencia de omitir el campo, que sería inválido, o de un `matchLabels` con claves específicas.
- Cuando `policyTypes` incluye `Ingress` pero no se define ninguna regla `ingress`, el efecto es "denegar todo el ingress" para los pods seleccionados: la ausencia de reglas equivale a una lista vacía de excepciones permitidas.

**Ejercicio 3**
- Las `NetworkPolicy` en Kubernetes son **aditivas**: cuando varias políticas seleccionan el mismo pod, el tráfico se permite si **al menos una** regla de **alguna** política lo autoriza (unión/OR). `default-deny-ingress` no agrega excepciones, pero `allow-frontend-to-web` sí agrega una: tráfico desde pods con `role=frontend` al puerto 80. Por eso `frontend` pasa y `client` (con `role=other`) sigue bloqueado.
- Se combinan por unión (OR): el resultado final es el conjunto de todas las reglas `allow` de todas las políticas que seleccionan ese pod de destino. No hay forma de que una política "deniegue explícitamente" algo que otra permite.

**Ejercicio 4**
- Porque en la política del Ejercicio 3 el `from` solo tiene `podSelector: {matchLabels: {role: frontend}}`, **sin** `namespaceSelector`. Un `podSelector` solo (sin `namespaceSelector` en la misma entrada) se evalúa **únicamente dentro del namespace donde vive el `NetworkPolicy`** (`netpol-lab`). Por eso un pod con la misma label pero en el namespace `partners` no matchea esa regla.
- Con ambos selectores en el **mismo ítem** de `from`, se aplica lógica **AND**: el origen debe cumplir namespace `team=partners` **y** label `role=frontend` a la vez. Si estuvieran en **ítems separados** de la lista (`from: [{namespaceSelector: ...}, {podSelector: ...}]`), sería lógica **OR**: se permitiría tráfico desde *cualquier* pod del namespace `partners` (sin importar su label) **o** desde cualquier pod con `role=frontend` en *cualquier namespace* (incluyendo `netpol-lab`), lo cual es una política mucho más permisiva y un error común en el examen.

**Ejercicio 5**
- Porque CoreDNS corre en el namespace `kube-system`, fuera del pod `frontend`. Bloquear el **egress** de `frontend` le impide iniciar la conexión UDP/TCP hacia el Service `kube-dns`, sin importar que el ingress de CoreDNS esté abierto: ambos lados (egress del origen e ingress del destino) deben permitir el tráfico.
- `podSelector` sin `namespaceSelector` se limita al namespace de la política (`netpol-lab`), pero CoreDNS vive en `kube-system`. Se necesita `namespaceSelector: {}` (matchea cualquier namespace) junto con el `podSelector` de la label de CoreDNS para autorizar tráfico cross-namespace hacia ese Pod específico.
- No. El `default-deny-egress` sigue activo y solo se agregaron dos excepciones puntuales (DNS y `web-svc` al puerto 80). Cualquier otro destino, incluida una IP pública de internet, sigue bloqueado porque ninguna regla `allow` lo cubre.

**Ejercicio 6**
- Conviene primero identificar el CNI instalado (`kubectl get pods -n kube-system`, buscando Calico/Cilium/Antrea/WeaveNet) y, si es posible, hacer una prueba rápida: aplicar un `default-deny-ingress` de prueba y confirmar que efectivamente corta la conectividad antes de construir políticas más complejas. Si el cluster usa un CNI que no soporta `NetworkPolicy` (por ejemplo kindnet básico), hay que dejarlo documentado como limitación, ya que no hay forma de lograr el aislamiento solo con manifests.
- Sin ningún `NetworkPolicy`, el tráfico es allow-all (ingress y egress libres). Con un `default-deny-ingress` sin reglas `allow`, el ingress queda completamente bloqueado para esos pods (egress no se ve afectado salvo que también se declare `Egress` en `policyTypes`), por lo que ningún otro pod puede iniciarles conexiones, aunque ellos sí puedan iniciar conexiones salientes.

</details>