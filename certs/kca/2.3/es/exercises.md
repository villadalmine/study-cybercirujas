# KCA 2.3 — Configuración del Controller con Flags

**Ejercicios guiados · Peso en el examen 3.0**

El `kube-controller-manager` es un único binario que ejecuta los bucles de control incorporados (ciclo de vida de nodos, deployment, job, service account, garbage collection, firma de CSR y ~30 más). En un cluster `kubeadm` corre como un **static Pod** cuya configuración completa es una lista plana de flags de línea de comandos en `/etc/kubernetes/manifests/kube-controller-manager.yaml`. No hay un archivo de configuración aparte: los flags *son* la API. Este lab te enseña a leer, cambiar, verificar, ajustar y diagnosticar esos flags de forma segura.

> **Requisitos previos**
> - Un cluster que puedas romper — idealmente `kubeadm` con un solo control-plane, Kubernetes ≥ 1.29.
> - `root`/`sudo` en el nodo del control-plane, además de `crictl` y `kubectl`.
> - Cada edición del manifest estático la aplica el kubelet automáticamente — **no hay `kubectl apply`** ni `systemctl restart` para este Pod.
>
> Referencia: <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>

---

## Ejercicio 1 — Leer la configuración en ejecución y sus fuentes

La primera habilidad es separar *qué está configurado* (el manifest) de *qué está corriendo* (el proceso del container) y de *cuáles son los valores por defecto* (la referencia).

1. Mirá la fuente autoritativa de la configuración — el manifest del static Pod:

   ```bash
   sudo grep -nE 'kube-controller-manager|--' /etc/kubernetes/manifests/kube-controller-manager.yaml
   ```

   Salida esperada (abreviada):

   ```
    10:    - command:
    11:    - kube-controller-manager
    12:    - --allocate-node-cidrs=true
    13:    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    14:    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    15:    - --bind-address=127.0.0.1
    16:    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    17:    - --cluster-cidr=10.244.0.0/16
    18:    - --cluster-name=kubernetes
    19:    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    20:    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    21:    - --controllers=*,bootstrapsigner,tokencleaner
    22:    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    23:    - --leader-elect=true
    24:    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    25:    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    26:    - --service-cluster-ip-range=10.96.0.0/12
    27:    - --use-service-account-credentials=true
   ```

2. Ahora mirá lo que realmente está corriendo como mirror Pod en la API. El nombre del nodo es un sufijo del nombre del Pod:

   ```bash
   kubectl -n kube-system get pod -l component=kube-controller-manager -o wide
   ```

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE    IP              NODE
   kube-controller-manager-controlplane   1/1     Running   0          3d2h   192.168.1.10    controlplane
   ```

3. Confirmá los flags con los que arrancó el *proceso* (no solamente el manifest en disco):

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane \
     -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep controllers
   ```

   ```
   "--controllers=*
   bootstrapsigner
   tokencleaner"
   ```

4. Verificá el valor **por defecto** de un flag para saber qué estás sobrescribiendo. Todo lo que no aparece en el manifest corre con su valor por defecto documentado:

   ```bash
   kube-controller-manager --help 2>/dev/null | grep -A2 -- '--node-monitor-grace-period'
   ```

   ```
       --node-monitor-grace-period duration     Default: 40s
         Amount of time which we allow running Node to be unresponsive before
         marking it unhealthy. ...
   ```

   > Si el binario no está en el `$PATH`, leé la página de referencia en su lugar: <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>

**Q1.** ¿Por qué el mirror Pod del paso 2 es una representación fiel del proceso pero aun así *no* es la configuración autoritativa que deberías editar?

**Q2.** El manifest del paso 1 no contiene `--node-monitor-grace-period`. ¿Significa eso que el flag está *sin definir* en el controller en ejecución? ¿Qué valor está vigente?

**Q3.** ¿Cuáles son los dos flags de la familia `kubeconfig` en el manifest que le indican al controller-manager cómo *autenticar peticiones delegadas hacia sí mismo* (su propio endpoint de serving), frente a cómo *hablar con el API server*?

---

