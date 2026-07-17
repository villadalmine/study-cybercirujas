# Ejercicios guiados — CKAD 5.2: Provide and troubleshoot access to applications via services

> Referencia: [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf). El contenido de este ejercicio es original; la fuente se usa solo para delimitar el alcance del objetivo de examen.

## Preparación

Antes de empezar, creá un namespace dedicado para no interferir con otros recursos del cluster.

1. Creá el namespace de trabajo:
   ```bash
   kubectl create namespace ckad-5-2
   kubectl config set-context --current --namespace=ckad-5-2
   ```
2. Verificá que el contexto quedó apuntando al namespace correcto:
   ```bash
   kubectl config view --minify | grep namespace
   ```

---

## Bloque 1 — Exponer un Deployment con un Service `ClusterIP`

1. Creá un Deployment simple basado en `nginx`:
   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=3
   ```
2. Esperá a que los Pods estén `Running`:
   ```bash
   kubectl get pods -l app=web -w
   ```
   (`Ctrl+C` cuando los tres estén `1/1 Running`).
3. Exponé el Deployment con un Service de tipo `ClusterIP` (el default) en el puerto 80:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 --name=web-svc
   ```
4. Inspeccioná el Service creado:
   ```bash
   kubectl get svc web-svc -o wide
   ```
5. Listá los **Endpoints** asociados (las IPs de Pod que el Service está balanceando):
   ```bash
   kubectl get endpoints web-svc
   ```
6. Lanzá un Pod temporal en el mismo namespace y probá el acceso vía el `ClusterIP` y vía el nombre del Service:
   ```bash
   kubectl run tmp-client --image=busybox:1.36 --rm -it --restart=Never -- \
     sh -c "wget -qO- http://web-svc && echo OK"
   ```

**Preguntas de verificación**

- ¿Qué campo del Service determina qué Pods reciben tráfico, y qué campo del Pod debe coincidir con él?
- Si `kubectl get endpoints web-svc` muestra tres IPs, ¿qué relación tienen esas IPs con las IPs de los Pods (`kubectl get pods -o wide`)?
- ¿Por qué `kubectl expose deployment` toma el selector automáticamente de los `labels` del Deployment y no hace falta escribirlo a mano?

---

## Bloque 2 — Troubleshooting: Service sin Endpoints por selector mal configurado

Este es el fallo más común en el objetivo 5.2: un Service "existe" (tiene ClusterIP) pero no enruta tráfico a ningún Pod.

1. Rompé intencionalmente el selector del Service editándolo:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web-wrong"}}}'
   ```
2. Confirmá que el Service sigue existiendo con su ClusterIP:
   ```bash
   kubectl get svc web-svc
   ```
3. Revisá los Endpoints ahora:
   ```bash
   kubectl get endpoints web-svc
   ```
4. Usá `describe` para ver el diagnóstico completo, incluyendo el selector activo:
   ```bash
   kubectl describe svc web-svc
   ```
5. Compará el selector del Service contra los labels reales de los Pods:
   ```bash
   kubectl get pods --show-labels
   ```
6. Corregí el selector para que vuelva a coincidir:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web"}}}'
   kubectl get endpoints web-svc
   ```

**Preguntas de verificación**

- ¿Qué valor muestra `kubectl get endpoints web-svc` cuando el selector no matchea ningún Pod?
- ¿Por qué el Service no pasa a un estado de error visible (`kubectl get svc` sigue mostrando `ClusterIP` normal) aunque no tenga a quién enrutar?
- Si en vez de `EndpointSlice` estuvieras usando un Service `headless` (`clusterIP: None`), ¿cómo cambiaría la forma de detectar este mismo problema?

---

## Bloque 3 — Troubleshooting: `targetPort` que no coincide con el puerto del contenedor

1. Editá el Service para apuntar a un `targetPort` que nginx no escucha:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'
   ```
2. Confirmá que los Endpoints siguen listando las IPs de los Pods (a diferencia del Bloque 2):
   ```bash
   kubectl get endpoints web-svc
   ```
3. Intentá acceder al servicio desde un Pod temporal:
   ```bash
   kubectl run tmp-client2 --image=busybox:1.36 --rm -it --restart=Never -- \
     wget -qO- --timeout=3 http://web-svc
   ```
4. Observá el error de conexión y confirmá en qué puerto escucha realmente el contenedor:
   ```bash
   kubectl exec deploy/web -- ss -tlnp
   ```
5. Corregí el `targetPort` para que coincida con el puerto real (80):
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"ports":[{"port":80,"targetPort":80}]}}'
   ```
