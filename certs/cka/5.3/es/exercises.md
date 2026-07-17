# CKA 5.3 — Service types y Endpoints: ClusterIP, NodePort, LoadBalancer

## Prerrequisitos

- Cluster con al menos 2 nodes worker (para probar NodePort correctamente).
- `kubectl` configurado contra el cluster.
- Namespace de trabajo, por ejemplo `svc-lab`: `kubectl create namespace svc-lab`.

---

## Ejercicio 1 — ClusterIP: exponer un Deployment dentro del cluster

1. Creá un Deployment de prueba con 3 réplicas:
   ```bash
   kubectl create deployment web --image=nginx:alpine --replicas=3 -n svc-lab
   ```

2. Verificá que los Pods tengan la label que el Deployment les asigna automáticamente:
   ```bash
   kubectl get pods -n svc-lab --show-labels
   ```

3. Exponé el Deployment con un Service de tipo `ClusterIP` (tipo por defecto):
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 -n svc-lab
   ```

4. Inspeccioná el Service creado:
   ```bash
   kubectl get svc web -n svc-lab -o wide
   kubectl describe svc web -n svc-lab
   ```
   Prestá atención a los campos `Type`, `IP` (ClusterIP), `Port`, `TargetPort` y `Endpoints`.

5. Probá la conectividad desde un Pod temporal dentro del cluster:
   ```bash
   kubectl run tmp-curl --image=busybox:1.36 --rm -it --restart=Never -n svc-lab -- \
     wget -qO- http://web.svc-lab.svc.cluster.local
   ```

6. Escalá el Deployment a 5 réplicas y confirmá que el Service actualiza sus Endpoints sin que cambie su IP ni su definición:
   ```bash
   kubectl scale deployment web --replicas=5 -n svc-lab
   kubectl get endpoints web -n svc-lab
   ```

**Preguntas de comprensión — Ejercicio 1**

1. ¿Cómo decide un Service de tipo `ClusterIP` a qué Pods enviar tráfico?
2. ¿Por qué la ClusterIP no cambia aunque se escale o se reemplace el Deployment?
3. ¿Qué componente del nodo es responsable de programar las reglas (iptables/IPVS) que implementan el balanceo hacia los Pods detrás del Service?

---

## Ejercicio 2 — NodePort: exponer el Service fuera del cluster

1. Cambiá el `type` del Service `web` a `NodePort` editándolo directamente:
   ```bash
   kubectl patch svc web -n svc-lab -p '{"spec": {"type": "NodePort"}}'
   ```

2. Consultá qué puerto de nodo (rango por defecto 30000-32767) fue asignado:
   ```bash
   kubectl get svc web -n svc-lab
   ```

3. Obtené la IP de un nodo worker y probá el acceso desde fuera del Pod network, usando esa IP y el `nodePort`:
   ```bash
   kubectl get nodes -o wide
   curl http://<NODE_IP>:<NODE_PORT>
   ```

4. Repetí el `curl` contra la IP de un nodo *distinto* al que corre alguno de los Pods `web`. Confirmá que también responde.

5. Borrá el Service y volvé a crearlo fijando explícitamente un `nodePort` dentro del rango permitido:
   ```bash
   kubectl delete svc web -n svc-lab
   kubectl expose deployment web --port=80 --target-port=80 --type=NodePort -n svc-lab --dry-run=client -o yaml > web-nodeport.yaml
   ```
   Editá el YAML generado para agregar `nodePort: 30080` bajo `spec.ports[0]`, aplicalo y confirmá:
   ```bash
   kubectl apply -f web-nodeport.yaml
   kubectl get svc web -n svc-lab
   ```

**Preguntas de comprensión — Ejercicio 2**

1. Un Service `NodePort` sigue teniendo una ClusterIP asignada: ¿verdadero o falso? ¿Por qué?
2. ¿Qué pasa si accedés al `nodePort` de un nodo donde ninguno de los Pods del Service está corriendo?
3. ¿Qué error da Kubernetes si intentás fijar un `nodePort` fuera del rango 30000-32767 (rango por defecto)?

---

## Ejercicio 3 — LoadBalancer y comparación entre tipos

1. Cambiá el Service a tipo `LoadBalancer`:
   ```bash
   kubectl patch svc web -n svc-lab -p '{"spec": {"type": "LoadBalancer"}}'
   kubectl get svc web -n svc-lab -w
   ```

2. Observá el campo `EXTERNAL-IP`:
   - Si el cluster corre en un cloud provider con integración (AWS, GCP, Azure), eventualmente se asigna una IP/hostname externo real.
   - Si es un cluster local (kind, minikube, kubeadm sin cloud-controller-manager), el `EXTERNAL-IP` queda en `<pending>` indefinidamente porque no hay ningún controlador que satisfaga la solicitud.

3. Describí el Service y confirmá que sigue teniendo asignado un `nodePort`, aunque el tipo sea `LoadBalancer`:
   ```bash
   kubectl describe svc web -n svc-lab
   ```

4. (Solo si tenés MetalLB u otro load-balancer controller instalado) Verificá los eventos del Service para ver cómo se satisface la asignación de IP:
   ```bash
   kubectl get events -n svc-lab --field-selector involvedObject.name=web
   ```

5. Completá la siguiente tabla en base a lo observado en los Ejercicios 1-3:

   | Type | Accesible desde | Requiere componente externo | Puerto de nodo |
   |---|---|---|---|
   | ClusterIP | ? | ? | ? |
   | NodePort | ? | ? | ? |
   | LoadBalancer | ? | ? | ? |

**Preguntas de comprensión — Ejercicio 3**

1. ¿Por qué un Service `LoadBalancer` en un cluster sin cloud-controller-manager queda con `EXTERNAL-IP: <pending>`?
2. ¿Es correcto decir que `LoadBalancer` reemplaza la funcionalidad de `NodePort`, o la extiende?
3. ¿Qué tipo de Service usarías para exponer una base de datos que solo debe ser accedida por otros Pods del mismo cluster, y por qué?

---

## Ejercicio 4 — Endpoints y EndpointSlices

1. Listá los Endpoints del Service `web` y compará con los Pods reales:
   ```bash
   kubectl get endpoints web -n svc-lab -o yaml
   kubectl get pods -n svc-lab -o wide
   ```

2. Listá el objeto EndpointSlice equivalente (API más moderna que reemplaza gradualmente a Endpoints para clusters grandes):
   ```bash
   kubectl get endpointslices -n svc-lab
   kubectl describe endpointslice -n svc-lab -l kubernetes.io/service-name=web
   ```

3. Rompé intencionalmente el `readinessProbe` de uno de los Pods (o directamente eliminá un Pod y observá el reemplazo) y mirá cómo cambian los Endpoints en tiempo real:
   ```bash
   kubectl delete pod -n svc-lab -l app=web --field-selector status.phase=Running -o name | head -n1 | xargs kubectl delete -n svc-lab
   kubectl get endpoints web -n svc-lab -w
   ```
   Confirmá que un Pod `NotReady` (por probe fallido) desaparece de la lista de Endpoints aunque el Pod siga existiendo.

4. Creá un Service sin selector, y un objeto `Endpoints` manual apuntando a una IP externa (por ejemplo, para integrar un servicio legacy fuera del cluster):
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: external-db
     namespace: svc-lab
   spec:
     ports:
       - port: 5432
         targetPort: 5432
   ---
   apiVersion: v1
   kind: Endpoints
   metadata:
     name: external-db
     namespace: svc-lab
   subsets:
     - addresses:
         - ip: 10.0.0.50
       ports:
         - port: 5432
   ```
   Aplicá el manifiesto y confirmá con `kubectl get endpoints external-db -n svc-lab` que Kubernetes no gestiona automáticamente esos Endpoints (porque el Service no tiene `selector`).

