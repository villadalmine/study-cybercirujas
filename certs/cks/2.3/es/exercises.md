# CKS v1.34 — Tema 2.3: Comprender e implementar técnicas de aislamiento

## Ejercicios guiados

**Peso en el examen:** 5%
**Tiempo estimado:** 150–180 minutos
**Dificultad:** intermedio → avanzado

---

### Objetivos

Al terminar estos ejercicios vas a ser capaz de:

- Construir una "línea base de tenant" reutilizable que combine Namespace, Pod Security Admission, ResourceQuota, LimitRange e higiene de ServiceAccount.
- Acotar el RBAC para que un tenant no pueda leer ni mutar nada fuera de su Namespace, y demostrarlo con `kubectl auth can-i`.
- Imponer aislamiento de red entre tenants con NetworkPolicies default-deny, más egress controlado para DNS y para los metadatos de la nube.
- Fijar las cargas de trabajo de un tenant a nodos dedicados usando taints, tolerations y etiquetas de nodo que un kubelet comprometido no pueda falsificar.
- Instalar y usar un runtime en sandbox (gVisor / `runsc`) a través de una RuntimeClass, y verificar desde dentro del Pod que la superficie del kernel realmente cambió.
- Leer y validar una RuntimeClass de Kata Containers, incluido el campo `overhead`.
- Reducir la exposición del kernel compartido con user namespaces (`hostUsers: false`) y rechazando Pods con host namespaces / hostPath.
- Forzar un runtime en sandbox para todo un Namespace con una ValidatingAdmissionPolicy.
- Auditar un Namespace existente y listar sus brechas de aislamiento bajo la presión de tiempo del examen.

---

### Requisitos previos del laboratorio

| Requisito | Detalle |
|---|---|
| Clúster | 2 nodos como mínimo (`controlplane` + `node01`), Kubernetes v1.33/v1.34 |
| CNI | Un CNI que aplique políticas (Cilium, Calico, Antrea). `kubectl get pods -n kube-system` debería mostrar alguno de ellos |
| Runtime | containerd (v1.7 o v2.x), con root/sudo en `node01` |
| Herramientas | `kubectl`, `jq`, `openssl`, `wget`/`curl` en el nodo |
| Opcional | Virtualización anidada (`grep -Eqc '(vmx|svm)' /proc/cpuinfo`) para el bloque de Kata |

> Si tu CNI **no** aplica NetworkPolicy (por ejemplo Flannel a secas), los objetos de política se crearán y se verán correctos, pero el tráfico no se bloqueará. Verificá el soporte antes de culpar a tu YAML — es una trampa clásica del examen.

Directorio de trabajo:

```bash
mkdir -p ~/cks/2.3 && cd ~/cks/2.3
kubectl version --short
kubectl get nodes -o wide
```

---

## Ejercicio 1 — La línea base del tenant: Namespace, PSA, quotas, límites

Un Namespace por sí solo es una frontera de nombres, **no** una frontera de seguridad. En este ejercicio convertís un Namespace pelado en una unidad de multi-tenancy blanda.

### Pasos

1. Creá dos Namespaces de tenant y etiquetalos para que Pod Security Admission aplique el perfil `restricted`:

   ```bash
   kubectl create namespace tenant-blue
   kubectl create namespace tenant-green

   for ns in tenant-blue tenant-green; do
     kubectl label namespace $ns \
       pod-security.kubernetes.io/enforce=restricted \
       pod-security.kubernetes.io/enforce-version=v1.34 \
       pod-security.kubernetes.io/audit=restricted \
       pod-security.kubernetes.io/warn=restricted \
       tenant=$ns --overwrite
   done
   ```

2. Confirmá que las etiquetas quedaron aplicadas, incluida la etiqueta automática con el nombre del Namespace:

   ```bash
   kubectl get ns tenant-blue -o jsonpath='{.metadata.labels}' | jq
   ```

3. Intentá ejecutar un Pod que viole el perfil `restricted`:

   ```bash
   kubectl -n tenant-blue run bad --image=nginx:1.27 --restart=Never
   ```

   Leé el mensaje de rechazo con atención — lista cada campo que falló.

4. Ahora ejecutá un Pod que sí satisfaga `restricted`:

   ```bash
   cat <<'EOF' > 01-good-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: good
     namespace: tenant-blue
     labels:
       app: good
   spec:
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile:
         type: RuntimeDefault
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh","-c","sleep 3600"]
       securityContext:
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
       resources:
         requests: {cpu: "50m", memory: "32Mi"}
         limits:   {cpu: "100m", memory: "64Mi"}
   EOF
   kubectl apply -f 01-good-pod.yaml
   kubectl -n tenant-blue get pod good
   ```

5. Limitá lo que el tenant puede consumir, para que un tenant no pueda dejar sin recursos a otro:

   ```bash
   cat <<'EOF' > 01-quota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-quota
     namespace: tenant-blue
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
       pods: "10"
       count/services.loadbalancers: "0"
       count/services.nodeports: "0"
       persistentvolumeclaims: "4"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: tenant-limits
     namespace: tenant-blue
   spec:
     limits:
     - type: Container
       default:        {cpu: "200m", memory: 128Mi}
       defaultRequest: {cpu: "50m",  memory: 64Mi}
       max:            {cpu: "1",    memory: 1Gi}
   EOF
   kubectl apply -f 01-quota.yaml
   kubectl -n tenant-blue describe quota tenant-quota
   ```

6. Comprobá que la restricción de NodePort funciona:

   ```bash
   kubectl -n tenant-blue expose pod good --type=NodePort --port=80 --name=leak
   ```

7. Revisá la ServiceAccount `default` del Namespace y desactivá el automontaje del token globalmente para el tenant:

   ```bash
   kubectl -n tenant-blue get sa default -o yaml | head -20
   kubectl -n tenant-blue patch sa default \
     -p '{"automountServiceAccountToken": false}'
   ```

### Comprobación de comprensión

**Q1.** Dá dos razones concretas por las que un Namespace por sí solo no es una frontera de seguridad.

**Q2.** En el paso 1 configuraste `enforce`, `audit` y `warn`. ¿Cuál es la diferencia práctica entre `enforce=restricted` y `audit=restricted` cuando se envía un Pod que viola el perfil?

**Q3.** ¿Por qué importa `pod-security.kubernetes.io/enforce-version=v1.34`? ¿Qué se rompe si lo omitís y después actualizás el clúster?

**Q4.** Pod Security Admission ignoró el Deployment en un hipotético Namespace `restricted` pero bloqueó sus Pods, dejando los eventos del `ReplicaSet` llenos de fallos. ¿Por qué PSA se comporta así, y dónde buscás el error?

**Q5.** ¿Cuál de los dos objetos del paso 5 (`ResourceQuota` o `LimitRange`) impide que un *único* contenedor pida 8 CPUs, y cuál impide que la *suma* del Namespace supere las 2 CPUs?

**Q6.** ¿Cómo contribuye `count/services.nodeports: "0"` al *aislamiento* y no solo al control de costos?

**Q7.** `automountServiceAccountToken: false` aparece tanto en el Pod (paso 4) como en la ServiceAccount (paso 7). Si no coinciden, ¿cuál gana?

---

## Ejercicio 2 — Acotar el RBAC: mantener al tenant dentro de su Namespace

### Pasos

1. Creá una ServiceAccount que represente al robot de CI del tenant:

   ```bash
   kubectl -n tenant-blue create serviceaccount blue-ci
   ```

2. Otorgale solo un Role con alcance de Namespace — deliberadamente sin ClusterRoleBinding:

   ```bash
   cat <<'EOF' > 02-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: blue-app-manager
     namespace: tenant-blue
   rules:
   - apiGroups: [""]
     resources: ["pods", "services", "configmaps"]
     verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
   - apiGroups: ["apps"]
     resources: ["deployments", "replicasets"]
     verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: blue-app-manager
     namespace: tenant-blue
   subjects:
   - kind: ServiceAccount
     name: blue-ci
     namespace: tenant-blue
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: blue-app-manager
   EOF
   kubectl apply -f 02-rbac.yaml
   ```