## Ejercicio 2 — Cambiar un flag y probar que el kubelet recargó el static Pod

Editar el manifest es un cambio en vivo. Tenés que poder demostrar que la recarga ocurrió y que el nuevo flag está activo — un fallo silencioso de parseo se ve idéntico a "no pasó nada" hasta que lo verificás.

1. Capturá el ID del container actual y su hora de inicio para poder probar después que hubo un reinicio:

   ```bash
   sudo crictl ps --name kube-controller-manager -o table
   ```

   ```
   CONTAINER      IMAGE          CREATED       STATE     NAME                      ATTEMPT   POD ID
   9f3a1c2b4d5e   1d2a3b4c5d6e   3 days ago    Running   kube-controller-manager   0         7a8b9c0d1e2f
   ```

2. Editá el manifest. Agregá un flag de tuning explícito e inofensivo — aumentá cuántos Deployments se reconcilian en paralelo respecto del valor por defecto de 5:

   ```bash
   sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml
   ```

   Agregá una línea dentro de la lista `command:`, manteniendo la indentación de la lista YAML idéntica a la de sus vecinas:

   ```yaml
       - --concurrent-deployment-syncs=10
   ```

3. Observá cómo el kubelet detecta el cambio del archivo y recrea el Pod (esto suele tardar entre 15 y 30 segundos):

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane -w
   ```

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE
   kube-controller-manager-controlplane   1/1     Running   0          3d2h
   kube-controller-manager-controlplane   0/1     Pending   0          0s
   kube-controller-manager-controlplane   0/1     Running   0          2s
   kube-controller-manager-controlplane   1/1     Running   0          12s
   ```

   Presioná `Ctrl-C` una vez que esté en `1/1 Running`.

4. Probá que se creó un **container nuevo** (ID / `CREATED` distintos):

   ```bash
   sudo crictl ps --name kube-controller-manager -o table
   ```

   ```
   CONTAINER      IMAGE          CREATED         STATE     NAME                      ATTEMPT
   0a1b2c3d4e5f   1d2a3b4c5d6e   30 seconds ago  Running   kube-controller-manager   0
   ```

5. Probá que el flag está realmente vigente leyéndolo de los argumentos del proceso en vivo:

   ```bash
   sudo crictl inspect $(sudo crictl ps -q --name kube-controller-manager) \
     | grep -o 'concurrent-deployment-syncs=[0-9]*'
   ```

   ```
   concurrent-deployment-syncs=10
   ```

**Q4.** El kubelet recreó el Pod y, sin embargo, `RESTARTS` quedó en `0`. Explicá la diferencia entre un *reinicio de container* y lo que ocurrió acá, y por qué cambió el `POD ID` anterior.

**Q5.** Editaste el manifest pero `kubectl -n kube-system get pod ...` sigue mostrando el `AGE` *viejo* después de dos minutos. Nombrá los dos errores más probables y el único comando que revelaría un error de parseo de YAML o de flags.

---

## Ejercicio 3 — Habilitar y deshabilitar controllers individuales con `--controllers`

`--controllers` es una lista con comodines: `*` significa "todos los controllers que están activos por defecto", un nombre suelto fuerza la activación de un controller apagado por defecto, y el prefijo `-` deshabilita uno. Este es el flag que aman los examinadores porque su efecto es directamente observable.

1. Mirá la lista efectiva y confirmá que `cronjob` está actualmente activo (viene incluido por `*`):

   ```bash
   kubectl -n kube-system logs kube-controller-manager-controlplane \
     | grep -i 'Started controller' | grep -iE 'cronjob|garbagecollector' | head
   ```

   ```
   I0813 10:02:14.331 1 controllermanager.go:... "Started controller" controller="cronjob-controller"
   I0813 10:02:14.402 1 controllermanager.go:... "Started controller" controller="garbage-collector-controller"
   ```

2. Creá un CronJob que se dispare cada minuto para tener algo observable:

   ```bash
   kubectl create cronjob heartbeat --image=busybox --schedule='* * * * *' -- date
   sleep 75
   kubectl get jobs -l job-name --no-headers | grep heartbeat
   ```

   ```
   heartbeat-29280612   Complete   1/1   3s   61s
   ```

   Apareció un Job — el controller está funcionando.

