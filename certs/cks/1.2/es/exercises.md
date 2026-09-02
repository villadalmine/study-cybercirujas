# CKS 1.2 — Ejercicios guiados: usar el CIS Benchmark para revisar la seguridad de los componentes de Kubernetes

**Dominio del examen:** Cluster Setup (1.2) · **Peso:** 3

---

## Requisitos previos del laboratorio

- Un clúster provisionado con `kubeadm`, Kubernetes **v1.34**, con al menos un nodo de plano de control (`cp1`) y un worker (`w1`).
- Acceso a shell como `root` (o `sudo`) en ambos nodos.
- `kube-bench` disponible. Si no está instalado, cualquiera de estas opciones sirve:
  - binario/paquete en el nodo,
  - `docker run --rm -v /etc:/etc:ro -v /var:/var:ro -t aquasec/kube-bench:latest run`,
  - un `Job` dentro del clúster (Ejercicio 7).

> **Sacá un snapshot de tus VMs antes de empezar.** Varios pasos rompen el plano de control a propósito para que practiques la recuperación.

---

## Ejercicio 1 — Entender qué es realmente el benchmark

El **CIS Kubernetes Benchmark** es una guía de hardening construida por consenso y publicada por el Center for Internet Security. Es un *documento*, no una herramienta. `kube-bench` es una implementación open source que automatiza los comandos de auditoría del documento.

Cada entrada del benchmark tiene una forma fija: un **ID** (por ejemplo `1.2.5`), un **título**, un **tipo de puntuación** (Automated o Manual), un **nivel** (L1 = ampliamente seguro, L2 = defensa en profundidad con costo operativo), un **comando de auditoría**, un **resultado esperado** y una **remediación**.

1. En `cp1`, confirmá qué revisiones del benchmark conoce tu herramienta:

   ```bash
   kube-bench version
   ls /etc/kube-bench/cfg/
   ```

2. Mirá las definiciones crudas de los checks, no solamente la salida. Elegí el directorio `cis-*` más nuevo que viste arriba e inspeccionalo:

   ```bash
   BENCH=$(ls -d /etc/kube-bench/cfg/cis-* | sort -V | tail -1)
   echo "$BENCH"
   ls "$BENCH"
   ```

3. Leé la definición de un único check del API server:

   ```bash
   grep -A 25 'id: 1.2.5' "$BENCH/master.yaml"
   ```

4. Fijate en la estructura: `audit:` (el comando que se ejecuta en el nodo), `tests:` → `test_items:` con `flag`, `compare` y `set`, más `remediation:` y `scored:`.

**Preguntas**

1. ¿Por qué leer `master.yaml` importa más que leer la salida resumida de la herramienta?
2. ¿Cuál es la diferencia entre un check marcado como `scored: true` y uno marcado como `scored: false`, y cómo se refleja eso en los resultados?
3. El benchmark se versiona de forma independiente de Kubernetes (por ejemplo, CIS 1.10 apunta a Kubernetes 1.29–1.30). ¿Por qué la numeración de los checks es algo poco confiable para memorizar?
4. `kube-bench` lee manifiestos de pods estáticos y argumentos de procesos. Nombrá una clase de configuración incorrecta que, por lo tanto, **no** puede detectar.

---

## Ejercicio 2 — Ejecutar el benchmark contra el plano de control

`kube-bench` agrupa los checks en **targets**: `master`, `controlplane`, `etcd`, `node`, `policies`. Qué targets son válidos depende del rol del nodo.

1. Ejecutá el barrido completo del plano de control en `cp1`:

   ```bash
   kube-bench run --targets=master,controlplane,etcd,policies
   ```

2. Si la herramienta se niega a arrancar con un error sobre la detección de la versión, fijala explícitamente:

   ```bash
   kube-bench run --benchmark cis-1.10 --targets=master,etcd
   ```

3. Volvé a ejecutarla suprimiendo el texto de remediación para que la lista de pass/fail entre en una pantalla:

   ```bash
   kube-bench run --targets=master --noremediations
   ```

4. Capturá una línea base legible por máquina y extraé solo los fallos:

   ```bash
   kube-bench run --targets=master,etcd --json --outputfile /root/bench-baseline.json
   jq -r '.Controls[].tests[].results[]
          | select(.status=="FAIL")
          | "\(.test_number)\t\(.test_desc)"' /root/bench-baseline.json
   ```

   > Si los nombres de los campos difieren en tu build, descubrilos con
   > `jq '.Controls[0].tests[0].results[0] | keys' /root/bench-baseline.json`.

5. Contá cada clase de resultado:

   ```bash
   jq -r '.Controls[].tests[].results[].status' /root/bench-baseline.json | sort | uniq -c
   ```

6. Ejecutá exactamente un check y después ejecutá todo excepto uno ruidoso:

   ```bash
   kube-bench run --targets=master --check 1.2.5
   kube-bench run --targets=master --skip 1.2.5
   ```

**Preguntas**

5. En `cp1`, ¿por qué `--targets=node` normalmente sigue produciendo resultados aunque sea un nodo del plano de control?
6. ¿Qué significa un estado `WARN`, y por qué ignorar un `WARN` es más peligroso que ignorar un `FAIL` en un contexto de auditoría?
7. Querés que el benchmark haga fallar un pipeline de CI cuando cualquier check falle. ¿Qué flag agregás, y cuál es el riesgo de conectarlo de manera ingenua?
8. ¿Por qué guardar `bench-baseline.json` antes de cambiar nada es un mejor flujo de trabajo que arreglar los hallazgos a medida que los leés?

---

## Ejercicio 3 — Corregir hallazgos de permisos y propiedad de archivos (sección 1.1 / 4.1)

Estos son los hallazgos más baratos de cerrar y aparecen tanto en las secciones del plano de control como en las de los workers.