3. Probá la frontera desde ambos lados usando impersonación:

   ```bash
   SA=system:serviceaccount:tenant-blue:blue-ci

   kubectl auth can-i create pods            -n tenant-blue  --as=$SA
   kubectl auth can-i create pods            -n tenant-green --as=$SA
   kubectl auth can-i list   secrets         -n tenant-blue  --as=$SA
   kubectl auth can-i list   nodes           --as=$SA
   kubectl auth can-i get    namespaces      --as=$SA
   kubectl auth can-i '*' '*' --all-namespaces --as=$SA
   ```

4. Volcá la lista completa de permisos efectivos — este es el comando de auditoría más rápido de memorizar:

   ```bash
   kubectl auth can-i --list -n tenant-blue --as=$SA
   ```

5. Ahora introducí un error realista y observá el radio de impacto:

   ```bash
   kubectl create clusterrolebinding oops \
     --clusterrole=view --serviceaccount=tenant-blue:blue-ci

   kubectl auth can-i list secrets -n tenant-green --as=$SA
   kubectl auth can-i list pods    -n kube-system  --as=$SA
   ```

6. Eliminá el error y verificá de nuevo:

   ```bash
   kubectl delete clusterrolebinding oops
   kubectl auth can-i list pods -n kube-system --as=$SA
   ```

7. Encontrá todos los bindings de alcance de clúster que podrían romper el aislamiento entre tenants:

   ```bash
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[] | select(.roleRef.name=="cluster-admin" or .roleRef.name=="edit" or .roleRef.name=="view")
              | "\(.metadata.name)\t\(.roleRef.name)\t\([.subjects[]?|"\(.kind):\(.namespace // "-"):\(.name)"]|join(","))"'
   ```

### Comprobación de comprensión

**Q8.** ¿Por qué el `ClusterRoleBinding` del paso 5 otorgó `view` sobre `tenant-green` aunque la ServiceAccount vive en `tenant-blue`?

**Q9.** ¿Cuál es la diferencia de alcance entre vincular un **ClusterRole** con un **RoleBinding** frente a hacerlo con un **ClusterRoleBinding**? ¿Cuál usarías para reutilizar el role integrado `view` para un solo tenant?

**Q10.** El Role del paso 2 otorga `create pods`. Explicá cómo eso solo puede escalarse hasta comprometer el nodo si faltan el resto de los controles de este tema, y nombrá dos controles del Ejercicio 1 que lo impiden.

**Q11.** ¿Por qué `kubectl auth can-i --list --as=<subject>` es más confiable que leer el YAML de los Roles a mano durante el examen?

**Q12.** El tenant pide `list secrets` en su propio Namespace. ¿Por qué otorgar `get`/`list` sobre Secrets en todo el Namespace sigue siendo riesgoso aunque tenga alcance de Namespace, y cuál es una alternativa más estricta?

---

## Ejercicio 3 — Aislamiento de red entre tenants

### Pasos

1. Desplegá un destino y un cliente en cada tenant:

   ```bash
   for ns in tenant-blue tenant-green; do
     kubectl -n $ns create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
       -- /agnhost netexec --http-port=8080
     kubectl -n $ns expose deployment web --port=8080
   done
   kubectl -n tenant-blue rollout status deploy/web
   kubectl -n tenant-green rollout status deploy/web
   ```

2. Confirmá que, por defecto, **todo puede hablar con todo**:

   ```bash
   kubectl -n tenant-blue run probe --rm -it --image=busybox:1.36 --restart=Never -- \
     sh -c 'wget -qO- --timeout=3 http://web.tenant-green:8080/hostname; echo; \
            wget -qO- --timeout=3 http://web.tenant-blue:8080/hostname'
   ```

3. Aplicá una política default-deny para ambas direcciones en `tenant-blue`:

   ```bash
   cat <<'EOF' > 03-default-deny.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: tenant-blue
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
   EOF
   kubectl apply -f 03-default-deny.yaml
   ```

4. Observá que ahora el tenant quedó completamente incomunicado — incluido el DNS:

   ```bash
   kubectl -n tenant-blue run probe --rm -it --image=busybox:1.36 --restart=Never -- \
     sh -c 'nslookup web.tenant-blue 2>&1 | tail -3'
   ```

5. Reabrí solo lo que el tenant legítimamente necesita: DNS y tráfico dentro del Namespace:

   ```bash
   cat <<'EOF' > 03-allow-baseline.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: tenant-blue
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
     egress:
     - to:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: kube-system
         podSelector:
           matchLabels:
             k8s-app: kube-dns
       ports:
       - {protocol: UDP, port: 53}
       - {protocol: TCP, port: 53}
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-same-namespace
     namespace: tenant-blue
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
     ingress:
     - from:
       - podSelector: {}
     egress:
     - to:
       - podSelector: {}
   EOF
   kubectl apply -f 03-allow-baseline.yaml
   ```

6. Volvé a ejecutar la prueba entre tenants y la prueba dentro del tenant:

   ```bash
   kubectl -n tenant-blue run probe --rm -it --image=busybox:1.36 --restart=Never -- \
     sh -c 'echo -n "blue->blue:  "; wget -qO- --timeout=3 http://web.tenant-blue:8080/hostname || echo BLOCKED; \
            echo -n "blue->green: "; wget -qO- --timeout=3 http://web.tenant-green:8080/hostname || echo BLOCKED'
   ```

7. Bloqueá el endpoint de metadatos de la instancia en la nube, una vía clásica de fuga de credenciales del nodo, permitiendo al mismo tiempo egress general a internet para una app etiquetada:

   ```bash
   cat <<'EOF' > 03-egress-external.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-external-except-metadata
     namespace: tenant-blue
   spec:
     podSelector:
       matchLabels:
         egress: internet
     policyTypes: ["Egress"]
     egress:
     - to:
       - ipBlock:
           cidr: 0.0.0.0/0
           except:
           - 169.254.169.254/32
           - 10.0.0.0/8
           - 172.16.0.0/12
           - 192.168.0.0/16
       ports:
       - {protocol: TCP, port: 443}
   EOF
   kubectl apply -f 03-egress-external.yaml
   kubectl -n tenant-blue get netpol
   ```

8. Verificá el bloqueo de los metadatos:

   ```bash
   kubectl -n tenant-blue run meta --rm -it --labels=egress=internet \
     --image=busybox:1.36 --restart=Never -- \
     sh -c 'wget -qO- --timeout=3 http://169.254.169.254/latest/meta-data/ || echo BLOCKED'
   ```

### Comprobación de comprensión

**Q13.** El manifiesto del paso 3 tiene un `spec` vacío salvo por `podSelector: {}` y `policyTypes`. ¿Por qué eso deniega el tráfico en lugar de permitirlo?

**Q14.** Después del paso 3, el DNS se rompió. Explicá el mecanismo exacto — ¿por qué una política de *egress* afecta la resolución de nombres?

**Q15.** En el paso 5, `allow-dns` y `allow-same-namespace` son objetos separados, y ambos seleccionan todos los Pods. ¿Cómo combina Kubernetes múltiples NetworkPolicies que seleccionan el mismo Pod — unión o intersección?

**Q16.** En `allow-dns`, `namespaceSelector` y `podSelector` son dos claves bajo un *único* elemento de la lista. ¿Qué cambiaría si los pusieras como dos elementos separados de la lista (cada uno con su propio `-`)?

**Q17.** ¿De dónde sale la etiqueta `kubernetes.io/metadata.name`, y por qué es más seguro confiar en ella que en una etiqueta `name:` aplicada a mano?

**Q18.** ¿Por qué `except: 169.254.169.254/32` dentro de un `ipBlock` no basta por sí solo para garantizar que el tenant no pueda alcanzar el servicio de metadatos? Nombrá dos formas de eludir el bloqueo.

**Q19.** Un Pod del tenant usa `hostNetwork: true`. ¿Qué les pasa a las NetworkPolicies que acabás de escribir, y qué control del Ejercicio 1 lo impide?

---

## Ejercicio 4 — Aislamiento a nivel de nodo con taints, tolerations y etiquetas confiables

### Pasos

1. Dedicá `node01` a `tenant-blue`:

   ```bash
   kubectl taint node node01 tenant=blue:NoExecute
   kubectl label node node01 node-restriction.kubernetes.io/tenant=blue
   kubectl describe node node01 | grep -A3 -E 'Taints|Labels'
   ```

