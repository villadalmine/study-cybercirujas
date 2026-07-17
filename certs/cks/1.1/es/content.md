# CKS 1.34 — Tema 1.1: Network Policies para restringir el acceso a nivel de cluster

## 1. Concepto

Por defecto, en un cluster de Kubernetes **todo pod puede comunicarse con cualquier otro pod**, sin restricciones, independientemente del namespace. Esto es un problema de seguridad crítico en clusters multi-tenant o cuando se ejecutan cargas de trabajo con distintos niveles de confianza (por ejemplo, un pod comprometido podría moverse lateralmente hacia el API server, hacia un namespace de otro equipo, o hacia servicios internos sensibles).

Un objeto `NetworkPolicy` es un recurso de la API de Kubernetes (`networking.k8s.io/v1`) que define reglas de firewall a nivel de pod: qué tráfico de entrada (`ingress`) y de salida (`egress`) está permitido hacia/desde un conjunto de pods seleccionados por labels.

**Punto clave para el examen**: `NetworkPolicy` es solo la especificación (API object). La aplicación real de la regla depende de que el **CNI plugin** la implemente. Si el CNI no soporta `NetworkPolicy`, el recurso se crea sin error pero **no tiene ningún efecto** — el tráfico sigue fluyendo libremente. `kubenet` no implementa NetworkPolicy. Plugins que sí lo soportan: Calico, Cilium, Weave Net, Antrea, entre otros.

Verificar el CNI en uso:

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|weave|antrea|flannel'
```

```
calico-node-4x9zq                        1/1     Running   0          10d
calico-kube-controllers-7d8f...          1/1     Running   0          10d
```

Si aparece `flannel` solo (sin Calico encima), probablemente **no** hay enforcement de NetworkPolicy.

## 2. Estructura de un NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: example-policy
  namespace: default
spec:
  podSelector:        # a qué pods se aplica esta policy (obligatorio)
    matchLabels:
      app: backend
  policyTypes:         # Ingress, Egress, o ambos
    - Ingress
    - Egress
  ingress:
    - from: [...]
      ports: [...]
  egress:
    - to: [...]
      ports: [...]
```

Reglas importantes:

- `podSelector: {}` (vacío) selecciona **todos** los pods del namespace.
- Si `policyTypes` incluye `Ingress` pero el bloque `ingress` está vacío o ausente → se deniega **todo** el ingress hacia esos pods.
- Si `policyTypes` incluye `Egress` pero el bloque `egress` está vacío o ausente → se deniega **todo** el egress desde esos pods.
- Múltiples `NetworkPolicy` que seleccionan el mismo pod son **aditivas** (unión de reglas permitidas), nunca se evalúan en orden ni se puede tener una regla "deny" explícita — todo lo no permitido queda denegado implícitamente.
- Dentro de `from`/`to`, cada elemento del array puede combinar `podSelector`, `namespaceSelector` e `ipBlock`. Si están en el **mismo item** del array, se combinan con AND. Si están en **items distintos**, se combinan con OR.

## 3. Default deny all (patrón base recomendado)

Denegar todo el ingress por defecto en un namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

Denegar todo el egress por defecto:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

Denegar ambos en una sola policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

Esto se aplica como **primer paso** en un namespace y luego se agregan policies específicas que abren solo lo necesario (whitelisting explícito).

## 4. Permitir tráfico entre pods (podSelector)

Permitir que solo pods con label `role: frontend` accedan a pods con label `app: backend` en el puerto 8080:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: prod
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
              role: frontend
      ports:
        - protocol: TCP
          port: 8080
```

## 5. Permitir tráfico desde otro namespace (namespaceSelector)

Los namespaces deben tener el label correspondiente para poder ser seleccionados:

```bash
kubectl label namespace monitoring purpose=monitoring
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-scrape
  namespace: prod
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
              purpose: monitoring
      ports:
        - protocol: TCP
          port: 9090
```

Combinando `namespaceSelector` + `podSelector` en el **mismo item** (AND lógico — el pod debe estar en un namespace con ese label **y** tener ese label de pod):

```yaml
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              purpose: monitoring
          podSelector:
            matchLabels:
              app: prometheus
```

## 6. Restringir por rango de IP (ipBlock)

Útil para restringir acceso a/desde IPs externas al cluster (por ejemplo, un servicio legacy on-prem o para bloquear rangos concretos):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-cidr
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: api-gateway
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 10.0.0.0/16
            except:
              - 10.0.5.0/24
```

`ipBlock` opera sobre IPs de origen/destino "crudas", no reconoce Services de Kubernetes (no hay resolución de DNS ni ClusterIP a nivel de policy).

## 7. Egress controlado (con DNS permitido)

Un error común en el examen: aplicar `default-deny-egress` y no permitir DNS, lo que rompe la resolución de nombres para toda app que dependa de ella. Hay que permitir explícitamente salida al `kube-dns`/`coredns`:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
kubectl get svc -n kube-system kube-dns
```

```
NAME       TYPE        CLUSTER-IP    PORT(S)
kube-dns   ClusterIP   10.96.0.10    53/UDP,53/TCP,9153/TCP
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: prod
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

Y luego una policy adicional que permita el egress específico de la app (por ejemplo, hacia una base de datos):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-db
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
```

## 8. Verificación y troubleshooting

```bash
kubectl get networkpolicy -n prod
```

```
NAME                        POD-SELECTOR   AGE
default-deny-all            <none>         2m
allow-frontend-to-backend    app=backend    1m
allow-dns-egress            <none>         30s
```

```bash
kubectl describe networkpolicy allow-frontend-to-backend -n prod
```

```
Name:         allow-frontend-to-backend
Namespace:    prod
Spec:
  PodSelector:     app=backend
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      PodSelector: role=frontend
  Policy Types: Ingress
```

Probar conectividad efectiva desde un pod (método rápido en el examen, sin instalar herramientas extra):

```bash
kubectl run tmp-test --rm -it --image=busybox --restart=Never -- wget -qO- --timeout=2 http://backend-svc:8080
```

Si la policy bloquea correctamente, el comando debe colgarse hasta timeout (`wget: download timed out`). Si responde, la regla no está aplicándose (revisar CNI, labels de pods/namespaces, o si falta el `policyTypes` correcto).

## 9. Buenas prácticas para el examen

- Aplicar **default-deny** (ingress y egress) en cada namespace de producción y luego permitir explícitamente solo lo necesario — modelo *whitelist*.
- Verificar labels reales de pods/namespaces con `kubectl get pods --show-labels` / `kubectl get ns --show-labels` antes de escribir selectors — un typo en el label deja la policy sin efecto silenciosamente.
- Recordar que `ingress` y `egress` son independientes: una policy que solo restringe `Ingress` no toca el `Egress` del pod (y viceversa), a menos que `policyTypes` incluya ambos.
- `NetworkPolicy` no soporta lógica de "deny" explícita ni prioridades entre policies — solo unión de reglas *allow*.
- No confundir con `CiliumNetworkPolicy`/`GlobalNetworkPolicy` (CRDs propios de Cilium/Calico) que agregan capacidades extra (L7, FQDN-based egress, deny explícito) pero no son parte del currículum base de la API estándar — el examen se centra en el recurso `networking.k8s.io/v1`.
- Confirmar siempre que el CNI soporta enforcement antes de asumir que una policy protege algo.

## Referencias

- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes docs — Declare Network Policy (tutorial): https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- Kubernetes API reference — NetworkPolicy: https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Calico docs — Network Policy: https://docs.tigera.io/calico/latest/network-policy/
- Cilium docs — Network Policy: https://docs.cilium.io/en/stable/security/policy/