1. En `cp1`, ejecutá solamente la sección de archivos de configuración:

   ```bash
   kube-bench run --targets=master --check 1.1.1,1.1.2,1.1.11,1.1.12,1.1.19,1.1.20,1.1.21
   ```

2. Inspeccioná el estado actual a mano — esto es lo mismo que hace el comando de auditoría:

   ```bash
   stat -c '%n %a %U:%G' /etc/kubernetes/manifests/*.yaml
   stat -c '%n %a %U:%G' /etc/kubernetes/admin.conf /etc/kubernetes/scheduler.conf
   stat -c '%n %a %U:%G' /var/lib/etcd
   find /etc/kubernetes/pki -name '*.key' -exec stat -c '%n %a %U:%G' {} \;
   ```

3. Introducí una violación deliberadamente y después confirmá que la herramienta la detecta:

   ```bash
   chmod 666 /etc/kubernetes/manifests/kube-apiserver.yaml
   kube-bench run --targets=master --check 1.1.1
   ```

4. Remediá al valor esperado por el benchmark y volvé a verificar:

   ```bash
   chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
   chown root:root /etc/kubernetes/manifests/kube-apiserver.yaml
   kube-bench run --targets=master --check 1.1.1
   ```

5. Endurecé el directorio de datos de etcd y sus claves PKI:

   ```bash
   chmod 700 /var/lib/etcd
   chown etcd:etcd /var/lib/etcd 2>/dev/null || chown root:root /var/lib/etcd
   chmod 600 /etc/kubernetes/pki/*.key
   ```

6. Repetí el ejercicio en el worker. En `w1`:

   ```bash
   kube-bench run --targets=node --check 4.1.1,4.1.2,4.1.9,4.1.10
   stat -c '%n %a %U:%G' /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet.conf
   chmod 600 /var/lib/kubelet/config.yaml
   chown root:root /var/lib/kubelet/config.yaml
   ```

**Preguntas**

9. `/etc/kubernetes/manifests/*.yaml` solo es legible por root de cualquiera de las dos maneras. ¿Por qué el benchmark insiste igual en `600` en lugar de `644`?
10. ¿Por qué se señala a `/var/lib/etcd` con el modo más estricto (`700`) de todas las rutas del benchmark?
11. Un hallazgo dice que la *propiedad* de `admin.conf` es incorrecta aunque el modo sea `600`. Dá un escenario donde el modo por sí solo es insuficiente.
12. Después de un `chmod 600` sobre un manifiesto de pod estático, ¿hace falta reiniciar el kubelet? ¿Por qué sí o por qué no?

---

## Ejercicio 4 — Remediar hallazgos de kube-apiserver (sección 1.2)

El API server se configura enteramente mediante flags en `/etc/kubernetes/manifests/kube-apiserver.yaml`. El kubelet vigila ese directorio y reinicia el pod estático al escribirse.

1. Mirá los flags que el benchmark está parseando realmente:

   ```bash
   ps -ef | grep '[k]ube-apiserver' | tr ' ' '\n' | grep '^--' | sort
   ```

2. Ejecutá la sección del API server y listá sus fallos:

   ```bash
   kube-bench run --targets=master --json \
     | jq -r '.Controls[].tests[].results[]
              | select(.status=="FAIL" and (.test_number|startswith("1.2")))
              | "\(.test_number)\t\(.test_desc)"'
   ```

3. Hacé un backup del manifiesto antes de editarlo — un error de sintaxis acá deja el clúster fuera de línea:

   ```bash
   cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
   ```

4. Aplicá tres remediaciones de bajo riesgo. Editá el manifiesto y asegurate de que la lista `command:` contenga:

   ```yaml
       - --profiling=false
       - --service-account-lookup=true
       - --request-timeout=60s
   ```

5. Observá cómo vuelve el pod estático. El ID del contenedor cambia cuando el manifiesto se reescribe:

   ```bash
   watch -n 2 'crictl ps --name kube-apiserver'
   # o, una vez que la API vuelve a responder:
   kubectl -n kube-system get pod kube-apiserver-cp1 -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
   ```