2. Mostrá que un Pod sin toleration no puede aterrizar ahí:

   ```bash
   kubectl -n tenant-green run stray --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"nodeSelector":{"node-restriction.kubernetes.io/tenant":"blue"}}}' \
     --command -- sleep 3600
   kubectl -n tenant-green describe pod stray | tail -6
   ```

3. Dale al tenant blue tanto una toleration **como** un nodeSelector:

   ```bash
   cat <<'EOF' > 04-pinned.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pinned
     namespace: tenant-blue
   spec:
     nodeSelector:
       node-restriction.kubernetes.io/tenant: blue
     tolerations:
     - key: tenant
       operator: Equal
       value: blue
       effect: NoExecute
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile: {type: RuntimeDefault}
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh","-c","sleep 3600"]
       securityContext:
         allowPrivilegeEscalation: false
         capabilities: {drop: ["ALL"]}
   EOF
   kubectl apply -f 04-pinned.yaml
   kubectl -n tenant-blue get pod pinned -o wide
   ```

4. Verificá que el plugin de admisión NodeRestriction esté habilitado en el API server:

   ```bash
   grep -o 'enable-admission-plugins=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

5. Confirmá lo que una identidad de kubelet *no* tiene permitido hacer:

   ```bash
   kubectl auth can-i label nodes --as=system:node:node01 --as-group=system:nodes
   kubectl auth can-i get secrets -n tenant-blue --as=system:node:node01 --as-group=system:nodes
   ```

6. Limpiá el Pod extraviado:

   ```bash
   kubectl -n tenant-green delete pod stray --force --grace-period=0
   ```

### Comprobación de comprensión

**Q20.** Taints/tolerations y nodeSelector/affinity resuelven dos mitades distintas del aislamiento de nodos. Indicá qué mitad resuelve cada uno, y qué sale mal si usás solo tolerations.

**Q21.** ¿Por qué elegimos el prefijo de etiqueta `node-restriction.kubernetes.io/` en lugar de una etiqueta simple `tenant=blue` en el nodo?

**Q22.** Un tenant puede crear Pods (Role del Ejercicio 2) y por lo tanto puede escribir `tolerations` arbitrarias en su propia especificación de Pod. ¿El aislamiento por taints de nodo realmente se sostiene contra un tenant malicioso? ¿Qué control a nivel de admisión agregarías?

**Q23.** Distinguí `NoSchedule`, `PreferNoSchedule` y `NoExecute`. ¿Cuál desaloja Pods que ya están corriendo?

**Q24.** Explicá en una oración cada uno: el **Node authorizer** y el plugin de admisión **NodeRestriction**. ¿Por qué necesitás ambos?

---

## Ejercicio 5 — Contenedores en sandbox con gVisor (`runsc`) vía RuntimeClass

Esta es la habilidad práctica central del tema: reemplazar el kernel compartido del host por un kernel en espacio de usuario.

### Pasos

1. En `node01`, instalá los binarios de gVisor:

   ```bash
   # run on node01
   (
     set -e
     ARCH=$(uname -m)
     URL=https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}
     wget ${URL}/runsc ${URL}/runsc.sha512 \
          ${URL}/containerd-shim-runsc-v1 ${URL}/containerd-shim-runsc-v1.sha512
     sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
     rm -f *.sha512
     chmod a+rx runsc containerd-shim-runsc-v1
     sudo mv runsc containerd-shim-runsc-v1 /usr/local/bin
   )
   runsc --version
   ```

2. Registrá el runtime en containerd y reinicialo:

   ```bash
   sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
   sudo runsc install
   sudo grep -A3 -i runsc /etc/containerd/config.toml
   sudo systemctl restart containerd
   sudo systemctl is-active containerd
   ```

   Si `runsc install` no está disponible para tu versión mayor de containerd, agregá la sección manualmente.
   containerd 1.7 (`version = 2`):

   ```toml
   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
     runtime_type = "io.containerd.runsc.v1"
   ```

   containerd 2.x (`version = 3`):

   ```toml
   [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
     runtime_type = 'io.containerd.runsc.v1'
   ```

3. Creá el objeto RuntimeClass:

   ```bash
   cat <<'EOF' > 05-runtimeclass.yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: gvisor
   handler: runsc
   scheduling:
     nodeSelector:
       sandbox.example.com/runtime: gvisor
   EOF
   kubectl apply -f 05-runtimeclass.yaml
   kubectl label node node01 sandbox.example.com/runtime=gvisor
   kubectl get runtimeclass
   ```

4. Ejecutá la misma imagen dos veces — una en el runtime por defecto, otra en sandbox:

   ```bash
   cat <<'EOF' > 05-compare.yaml
   apiVersion: v1
   kind: Pod
   metadata: {name: plain, namespace: default}
   spec:
     nodeName: node01
     tolerations: [{key: tenant, operator: Equal, value: blue, effect: NoExecute}]
     containers:
     - {name: c, image: busybox:1.36, command: ["sh","-c","sleep 3600"]}
   ---
   apiVersion: v1
   kind: Pod
   metadata: {name: sandboxed, namespace: default}
   spec:
     runtimeClassName: gvisor
     nodeName: node01
     tolerations: [{key: tenant, operator: Equal, value: blue, effect: NoExecute}]
     containers:
     - {name: c, image: busybox:1.36, command: ["sh","-c","sleep 3600"]}
   EOF
   kubectl apply -f 05-compare.yaml
   kubectl get pod plain sandboxed -o wide
   ```

5. Compará el kernel que cada Pod cree estar ejecutando, y el kernel real del host:

   ```bash
   echo "--- host ---";      uname -r   # run on node01
   echo "--- plain ---";     kubectl exec plain     -- uname -r
   echo "--- sandboxed ---"; kubectl exec sandboxed -- uname -r
   ```

6. Buscá la huella de gVisor desde dentro del sandbox:

   ```bash
   kubectl exec sandboxed -- dmesg | head -5
   kubectl exec sandboxed -- cat /proc/version
   kubectl exec plain     -- dmesg | head -3
   ```

7. Compará lo que cada uno de los dos Pods puede ver del host:

   ```bash
   kubectl exec plain     -- sh -c 'nproc; ls /sys/module | wc -l'
   kubectl exec sandboxed -- sh -c 'nproc; ls /sys/module | wc -l'
   ```

8. Confirmá desde el nodo qué runtime se usó realmente:

   ```bash
   sudo crictl pods --name sandboxed -q | xargs -I{} sudo crictl inspectp {} \
     | jq -r '.status.runtimeHandler // .info.runtimeHandler'
   sudo ps -ef | grep -c '[r]unsc'
   ```

9. Rompelo deliberadamente, para aprender la firma del fallo:

   ```bash
   kubectl run typo --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"runtimeClassName":"gvisorr"}}' --command -- sleep 60
   kubectl get pod typo
   kubectl describe pod typo | tail -5
   ```

### Comprobación de comprensión

**Q25.** En una o dos oraciones, explicá *cómo* aísla gVisor una carga de trabajo. ¿Qué cumple el rol del kernel, y qué pasa con una `syscall` que hace el contenedor?

**Q26.** En el paso 5, ¿por qué el Pod en sandbox reporta una versión de kernel distinta a la del host y a la del Pod `plain`?

**Q27.** La RuntimeClass tiene `handler: runsc`. ¿Cuál es la relación entre esa cadena y la configuración de containerd del paso 2? ¿Qué error obtenés si no coinciden?

**Q28.** ¿Cuál es el propósito de `scheduling.nodeSelector` dentro de una RuntimeClass, y por qué importa en un clúster heterogéneo donde solo algunos nodos tienen `runsc` instalado?

**Q29.** El Pod del paso 9 falló en una fase específica. ¿Fue rechazado por la admisión, por el scheduler o por el kubelet? ¿Cómo lo distinguís a partir de la salida?

**Q30.** Nombrá tres categorías de cargas de trabajo que *no* van a funcionar (o van a funcionar mal) bajo gVisor, y decí por qué.

**Q31.** gVisor bloquea un exploit de kernel que un perfil `seccomp` no bloquearía, y viceversa. Dá un ejemplo en cada dirección y explicá por qué el sandboxing y el filtrado de syscalls son complementarios y no redundantes.

---

## Ejercicio 6 — Kata Containers: aislamiento a nivel de VM y `overhead` de RuntimeClass

### Pasos

1. Comprobá si tu laboratorio puede ejecutar sandboxes basados en VM:

   ```bash
   grep -Eoc '(vmx|svm)' /proc/cpuinfo   # 0 means no nested virtualisation
   ls -l /dev/kvm 2>/dev/null || echo "no /dev/kvm"
   ```

2. Inspeccioná las RuntimeClasses que crea una instalación de Kata (`kata-deploy`). Si Kata no está instalado, leé y razoná sobre este manifiesto en lugar de aplicarlo:

   ```bash
   cat <<'EOF' > 06-kata.yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: kata-qemu
   handler: kata-qemu
   overhead:
     podFixed:
       cpu: "250m"
       memory: "160Mi"
   scheduling:
     nodeSelector:
       katacontainers.io/kata-runtime: "true"
   EOF
   kubectl get runtimeclass -o custom-columns=\
   NAME:.metadata.name,HANDLER:.handler,OVERHEAD_CPU:.overhead.podFixed.cpu,OVERHEAD_MEM:.overhead.podFixed.memory
   ```

3. Si `/dev/kvm` existe, desplegá Kata y ejecutá una carga de trabajo:

   ```bash
   kubectl apply -k "github.com/kata-containers/kata-containers/tools/packaging/kata-deploy/kata-deploy/overlays/k3s?ref=main"
   kubectl -n kube-system rollout status ds/kata-deploy --timeout=300s
   kubectl get runtimeclass | grep kata

   kubectl run kata-test --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"runtimeClassName":"kata-qemu"}}' --command -- sleep 3600
   kubectl wait --for=condition=Ready pod/kata-test --timeout=180s
   ```

4. Verificá el aislamiento a nivel de VM desde dentro del Pod:

   ```bash
   kubectl exec kata-test -- uname -r          # guest kernel, not host kernel
   kubectl exec kata-test -- sh -c 'nproc; free -m | head -2'
   kubectl exec kata-test -- sh -c 'cat /proc/cmdline'
   kubectl exec kata-test -- sh -c 'ls /dev/vd* 2>/dev/null; echo "---"; dmesg | grep -ic virtio'
   ```

5. Observá cómo `overhead` cambia la contabilidad:

   ```bash
   kubectl get pod kata-test -o jsonpath='{.spec.overhead}{"\n"}'
   kubectl describe node node01 | grep -A6 'Allocated resources'
   ```

6. Comprobá la interacción con la quota dentro de un tenant:

   ```bash
   kubectl -n tenant-blue describe quota tenant-quota | head
   ```

### Comprobación de comprensión

**Q32.** Ordená estos tres niveles de aislamiento del más débil al más fuerte y dá la frontera en la que se apoya cada uno: (a) dos Pods con `runc` en Namespaces distintos, (b) un Pod con `runtimeClassName: gvisor`, (c) un Pod con `runtimeClassName: kata-qemu`.

**Q33.** ¿Qué hace `overhead.podFixed`? ¿Qué dos componentes consumen ese valor, y qué sale mal en un nodo si el campo falta para un runtime basado en VM?

**Q34.** Tanto gVisor como Kata se exponen al usuario a través del *mismo* objeto de la API de Kubernetes. ¿Por qué eso es significativo para un equipo de plataforma que quiera cambiar de tecnología de sandbox más adelante?

**Q35.** Un Pod de un tenant bajo `kata-qemu` reporta 2 CPUs mientras que el host tiene 16. ¿De dónde sale ese número?

**Q36.** Kata da un aislamiento más fuerte que gVisor pero no siempre es la respuesta correcta. Dá dos costos de Kata y un tipo de carga de trabajo donde Kata gane claramente sobre gVisor.

---

## Ejercicio 7 — Reducir la superficie del kernel compartido: user namespaces y host namespaces

### Pasos

1. Comprobá si los user namespaces son utilizables en tu clúster:

   ```bash
   kubectl explain pod.spec.hostUsers
   kubectl get --raw='/metrics' | grep -m5 'kubernetes_feature_enabled.*UserNamespaces' || \
     grep -o 'feature-gates=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