3. Ahora **deshabilitá solamente** el controller `cronjob`. Editá el manifest y cambiá la línea `--controllers` para que conserve todos los valores por defecto pero reste `cronjob`:

   ```yaml
       - --controllers=*,bootstrapsigner,tokencleaner,-cronjob
   ```

   Esperá la recarga (Ejercicio 2, paso 3) y después confirmá que **no** arrancó:

   ```bash
   kubectl -n kube-system logs kube-controller-manager-controlplane \
     | grep -iE 'cronjob' | tail -2
   ```

   ```
   I0813 10:35:01.118 1 controllermanager.go:... "Controller is disabled by a flag..." controller="cronjob"
   ```

4. Probá el efecto a nivel de workload — no se crean Jobs nuevos mientras el controller está apagado:

   ```bash
   kubectl get jobs --no-headers | wc -l   # note the number
   sleep 130
   kubectl get jobs --no-headers | wc -l   # unchanged
   ```

5. Volvé a habilitarlo restaurando la línea original, esperá la recarga y confirmá que los Jobs se reanudan en menos de un minuto.

   ```yaml
       - --controllers=*,bootstrapsigner,tokencleaner
   ```

**Q6.** ¿Por qué hay que escribir `*,bootstrapsigner,tokencleaner,-cronjob` en lugar de simplemente `-cronjob`? ¿Qué le haría `--controllers=-cronjob` por sí solo al resto del cluster?

**Q7.** Con el controller `cronjob` deshabilitado, el objeto CronJob sigue existiendo y muestra un `SCHEDULE` válido. ¿Qué principio arquitectónico explica que el *estado deseado* esté intacto pero *nada actúe sobre él*?

**Q8.** Dá una razón de producción por la que un operador deshabilitaría deliberadamente un controller incorporado específico (por ejemplo `nodeipam` o `service`) en lugar de correr el conjunto completo.

---

## Ejercicio 4 — Flags del ciclo de vida de nodos y la ruta de eviction basada en taints

`--node-monitor-period`, `--node-monitor-grace-period` y el (obsoleto) `--pod-eviction-timeout` gobiernan qué tan rápido se detecta un nodo muerto y qué tan rápido se desalojan sus Pods. Tener el modelo mental correcto importa porque uno de estos flags ya no hace lo que su nombre sugiere.

1. Leé los tres flags y sus valores por defecto:

   ```bash
   kube-controller-manager --help 2>/dev/null \
     | grep -EA1 -- '--node-monitor-period|--node-monitor-grace-period|--pod-eviction-timeout'
   ```

   ```
       --node-monitor-period duration            Default: 5s
       --node-monitor-grace-period duration      Default: 40s
       --pod-eviction-timeout duration           Default: 5m0s   (DEPRECATED: no effect when
                                                 taint-based eviction is enabled — the default)
   ```

2. Ajustá la detección para el lab: marcá un nodo como no saludable a los 20s en lugar de 40s. Editá el manifest:

   ```yaml
       - --node-monitor-period=2s
       - --node-monitor-grace-period=20s
   ```

   Esperá la recarga y confirmá que los flags están vigentes (Ejercicio 2, paso 5).

3. Simulá una falla de nodo. En un nodo *worker*, detené el kubelet:

   ```bash
   sudo systemctl stop kubelet     # run on the worker, NOT the control plane
   ```

4. Desde el control plane, medí cuánto tarda el nodo en pasar a `NotReady` y observá cómo aparece el taint:

   ```bash
   kubectl get nodes -w
   ```

   ```
   NAME     STATUS     ROLES    AGE   VERSION
   worker   Ready      <none>   3d    v1.31.0
   worker   NotReady   <none>   3d    v1.31.0     # ~20s after kubelet stopped
   ```

   ```bash
   kubectl describe node worker | grep -A2 Taints
   ```

   ```
   Taints: node.kubernetes.io/not-ready:NoExecute
           node.kubernetes.io/not-ready:NoSchedule
   ```