6. Asegurate de que el plugin de admisión que exige el benchmark esté presente. Encontrá la línea existente y agregá `NodeRestriction` si falta:

   ```bash
   grep 'enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

7. Ahora activá la trampa clásica. Agregá `--anonymous-auth=false` al manifiesto, guardá y observá:

   ```bash
   sleep 30
   crictl ps -a --name kube-apiserver
   crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -20
   kubectl get nodes
   ```

8. Diagnosticalo. `kubeadm` configura `livenessProbe`/`readinessProbe`/`startupProbe` contra `/livez`, `/readyz` y `/healthz` en el puerto 6443 **sin credenciales**. Con la autenticación anónima deshabilitada, las probes reciben `401`, el kubelet declara al contenedor no saludable y lo mata en un bucle.

9. Recuperate:

   ```bash
   cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
   sleep 45 && kubectl get nodes
   ```

10. Aplicá en cambio la remediación moderna. En Kubernetes 1.32+, el acceso anónimo puede restringirse a rutas específicas mediante una configuración estructurada de autenticación:

    ```bash
    mkdir -p /etc/kubernetes/auth
    cat > /etc/kubernetes/auth/anonymous.yaml <<'EOF'
    apiVersion: apiserver.config.k8s.io/v1
    kind: AuthenticationConfiguration
    anonymous:
      enabled: true
      conditions:
      - path: /livez
      - path: /readyz
      - path: /healthz
    EOF
    ```

    Después referencialo desde el manifiesto, montando el directorio dentro del pod:

    ```yaml
        - --authentication-config=/etc/kubernetes/auth/anonymous.yaml
    ```

    ```yaml
        volumeMounts:
        - mountPath: /etc/kubernetes/auth
          name: auth-config
          readOnly: true
      volumes:
      - hostPath:
          path: /etc/kubernetes/auth
          type: DirectoryOrCreate
        name: auth-config
    ```

11. Verificá que las peticiones anónimas ahora sean rechazadas en todas partes excepto en las rutas de las probes:

    ```bash
    curl -sk https://127.0.0.1:6443/livez ; echo
    curl -sk https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets | head -5
    ```

**Preguntas**

13. ¿Por qué la remediación `--anonymous-auth=false` del benchmark rompe un clúster `kubeadm` por defecto, y qué falla exactamente primero?
14. `--authentication-config` y `--anonymous-auth` no pueden estar ambos configurados. ¿Qué implica eso para un plan de rollback?
15. ¿Contra qué protege `--service-account-lookup=true` que la validación ordinaria de firma de tokens no cubre?
16. Agregaste un flag y el API server nunca vuelve — `kubectl` da timeout. Nombrá dos maneras de leer el motivo del fallo sin un API server funcionando.
17. ¿Por qué aparece `NodeRestriction` en el benchmark, y a qué principal restringe?

---

## Ejercicio 5 — Remediar hallazgos de etcd (sección 2)

etcd guarda cada Secret del clúster en texto plano a menos que se configure el cifrado en reposo. El compromiso de etcd es el compromiso total del clúster.

1. Ejecutá la sección de etcd:

   ```bash
   kube-bench run --targets=etcd
   ```

2. Leé los flags en vivo:

   ```bash
   ps -ef | grep '[e]tcd ' | tr ' ' '\n' | grep '^--' | sort
   ```

3. Verificá las cuatro propiedades de seguridad de transporte que le importan al benchmark, en el manifiesto `/etc/kubernetes/manifests/etcd.yaml`:

   ```bash
   grep -E 'cert-file|key-file|client-cert-auth|auto-tls|trusted-ca-file|peer-' \
     /etc/kubernetes/manifests/etcd.yaml
   ```

   Deberías ver `--client-cert-auth=true`, `--peer-client-cert-auth=true`, y **ningún** `--auto-tls=true` ni `--peer-auto-tls=true`.

4. Comprobá que la autenticación por certificado de cliente esté aplicada. Primero, un intento sin autenticar:

   ```bash
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     endpoint health
   ```

   Después, uno correctamente autenticado:

   ```bash
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     endpoint health
   ```

5. Demostrá por qué esto importa — leé un Secret directamente del almacén de datos:

   ```bash
   kubectl -n default create secret generic cis-demo --from-literal=password=Sup3rS3cret
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/default/cis-demo | strings | grep -i sup3r
   ```

6. Confirmá que el API server habla con etcd sobre mTLS con una identidad dedicada:

   ```bash
   grep -E 'etcd-(cafile|certfile|keyfile)' /etc/kubernetes/manifests/kube-apiserver.yaml
   openssl x509 -in /etc/kubernetes/pki/apiserver-etcd-client.crt -noout -subject -issuer
   ```

7. Verificá si etcd usa una CA distinta de la CA del clúster:

   ```bash
   openssl x509 -in /etc/kubernetes/pki/etcd/ca.crt -noout -subject -fingerprint
   openssl x509 -in /etc/kubernetes/pki/ca.crt      -noout -subject -fingerprint
   ```

**Preguntas**

18. ¿Qué agrega `--client-cert-auth=true` por encima de tener ya configurados `--cert-file` y `--key-file`?
19. ¿Por qué el benchmark insiste en `--auto-tls=false` si auto-TLS igual cifra la conexión?
20. El paso 5 expuso un Secret en texto plano. ¿Qué control adicional cierra esto, y es un flag de etcd o un flag del API server?
21. El benchmark pide que etcd use una CA **única**. ¿Qué ataque habilita compartir la CA del clúster con etcd?
22. Explicá la diferencia práctica entre los flags `--peer-*` y los orientados al cliente.

---

## Ejercicio 6 — Remediar hallazgos del kubelet (sección 4.2)

El kubelet es el objetivo más atractivo en un worker: puede hacer exec dentro de cualquier pod del nodo. Los clústeres `kubeadm` modernos lo configuran mediante `/var/lib/kubelet/config.yaml`, **no** con flags de línea de comandos — y los ajustes del archivo de configuración son los que tenés que editar.

1. En `w1`, ejecutá la sección del kubelet:

   ```bash
   kube-bench run --targets=node
   ```

2. Determiná de dónde viene realmente la configuración:

   ```bash
   systemctl cat kubelet | grep -E 'ExecStart|EnvironmentFile|--config'
   cat /var/lib/kubelet/config.yaml
   ```

3. Confirmá la postura actual de authn/authz. Estos son los dos checks de mayor valor de toda la sección:

   ```bash
   grep -A 5 -E '^authentication:|^authorization:' /var/lib/kubelet/config.yaml
   ```

   Esperado: `authentication.anonymous.enabled: false`, `authentication.x509.clientCAFile` configurado, `authorization.mode: Webhook`.

4. Comprobá el efecto atacando la API del kubelet desde el propio nodo:

   ```bash
   curl -sk https://127.0.0.1:10250/pods | head -c 200 ; echo
   curl -s  http://127.0.0.1:10255/pods | head -c 200 ; echo
   ```

   El primero debería devolver `401 Unauthorized`; el segundo debería fallar al conectar porque `readOnlyPort` es `0`.

5. Debilitá temporalmente el kubelet para ver la superficie de fallo y después observá qué gana un atacante:

   ```bash
   cp /var/lib/kubelet/config.yaml /root/kubelet-config.yaml.bak
   sed -i 's/^\( *\)enabled: false/\1enabled: true/' /var/lib/kubelet/config.yaml
   systemctl restart kubelet && sleep 10
   curl -sk https://127.0.0.1:10250/pods | jq -r '.items[].metadata.name' | head
   kube-bench run --targets=node --check 4.2.1
   ```

6. Restaurá de inmediato:

   ```bash
   cp /root/kubelet-config.yaml.bak /var/lib/kubelet/config.yaml
   systemctl restart kubelet && sleep 10
   kube-bench run --targets=node --check 4.2.1
   ```

7. Aplicá las remediaciones comunes restantes. Editá `/var/lib/kubelet/config.yaml` para que contenga:

   ```yaml
   readOnlyPort: 0
   streamingConnectionIdleTimeout: 5m
   makeIPTablesUtilChains: true
   eventRecordQPS: 5
   rotateCertificates: true
   serverTLSBootstrap: true
   tlsCipherSuites:
     - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
     - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
     - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
   ```

8. Ahora la segunda trampa clásica — `protectKernelDefaults`. Agregala y reiniciá:

   ```bash
   echo 'protectKernelDefaults: true' >> /var/lib/kubelet/config.yaml
   systemctl restart kubelet
   sleep 5
   systemctl is-active kubelet
   journalctl -u kubelet --no-pager -n 30 | grep -i sysctl
   ```

9. Si el kubelet se niega a arrancar, configurá los parámetros del kernel que el kubelet espera en lugar de revertir el ajuste:

   ```bash
   cat > /etc/sysctl.d/99-kubelet-cis.conf <<'EOF'
   vm.overcommit_memory = 1
   vm.panic_on_oom = 0
   kernel.panic = 10
   kernel.panic_on_oops = 1
   EOF
   sysctl --system
   systemctl restart kubelet && systemctl is-active kubelet
   ```

10. Volvé a ejecutar la sección y hacé un diff contra tu línea base:

    ```bash
    kube-bench run --targets=node --noremediations
    ```

11. Si habilitaste `serverTLSBootstrap`, el certificado de servidor del kubelet ahora necesita aprobación:

    ```bash
    kubectl get csr
    kubectl certificate approve <csr-name>
    ```

**Preguntas**

23. ¿Por qué importa `authorization.mode: Webhook` incluso cuando `anonymous.enabled` ya es `false`?
24. ¿Qué podría hacer exactamente un atacante en el puerto `10255` si `readOnlyPort` se hubiera dejado en su antiguo valor por defecto de `10255`?
25. ¿Por qué `protectKernelDefaults: true` impide que el kubelet arranque en algunos hosts, y cuál es el argumento de seguridad para mantenerlo activado de todos modos?
26. Editaste `/var/lib/kubelet/config.yaml` pero `kube-bench` sigue reportando el valor viejo. Dá dos causas distintas.
27. `rotateCertificates` y `serverTLSBootstrap` cubren certificados diferentes. ¿Cuál es cuál, y por qué el segundo genera CSRs pendientes?
28. ¿Por qué `streamingConnectionIdleTimeout: 0` es un hallazgo y no una comodidad?

---

## Ejercicio 7 — Auditar CoreDNS (el componente "kubedns")

El benchmark no tiene una sección dedicada a DNS, así que este componente se revisa a través de los checks generales de política de la sección 5 más la inspección manual. CoreDNS está altamente expuesto: cada pod del clúster puede alcanzarlo por defecto.

1. Inspeccioná la postura de seguridad de la carga de trabajo:

   ```bash
   kubectl -n kube-system get deploy coredns -o yaml \
     | grep -A 15 -E 'securityContext|serviceAccountName|automountServiceAccountToken'
   ```

   Buscá `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, y capacidades reducidas a `ALL` con solamente `NET_BIND_SERVICE` agregada.