2. Ejecutá un Pod **con** el user namespace del host (el comportamiento histórico por defecto) e inspeccioná su mapa de UIDs:

   ```bash
   kubectl run hostusers --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"hostUsers":true}}' \
     --command -- sh -c 'sleep 3600'
   kubectl exec hostusers -- cat /proc/self/uid_map
   kubectl exec hostusers -- id
   ```

3. Ejecutá el mismo Pod en su **propio** user namespace:

   ```bash
   kubectl run userns --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"hostUsers":false}}' \
     --command -- sh -c 'sleep 3600'
   kubectl get pod userns
   kubectl exec userns -- cat /proc/self/uid_map
   kubectl exec userns -- id
   ```

4. Compará a qué se mapea el root del contenedor en el host:

   ```bash
   # on node01
   sudo ps -eo pid,user,uid,comm | grep -E 'sleep' | head
   ```

5. Probá los escapes clásicos por host namespaces contra el Namespace endurecido del tenant:

   ```bash
   for f in hostPID hostNetwork hostIPC; do
     echo "== $f =="
     kubectl -n tenant-blue run esc-$f --image=busybox:1.36 --restart=Never \
       --overrides="{\"spec\":{\"$f\":true}}" --command -- sleep 60 2>&1 | tail -2
   done

   echo "== hostPath =="
   kubectl -n tenant-blue run esc-hp --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"volumes":[{"name":"h","hostPath":{"path":"/"}}],"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","60"],"volumeMounts":[{"name":"h","mountPath":"/host"}]}]}}' 2>&1 | tail -2
   ```

6. Mostrá qué hacen los mismos Pods en un Namespace sin etiquetar, para apreciar la diferencia:

   ```bash
   kubectl create ns danger
   kubectl -n danger run esc --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"hostPID":true,"containers":[{"name":"c","image":"busybox:1.36","command":["sh","-c","ps -ef | head -5; sleep 30"]}]}}'
   kubectl -n danger logs esc
   ```

### Comprobación de comprensión

**Q37.** Leé las dos salidas de `/proc/self/uid_map` de los pasos 2 y 3. Explicá qué significa cada una de las tres columnas y qué te dice la diferencia sobre el usuario root del contenedor.

**Q38.** Un proceso de un contenedor corre como UID 0 dentro de un Pod con `hostUsers: false`. Se escapa del sistema de archivos del contenedor. ¿Qué puede hacerle a `/etc/shadow` en el host, y por qué?

**Q39.** ¿Por qué `hostUsers: false` mitiga toda una clase de CVEs incluso cuando el camino de código vulnerable es alcanzable?

**Q40.** ¿Qué componente (que no sea el API server) debe soportar idmapped mounts / user namespaces para que `hostUsers: false` funcione realmente, y qué síntoma ves si no lo hace?

**Q41.** El paso 5 bloqueó `hostPID`, `hostNetwork`, `hostIPC` y `hostPath`. ¿Qué mecanismo los bloqueó, y en qué punto del ciclo de vida de la petición?

**Q42.** En el paso 6 el Pod listó procesos del host. Nombrá dos piezas distintas de información sensible que un atacante obtiene solo con `hostPID: true`.

---

## Ejercicio 8 — Forzar un runtime en sandbox para todo un tenant (ValidatingAdmissionPolicy)

### Pasos

1. Etiquetá el tenant que debe estar en sandbox:

   ```bash
   kubectl label namespace tenant-green tenant-isolation=sandboxed --overwrite
   ```

2. Escribí una política que rechace cualquier Pod que no use la RuntimeClass `gvisor`:

   ```bash
   cat <<'EOF' > 08-vap.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: require-sandboxed-runtime
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
       - apiGroups:   [""]
         apiVersions: ["v1"]
         operations:  ["CREATE", "UPDATE"]
         resources:   ["pods"]
     validations:
     - expression: >-
         has(object.spec.runtimeClassName) &&
         object.spec.runtimeClassName in ['gvisor', 'kata-qemu']
       message: "pods in a sandboxed tenant must set runtimeClassName to gvisor or kata-qemu"
       reason: Forbidden
   ---
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: require-sandboxed-runtime-binding
   spec:
     policyName: require-sandboxed-runtime
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           tenant-isolation: sandboxed
   EOF
   kubectl apply -f 08-vap.yaml
   ```