5. Observá *cuándo* se desalojan realmente los Pods de ese nodo:

   ```bash
   kubectl get pods -o wide --field-selector spec.nodeName=worker -w
   ```

   Los Pods no se desalojan a los 20s — permanecen hasta que expira su toleration de `NoExecute` (por defecto `tolerationSeconds: 300`).

6. Restaurá el nodo y los valores por defecto:

   ```bash
   sudo systemctl start kubelet    # on the worker
   ```

   Quitá tus dos flags (o volvelos a `5s`/`40s`) y dejá que el manifest se recargue.

**Q9.** Después de `--node-monitor-grace-period`, el nodo quedó tainteado casi de inmediato pero los Pods sobrevivieron ~5 minutos más. ¿Qué componente agrega los `tolerationSeconds` que producen ese retraso de 5 minutos, y qué flag ajustarías para acortarlo — uno del controller-manager, u otra cosa?

**Q10.** Un colega configura `--pod-eviction-timeout=30s` para "desalojar más rápido" e informa que no hizo nada. ¿Por qué el flag es inerte en un cluster moderno, y cuál es la palanca correcta?

**Q11.** Bajar `--node-monitor-grace-period` a `10s` acelera la detección de fallas. Indicá un modo de falla concreto que esto genera en un cluster ocupado o con alta latencia.

---

## Ejercicio 5 — Flags de firma, ServiceAccount y confianza

El controller-manager es una autoridad certificante y un emisor de tokens. Cuatro flags cablean esa confianza: `--cluster-signing-cert-file`/`--cluster-signing-key-file` (aprueba y firma CSRs), `--service-account-private-key-file` (firma tokens de SA), `--root-ca-file` (el bundle de CA que inyecta) y `--use-service-account-credentials`.

1. Confirmá que los controllers de firma están corriendo y mirá en quién confían:

   ```bash
   kubectl -n kube-system logs kube-controller-manager-controlplane \
     | grep -iE 'csrsigning|serviceaccount-token|root-ca-cert-publisher' | grep -i started
   ```

   ```
   ... "Started controller" controller="certificate-csrsigning-kubelet-serving-controller"
   ... "Started controller" controller="serviceaccount-token-controller"
   ... "Started controller" controller="root-ca-cert-publisher-controller"
   ```

2. Probá que el `root-ca-cert-publisher` está haciendo su trabajo — cada namespace recibe un ConfigMap `kube-root-ca.crt` sembrado desde `--root-ca-file`:

   ```bash
   kubectl create ns trust-demo
   kubectl -n trust-demo get configmap kube-root-ca.crt
   ```

   ```
   NAME               DATA   AGE
   kube-root-ca.crt   1      2s
   ```

3. Probá la ruta de firma de CSR de punta a punta. Generá una key + CSR, enviala, aprobala y observá cómo el controller `csrsigning` la firma usando `--cluster-signing-cert-file`:

   ```bash
   openssl genrsa -out demo.key 2048
   openssl req -new -key demo.key -out demo.csr -subj "/CN=demo-user/O=dev"
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: demo-user
   spec:
     request: $(base64 -w0 demo.csr)
     signerName: kubernetes.io/kube-apiserver-client
     usages: ["client auth"]
   EOF
   kubectl certificate approve demo-user
   kubectl get csr demo-user
   ```

   ```
   NAME        AGE   SIGNERNAME                            REQUESTOR          CONDITION
   demo-user   8s    kubernetes.io/kube-apiserver-client   kubernetes-admin   Approved,Issued
   ```

   `Issued` significa que el controller-manager la firmó — ningún otro componente lo hizo.

4. Limpieza:

   ```bash
   kubectl delete csr demo-user; kubectl delete ns trust-demo; rm -f demo.key demo.csr
   ```

Referencia: <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/>

**Q12.** Si `--service-account-private-key-file` y el `--service-account-key-file` del API server son inconsistentes (claves distintas), ¿qué se rompe: la *emisión* de tokens, la *verificación* de tokens, o ambas? ¿Qué componente tiene cada flag?