**Preguntas de comprensión — Ejercicio 4**

1. ¿Qué relación hay entre el `selector` de un Service y el contenido del objeto `Endpoints` con el mismo nombre?
2. ¿Por qué un Pod que está `Running` pero falla su `readinessProbe` deja de aparecer en los Endpoints del Service?
3. ¿Para qué sirve crear un Service sin `selector` junto con un objeto `Endpoints` manual?
4. ¿Qué ventaja tiene `EndpointSlice` sobre el objeto `Endpoints` clásico en clusters con muchos Pods detrás de un mismo Service?

---

## Ejercicio 5 — Limpieza

1. Eliminá todos los recursos creados en el namespace de laboratorio:
   ```bash
   kubectl delete namespace svc-lab
   ```

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**

1. El Service usa el campo `spec.selector` para hacer match contra las labels de los Pods; todos los Pods cuyas labels coincidan pasan a formar parte de los Endpoints del Service, sin importar de qué Deployment/ReplicaSet provengan.
2. La ClusterIP se asigna al objeto Service en sí (desde el rango `service-cluster-ip-range` del cluster) y es independiente del ciclo de vida de los Pods. Escalar, reiniciar o reemplazar Pods solo cambia la lista de Endpoints; el Service y su IP virtual permanecen estables.
3. `kube-proxy`, corriendo en cada nodo, observa los objetos Service/Endpoints vía el API server y programa las reglas de `iptables` (o `IPVS`, según el modo configurado) que redirigen el tráfico dirigido a la ClusterIP hacia una de las IPs de Pod backend.