3. Probá en ambas direcciones:

   ```bash
   kubectl -n tenant-green run nosandbox --image=busybox:1.36 --restart=Never --command -- sleep 60
   kubectl -n default      run nosandbox --image=busybox:1.36 --restart=Never --command -- sleep 60
   ```

4. Confirmá que un Pod que cumple es admitido:

   ```bash
   kubectl -n tenant-green run withsandbox --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"runtimeClassName":"gvisor","securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
     --command -- sleep 60
   kubectl -n tenant-green get pod withsandbox -o jsonpath='{.spec.runtimeClassName}{"\n"}'
   ```

5. Cambiá el binding a modo solo-auditoría y observá la diferencia:

   ```bash
   kubectl patch validatingadmissionpolicybinding require-sandboxed-runtime-binding \
     --type=merge -p '{"spec":{"validationActions":["Warn","Audit"]}}'
   kubectl -n tenant-green run nosandbox2 --image=busybox:1.36 --restart=Never --command -- sleep 60
   kubectl -n tenant-green get pod nosandbox2
   ```

6. Restaurá la aplicación de la política:

   ```bash
   kubectl patch validatingadmissionpolicybinding require-sandboxed-runtime-binding \
     --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
   ```

### Comprobación de comprensión

**Q43.** ¿Por qué hace falta una ValidatingAdmissionPolicy acá — no alcanza con decirle al tenant que configure `runtimeClassName: gvisor`?

**Q44.** Explicá la división entre `ValidatingAdmissionPolicy` y `ValidatingAdmissionPolicyBinding`. ¿Cuál de los dos decide *dónde* se aplica la regla?

**Q45.** La expresión CEL empieza con `has(object.spec.runtimeClassName)`. ¿Qué pasa si sacás esa guarda y un Pod omite el campo?

**Q46.** `failurePolicy: Fail` — ¿qué significa para una VAP, y cómo se compara con el mismo campo en un `ValidatingWebhookConfiguration` basado en webhook?

**Q47.** En el paso 5 el Pod se creó a pesar de violar la política. ¿Qué valor de `validationActions` causó eso, y dónde buscarías la violación registrada?

**Q48.** Dá una ventaja de VAP sobre un admission webhook para esta regla específica, y una situación en la que igual necesitarías un webhook.

---

## Ejercicio 9 — Auditoría de aislamiento bajo presión de examen

### Pasos

1. Creá un Namespace deliberadamente débil:

   ```bash
   kubectl create ns legacy
   kubectl -n legacy create deployment app --image=nginx:1.27
   kubectl create clusterrolebinding legacy-admin \
     --clusterrole=cluster-admin --serviceaccount=legacy:default
   ```

2. Ejecutá una auditoría de cinco comandos y anotá cada brecha que encuentres:

   ```bash
   NS=legacy
   kubectl get ns $NS --show-labels
   kubectl -n $NS get netpol
   kubectl -n $NS get quota,limitrange
   kubectl get clusterrolebindings,rolebindings -A -o json \
     | jq -r --arg ns "$NS" '.items[] | select(any(.subjects[]?; .namespace==$ns))
              | "\(.kind)/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
   kubectl -n $NS get pods -o json | jq -r '.items[] |
     "\(.metadata.name) runtimeClass=\(.spec.runtimeClassName // "default") hostNet=\(.spec.hostNetwork // false) hostPID=\(.spec.hostPID // false) hostUsers=\(.spec.hostUsers // true) sa=\(.spec.serviceAccountName) automount=\(.spec.automountServiceAccountToken // "unset")"'
   ```

3. Remediá en el orden correcto y volvé a ejecutar la auditoría después de cada arreglo:

   ```bash
   kubectl delete clusterrolebinding legacy-admin
   kubectl label ns legacy \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=v1.34 \
     pod-security.kubernetes.io/warn=restricted --overwrite
   kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: {name: default-deny-all, namespace: legacy}
   spec:
     podSelector: {}
     policyTypes: ["Ingress","Egress"]
   EOF
   ```

4. Anotá qué Pod existente sigue sin cumplir y por qué el reetiquetado no lo arregló:

   ```bash
   kubectl -n legacy get pods
   kubectl -n legacy rollout restart deploy/app
   kubectl -n legacy get events --sort-by=.lastTimestamp | tail -5
   ```

### Comprobación de comprensión

**Q49.** Listá, en orden de prioridad, las seis cosas que revisás para decidir si un Namespace está aislado. Justificá las dos primeras.

**Q50.** En el paso 3 configuraste `enforce=baseline` pero `warn=restricted`. ¿Por qué es un patrón de migración sensato para un Namespace existente?

**Q51.** ¿Por qué agregar las etiquetas de PSA no desalojó el Pod de `nginx` que ya estaba corriendo, y qué implica eso sobre el orden de las operaciones al endurecer un clúster en producción?

**Q52.** Te quedan 4 minutos en el examen y te dicen "aislá el namespace `X` de todos los demás namespaces". ¿Qué único objeto creás, y qué es lo único que no te tenés que olvidar de permitir además?

---

## Limpieza