2. Verificá qué tiene permitido hacer su ServiceAccount:

   ```bash
   kubectl -n kube-system get sa coredns
   kubectl get clusterrole system:coredns -o yaml
   kubectl get clusterrolebinding system:coredns -o yaml
   ```

3. Ejecutá los checks de política y leé la guía manual:

   ```bash
   kube-bench run --targets=policies
   ```

4. Verificá los dos checks de la ServiceAccount `default` que plantea el benchmark, usando el namespace de CoreDNS como ejemplo:

   ```bash
   kubectl -n kube-system get sa default -o yaml | grep -i automount
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
              | "\(.metadata.name)\t\(.subjects[]?.kind):\(.subjects[]?.name)"'
   ```

5. Leé la configuración de CoreDNS en busca de plugins riesgosos:

   ```bash
   kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
   ```

   Confirmá que no haya un `proxy`/`forward` comodín hacia un resolver no confiable y que el plugin `kubernetes` esté acotado a `cluster.local`.

6. Demostrá la exposición de la red plana y después restringila:

   ```bash
   kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \
     nslookup kubernetes.default.svc.cluster.local
   ```

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: coredns-ingress
     namespace: kube-system
   spec:
     podSelector:
       matchLabels:
         k8s-app: kube-dns
     policyTypes: ["Ingress"]
     ingress:
     - ports:
       - protocol: UDP
         port: 53
       - protocol: TCP
         port: 53
   EOF
   ```

7. Volvé a probar la resolución para confirmar que no rompiste el clúster:

   ```bash
   kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \
     nslookup kubernetes.default.svc.cluster.local
   ```

**Preguntas**

29. ¿Por qué CoreDNS necesita `NET_BIND_SERVICE` y nada más?
30. El check 5.1.5 del benchmark dice que la ServiceAccount `default` no debería usarse activamente y no debería montar automáticamente su token. ¿Cuál es el ataque concreto que esto previene?
31. La NetworkPolicy de arriba permite ingress en el 53 desde **cualquier** origen. ¿Por qué sigue siendo una mejora respecto de no tener ninguna política, y cómo se vería una versión más estricta?
32. Si CoreDNS fuera comprometido, nombrá dos ataques que el atacante podría montar contra cargas de trabajo que nunca tocan el API server.

---

## Ejercicio 8 — Ejecutar el benchmark dentro del clúster y producir un reporte

En clústeres reales — y en nodos a los que no podés entrar por SSH — el benchmark se ejecuta como un Job.

1. Creá un Job que ejecute `kube-bench` en el nodo del plano de control:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: kube-bench-master
     namespace: default
   spec:
     template:
       spec:
         hostPID: true
         nodeSelector:
           node-role.kubernetes.io/control-plane: ""
         tolerations:
         - key: node-role.kubernetes.io/control-plane
           operator: Exists
           effect: NoSchedule
         containers:
         - name: kube-bench
           image: docker.io/aquasec/kube-bench:latest
           command: ["kube-bench", "run", "--targets", "master,etcd,controlplane,policies"]
           volumeMounts:
           - name: var-lib-etcd
             mountPath: /var/lib/etcd
             readOnly: true
           - name: etc-kubernetes
             mountPath: /etc/kubernetes
             readOnly: true
           - name: etc-systemd
             mountPath: /etc/systemd
             readOnly: true
         restartPolicy: Never
         volumes:
         - name: var-lib-etcd
           hostPath: {path: /var/lib/etcd}
         - name: etc-kubernetes
           hostPath: {path: /etc/kubernetes}
         - name: etc-systemd
           hostPath: {path: /etc/systemd}
   EOF
   ```