6. Repetí el `wget` del paso 3 para confirmar que ahora funciona.

**Preguntas de verificación**

- ¿Por qué en este escenario los Endpoints sí muestran IPs, a diferencia del Bloque 2, aunque el acceso igual falla?
- ¿Qué diferencia hay entre `port`, `targetPort` y `nodePort` en la spec de un Service?
- ¿Qué comando usarías dentro del contenedor para confirmar en qué puerto está escuchando realmente el proceso, sin depender de la documentación de la imagen?

---

## Bloque 4 — Acceso externo con `NodePort`

1. Cambiá el Service a tipo `NodePort`:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"type":"NodePort"}}'
   ```
2. Verificá el puerto asignado automáticamente en el rango 30000-32767:
   ```bash
   kubectl get svc web-svc
   ```
3. Obtené la IP de un nodo del cluster:
   ```bash
   kubectl get nodes -o wide
   ```
4. Probá el acceso combinando IP de nodo + NodePort (ajustá `<NODE_IP>` y `<NODE_PORT>` con los valores reales):
   ```bash
   curl http://<NODE_IP>:<NODE_PORT>
   ```
5. Si el `curl` falla pero el Service y los Endpoints están bien, revisá si hay un firewall o `NetworkPolicy` bloqueando el rango de NodePorts a nivel de infraestructura (fuera del scope de Kubernetes puro, pero común en la práctica).

**Preguntas de verificación**

- ¿Qué ventaja tiene `NodePort` sobre `ClusterIP` para pruebas manuales desde fuera del cluster, y qué limitación tiene frente a `LoadBalancer`?
- Un mismo Service `NodePort` reserva el mismo puerto en **todos** los nodos del cluster, no solo en el nodo donde corren los Pods. ¿Por qué esto permite acceder al servicio usando la IP de cualquier nodo, incluso uno sin Pods del Deployment?

---

## Bloque 5 — DNS y descubrimiento de servicios entre namespaces

1. Creá un segundo namespace y un Pod cliente allí:
   ```bash
   kubectl create namespace ckad-5-2-other
   kubectl run tmp-client3 -n ckad-5-2-other --image=busybox:1.36 --rm -it --restart=Never -- \
     nslookup web-svc.ckad-5-2.svc.cluster.local
   ```
2. Repetí la resolución usando solo el nombre corto (sin namespace) desde el mismo namespace `ckad-5-2-other` y observá que falla o resuelve otra cosa:
   ```bash
   kubectl run tmp-client4 -n ckad-5-2-other --image=busybox:1.36 --rm -it --restart=Never -- \
     nslookup web-svc
   ```
3. Confirmá el FQDN completo que sí funciona desde cualquier namespace:
   ```bash
   kubectl run tmp-client5 -n ckad-5-2-other --image=busybox:1.36 --rm -it --restart=Never -- \
     wget -qO- http://web-svc.ckad-5-2.svc.cluster.local
   ```
4. Revisá el Service `kube-dns`/`coredns` para confirmar que CoreDNS está corriendo (útil cuando *ninguna* resolución funciona, ni siquiera dentro del mismo namespace):
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   ```

**Preguntas de verificación**

- ¿Cuál es el FQDN completo que CoreDNS genera para un Service, y qué partes de ese nombre son fijas frente a las que dependen del recurso?
- ¿Por qué `nslookup web-svc` sin namespace falla al resolverse desde un namespace distinto al del Service?
- Si `kubectl exec` a un Pod muestra que ni siquiera puede resolver `kubernetes.default.svc.cluster.local`, ¿qué componente del cluster (no del namespace de la app) es el primer sospechoso?

---

## Bloque 6 — Readiness probe y su efecto sobre los Endpoints

1. Editá el Deployment para agregar una `readinessProbe` que apunte a un path inexistente:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/no-existe","port":80},"periodSeconds":5}}]}}}}'
   ```
2. Esperá el rollout y observá el estado `READY`:
   ```bash
   kubectl rollout status deployment/web
   kubectl get pods -l app=web
   ```
3. Confirmá que los Pods figuran `Running` pero **no** `Ready` (por ejemplo `0/1`).
4. Revisá qué pasó con los Endpoints del Service mientras los Pods no están `Ready`:
   ```bash
   kubectl get endpoints web-svc
   ```
5. Corregí la probe apuntando a un path válido (`/`) y confirmá que los Endpoints reaparecen:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/","port":80},"periodSeconds":5}}]}}}}'
   kubectl rollout status deployment/web
   kubectl get endpoints web-svc
   ```