**Ejercicio 2**

1. Verdadero. `NodePort` es un superset de `ClusterIP`: Kubernetes sigue asignando una ClusterIP normal y, además, abre el mismo puerto (`nodePort`) en todos los nodos del cluster, redirigiendo hacia esa ClusterIP.
2. Igual responde correctamente. `kube-proxy` en *cada* nodo programa las mismas reglas de reenvío hacia los Pods backend, sin importar en qué nodo estén corriendo esos Pods; el tráfico se reenvía a través de la red del cluster hasta llegar al Pod correcto.
3. Un error de validación del API server indicando que el valor está fuera del rango permitido (por defecto `30000-32767`, configurable vía `--service-node-port-range` en el kube-apiserver).

**Ejercicio 3**

1. Porque `LoadBalancer` depende de un controlador externo (cloud-controller-manager del proveedor cloud, o algo como MetalLB en on-prem) que observe Services de tipo `LoadBalancer` y aprovisione un balanceador real, asignando luego su IP/hostname al campo `status.loadBalancer`. Sin ese controlador, nadie satisface la solicitud y el campo queda `<pending>` indefinidamente.
2. La extiende. `LoadBalancer` no reemplaza el mecanismo de `NodePort`: internamente sigue usando un `nodePort` (y una ClusterIP) como target al que el balanceador externo reenvía el tráfico.
3. `ClusterIP`, porque no necesita exponer el servicio fuera del cluster; es el tipo más restrictivo y evita abrir superficie de ataque innecesaria en los nodos o hacia internet.

**Ejercicio 4**

1. El controller de Endpoints (parte del `kube-controller-manager`) observa los Pods que hacen match con el `selector` del Service y mantiene sincronizado un objeto `Endpoints` (mismo `name`/`namespace` que el Service) con las IPs y puertos de esos Pods. Si el Service no tiene `selector`, ese objeto no se gestiona automáticamente.
2. Los Endpoints solo incluyen Pods considerados "listos" para recibir tráfico. El `readinessProbe` es justamente el mecanismo que le indica al kubelet (y de ahí al controller de Endpoints) si el Pod está en condiciones de servir requests; un Pod `Running` pero `NotReady` se excluye de los Endpoints para evitar enviarle tráfico mientras no esté preparado (por ejemplo, durante un warm-up).
3. Permite usar el mecanismo de Service (DNS interno, ClusterIP estable) para enrutar tráfico hacia destinos que no son Pods gestionados por Kubernetes, como una base de datos externa, un servicio legacy en otra VM, o un endpoint fuera del cluster.
4. `EndpointSlice` particiona los endpoints de un Service en múltiples objetos más pequeños (por defecto hasta 100 endpoints por slice), lo que reduce el volumen de actualizaciones que hay que propagar a todos los nodos cuando cambia un solo Pod, mejorando el escalado en clusters con miles de Pods detrás de un mismo Service.

</details>

---

**Fuentes**
- CNCF, *Certified Kubernetes Administrator (CKA) Program Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes docs, *Service*: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes docs, *EndpointSlices*: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/