2. Leé el reporte:

   ```bash
   kubectl wait --for=condition=complete job/kube-bench-master --timeout=120s
   kubectl logs job/kube-bench-master | tail -40
   ```

3. Compará tu estado posterior a la remediación contra la línea base que guardaste en el Ejercicio 2:

   ```bash
   kube-bench run --targets=master,etcd --json --outputfile /root/bench-after.json
   diff <(jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | .test_number' /root/bench-baseline.json | sort) \
        <(jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | .test_number' /root/bench-after.json    | sort)
   ```

4. Limpiá:

   ```bash
   kubectl delete job kube-bench-master
   kubectl -n default delete secret cis-demo
   kubectl -n kube-system delete networkpolicy coredns-ingress
   ```

**Preguntas**

33. El Job monta `/etc/kubernetes` y `/var/lib/etcd` en modo solo lectura desde el host. ¿Por qué un Pod que puede hacer esto tiene, en la práctica, privilegios de nivel plano de control?
34. Se configura `hostPID: true`. ¿Para qué lo usa `kube-bench`, y cuál es el costo de seguridad de otorgarlo?
35. El Job que se planifica en el nodo del plano de control necesita una toleration. ¿Qué pasa con los resultados si en cambio cae en un worker?
36. Tu diff muestra un check que pasó de `FAIL` a `PASS` sin que cambiaras nada. Dá dos explicaciones plausibles.

---

<details>
<summary><strong>Clave de respuestas</strong> — hacé clic para expandir</summary>

### Ejercicio 1

**1.** El resumen te dice *que* un check falló; `master.yaml` te dice *qué comando se ejecutó* y *qué cadena comparó*. Eso importa porque el parseo de la herramienta es textual y puede producir resultados falsos — por ejemplo, un flag configurado en un archivo de configuración en lugar de en la línea de comandos, un flag que aparece dos veces, o un valor que la herramienta compara con `has` en lugar de una comparación exacta. En un examen o en una auditoría tenés que poder justificar un veredicto, no solamente reportarlo.

**2.** Los checks con `scored: true` contribuyen al total de pass/fail y están pensados para ser verificables por máquina ("Automated" en el lenguaje de CIS). Los checks con `scored: false` ("Manual") requieren juicio humano — la herramienta no puede decidir, así que emite `WARN` e imprime la guía en lugar de un veredicto. Igual cuentan como riesgo no revisado.

**3.** Las revisiones del benchmark renumeran, fusionan, dividen y retiran checks a medida que Kubernetes cambia. Los checks del puerto inseguro removido (`--insecure-port`, `--insecure-bind-address`) desaparecieron por completo una vez que esos flags se eliminaron de Kubernetes; el check de `--hostname-override` del kubelet fue retirado; los checks de política de la sección 5 se reorganizaron en torno a los Pod Security Standards después de que se removiera PodSecurityPolicy. Memorizá el *control* ("el kubelet no debe permitir autenticación anónima") y buscá el número.

**4.** Cualquier cosa que no sea visible en una lista de argumentos de proceso o en un archivo de configuración en disco. Ejemplos: bindings de RBAC que otorgan privilegios excesivos, si los logs de auditoría efectivamente se envían a algún lado, si los certificados en uso son realmente confiables, el comportamiento de los admission webhooks, la configuración de los contenedores en tiempo de ejecución y la alcanzabilidad de la red. Tampoco puede ver planos de control gestionados (EKS/GKE/AKS) donde el API server no es un proceso en tu nodo.

### Ejercicio 2

**5.** Un nodo de plano de control `kubeadm` también ejecuta un kubelet y `kube-proxy` — *es* un nodo. Los checks de la sección 4 le aplican, y un API server endurecido en un nodo con un kubelet con autenticación anónima no está endurecido en absoluto.

**6.** `WARN` significa que el check es Manual o que la herramienta no pudo reunir información suficiente para decidir. Es más peligroso que `FAIL` porque un `FAIL` es un defecto conocido con una corrección conocida, mientras que un `WARN` es un *desconocido* — los equipos rutinariamente filtran los `WARN` de los dashboards y después reportan "cero hallazgos" en un clúster con controles sin revisar. El truncamiento silencioso de una auditoría se lee como una cobertura que no tiene.

**7.** `--exit-code 1` hace que `kube-bench` salga con código distinto de cero cuando hay al menos un `FAIL`. El riesgo ingenuo: cualquier actualización del benchmark agrega checks nuevos, así que un pipeline que ayer estaba en verde hoy se pone en rojo por razones ajenas a tu cambio. Mitigalo fijando `--benchmark`, manteniendo una lista `--skip` explícita con justificaciones documentadas, y revisando los skips con una periodicidad definida.

**8.** Tres razones. Primero, necesitás un diff de antes/después para probar que la remediación funcionó — de lo contrario lo estás afirmando sin más. Segundo, algunas remediaciones cambian *otros* checks como efecto secundario, y solo un diff revela eso. Tercero, si rompés el clúster necesitás saber cómo se veía la configuración que funcionaba.