**Preguntas de verificación**

- ¿Por qué un Pod `Running` pero no `Ready` queda automáticamente excluido de los Endpoints de un Service, sin que nadie edite el selector ni el Deployment?
- ¿Qué diferencia práctica hay entre depurar "el Service no tiene Endpoints por selector" (Bloque 2) y "el Service no tiene Endpoints por readiness" (este bloque), en términos de qué comando revela la causa raíz más rápido?

---

## Limpieza

```bash
kubectl delete namespace ckad-5-2 ckad-5-2-other
kubectl config set-context --current --namespace=default
```

---

<details>
<summary>Ver respuestas</summary>

**Bloque 1**
- El Service usa `spec.selector` (pares clave-valor) para elegir Pods; esos valores deben coincidir con `metadata.labels` del Pod (heredados del `template` del Deployment).
- Las IPs en `endpoints` son las IPs internas de Pod (`podIP`) de cada réplica que matchea el selector y está `Ready`; son las mismas que aparecen en `kubectl get pods -o wide`.
- Porque `kubectl expose` toma como selector los labels definidos en `spec.template.metadata.labels` del Deployment, asumiendo que querés exponer exactamente esos Pods sin necesidad de repetir la configuración a mano.

**Bloque 2**
- Muestra `<none>`, indicando que ningún Pod matchea el selector actual del Service.
- Porque el Service es un objeto independiente del Deployment/Pods: su `ClusterIP` se asigna al crearse y no depende de que existan Endpoints; el "error" es lógico (0 endpoints), no un estado de fallo del objeto Service en sí.
- Con un Service headless no hay `ClusterIP` ni balanceo vía kube-proxy: el DNS devuelve directamente las IPs de los Pods que matchean el selector. El mismo problema se vería como que la consulta DNS (`nslookup`) no devuelve ninguna IP, en vez de ver `endpoints` vacío en el sentido de kube-proxy.

**Bloque 3**
- Porque el selector sí matchea los Pods correctamente (el Endpoint controller solo verifica labels y readiness, no si el puerto realmente responde), pero kube-proxy reenvía el tráfico al `targetPort` configurado, que el proceso dentro del contenedor no tiene abierto.
- `port` es el puerto que expone el Service hacia sus clientes; `targetPort` es el puerto del contenedor al que se reenvía ese tráfico; `nodePort` es el puerto reservado en cada nodo del cluster (solo aplica a tipo `NodePort`/`LoadBalancer`).
- `ss -tlnp` (o `netstat -tlnp` si está disponible) dentro del contenedor, para listar los puertos TCP en escucha y el proceso asociado.

**Bloque 4**
- `NodePort` permite acceso externo sin depender de un proveedor de nube (a diferencia de `LoadBalancer`, que requiere integración con un balanceador externo); su limitación es que expone el mismo puerto alto (30000-32767) en todos los nodos, lo cual es menos práctico y menos seguro para tráfico de producción.
- Porque kube-proxy configura reglas de red (iptables/IPVS) en **todos** los nodos del cluster para ese NodePort, redirigiendo el tráfico hacia algún Pod válido vía el Service, sin importar en qué nodo esté corriendo ese Pod.

**Bloque 5**
- `<nombre-servicio>.<namespace>.svc.cluster.local`; el sufijo `svc.cluster.local` es fijo (o el dominio del cluster configurado), mientras que `<nombre-servicio>` y `<namespace>` dependen del recurso.
- Porque el nombre corto solo se resuelve automáticamente dentro del **mismo** namespace del Pod que hace la consulta (CoreDNS usa el `search` domain del propio namespace); desde otro namespace hace falta el nombre calificado con el namespace o el FQDN completo.
- CoreDNS (los Pods en `kube-system` con label `k8s-app=kube-dns`): si ni siquiera resuelve el Service `kubernetes.default`, el problema es del propio DNS del cluster, no de la app.

**Bloque 6**
- El Endpoint controller de Kubernetes solo agrega a la lista de Endpoints de un Service las direcciones de Pods que están tanto matcheados por el selector como en estado `Ready`; una readinessProbe fallida marca al Pod como no `Ready` y lo saca automáticamente de esa lista, sin tocar Deployment ni Service.
- En el Bloque 2 la causa raíz se ve comparando `selector` (`describe svc`) contra `labels` (`get pods --show-labels`). En este bloque, `get endpoints` también aparece vacío o incompleto, pero la causa se confirma con `kubectl get pods` (columna `READY` en `0/1`) y `kubectl describe pod` (evento de probe fallida), no con un desajuste de labels.

</details>