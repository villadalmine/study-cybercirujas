# 1.1 Usar Network Security Policies para restringir el acceso a nivel de clúster

## Por qué esto importa

Por defecto, la red de Kubernetes es **plana y totalmente permisiva**: cada Pod puede alcanzar a cualquier otro Pod en cualquier namespace, además de cualquier endpoint externo al que el nodo pueda enrutar. No hay segmentación incorporada. Un único Pod frontend comprometido puede, por lo tanto, alcanzar tu base de datos, el servicio interno de administración en otro namespace, el endpoint de metadatos del proveedor cloud o el kube-apiserver.

`NetworkPolicy` es la respuesta nativa de Kubernetes: un firewall L3/L4 expresado como un objeto de API con namespace, seleccionado por labels en lugar de por IPs. En los escenarios de CKS es la herramienta principal para implementar **tráfico este-oeste con mínimo privilegio** y para bloquear las rutas de egress usadas en ataques de robo de credenciales.

## Requisito previo: el plugin CNI debe aplicar las políticas

Los objetos `NetworkPolicy` son almacenados por el API server sin importar si algo los aplica o no. Si tu plugin CNI no implementa la funcionalidad, `kubectl apply` tiene éxito y **nada queda bloqueado** — una peligrosa falsa sensación de seguridad.

| Plugin CNI | Soporte de NetworkPolicy |
|---|---|
| Calico | Sí (además de sus propios CRDs) |
| Cilium | Sí (además de `CiliumNetworkPolicy`) |
| Weave Net | Sí |
| Antrea, Kube-router, OVN-Kubernetes | Sí |
| Flannel (solo) | **No** |

Verificación rápida de lo que está instalado:

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|weave|antrea|flannel'
```

```
calico-kube-controllers-7d4b8c9f5-2xq7m   1/1     Running   0     4d
calico-node-8fkzp                          1/1     Running   0     4d
calico-node-lm2vd                          1/1     Running   0     4d
```

## Anatomía de una NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-frontend
  namespace: prod
spec:
  podSelector:                 # WHICH pods this policy protects (in this namespace)
    matchLabels:
      app: api
  policyTypes:                 # WHICH directions this policy governs
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
```

Cuatro reglas gobiernan la semántica, y todos los errores del examen vienen de olvidar alguna de ellas:

1. **Con namespace y guiada por labels.** Una política solo protege a los Pods de su propio namespace, elegidos por `spec.podSelector`. Un selector vacío (`podSelector: {}`) significa *todos los Pods de este namespace*.
2. **Seleccionar un Pod lo cambia a denegar-por-defecto** para los `policyTypes` listados. Un Pod que no es seleccionado por ninguna política permanece totalmente abierto.
3. **Las políticas son puramente aditivas (solo lista de permitidos).** No existe una regla `deny`. Si dos políticas seleccionan el mismo Pod, se aplica la unión de sus permisos. No podés "restar" acceso con una segunda política.
4. **`policyTypes` se infiere si se omite:** `Ingress` siempre se incluye; `Egress` solo si existe un bloque `egress`. Escribí siempre `policyTypes` de forma explícita — una política con únicamente reglas de `ingress` **no** restringe el egress.

### La trampa del selector: AND vs OR

Este es el error más común de todos. Compará la indentación del YAML:

```yaml
# OR — pods labelled app=frontend in ANY namespace,
#      OR any pod in a namespace labelled env=trusted
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: frontend
      - namespaceSelector:
          matchLabels:
            env: trusted
```

```yaml
# AND — ONLY pods labelled app=frontend that live
#       in a namespace labelled env=trusted
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: frontend
        namespaceSelector:
          matchLabels:
            env: trusted
```

Dos elementos de lista (`-`) = OR. Dos claves dentro de un mismo elemento de lista = AND. Notá también: un `podSelector` a secas dentro de `from`/`to` significa *el propio namespace de la política*; para permitir un Pod de otro namespace **tenés que** agregar un `namespaceSelector`.

Kubernetes etiqueta automáticamente cada namespace con `kubernetes.io/metadata.name: <namespace>`, así que podés apuntar a un namespace por nombre sin editarlo:

```yaml
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: monitoring
```

## Bases de denegación por defecto

Empezá cada namespace endurecido desde una postura de denegar todo, y después abrí agujeros precisos.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}              # every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
  # no ingress/egress blocks at all => deny everything both ways
```

Variantes que deberías poder escribir de memoria:

```yaml
# Deny all ingress only
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

```yaml
# Allow all egress (explicit permit — useful to override a broad deny in a legacy setup)
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - {}
```

### Volvé a permitir siempre el DNS

Una política de denegar-todo-el-egress rompe la resolución de nombres, y el síntoma parece una falla total de red. Todo servicio que deba resolver nombres necesita egress hacia CoreDNS en el puerto 53 (tanto UDP como TCP — TCP se usa para respuestas grandes):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

## Restringir el acceso a nivel de clúster

### Aislar un namespace de todos los demás