### Ejercicio 3

**9.** Defensa en profundidad frente a un compromiso *parcial*. Cualquier proceso que corra como usuario no root y que pueda leer el manifiesto conoce la topología completa del plano de control, las rutas de los certificados, los endpoints de etcd y la configuración de admisión — reconocimiento útil para la escalada de privilegios. También importa para las herramientas de backup, los shippers de logs y los agentes de monitoreo, que a menudo corren como usuarios sin privilegios con amplio acceso de lectura al sistema de archivos.

**10.** `/var/lib/etcd` contiene cada objeto del clúster, incluyendo cada Secret, en texto plano a menos que el cifrado en reposo esté habilitado. El acceso de lectura a ese directorio equivale a `cluster-admin` más cada credencial que el clúster tiene. No hay ruta más sensible en la máquina. `700` además bloquea el acceso de grupo, lo que importa porque las cuentas del runtime de contenedores y de monitoreo suelen colocarse en grupos compartidos.

**11.** El modo `600` significa "lectura/escritura solo para el propietario" — pero si el propietario no es `root`, entonces la cuenta que *sí* lo posee tiene acceso completo. Un caso real común: una ejecución mal configurada de backup o de gestión de configuración deja `admin.conf` como propiedad de una cuenta de servicio, así que esa cuenta de servicio tiene un kubeconfig de `cluster-admin` a pesar del modo restrictivo. El modo gobierna *quién más*; la propiedad gobierna *quién*.

**12.** No. El kubelet vigila `/etc/kubernetes/manifests` en busca de cambios en el *contenido* de los archivos, y un cambio solo de metadatos (modo/propietario) no altera el contenido, así que no se reinicia nada. Esto es conveniente: la remediación de permisos en el plano de control es de cero downtime. Los cambios de flags del paso 4 del Ejercicio 4 son lo opuesto — esos reescriben el archivo y sí disparan un reinicio del pod.

### Ejercicio 4

**13.** `kubeadm` le da al pod estático `kube-apiserver` entradas de `startupProbe`, `livenessProbe` y `readinessProbe` que emiten peticiones HTTPS `GET` planas a `/livez`, `/readyz` y `/healthz` en el puerto 6443 sin credenciales de cliente. Esas son peticiones anónimas. Con `--anonymous-auth=false` devuelven `401`, el kubelet las cuenta como fallos de probe, y la startup/liveness probe mata al contenedor — que después vuelve a fallar al reiniciarse. El primer síntoma visible es el contenedor del API server reiniciándose en bucle y `kubectl` dando timeout.

**14.** Los dos son mutuamente excluyentes: configurar ambos hace que el API server se niegue a arrancar. Así que el rollback no es "eliminar una línea" — tenés que eliminar `--authentication-config`, y si además habías eliminado el volumen montado tenés que restaurarlo también, o el contenedor fallará por una ruta faltante. Guardá el manifiesto de backup y hacé rollback del archivo entero, no de flags individuales. Notá también que `--authentication-config` lee desde dentro del sistema de archivos del pod, así que el volumen `hostPath` y el `volumeMount` deben estar ambos presentes o el API server sale antes de llegar siquiera a atender una petición.

**15.** La validación de firma solo prueba que el token fue emitido por la clave de firma de este clúster. `--service-account-lookup=true` hace que el API server además verifique que el objeto Secret/token correspondiente todavía exista en etcd. Sin eso, un token estático legacy de ServiceAccount que haya sido robado permanece válido para siempre incluso después de que borres la ServiceAccount — la revocación silenciosamente no hace nada. (Los tokens acotados modernos llevan expiración y audiencia, lo que reduce pero no elimina la preocupación.)

**16.** Dos cualesquiera de: `crictl ps -a --name kube-apiserver` más `crictl logs <id>` para leer el stderr del contenedor directamente desde el runtime; `journalctl -u kubelet -f` para ver la perspectiva del kubelet sobre por qué está reiniciando el pod estático; leer `/var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log` en disco; o `docker ps -a` / `docker logs` en un runtime basado en Docker. La idea clave es que un pod estático no necesita al API server para correr, así que el runtime y el kubelet todavía tienen la evidencia.

**17.** `NodeRestriction` es un plugin de admisión que limita lo que un kubelet puede hacer con su propia identidad de nodo: solo puede modificar su propio objeto `Node` y solamente objetos `Pod` vinculados a sí mismo, y no puede agregar ni quitar ciertas etiquetas. Restringe al principal `system:node:<name>`. Sin él, robar las credenciales de un solo kubelet le permite a un atacante manipular los objetos de otros nodos y etiquetarse a sí mismo hacia posiciones de planificación privilegiadas.

### Ejercicio 5

**18.** `--cert-file`/`--key-file` le dan a etcd un certificado de servidor — eso te da cifrado y autenticación del servidor, pero cualquier cliente que confíe en la CA puede conectarse. `--client-cert-auth=true` hace que etcd *exija* que los clientes presenten un certificado firmado por la CA confiable, convirtiendo TLS unidireccional en TLS mutuo. Sin eso, el acceso de red al puerto 2379 es acceso a todo el almacén de datos.

**19.** Auto-TLS hace que etcd genere sus propios certificados autofirmados al arrancar. El tráfico está cifrado, pero no hay una CA confiable contra la cual validar, así que las identidades de peers y clientes no pueden verificarse — el cifrado protege contra la escucha pasiva mientras deja el despliegue abierto a un man-in-the-middle activo o a cualquier cliente que se conecte. El cifrado sin autenticación no es un control de seguridad.

**20.** Cifrado en reposo, configurado con el flag del API server `--encryption-provider-config` apuntando a una `EncryptionConfiguration` (proveedores AES-CBC/AES-GCM/KMS). Es deliberadamente un flag del **API server**, no de etcd: el API server cifra los recursos antes de escribirlos, así que etcd nunca ve texto plano. Los Secrets existentes se mantienen en su forma vieja hasta que se reescriben — `kubectl get secrets -A -o json | kubectl replace -f -` fuerza el recifrado.

**21.** Si etcd confía en la CA del clúster, entonces *cualquier* certificado que esa CA emita se convierte en un certificado de cliente válido para etcd. La CA del clúster firma rutinariamente certificados de cliente de kubelet a través de la API de CSR. Así que un atacante que compromete un solo nodo worker — o que consigue que se apruebe una CSR — obtiene un certificado que se autentica directamente contra etcd, evitando por completo el API server, RBAC, el control de admisión y el logging de auditoría. Una CA separada para etcd rompe esa cadena.

**22.** El conjunto `--cert-file`/`--key-file`/`--client-cert-auth`/`--trusted-ca-file` gobierna el canal **cliente-a-servidor** en el puerto 2379 — así es como el API server habla con etcd. Los equivalentes `--peer-*` gobiernan el canal de replicación **servidor-a-servidor** en el puerto 2380 entre los miembros de etcd. Ambos necesitan mTLS: un canal de peers sin autenticar le permite a un atacante unirse al clúster como miembro falso y leer o escribir todo el keyspace vía replicación, sin tocar nunca el puerto 2379.

### Ejercicio 6

**23.** La autenticación responde "quién sos"; la autorización responde "qué podés hacer". Con `anonymous.enabled: false` y `authorization.mode: AlwaysAllow`, *cualquier* cliente que pueda presentar un certificado firmado por la CA de clientes del kubelet — incluyendo la credencial del kubelet de cualquier otro nodo, o cualquier carga de trabajo que obtenga una — consigue acceso irrestricto a la API del kubelet: listar pods, leer logs y hacer `exec` dentro de los contenedores de ese nodo. El modo `Webhook` delega cada petición al `SubjectAccessReview` del API server, con lo que RBAC efectivamente aplica.

**24.** El puerto 10255 es el puerto de solo lectura del kubelet: sin autenticación, sin autorización, HTTP plano. Un atacante con acceso a la red de pods podría enumerar `/pods` para obtener cada spec de pod del nodo — incluyendo variables de entorno, que frecuentemente contienen credenciales — más `/metrics` y `/spec` para reconocimiento del nodo. No requiere credenciales en absoluto, así que es alcanzable desde cualquier pod comprometido en la red. Configurar `readOnlyPort: 0` lo deshabilita; este es el valor por defecto de `kubeadm` en las versiones actuales.

**25.** Con `protectKernelDefaults: true`, el kubelet se niega a sobrescribir los valores sysctl del kernel y en cambio **falla con error al arrancar** si los valores del host no coinciden ya con lo que espera (`vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`). El argumento de seguridad: sin eso, el kubelet muta silenciosamente los parámetros ajustables del kernel del host al arrancar, lo que significa que un kubelet comprometido o mal configurado puede cambiar el comportamiento relevante para la seguridad de toda la máquina, y tu línea base de hardening del host no está realmente en vigor. Arreglá el host, no deshabilites el flag.

**26.** Dos cualesquiera de: (a) no reiniciaste el kubelet, así que el proceso en ejecución todavía tiene la configuración vieja — el archivo de configuración se lee al arrancar, no se vigila (a menos que la recarga dinámica esté habilitada); (b) el ajuste *también* está presente como flag de línea de comandos en la unidad de systemd o en un drop-in, y los flags le ganan al archivo de configuración; (c) editaste el archivo en el nodo equivocado; (d) la indentación de YAML puso la clave en el bloque equivocado, así que el kubelet la ignoró — revisá `journalctl -u kubelet` en busca de una advertencia de parseo; (e) `kube-bench` está leyendo una ruta de configuración distinta de aquella con la que se arrancó el kubelet.

**27.** `rotateCertificates: true` rota el certificado de **cliente** del kubelet — la credencial que usa para autenticarse *ante* el API server. `serverTLSBootstrap: true` hace que el kubelet solicite su certificado de **servidor** — el que presenta a los clientes en el puerto 10250 — al API server vía la API de CSR en lugar de autofirmarlo. El segundo genera CSRs pendientes porque las CSRs de certificados de servidor no son aprobadas automáticamente por el controlador por defecto (aprobarlas automáticamente le permitiría a un nodo reclamar nombres/IPs arbitrarios), así que un humano o un controlador aprobador dedicado debe aprobar cada una.

**28.** `streamingConnectionIdleTimeout: 0` deshabilita el timeout en los streams de `exec`, `attach` y `port-forward`. Una sesión abandonada o secuestrada queda entonces abierta indefinidamente: sobrevive a la rotación de credenciales y a la revocación de RBAC, porque la decisión de autorización se tomó una sola vez en el momento de la conexión. También es un vector de agotamiento de recursos. El benchmark pide un valor distinto de cero, convencionalmente `5m` o más.

### Ejercicio 7

**29.** CoreDNS se enlaza a los puertos 53 UDP y TCP, que están por debajo de 1024 y por lo tanto requieren `CAP_NET_BIND_SERVICE` en Linux cuando se corre como usuario no root. Todo lo demás — escrituras al sistema de archivos, sockets raw, carga de módulos, `chroot` — es innecesario para un servidor DNS que lee sus datos de zona de la API y su configuración de un ConfigMap montado. De ahí `drop: [ALL]` más un único `add: [NET_BIND_SERVICE]`, con `readOnlyRootFilesystem: true` y `allowPrivilegeEscalation: false`.

**30.** Cada pod que no nombra una ServiceAccount obtiene la `default` del namespace, y por defecto su token se monta en `/var/run/secrets/kubernetes.io/serviceaccount/token`. Si un atacante logra ejecución de código en *cualquier* pod de ese tipo, inmediatamente tiene una credencial de API válida con lo que sea que se le haya otorgado a la SA `default` — y en clústeres donde alguien vinculó `default` a un Role amplio (o a `cluster-admin`), eso es escalada instantánea. Configurar `automountServiceAccountToken: false` en la SA o en el Pod quita la credencial del radio de impacto de un compromiso de contenedor.