**Q13.** Una CSR queda para siempre en `Approved` pero nunca llega a `Issued`. El API server está sano y la CSR es válida. ¿Qué flag o controller del controller-manager es el principal sospechoso?

**Q14.** ¿Qué cambia `--use-service-account-credentials=true` respecto de *cómo se autentican los propios controllers*, y por qué eso es mejor para auditoría que una única identidad compartida?

---

## Ejercicio 6 — Diagnosticar un controller-manager que no arranca

Como toda la configuración son flags de CLI sin validación de esquema previa al arranque, un solo typo produce un `CrashLoopBackOff` que `kubectl` apenas puede ver (el mirror Pod desaparece cuando el container está caído). Hay que depurar en la capa del container runtime.

1. Rompelo a propósito — introducí un valor de flag inválido:

   ```yaml
       - --leader-elect=maybe
   ```

   (`--leader-elect` es un booleano; `maybe` no es parseable.) Guardá y dejá que el kubelet intente recargar.

2. Observá el síntoma. `kubectl` puede mostrar el Pod oscilando o ausente:

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane
   ```

   ```
   NAME                                   READY   STATUS             RESTARTS      AGE
   kube-controller-manager-controlplane   0/1     CrashLoopBackOff   4 (20s ago)   90s
   ```

3. Cuando el mirror Pod desapareció, bajá a `crictl` para encontrar el container que falla y leer sus logs — esta es la maniobra diagnóstica clave:

   ```bash
   sudo crictl ps -a --name kube-controller-manager --state exited -o table
   sudo crictl logs $(sudo crictl ps -a -q --name kube-controller-manager | head -1)
   ```

   ```
   invalid argument "maybe" for "--leader-elect" flag: strconv.ParseBool: parsing "maybe": invalid syntax
   ```

4. Si ni siquiera `crictl` muestra nada, revisá la propia visión del kubelet sobre por qué rechazó el static Pod:

   ```bash
   sudo journalctl -u kubelet --since "-3 min" | grep -i 'controller-manager\|static' | tail
   ```

5. Corregí el flag (`--leader-elect=true`), guardá y confirmá la recuperación:

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane
   ```

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE
   kube-controller-manager-controlplane   1/1     Running   0          15s
   ```

**Q15.** ¿Por qué `kubectl -n kube-system logs` puede no mostrar la causa del crash de este Pod, mientras que `crictl logs` sí lo logra? Relacioná tu respuesta con el funcionamiento de los mirror Pods.

**Q16.** Guardás un manifest con un error de indentación YAML (no un error de flag). El container viejo sigue corriendo y no aparece ninguno nuevo. ¿Dónde mirás, y por qué el kubelet *no* mató al container viejo que estaba sano?

**Q17.** Durante el crash loop, los workloads siguieron corriendo y los Services siguieron enrutando, pero un Deployment recién escalado no creó Pods. Explicá, usando el rol del controller-manager, por qué el *data plane* estuvo bien pero la *reconciliación* se detuvo.

---

## Respuestas

<details>
<summary>Mostrar respuestas (Q1–Q17)</summary>

**Q1.** El mirror Pod es un *reflejo de solo lectura* que el kubelet publica en la API para un static Pod; no podés editarlo (`kubectl edit`/`delete` sobre él es revertido o recreado por el kubelet). La configuración autoritativa es el archivo `/etc/kubernetes/manifests/kube-controller-manager.yaml` en el nodo — ese archivo es lo único que cambiás, y el kubelet vuelve a derivar de él tanto el container como el mirror Pod.

**Q2.** No — un flag ausente del manifest no está "sin definir"; corre con su valor por defecto documentado. Por lo tanto `--node-monitor-grace-period` está vigente en **40s**. El manifest solo lista *sobrescrituras*; todo lo demás es el valor por defecto incorporado en el binario (verificalo con `--help`, no asumiendo que la ausencia significa deshabilitado).

**Q3.** `--authentication-kubeconfig` y `--authorization-kubeconfig` le indican al controller-manager cómo autenticar y autorizar peticiones delegadas *entrantes* a su propio puerto de serving (por ejemplo, scrapers de métricas), delegando en el API server. `--kubeconfig` (y el par `--client-ca-file`/`--root-ca-file`) es cómo actúa como *cliente que habla con* el API server. La distinción es la dirección: autenticación del lado servidor vs. identidad del lado cliente.

**Q4.** `RESTARTS` cuenta reinicios de un container *dentro del mismo sandbox de Pod*. Acá el kubelet eliminó el Pod entero (el `POD ID`/sandbox viejo) y creó uno completamente nuevo porque cambió la spec del Pod derivada del manifest — así que un sandbox y un container nuevos arrancan con `RESTARTS=0`. Un *reinicio* de container mantendría el mismo Pod/sandbox e incrementaría el contador (como se ve en el CrashLoop del Ejercicio 6). El `POD ID` cambió precisamente porque es un sandbox nuevo, no una re-ejecución del anterior.

**Q5.** Lo más probable: (a) editaste una copia o una ruta equivocada (el kubelet solo vigila `--pod-manifest-path`, normalmente `/etc/kubernetes/manifests/`), o (b) el manifest tiene un error de YAML o de flags, así que el kubelet se niega a crear el Pod nuevo y conserva el viejo. El único comando revelador: `sudo journalctl -u kubelet --since "-3 min" | grep -i static` (para rechazos de parseo/admisión) o `sudo crictl logs <exited-container>` (para un flag que parseó como YAML pero el binario rechazó).

**Q6.** `*` se expande a "todos los controllers activos por defecto"; `bootstrapsigner,tokencleaner` agregan los dos apagados por defecto que kubeadm necesita; `-cronjob` resta uno. Escribir `--controllers=-cronjob` por sí solo hace que la lista sea *exactamente* `{deshabilitar cronjob}` **sin `*`**, con lo cual todos los demás controllers quedan apagados — deployments, replicasets, endpoints, garbage collection, ciclo de vida de nodos, etc. dejan de reconciliar. El comodín tiene que estar presente para mantener el resto habilitado.

**Q7.** El principio de controller/reconciliación (bucle de control level-triggered): el object store guarda el *estado deseado* independientemente de cualquier controller. Con el controller `cronjob` deshabilitado, el estado deseado (el CronJob) queda intacto, pero no hay ningún bucle de control activo observando CronJobs que empuje el *estado actual* hacia él — por eso no se crean Jobs. Al volver a habilitar el controller, la reconciliación se reanuda a partir del estado deseado existente.

**Q8.** Razones comunes: en un cluster gestionado/en la nube o aprovisionado externamente, deshabilitás `nodeipam`/`route`/`service`/`cloud-node-lifecycle` porque un controller externo (CCM, CNI, controller de load-balancer del proveedor) es el dueño de esa responsabilidad, y correr ambos causa escrituras en conflicto y thrash. Deshabilitar el controller incorporado redundante evita reconciliación duplicada o peleada.

**Q9.** El admission controller `DefaultTolerationSeconds` (en el API server) inyecta `tolerationSeconds: 300` para los taints `NoExecute` `node.kubernetes.io/not-ready` y `unreachable` en todo Pod que no tenga los suyos. Esa toleration de 300s — no un flag del controller-manager — es lo que mantiene vivos a los Pods durante ~5 minutos después del taint. Para acortarla configurás los flags del API server `--default-not-ready-toleration-seconds` / `--default-unreachable-toleration-seconds`, o definís `tolerations` explícitas en el Pod. `--node-monitor-grace-period` solo controla *qué tan rápido aparece el taint*, no cuánto lo toleran los Pods.

**Q10.** `--pod-eviction-timeout` está obsoleto y **no tiene efecto** porque la eviction basada en taints (la ruta del taint `NoExecute` + `tolerationSeconds` por Pod) es la opción por defecto y el único mecanismo de eviction activo en clusters modernos. Las palancas correctas son: `--node-monitor-grace-period` (qué tan rápido se taintea el nodo) más los flags de default-toleration-seconds del API server o las `tolerations` por Pod (qué tan rápido se desalojan los Pods de un nodo tainteado).

**Q11.** Un grace period corto hace que el controller declare muerto un nodo ante fluctuaciones transitorias — un heartbeat lento del kubelet bajo carga, una partición de red breve, o latencia del API server. Eso dispara taints `NoExecute` innecesarios y, una vez que expiran las tolerations, un rescheduling masivo de Pods ("tormentas de eviction") que mueve workloads sanos y agrega más carga, con potencial de cascada. Cambia detección más rápida por falsos positivos.

**Q12.** El controller-manager *emite/firma* tokens de ServiceAccount con `--service-account-private-key-file` (clave privada); el API server los *verifica* con `--service-account-key-file` (la clave pública correspondiente, y acepta una lista). Si son inconsistentes, se rompe la verificación: los tokens se siguen emitiendo pero el API server los rechaza (401), así que los Pods no pueden autenticarse como su ServiceAccount. La solución es incluir la contraparte pública de la clave de firma en el conjunto de claves del API server (la rotación es la razón por la que acepta varias).

**Q13.** El controller `csrsigning` y sus `--cluster-signing-cert-file`/`--cluster-signing-key-file` (o las variantes más nuevas por signer). `Approved` es una decisión de autorización (RBAC/`kubectl certificate approve`); `Issued` requiere que el controller-manager efectivamente firme. Si los archivos de cert/key de firma faltan, son ilegibles, o el `signerName` de la CSR no está manejado por los signers configurados en el controller-manager, queda en `Approved` pero nunca llega a `Issued`.

**Q14.** Con `--use-service-account-credentials=true`, cada controller incorporado se autentica ante el API server con su *propia* ServiceAccount dedicada (por ejemplo `system:serviceaccount:kube-system:deployment-controller`) en vez de compartir todos la única identidad del controller-manager. Eso permite RBAC de mínimo privilegio por controller y hace que los audit logs atribuyan cada escritura al controller específico que la hizo, en lugar de a una única cuenta compartida y opaca.

**Q15.** `kubectl logs` lee a través del API server, que necesita que el objeto *mirror Pod* exista y que el container haya producido logs recuperables. En `CrashLoopBackOff` el container puede estar exited o ausente y el mirror Pod desactualizado o desaparecido, así que la ruta del API server devuelve nada o un error. `crictl` habla directamente con el container runtime del nodo (CRI), por lo que puede leer los logs del container *exited* sin importar el estado de la API o del mirror Pod — está por debajo de la abstracción que se rompió.

**Q16.** Mirá el propio journal del kubelet: `sudo journalctl -u kubelet | grep -i static` (registra rechazos de parseo/admisión de YAML para el manifest). El kubelet no mató el container en ejecución porque *rechazó el manifest nuevo antes de actuar sobre él* — un archivo inválido se trata como "no hay spec nueva válida", así que deja corriendo el último Pod bueno conocido en vez de desarmar un componente sano del control plane por una edición mala. Comportamiento a prueba de fallos.

**Q17.** El data plane (enrutamiento de kube-proxy/CNI, Pods en ejecución, kubelet) no depende del controller-manager, así que el tráfico y los Pods existentes siguen funcionando. Pero el controller-manager ejecuta los bucles de *reconciliación* — Deployment→ReplicaSet→creación de Pods, endpoints, GC, etc. Mientras está en crash loop, ningún bucle avanza el estado deseado, así que escalar un Deployment registra el nuevo `replicas` en etcd pero nada crea los Pods. El control plane (reconciliación) estaba caído; el data plane (reenvío de paquetes) era independiente y estaba bien.

</details>

---

**Fuentes**
- Referencia de flags de `kube-controller-manager` — <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>
- Controllers (arquitectura) — <https://kubernetes.io/docs/concepts/architecture/controller/>
- Node controller y eviction basada en taints — <https://kubernetes.io/docs/concepts/architecture/nodes/#node-controller> y <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/#taint-based-evictions>
- Static Pods — <https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/>
- CertificateSigningRequests — <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/>
- Currícula KCA — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>