Permitir el tráfico dentro del namespace mientras se rechaza todo lo que venga de afuera:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace-only
  namespace: payments
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}      # every pod in namespace "payments"
```

### Bloquear el endpoint de metadatos del cloud

`169.254.169.254` sirve credenciales de instancia en AWS/GCP/Azure. Alcanzarlo desde un Pod comprometido es una ruta clásica de escalada de privilegios (SSRF → rol IAM del nodo). Denegalo con una cláusula `except` manteniendo el egress general a internet:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

`ipBlock` está pensado para CIDRs **externos al clúster**. Debido al comportamiento de SNAT/masquerading en la mayoría de los CNIs, hacer coincidir IPs de Pods con `ipBlock` no es confiable — usá `podSelector`/`namespaceSelector` para el tráfico dentro del clúster.

### Restringir el egress hacia el kube-apiserver

Para impedir que las cargas de trabajo hablen directamente con el control plane, denegá el egress al endpoint del API server. Primero encontrá la dirección real — el Service `kubernetes` en `default` es una ClusterIP que hace DNAT hacia la dirección del nodo/VIP:

```bash
kubectl get endpoints kubernetes -n default
```

```
NAME         ENDPOINTS            AGE
kubernetes   192.168.56.10:6443   12d
```

Después, o bien omití ese CIDR de tu lista de permitidos, o excluilo explícitamente:

```yaml
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 192.168.56.10/32
              - 169.254.169.254/32
```

Como la evaluación de la política ocurre sobre la **IP de destino Pod/host post-DNAT**, nunca escribas reglas contra ClusterIPs de Services — apuntá siempre a los Pods de respaldo o a la dirección del endpoint.

### Rangos de puertos

Para un rango contiguo, usá `endPort` (estable desde v1.25) en lugar de listar cada puerto:

```yaml
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: gateway
      ports:
        - protocol: TCP
          port: 8000
          endPort: 8100
```

`port` también puede ser un **puerto con nombre** tomado del `containerPort.name` del contenedor destino, lo que sobrevive a una renumeración de puertos.

## Verificar la aplicación

Escribir la política es la mitad de la tarea; el examen espera que demuestres que funciona.

```bash
# Inspect what is actually applied
kubectl get netpol -n prod
kubectl describe netpol default-deny-all -n prod
```

```
Name:         default-deny-all
Namespace:    prod
Created on:   2026-07-28 10:14:02 +0000 UTC
Spec:
  PodSelector:     <none> (Allowing the specific traffic to all pods in this namespace)
  Allowing ingress traffic:
    <none> (Selected pods are isolated for ingress connectivity)
  Allowing egress traffic:
    <none> (Selected pods are isolated for egress connectivity)
  Policy Types: Ingress, Egress
```

Probá la conectividad desde un Pod descartable:

```bash
kubectl run probe -n prod --rm -it --restart=Never \
  --image=busybox:1.36 -- wget -qO- --timeout=2 http://api:8080/healthz
```

El tráfico bloqueado expira por timeout en lugar de ser rechazado (los paquetes se descartan, no se rechazan):

```
wget: download timed out
pod "probe" deleted
pod prod/probe terminated (Error)
```

El tráfico permitido responde de inmediato:

```
ok
pod "probe" deleted
```

Probá desde un Pod *con labels* para validar la coincidencia de selectores, y desde otro namespace para validar el aislamiento:

```bash
kubectl run probe -n prod --labels=app=frontend --rm -it --restart=Never \
  --image=busybox:1.36 -- nc -zv -w 2 api 8080
kubectl run probe -n staging --rm -it --restart=Never \
  --image=busybox:1.36 -- nc -zv -w 2 api.prod.svc.cluster.local 8080
```

## Lista de verificación para troubleshooting

| Síntoma | Causa probable |
|---|---|
| La política se aplicó, nada se bloquea | El CNI no aplica NetworkPolicy |
| Todo se rompe después del default-deny | Falta la regla de egress de DNS (puerto 53 UDP **y** TCP) |
| El tráfico entre namespaces sigue denegado | Solo se usó `podSelector` — también hace falta `namespaceSelector` |
| Se permite tráfico inesperado | Otra política selecciona los mismos Pods; los efectos son aditivos |
| La regla de egress hacia un Service no funciona | La regla apunta a la ClusterIP; debe apuntar a los Pods de respaldo post-DNAT |
| El ingress desde un Pod no queda restringido | El Pod origen usa `hostNetwork: true`, o el tráfico se origina en el nodo (health probes) |
| La política se ignora por completo | Namespace equivocado, o `policyTypes` omitió la dirección que pretendías |

## Consejos para el examen

- Creá siempre la política de **default-deny** más un **allow de DNS** explícito como tu par de base.
- Revisá los labels del namespace (`kubectl get ns --show-labels`) antes de escribir un `namespaceSelector`; agregá uno con `kubectl label ns staging env=trusted` si hace falta.
- Nunca memorices YAML desde cero bajo presión de tiempo — copiá el ejemplo canónico de la documentación de Kubernetes (página Network Policies) y editalo.
- Confirmá tu trabajo con un Pod de prueba; una política que silenciosamente no coincide con nada vale cero.
- Tené en cuenta que las APIs más nuevas con alcance de clúster `AdminNetworkPolicy` / `BaselineAdminNetworkPolicy` (grupo `policy.networking.k8s.io`, implementadas por Calico, Cilium y OVN-Kubernetes) agregan acciones reales de `Deny` y `Pass` y se evalúan *antes* que las `NetworkPolicy` con namespace. Son una extensión fuera del árbol principal, así que el estándar `networking.k8s.io/v1` sigue siendo el objetivo del examen.

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes API Reference — NetworkPolicy v1 — https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Kubernetes — Cluster Networking — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes — Automatic labelling of namespaces — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/#automatic-labelling
- Kubernetes — Network Policy targeting a range of ports — https://kubernetes.io/docs/concepts/services-networking/network-policies/#targeting-a-range-of-ports
- Kubernetes — Admin Network Policy (SIG Network Policy API) — https://network-policy-api.sigs.k8s.io/
- Calico — Network Policy — https://docs.tigera.io/calico/latest/network-policy/
- Cilium — Network Policy — https://docs.cilium.io/en/stable/security/policy/