**31.** Antes de la política, los pods de CoreDNS no tienen ninguna restricción de ingress: cualquier pod del clúster puede alcanzar *cualquier* puerto en ellos, incluyendo las métricas en el 9153, el endpoint de salud en 8080/8181 y — si alguna vez se agregara un sidecar o un puerto de depuración — también eso. Después de la política, solo 53/UDP y 53/TCP son alcanzables, lo que reduce la superficie de ataque al único servicio que CoreDNS se supone que ofrece. Una versión más estricta agrega selectores `from:`, pero eso rara vez es práctico ya que todos los namespaces legítimamente necesitan DNS; el endurecimiento realista es una política separada que permita el 9153 solo desde el namespace de monitoreo, más una política de egress que limite a CoreDNS al API server y a los resolvers upstream.

**32.** Dos cualesquiera de: (a) envenenamiento de DNS — devolver IPs controladas por el atacante para `internal-service.default.svc.cluster.local`, redirigiendo el tráfico servicio-a-servicio hacia un proxy que cosecha credenciales y tokens de las peticiones interceptadas; (b) exfiltración vía el plugin `forward` — apuntar la resolución upstream a un nameserver controlado por el atacante y tunelizar datos hacia afuera sobre consultas DNS, lo que frecuentemente evade el filtrado de egress; (c) denegación de servicio devolviendo NXDOMAIN para nombres críticos, lo que rompe todo el clúster ya que casi toda carga de trabajo resuelve nombres de servicio; (d) reconocimiento — la ServiceAccount de CoreDNS puede listar Services y EndpointSlices en todo el clúster, así que su token mapea la topología completa del clúster.

### Ejercicio 8

**33.** `/etc/kubernetes` contiene `admin.conf` (un kubeconfig de `cluster-admin`) y todo el árbol `pki/`, incluyendo `ca.key` — la clave de firma del clúster. El acceso de lectura a `ca.key` le permite a un atacante acuñar un certificado de cliente para cualquier usuario o grupo, incluido `system:masters`, lo que evita RBAC por completo y no es revocable sin rotar la CA. `/var/lib/etcd` entrega cada Secret en texto plano. Así que la capacidad de crear este Pod es la capacidad de convertirse en cluster-admin permanentemente — que es exactamente por qué la sección de políticas del benchmark marca los Pods que montan rutas sensibles del host, y por qué `hostPath` debería estar bloqueado por el control de admisión para cualquier cosa que no sea una carga de trabajo auditada y de vida corta.

**34.** `kube-bench` usa el namespace de PID del host para inspeccionar las líneas de comando de los procesos del plano de control (`kube-apiserver`, `etcd`, `kubelet`) que corren fuera de su propio contenedor — así es como lee los flags que audita. El costo: `hostPID` le permite al contenedor ver y enviar señales a cada proceso del nodo, leer `/proc/<pid>/environ` para obtener las variables de entorno de otros procesos (una fuga de credenciales común) y, combinado con otros privilegios, escapar al host. Es un otorgamiento genuino de privilegios, no una formalidad.

**35.** Los targets `master` y `etcd` reportarían una gran cantidad de fallos o errores — no porque el clúster sea inseguro, sino porque `/etc/kubernetes/manifests/kube-apiserver.yaml` y `/var/lib/etcd` no existen en un worker. La lección: los resultados del benchmark solo son significativos cuando el target coincide con el rol real del nodo, y "falló todo" es más a menudo un error de targeting que un hallazgo. Confirmá siempre en qué nodo cayó el Job antes de actuar sobre los resultados.

**36.** Dos cualesquiera de: (a) una remediación que aplicaste para otro check también satisfizo a este — por ejemplo, reemplazar el manifiesto del API server para agregar un flag también corrigió su modo de archivo; (b) `kube-bench` seleccionó una revisión distinta del benchmark en la segunda ejecución (la autodetección puede cambiar después de que cambie la versión de un componente), y esa revisión define el check de otra manera o lo retira; (c) el check es sensible al tiempo y el componente no había terminado de reiniciarse durante la primera ejecución, así que la herramienta leyó un proceso obsoleto o ausente; (d) el check es Manual y el manejo de `WARN`/`PASS` de la herramienta difiere entre los conjuntos de flags de las dos invocaciones.

</details>

---

## Referencias

- CKS Curriculum v1.34, CNCF — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
- CIS Kubernetes Benchmark (requiere registro) — <https://www.cisecurity.org/benchmark/kubernetes>
- `kube-bench`, Aqua Security — <https://github.com/aquasecurity/kube-bench>
- Documentación de Kubernetes, archivo de configuración del kubelet — <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/>
- Documentación de Kubernetes, referencia de `kubelet` — <https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/>
- Documentación de Kubernetes, referencia de `kube-apiserver` — <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/>
- Documentación de Kubernetes, autenticación (peticiones anónimas y `AuthenticationConfiguration`) — <https://kubernetes.io/docs/reference/access-authn-authz/authentication/>
- Documentación de Kubernetes, uso de Node Authorization y `NodeRestriction` — <https://kubernetes.io/docs/reference/access-authn-authz/node/>
- Documentación de Kubernetes, cifrar datos confidenciales en reposo — <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>
- Documentación de Kubernetes, operar clústeres etcd para Kubernetes — <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- Documentación de Kubernetes, TLS bootstrapping del kubelet y rotación de certificados — <https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/>
- Documentación de Kubernetes, personalizar el servicio DNS (CoreDNS) — <https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/>
- Documentación de Kubernetes, network policies — <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- Documentación de etcd, modelo de seguridad de transporte — <https://etcd.io/docs/latest/op-guide/security/>