```bash
kubectl delete ns tenant-blue tenant-green danger legacy --ignore-not-found
kubectl delete pod plain sandboxed typo hostusers userns kata-test --ignore-not-found
kubectl delete validatingadmissionpolicybinding require-sandboxed-runtime-binding --ignore-not-found
kubectl delete validatingadmissionpolicy require-sandboxed-runtime --ignore-not-found
kubectl delete runtimeclass gvisor --ignore-not-found
kubectl delete clusterrolebinding legacy-admin oops --ignore-not-found
kubectl taint node node01 tenant=blue:NoExecute-
kubectl label node node01 node-restriction.kubernetes.io/tenant- sandbox.example.com/runtime-
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** (a) La frontera del Namespace es solo una agrupación de objetos de la API — los Pods en Namespaces distintos comparten el mismo kernel del nodo, el mismo sistema de archivos del nodo y, por defecto, una red de Pods plana y completamente enrutable. (b) Muchos recursos tienen alcance de clúster (Nodes, PersistentVolumes, ClusterRoles, CRDs, RuntimeClasses), así que un Namespace no dice nada sobre el acceso a ellos. El aislamiento solo existe una vez que agregás RBAC, NetworkPolicy, quotas, PSA y — para separación a nivel de kernel — un runtime en sandbox.

**Q2.** `enforce` rechaza el Pod en el momento de la admisión; la petición a la API falla y no se crea ningún objeto Pod. `audit` deja pasar el Pod pero registra una anotación en la entrada del log de auditoría. `warn` devuelve un aviso al cliente (visible en la salida de `kubectl`) pero igual lo admite. Configurar los tres es lo estándar: aplicá el nivel al que te podés comprometer hoy, y auditá/avisá en el nivel más estricto hacia el que estás migrando.

**Q3.** Los perfiles de PSA evolucionan entre versiones de Kubernetes — se puede agregar un campo nuevo o una restricción nueva a `restricted`. Fijar `enforce-version` congela la semántica a la definición que trae v1.34, de modo que una actualización del clúster no puede empezar a rechazar silenciosamente Pods que antes eran válidos. Omitirlo significa que la etiqueta toma el valor por defecto `latest`, que sigue lo que implemente el control plane en ejecución y puede romper cargas de trabajo al actualizar.

**Q4.** PSA es un admission controller a nivel de Pod: valida objetos Pod, no los controladores de carga de trabajo que los crean. El Deployment es admitido, su ReplicaSet es admitido, y el fallo aparece solo cuando el controlador del ReplicaSet intenta crear Pods. Mirá `kubectl -n <ns> describe replicaset <name>` y `kubectl -n <ns> get events` — el Deployment en sí solo reporta cero réplicas disponibles. (PSA sí emite un *warning* al crear el Deployment, que es justamente por qué vale la pena habilitar `warn`.)

**Q5.** `LimitRange.spec.limits[].max` limita un único contenedor/Pod, así que bloquea el contenedor de 8 CPUs. `ResourceQuota.spec.hard.requests.cpu` limita el agregado en todo el Namespace. Son complementarios: la quota sola dejaría que un solo Pod se coma toda la asignación; el LimitRange solo dejaría que mil Pods chicos hagan lo mismo.

**Q6.** Un Service de tipo NodePort abre un puerto en la interfaz de red de **cada** nodo, alcanzable desde fuera del clúster y saltándose la visión a nivel de Pod que tiene la NetworkPolicy de "quién puede alcanzarme". En efecto, le permite a un tenant publicarse en infraestructura compartida sin el consentimiento del equipo de plataforma. Poner el contador en `0` mantiene el ingreso por una vía controlada y auditada (Ingress/Gateway con su propia política).

**Q7.** Gana la especificación del **Pod**. `automountServiceAccountToken` en la ServiceAccount es el valor por defecto que se aplica cuando el Pod no especifica el campo; un valor explícito en el Pod lo sobrescribe. Así que un tenant que puede crear Pods puede volver a habilitar el automontaje — por eso la higiene de tokens tiene que ir acompañada de un RBAC que haga que el token no valga nada.

**Q8.** Un `ClusterRoleBinding` vincula el ClusterRole en **todos** los Namespaces más los recursos de alcance de clúster. El Namespace propio del sujeto es solo parte de su identidad (`system:serviceaccount:tenant-blue:blue-ci`); no limita dónde se aplican los permisos otorgados. Esta es la forma más común de destruir accidentalmente el aislamiento entre tenants.

**Q9.** Vincular un ClusterRole con un **RoleBinding** otorga las reglas de ese ClusterRole *solo dentro del Namespace del RoleBinding* — esta es la forma correcta de reutilizar `view`, `edit` o `admin` para un tenant. Vincularlo con un **ClusterRoleBinding** lo otorga a nivel de todo el clúster, incluidos los recursos de alcance de clúster. Entonces: `kubectl create rolebinding blue-view --clusterrole=view --serviceaccount=tenant-blue:blue-ci -n tenant-blue`.

**Q10.** `create pods` le permite al tenant enviar un Pod con `privileged: true`, `hostPID: true`, o un volumen `hostPath` montando `/`, y después leer las credenciales del kubelet del nodo o hacer `chroot` al host — compromiso total del nodo, y desde el nodo, los Secrets de otros tenants. Del Ejercicio 1: (a) PSA `enforce=restricted` rechaza privileged, host namespaces y hostPath en la admisión; (b) `automountServiceAccountToken: false` más un RBAC ajustado limita lo que rinde el token robado. El aislamiento de nodo (Ejercicio 4) y un runtime en sandbox (Ejercicio 5) contienen aún más el radio de impacto.

**Q11.** Porque los permisos efectivos son la **unión** de cada Role y ClusterRole vinculado al sujeto — directamente, a través de sus grupos (`system:serviceaccounts`, `system:authenticated`), y a través de ClusterRoles agregados. Leer un solo Role no te dice nada sobre los demás bindings. `auth can-i --list` le pregunta al propio authorizer, que es el mismo camino de código que toma una petición real.

**Q12.** Los Secrets con alcance de Namespace igual incluyen los tokens de las ServiceAccounts del propio tenant, claves TLS, credenciales de image-pull y cualquier cosa que haya escrito ahí un controlador — leerlos puede ser una vía de escalada de privilegios dentro del Namespace (por ejemplo, leer el token de una SA más privilegiada). Alternativa más estricta: otorgar `get` solo sobre recursos nombrados (`resourceNames: ["app-config"]`), o directamente no otorgar acceso a Secrets e inyectar los valores vía la especificación del Pod / un almacén de secretos externo con identidad por carga de trabajo.

**Q13.** NetworkPolicy funciona por lista de permitidos. Apenas *cualquier* política selecciona un Pod para un `policyType` dado, el tráfico de ese Pod en esa dirección pasa a ser denegado por defecto y solo se permite la unión de las reglas `ingress`/`egress` que coincidan. Con `policyTypes: [Ingress, Egress]` y ninguna regla listada, la lista de permitidos está vacía, así que no se permite nada.

**Q14.** La resolución DNS es tráfico saliente del Pod hacia `kube-dns`/CoreDNS en UDP/TCP 53. Apenas una política de egress selecciona el Pod con una lista de permitidos vacía, ese paquete se descarta. El síntoma es un timeout de resolución, que suele diagnosticarse mal como "el Service no existe" — siempre agregá la regla de egress de DNS junto con un default-deny de egress.

**Q15.** **Unión.** Las políticas son puramente aditivas; no hay reglas de denegación ni orden ni prioridad en la API core de NetworkPolicy. El tráfico permitido de un Pod es la unión de todas las reglas de todas las políticas que lo seleccionan. (Algunos CNIs ofrecen sus propios CRDs — CiliumClusterwideNetworkPolicy, `GlobalNetworkPolicy` de Calico — que sí agregan semántica de denegación y precedencia.)

**Q16.** Dentro de un mismo elemento de la lista, `namespaceSelector` y `podSelector` se combinan con **AND**: "Pods que coincidan con `k8s-app=kube-dns` *en* Namespaces que coincidan con `kubernetes.io/metadata.name=kube-system`". Como dos elementos separados de la lista se combinan con **OR**: "todos los Pods en kube-system" O "todos los Pods con `k8s-app=kube-dns` en *cualquier* Namespace, incluido cada tenant". La segunda forma es dramáticamente más amplia y es una trampa favorita del examen.

**Q17.** El comportamiento `NamespaceDefaultLabelName` del API server establece `kubernetes.io/metadata.name` en cada Namespace automáticamente y es inmutable/reconciliada por el control plane. Una etiqueta `name:` aplicada a mano se puede olvidar, escribir mal o eliminar por quien pueda editar el Namespace — lo que ampliaría o rompería la política silenciosamente.

**Q18.** (a) `ipBlock` solo coincide con el tráfico que sale de la overlay del clúster; un Pod con `hostNetwork: true` esquiva por completo el camino de políticas a nivel de Pod en la mayoría de los CNIs. (b) El tenant puede hacer proxy a través de otro Pod que *sí* tenga permitido alcanzar la IP de metadatos, o llegar al servicio de metadatos por una dirección/hostname alternativo (link-local IPv6, `metadata.google.internal` resolviendo a otro lado, un Service proxy de IMDS). Respuestas robustas: bloquear el rango de IMDS en el firewall del nodo/host, exigir IMDSv2, y dejar de asociar roles de instancia poderosos a los nodos.

**Q19.** Con `hostNetwork: true` el Pod comparte el network namespace del nodo, así que su tráfico es tráfico del nodo, no tráfico de Pod — la mayoría de los CNIs no le aplican NetworkPolicies de Pod, y tu default-deny queda esquivado. PSA `enforce=baseline` o `restricted` (Ejercicio 1) rechaza `hostNetwork: true` en la admisión, que es por qué PSA es un prerrequisito para poder confiar en NetworkPolicy.

**Q20.** Taints/tolerations son un **repelente**: mantienen *otras* cargas de trabajo *fuera* del nodo dedicado. nodeSelector/nodeAffinity es un **atrayente**: mantiene la carga del tenant *sobre* el nodo dedicado. Con solo tolerations, los Pods del tenant tienen *permitido* estar en `node01` pero el scheduler igual puede ubicarlos en nodos compartidos — así que el tenant termina conviviendo con todos los demás, y el nodo dedicado queda ocioso.

**Q21.** El plugin de admisión NodeRestriction le prohíbe a un kubelet establecer o modificar etiquetas bajo el prefijo `node-restriction.kubernetes.io/` (y restringe la mayoría de los demás cambios de etiquetas). Por lo tanto, un nodo comprometido no puede reetiquetarse a sí mismo como `tenant=blue` para atraer las cargas de trabajo de otro tenant. Una etiqueta simple `tenant=blue` sí podría ser auto-aplicada por el kubelet, lo que haría que la ubicación basada en etiquetas no sea confiable.

**Q22.** No — un tenant que controla su propia especificación de Pod puede agregar cualquier toleration, así que los taints por sí solos no confinan a un tenant *malicioso*; solo previenen la co-ubicación *accidental*. Agregá un control de admisión que fije la ubicación: una ValidatingAdmissionPolicy o una política de mutación que fuerce el `nodeSelector` por Namespace, o una política que rechace tolerations para las claves de taint de otros tenants. (Equivalentes en clústeres gestionados: node pools por tenant con node selectors obligatorios.)

**Q23.** `NoSchedule` — el scheduler no ubicará Pods nuevos sin una toleration que coincida; los Pods en ejecución no se tocan. `PreferNoSchedule` — una preferencia blanda; el scheduler evita el nodo si puede, pero lo usará si no entra en ningún otro lado. `NoExecute` — los Pods nuevos necesitan una toleration **y** los Pods ya en ejecución que no la tengan son **desalojados** (inmediatamente, o después de `tolerationSeconds`).

**Q24.** El **Node authorizer** es un modo de autorización que limita lo que cada identidad de kubelet (`system:node:<name>` en el grupo `system:nodes`) puede *leer* — esencialmente solo los objetos relacionados con los Pods programados en ese nodo. **NodeRestriction** es un plugin de admisión que limita lo que un kubelet puede *escribir* — solo su propio objeto Node y el estado de sus propios Pods, y nunca etiquetas/taints protegidas. Necesitás ambos porque la autorización gobierna lecturas/verbos mientras que la admisión gobierna el contenido de las escrituras.

**Q25.** El `runsc` de gVisor implementa un **kernel en espacio de usuario** (el Sentry): intercepta las llamadas al sistema del contenedor y las atiende él mismo, en lugar de pasarlas al kernel del host. El Sentry hace solo un conjunto pequeño y estrictamente filtrado de syscalls al host (vía una capa de plataforma restringida por seccomp, con el acceso a archivos intermediado por el Gofer). Un exploit de kernel dentro del contenedor por lo tanto ataca la reimplementación del Sentry, no el kernel del host — reduciendo drásticamente la superficie de ataque.

**Q26.** Porque el contenedor en sandbox no está hablando con el kernel del host en absoluto. `uname` es una syscall respondida por el Sentry, que reporta su propia versión de kernel sintética y compatible con gVisor (históricamente una cadena estilo `4.4.x`). El `uname` del Pod `plain` llega al kernel real del host a través del namespace compartido, así que coincide exactamente con el nodo.

**Q27.** `handler` es la clave que el kubelet le pasa al runtime CRI; containerd la busca como el nombre del runtime en su configuración (`...containerd.runtimes.<handler>`). Deben coincidir exactamente: `handler: runsc` requiere una sección `runtimes.runsc`. Si no coinciden, el Pod se queda en `ContainerCreating`/no arranca y el evento del kubelet dice aproximadamente `failed to create containerd task: ... no runtime for "X" is configured` — un error del kubelet/runtime, no de admisión.

**Q28.** `scheduling.nodeSelector` se agrega a cualquier Pod que use la RuntimeClass, restringiéndolo a los nodos que efectivamente tienen el handler instalado (también existe `scheduling.tolerations` para nodos de sandbox con taints). Sin él, el scheduler ubica alegremente un Pod `gvisor` en un nodo sin el binario `runsc`, y el Pod se queda colgado en `ContainerCreating` — un fallo que parece un bug de RuntimeClass pero en realidad es un bug de scheduling.

**Q29.** Fue rechazado en la **admisión**: la existencia de la RuntimeClass la valida el API server, así que `kubectl get pod typo` no muestra ningún Pod (o, si llegó a crearse, la salida de `describe` muestra una condición de `FailedCreatePodSandBox`/RuntimeClass-no-encontrada). La señal distintiva: un rechazo de admisión devuelve un error inmediatamente desde `kubectl create` y no existe ningún objeto; un fallo del scheduler muestra `Pending` con eventos `FailedScheduling`; un fallo del kubelet muestra una asignación de nodo más `ContainerCreating` y eventos del runtime.

**Q30.** (a) Cargas que necesitan acceso directo a hardware o a módulos del kernel — cómputo con GPU, herramientas eBPF, agentes con `CAP_SYS_ADMIN` — porque gVisor no implementa ni expone esas interfaces. (b) Cargas intensivas en syscalls o en E/S — bases de datos ocupadas, proxies de alto throughput — porque cada syscall atraviesa el Sentry, agregando latencia y reduciendo el throughput. (c) Cualquier cosa que dependa de syscalls no implementadas o implementadas parcialmente / de entradas oscuras de `/proc` y `/sys`; el Sentry cubre la mayor parte de Linux, no todo, así que esas cargas fallan con errores del estilo `ENOSYS`.

**Q31.** Sandbox-y-no-seccomp: un exploit en la implementación del kernel de una syscall *permitida* (por ejemplo un bug de corrupción de memoria en un `ioctl` permitido o en la pila de red) pasa intacto una lista de permitidos de seccomp, pero impacta en la reimplementación propia de gVisor en lugar del kernel del host. Seccomp-y-no-sandbox: seccomp puede denegar una syscall para un Pod que corre en el runtime **por defecto**, donde no hay ningún sandbox — y además protege al propio supervisor del sandbox. En la práctica aplicás ambos: `seccompProfile: RuntimeDefault` en cada Pod, más una RuntimeClass en sandbox para tenants no confiables (defensa en profundidad).

**Q32.** Del más débil al más fuerte: (a) `runc` en Namespaces distintos — se apoya en namespaces de Linux, cgroups, capabilities y seccomp sobre un **kernel de host compartido**; un bug de kernel es un escape total. (b) `gvisor` — se apoya en un **kernel en espacio de usuario** que intercepta syscalls, así que un exploit de kernel del contenedor primero tiene que romper el Sentry, que a su vez está confinado por seccomp. (c) `kata-qemu` — se apoya en una **frontera de virtualización por hardware**: cada Pod obtiene su propio kernel invitado dentro de una VM liviana, así que escapar requiere una vulnerabilidad del hipervisor/VMM.

**Q33.** `overhead.podFixed` declara la CPU/memoria extra que consume la propia infraestructura del sandbox (proceso del VMM, kernel invitado, agente). El **scheduler** la suma al calcular si un Pod entra en un nodo, y el **kubelet**/la contabilidad de recursos (incluida ResourceQuota) la incluye en el total del Pod. Sin ella, el nodo queda sobrecomprometido: el scheduler cree que solo se consumen los requests de los contenedores, y los cientos de MiB extra por Pod terminan causando presión de memoria en el nodo y desalojos.

**Q34.** Porque RuntimeClass es una **indirección enchufable**: el autor de la carga de trabajo referencia un nombre (`gvisor`, `kata-qemu`, `sandboxed`), y el equipo de plataforma mapea ese nombre a un handler y a nodos. Cambiar la tecnología subyacente, o enrutar la misma clase a handlers distintos en pools de nodos distintos, no requiere ningún cambio en los manifiestos del tenant — el contrato de aislamiento queda en manos de la plataforma.

**Q35.** De la configuración de la VM invitada, no del host. Kata dimensiona las CPUs virtuales de la VM a partir de los requests/limits de recursos del Pod y de los valores por defecto de la configuración de Kata (`default_vcpus`), así que el kernel invitado solo ve las vCPUs que le fueron asignadas. Eso también es *por qué* es un aislamiento más fuerte: la carga de trabajo no tiene visibilidad de la topología real del host.

**Q36.** Costos: (a) mayor overhead de recursos por Pod y arranque más lento (hay que bootear una VM), que es exactamente lo que codifica `overhead.podFixed`; (b) una dependencia de infraestructura en virtualización anidada / `/dev/kvm`, que muchos entornos gestionados y virtualizados no proveen, además de más piezas móviles que operar. Kata gana claramente para cargas que necesitan funcionalidad de kernel amplia y fiel **y** aislamiento fuerte — por ejemplo, ejecutar código de clientes no confiable que usa syscalls inusuales, módulos del kernel, o su propio runtime de contenedores, donde la cobertura de syscalls de gVisor lo rompería.

**Q37.** Las columnas son: *primer UID dentro del namespace*, *primer UID correspondiente en el host*, *longitud del rango*. Con `hostUsers: true` ves `0  0  4294967295` — el espacio de UIDs del contenedor **es** el del host, así que el root del contenedor es root del host. Con `hostUsers: false` ves algo como `0  <algúnUIDAltoDelHost>  65536` — el UID 0 del contenedor se mapea a un UID no privilegiado del host, y solo hay disponible una porción de 65536 de ancho.

**Q38.** Nada. Desde el punto de vista del host, el proceso es un usuario común sin privilegios (el UID alto mapeado), así que no tiene acceso de escritura a `/etc/shadow` ni permiso sobre archivos del host que pertenezcan al root real. Su UID 0 solo tiene significado *dentro* de su propio user namespace; las capabilities que posee son capabilities con alcance de namespace, impotentes frente a recursos que pertenecen al user namespace inicial.

**Q39.** Porque desacopla "root en el contenedor" de "root en el host" para toda la clase de bugs cuyo impacto depende de que el atacante tenga UID 0 real / capabilities reales — escapes de contenedor vía rutas del host escribibles, interfaces del kernel protegidas por `CAP_*`, trucos con setuid. El código vulnerable igual puede ejecutarse, pero los privilegios que rinde están confinados a un rango de UIDs mapeado y sin privilegios, así que el escape no lleva a ningún lado útil.

**Q40.** El **runtime de contenedores** (containerd/CRI-O junto con el runtime OCI — `runc` ≥1.2 o `crun` — y soporte del kernel para idmapped mounts en los sistemas de archivos relevantes). Si falta o es demasiado viejo, el Pod no arranca: se queda en `ContainerCreating` con un evento del kubelet/runtime sobre user namespaces o idmap no soportados. El feature gate en el control plane es necesario pero no suficiente.

**Q41.** Los bloqueó Pod Security Admission con `enforce=restricted` (del Ejercicio 1). Corre como un controlador de **admisión validante** integrado dentro del API server, así que la petición se rechaza antes de que el objeto se persista — no se crea ningún Pod, no interviene el scheduler ni el kubelet, y el error nombra cada campo infractor.

**Q42.** (a) La tabla de procesos completa del nodo, incluidos los procesos de otros tenants, sus líneas de comando y por lo tanto cualquier secreto, token o cadena de conexión pasada como argumento. (b) La capacidad de inspeccionar el `/proc/<pid>/` de otros procesos — variables de entorno (`environ`), descriptores de archivo abiertos y namespaces montados — que es una vía directa hacia credenciales y hacia escapes estilo `nsenter` cuando se combina con privilegios.

**Q43.** Porque "decirle al tenant" no es un control. Un tenant que puede crear Pods (o cualquier controlador actuando en su nombre) puede omitir o cambiar `runtimeClassName`, y un solo Pod sin sandbox reinstaura el riesgo del kernel compartido para todo el nodo. El requisito tiene que hacerlo cumplir el API server en la admisión, evaluado en cada CREATE y UPDATE, con independencia de la cooperación del tenant.

**Q44.** La **política** define *qué* se comprueba — las expresiones CEL, los tipos de recurso a los que puede aplicarse, la failure policy — y es reutilizable. El **binding** define *dónde y cómo* se aplica — a qué Namespaces u objetos (`matchResources`, `namespaceSelector`, `objectSelector`) y con qué `validationActions` (Deny/Warn/Audit). El binding decide el alcance; una misma política puede tener muchos bindings con alcances y acciones distintos.

**Q45.** La evaluación CEL sobre un campo opcional ausente es un error, no `false`. Combinado con `failurePolicy: Fail`, la petición se rechaza con un error de evaluación en lugar del mensaje que pretendías — cada Pod en los Namespaces vinculados falla con un error interno confuso. `has()` (o `object.spec.?runtimeClassName.orValue('')`) hace explícito el caso de ausencia y produce el `message` correcto.

**Q46.** Para una VAP, `failurePolicy` gobierna qué pasa cuando la **expresión CEL falla al evaluarse** (error de tipo, campo ausente, límite de costo): `Fail` rechaza la petición, `Ignore` la admite. Para un `ValidatingWebhookConfiguration` gobierna qué pasa cuando el **webhook externo es inalcanzable o da error** — una preocupación de disponibilidad mucho mayor, ya que un webhook caído con `Fail` puede congelar el clúster. Una VAP no tiene dependencia de red, así que `Fail` es mucho más seguro de usar.

**Q47.** `validationActions: ["Warn","Audit"]` — `Warn` devuelve el mensaje como un aviso visible para el cliente y `Audit` lo registra en la anotación del log de auditoría (`validation.policy.admission.k8s.io/validation_failure`), pero ninguno rechaza. Solo `Deny` rechaza. Encontrás la violación en la salida de warning de `kubectl` y en el log de auditoría del API server. Este par es la forma correcta de hacer un dry-run de una política contra un clúster vivo antes de aplicarla.

**Q48.** Ventaja: la VAP corre **en proceso** dentro del API server — sin Deployment extra, sin Service, sin rotación de certificados TLS ni riesgo de disponibilidad del webhook, y sin latencia agregada por un salto de red; no puede tirar abajo el clúster cuando se cae. Igual necesitás un webhook cuando la decisión requiere estado que el API server no tiene en la petición — llamar a un servicio externo (verificación de firma de imágenes contra un registry, una base de datos de CVEs, un motor de políticas externo), o realizar mutaciones complejas más allá de lo que expresan las políticas de admisión mutantes.

**Q49.** En orden: (1) **RBAC** — cada binding cuyo sujeto viva en el Namespace, especialmente los ClusterRoleBindings, porque un solo binding a `cluster-admin` vuelve cosmético a todo el resto de los controles. (2) **Etiquetas de Pod Security Admission** — porque sin ellas un tenant puede crear un Pod privileged/hostPath/hostNetwork y saltearse de una sola vez la política de red, el aislamiento de nodo y las protecciones de user namespace. Luego: (3) NetworkPolicy default-deny más los permisos explícitos; (4) ResourceQuota + LimitRange; (5) higiene de la especificación del Pod (`runtimeClassName`, `hostUsers`, `automountServiceAccountToken`, host namespaces); (6) ubicación en nodos (taints/tolerations, etiquetas de nodo confiables).

**Q50.** `enforce=baseline` bloquea las cosas genuinamente peligrosas (privileged, host namespaces, hostPath, la mayoría de las capabilities) sin romper las muchas cargas de trabajo que todavía corren como root o carecen de un `seccompProfile`. `warn=restricted` simultáneamente le dice a cada autor exactamente qué tiene que arreglar para llegar al nivel más estricto, generando el backlog de migración sin una caída. Cuando los avisos se acallan, promovés `enforce` a `restricted`.

**Q51.** PSA es un controlador de **admisión**: evalúa Pods en CREATE/UPDATE, no continuamente contra los objetos existentes. Los Pods ya en ejecución nunca se revalidan ni se desalojan, así que un Namespace reetiquetado puede seguir sirviendo Pods no conformes indefinidamente. Implicación: después de etiquetar, tenés que recrear las cargas de trabajo (`rollout restart`) — y deberías revisar la salida de `warn`/`audit` *antes* de aplicar la política, porque la rotura solo aparece en la próxima creación de un Pod, posiblemente durante un drenaje de nodo no relacionado a las 3 de la mañana.

**Q52.** Una única `NetworkPolicy` en el Namespace X con `podSelector: {}` y `policyTypes: [Ingress, Egress]` (default-deny en ambas direcciones), más — lo que todo el mundo se olvida — una regla que permita **egress de DNS hacia CoreDNS en kube-system por UDP/TCP 53**, y normalmente el tráfico Pod-a-Pod dentro del Namespace. Sin la regla de DNS el Namespace queda aislado pero también no funcional, y el ejercicio se marca como incorrecto.

</details>

---

## Referencias

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Documentación de Kubernetes, *Multi-tenancy* — https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Documentación de Kubernetes, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Documentación de Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Documentación de Kubernetes, *Runtime Class* — https://kubernetes.io/docs/concepts/containers/runtime-class/
- Documentación de Kubernetes, *Pod Overhead* — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/
- Documentación de Kubernetes, *User Namespaces* — https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
- Documentación de Kubernetes, *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Documentación de Kubernetes, *Taints and Tolerations* — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Documentación de Kubernetes, *Using Node Authorization* — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Documentación de Kubernetes, *Admission Control: NodeRestriction* — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Documentación de Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Documentación de Kubernetes, *Resource Quotas* — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Documentación de Kubernetes, *Limit Ranges* — https://kubernetes.io/docs/concepts/policy/limit-range/
- Documentación de gVisor, *Kubernetes / containerd quick start* — https://gvisor.dev/docs/user_guide/containerd/quick_start/
- Documentación de gVisor, *Architecture Guide* — https://gvisor.dev/docs/architecture_guide/
- Documentación de Kata Containers, *Kubernetes integration and kata-deploy* — https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy