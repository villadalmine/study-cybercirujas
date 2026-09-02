# Tema 3.4 — Actualizar Kubernetes para evitar vulnerabilidades

**Certificación:** CKS (Certified Kubernetes Security Specialist) — Versión de examen 1.34
**Dominio:** Cluster Hardening — *Upgrade Kubernetes to avoid vulnerabilities*
**Peso en el examen:** 3,75 %
**Formato:** ejercicios guiados. Ejecutá cada paso numerado; respondé las preguntas de checkpoint antes de seguir. Todas las respuestas están plegadas al final del documento.

---

## 0. Entorno de laboratorio y reglas básicas

Estos ejercicios modifican un control plane. **No los ejecutes contra nada que te importe.** Armá primero un cluster descartable.

**Topología de referencia usada a lo largo del documento:**

| Host   | Rol                     | Versión inicial  |
|--------|-------------------------|------------------|
| `cp01` | control-plane (kubeadm) | v1.33.4          |
| `w01`  | worker                  | v1.33.4          |
| `w02`  | worker                  | v1.33.4          |

* Cluster inicializado con `kubeadm`, control plane corriendo como **static Pods**, `etcd` stacked.
* Container runtime: `containerd`.
* Root/`sudo` en todos los nodos, y `kubectl` configurado contra `cp01`.
* Versión objetivo en los ejemplos: **v1.34.1**. Sustituila por el último parche de v1.34 disponible en tu repositorio de paquetes — lo que estás aprendiendo es la *mecánica*, no los dígitos.

> **Opción de armado rápido (Debian/Ubuntu):** `kubeadm init --kubernetes-version v1.33.4 --pod-network-cidr 10.244.0.0/16` en `cp01`, después unís `w01`/`w02`, y después instalás un CNI. Si sólo tenés una máquina, `kind create cluster --image kindest/node:v1.33.4` sirve para los Ejercicios 1, 2, 4, 8 y 9, pero **no** para el 5–7 (los nodos de kind no están gestionados por paquetes como los nodos kubeadm).

**Encuadre de examen.** En el examen CKS este objetivo aparece casi siempre así: *"Actualizá este cluster de v1.X a v1.Y. Actualizá **solamente** el nodo de control plane (o: actualizá `cp` primero, después `node01`). No actualices los nodos worker."* La tarea completa vale unos pocos puntos y debería llevarte menos de 8 minutos una vez que tengas la secuencia memorizada. Acá la velocidad importa más que la elegancia — el Ejercicio 10 es la corrida cronometrada.

---

## Ejercicio 1 — Establecer la línea base e internalizar la política de version skew

No podés decidir *si* estás expuesto, ni *cuán lejos* podés saltar, sin un inventario exacto. "El cluster está en 1.33" no es un inventario: `kube-apiserver`, `kubelet`, `kube-proxy`, `etcd`, `CoreDNS` y el container runtime versionan de forma independiente, y cada uno tiene su propio flujo de CVEs.

### Pasos

1. Obtené las versiones reportadas por los nodos. La columna `VERSION` es la versión del **kubelet**, no la del API server — una distinción que hace tropezar a mucha gente constantemente.

   ```bash
   kubectl get nodes -o wide
   ```

   ```
   NAME   STATUS   ROLES           AGE   VERSION   INTERNAL-IP    OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
   cp01   Ready    control-plane   31d   v1.33.4   10.10.0.11     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://2.0.5
   w01    Ready    <none>          31d   v1.33.4   10.10.0.21     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://2.0.5
   w02    Ready    <none>          31d   v1.33.4   10.10.0.22     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://2.0.5
   ```

2. Obtené las versiones de cliente (`kubectl`) y de servidor (`kube-apiserver`) por separado:

   ```bash
   kubectl version
   ```

   ```
   Client Version: v1.33.4
   Kustomize Version: v5.6.0
   Server Version: v1.33.4
   ```

3. Obtené la versión del binario `kubeadm` en `cp01`. **Esta es la versión que gobierna a qué podés actualizar** — `kubeadm upgrade apply vX.Y.Z` se niega a instalar una versión que no coincida con el binario `kubeadm` en ejecución.

   ```bash
   sudo kubeadm version -o short
   ```

   ```
   v1.33.4
   ```

4. Leé los *tags de imagen reales* de los static Pods del control plane. Esta es la verdad de campo; el ConfigMap `kubeadm-config` puede desviarse de la realidad después de una actualización parcial o fallida.

   ```bash
   kubectl -n kube-system get pods \
     -l tier=control-plane \
     -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   ```

   ```
   POD                    IMAGE
   etcd-cp01              registry.k8s.io/etcd:3.6.4-0
   kube-apiserver-cp01    registry.k8s.io/kube-apiserver:v1.33.4
   kube-controller-manager-cp01  registry.k8s.io/kube-controller-manager:v1.33.4
   kube-scheduler-cp01    registry.k8s.io/kube-scheduler:v1.33.4
   ```

5. Agregá los componentes que kubeadm trata como *addons* (los actualiza `kubeadm upgrade apply`, pero no forman parte de las reglas de skew del control plane):

   ```bash
   kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   registry.k8s.io/kube-proxy:v1.33.4
   registry.k8s.io/coredns/coredns:v1.12.0
   ```

6. Agregá las capas que Kubernetes **no** va a actualizar por vos — el runtime y el kernel. Una porción muy grande de los CVEs reales de escape de contenedor vive acá (`runc`, `containerd`), no en Kubernetes.

   ```bash
   sudo crictl version
   containerd --version
   runc --version
   uname -r
   ```

   ```
   Version:  0.1.0
   RuntimeName:  containerd
   RuntimeVersion:  v2.0.5
   RuntimeApiVersion:  v1
   containerd github.com/containerd/containerd/v2 v2.0.5 ...
   runc version 1.2.6
   6.8.0-51-generic
   ```

7. Persistí la línea base. Vas a comparar contra ella en el Ejercicio 8.

   ```bash
   { kubectl get nodes -o wide
     kubectl version
     kubectl -n kube-system get pods -l tier=control-plane \
       -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   } > ~/upgrade-baseline-$(date +%F).txt
   ```

8. Leé la política de version skew — **https://kubernetes.io/releases/version-skew-policy/** — y anotá, tomándolo del documento, el skew máximo permitido para `kubelet` respecto de `kube-apiserver`, y para `kubectl` respecto de `kube-apiserver`.

### ✅ Checkpoint 1

- **Q1.1** — La columna `VERSION` de `kubectl get nodes` muestra `v1.33.4` para `cp01`. ¿De qué binario es esa versión, y de qué componente *no* es?
- **Q1.2** — Un colega propone ir de v1.31 directo a v1.34 con `kubeadm upgrade apply v1.34.1` para cerrar rápido un CVE. ¿Por qué va a fallar, y cuál es el camino correcto?
- **Q1.3** — Después de actualizar `kube-apiserver` a v1.34.1 pero dejando todos los `kubelet` en v1.33.4, ¿el cluster queda en un estado soportado? ¿Por cuántas versiones minor puede persistir esa situación?
- **Q1.4** — Tu workstation tiene `kubectl` v1.31.0 y el cluster se está actualizando a v1.34.1. ¿Esa combinación está soportada? ¿Qué síntoma esperarías primero?
- **Q1.5** — ¿Por qué hay que actualizar `kube-apiserver` *antes* que los kubelets, y nunca al revés?
- **Q1.6** — `containerd` 2.0.5 y `runc` 1.2.6 aparecen en tu inventario. ¿`kubeadm upgrade apply v1.34.1` los parchea? ¿Cuál es la implicancia de seguridad?

---

## Ejercicio 2 — Decidir si realmente sos vulnerable (triage de CVEs)

"Actualizar para evitar vulnerabilidades" no es "actualizar constantemente". El flujo profesional es: **identificar el CVE → encontrar las versiones *fixed-in* → determinar si tus componentes están por debajo de alguna de ellas → actualizar al parche corregido más cercano.** Kubernetes publica un feed de CVEs auto-generado y legible por máquina exactamente para esto.

### Pasos

1. Descargá el feed oficial de CVEs. Es JSON Feed 1.1, construido a partir de issues etiquetadas `official-cve-feed` en `kubernetes/kubernetes`.

   ```bash
   curl -sSL https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json -o /tmp/k8s-cve.json
   jq 'keys' /tmp/k8s-cve.json
   ```

   ```json
   [
     "description",
     "home_page_url",
     "items",
     "title",
     "version"
   ]
   ```

2. **Inspeccioná un ítem antes de escribir filtros.** Nunca asumas el esquema de un feed; cambia.

   ```bash
   jq '.items[0]' /tmp/k8s-cve.json
   ```

   ```json
   {
     "id": "https://github.com/kubernetes/kubernetes/issues/NNNNNN",
     "url": "https://github.com/kubernetes/kubernetes/issues/NNNNNN",
     "external_url": "https://www.cve.org/CVERecord?id=CVE-20XX-NNNNN",
     "title": "CVE-20XX-NNNNN: <short description>",
     "content_text": "<issue body: affected components, affected versions, fixed versions, CVSS>",
     "date_published": "20XX-XX-XXT00:00:00Z"
   }
   ```

3. Listá los avisos más recientes en un formato legible:

   ```bash
   jq -r '.items | sort_by(.date_published) | reverse | .[:10][]
          | [ (.date_published[:10]), .title ] | @tsv' /tmp/k8s-cve.json | column -t -s $'\t'
   ```

4. Buscá en el feed un componente que estés corriendo, y leé la línea *fixed-in* dentro del cuerpo del texto:

   ```bash
   jq -r '.items[] | select(.content_text | test("kubelet"; "i"))
          | "\(.date_published[:10])  \(.title)\n\(.external_url)\n"' /tmp/k8s-cve.json | head -40
   ```

5. Verificá la ventana de soporte de patch releases. Kubernetes mantiene las **tres releases minor más recientes**; cada una recibe parches por aproximadamente 12 meses más una cola de 2 meses en modo mantenimiento. Cualquier cosa más vieja **no recibe ningún parche de seguridad**.

   ```bash
   curl -sSL https://kubernetes.io/releases/patch-releases/ | grep -iEo '1\.3[0-9]' | sort -u
   ```

   Leé la tabla autoritativa en **https://kubernetes.io/releases/patch-releases/**.

6. Cubrí las capas que el feed de Kubernetes no cubre: el propio tracker de seguridad de tu distribución para `containerd`, `runc`, `kernel` y `openssl`.

   ```bash
   sudo apt-get update
   apt list --upgradable 2>/dev/null | grep -Ei 'containerd|runc|linux-image|kube'
   # RPM-based:
   # sudo dnf updateinfo list --security
   ```

7. Suscribite (hacelo una vez, en serio, en un cluster real): el grupo de Google `kubernetes-announce` es el canal donde se anuncian los fixes embargados — **https://kubernetes.io/docs/reference/issues-security/security/**.

### ✅ Checkpoint 2

- **Q2.1** — Un aviso dice: *"Affected: kubelet v1.32.0 – v1.32.6, v1.33.0 – v1.33.5. Fixed in: v1.32.7, v1.33.6, v1.34.0."* Tu cluster corre kubelet v1.33.4. ¿Cuál es la remediación de **mínimo riesgo**, y por qué no es "actualizar a v1.34.1"?
- **Q2.2** — Tu cluster corre v1.29. Nada está roto y las cargas de trabajo andan bien. Dá el argumento de seguridad, en una oración, de por qué v1.29 es igualmente inaceptable.
- **Q2.3** — El feed de CVEs no muestra nada nuevo este mes, pero circula públicamente un exploit de escape de contenedor. ¿Qué dos líneas del inventario del Ejercicio 1 revisarías primero, y por qué el feed de Kubernetes no las cubre?
- **Q2.4** — ¿Por qué el feed oficial de CVEs vive detrás de issues de GitHub etiquetadas `official-cve-feed` en lugar de una página curada a mano? ¿Qué implica eso sobre latencia y completitud?
- **Q2.5** — Explicá por qué actualizar una versión *minor* para corregir un CVE es en general una acción de *mayor* riesgo que actualizar una versión *patch*, aunque ambas cierren el CVE.

---

## Ejercicio 3 — Pre-flight: respaldar etcd y el estado del control plane

En Kubernetes **no hay un camino de downgrade soportado**. `kubeadm upgrade` sólo avanza. Tu rollback es un snapshot de etcd más el directorio de PKI/manifests — nada más. Tomalo *antes* de tocar un solo paquete.

### Pasos

1. Ubicá los certificados de cliente de etcd a partir del manifest del static Pod (no adivines las rutas):

   ```bash
   sudo grep -E 'cert-file|key-file|trusted-ca-file|listen-client-urls|data-dir' \
     /etc/kubernetes/manifests/etcd.yaml
   ```

   ```
       - --cert-file=/etc/kubernetes/pki/etcd/server.crt
       - --key-file=/etc/kubernetes/pki/etcd/server.key
       - --listen-client-urls=https://127.0.0.1:2379,https://10.10.0.11:2379
       - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
       - --data-dir=/var/lib/etcd
   ```

2. Tomá el snapshot. Usá el par de certificado **cliente** (`healthcheck-client` o `apiserver-etcd-client`), no la clave del servidor:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
     --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
     snapshot save /var/backups/etcd-pre-1.34-$(date +%F).db
   ```

   ```
   {"level":"info","msg":"created temporary db file",...}
   {"level":"info","msg":"fetching snapshot","endpoint":"https://127.0.0.1:2379"}
   {"level":"info","msg":"fetched snapshot","size":"42 MB"}
   Snapshot saved at /var/backups/etcd-pre-1.34-2026-07-31.db
   ```

3. Verificá que el snapshot sea legible y no esté vacío. `etcdctl snapshot status` está deprecado; la herramienta moderna es `etcdutl`:

   ```bash
   sudo etcdutl snapshot status /var/backups/etcd-pre-1.34-$(date +%F).db --write-out=table
   ```

   ```
   +----------+----------+------------+------------+
   |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
   +----------+----------+------------+------------+
   | 8f1c1a2b |   918442 |       1873 |      42 MB |
   +----------+----------+------------+------------+
   ```

4. Respaldá la configuración y la PKI del control plane. Un snapshot solo no reconstruye un nodo:

   ```bash
   sudo tar -czf /var/backups/k8s-etc-$(date +%F).tgz \
     /etc/kubernetes \
     /var/lib/kubelet/config.yaml \
     /var/lib/kubelet/kubeadm-flags.env
   sudo tar -tzf /var/backups/k8s-etc-$(date +%F).tgz | head
   ```

5. Copiá ambos artefactos **fuera del nodo**. Un backup que vive únicamente en la máquina que estás por romper no es un backup.

   ```bash
   scp /var/backups/etcd-pre-1.34-*.db /var/backups/k8s-etc-*.tgz backup-host:/srv/k8s-backups/
   ```

6. Aprovechá para revisar el vencimiento de los certificados — `kubeadm upgrade apply` renueva automáticamente los certificados del control plane, un efecto secundario útil que conviene registrar *antes*:

   ```bash
   sudo kubeadm certs check-expiration
   ```

   ```
   CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   admin.conf                 Aug 20, 2026 09:11 UTC   20d             no
   apiserver                  Aug 20, 2026 09:11 UTC   20d             no
   apiserver-etcd-client      Aug 20, 2026 09:11 UTC   20d             no
   apiserver-kubelet-client   Aug 20, 2026 09:11 UTC   20d             no
   controller-manager.conf    Aug 20, 2026 09:11 UTC   20d             no
   etcd-healthcheck-client    Aug 20, 2026 09:11 UTC   20d             no
   etcd-peer                  Aug 20, 2026 09:11 UTC   20d             no
   etcd-server                Aug 20, 2026 09:11 UTC   20d             no
   front-proxy-client         Aug 20, 2026 09:11 UTC   20d             no
   scheduler.conf             Aug 20, 2026 09:11 UTC   20d             no
   ```

### ✅ Checkpoint 3

- **Q3.1** — `kubeadm upgrade apply v1.32.9` en un cluster v1.33: ¿qué hace kubeadm, y cuál es tu único camino real de vuelta a v1.32?
- **Q3.2** — Restaurás el snapshot de etcd del paso 2 pero mantenés los manifests de static Pods ya actualizados a v1.34.1. ¿Qué clase de falla deberías esperar?
- **Q3.3** — ¿Qué certificados renueva `kubeadm upgrade apply` por defecto, y qué flag lo deshabilita? Nombrá una situación en la que querrías deshabilitarlo.
- **Q3.4** — ¿Por qué `healthcheck-client.crt` es el certificado correcto para `etcdctl snapshot save`, en lugar de `server.crt`?
- **Q3.5** — En un cluster con etcd **externo**, ¿qué cambia en este ejercicio?

---

## Ejercicio 4 — Detectar APIs removidas antes de que la actualización te las remueva

Las actualizaciones minor remueven APIs que fueron deprecadas una o más releases antes. Si un Deployment, un chart de Helm, el CRD de un operador o un admission webhook todavía habla una versión removida, la actualización lo rompe silenciosamente — y "hacer rollback para arreglarlo" no está disponible. Esta verificación va *antes* de `kubeadm upgrade plan`, no después.

### Pasos

1. Preguntale al propio API server qué APIs deprecadas vienen llamando los clientes. Esta métrica es la señal previa a la actualización de mayor valor en todo el cluster:

   ```bash
   kubectl get --raw /metrics | grep -E '^apiserver_requested_deprecated_apis'
   ```

   ```
   apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.35",resource="flowschemas",subresource="",version="v1beta3"} 1
   apiserver_requested_deprecated_apis{group="",removed_release="",resource="endpoints",subresource="",version="v1"} 1
   ```

   La etiqueta `removed_release` te dice la versión minor exacta en la que la llamada deja de funcionar.

2. Cruzá esa métrica con los contadores de requests, para saber **quién** llama y con qué frecuencia:

   ```bash
   kubectl get --raw /metrics | grep -E 'apiserver_request_total.*v1beta3' | head
   ```

3. Enumerá las versiones de API servidas actualmente en el cluster, y compará contra la guía de deprecación:

   ```bash
   kubectl api-resources --sort-by=name -o wide | head -30
   kubectl api-versions | sort
   ```

   Tabla autoritativa de remociones: **https://kubernetes.io/docs/reference/using-api/deprecation-guide/**

4. Escaneá los manifests que realmente desplegás (tu repositorio GitOps, tus charts de Helm), no sólo el cluster vivo. Un recurso almacenado en etcd se auto-convierte al leerse; un manifest en Git no.

   ```bash
   # kube-no-trouble (third-party, widely used):
   kubent --context "$(kubectl config current-context)"
   # or, against files:
   kubent -f ./manifests/
   ```

   ```
   __ ____  _ _____
   ...
   >>> Deprecated APIs removed in 1.35 <<<
   KIND        NAMESPACE   NAME        API_VERSION                                REPLACE_WITH (SINCE)
   FlowSchema  <undefined> my-flow     flowcontrol.apiserver.k8s.io/v1beta3       flowcontrol.apiserver.k8s.io/v1 (1.29.0)
   ```

5. Convertí un manifest infractor con el plugin oficial (instalá `kubectl-convert` por separado — no viene incluido en `kubectl`):

   ```bash
   kubectl convert -f ./manifests/my-flow.yaml --output-version flowcontrol.apiserver.k8s.io/v1
   ```

6. Inventariá las cosas que se rompen *silenciosamente* en una actualización minor porque son out-of-tree: admission webhooks, CRDs con una versión de `apiextensions` removida, y plugins CSI/CNI/device.

   ```bash
   kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
   kubectl get crd -o custom-columns='NAME:.metadata.name,VERSIONS:.spec.versions[*].name'
   kubectl -n kube-system get ds -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
   ```

7. Revisá la matriz de compatibilidad propia de cada componente de terceros para v1.34 (Calico/Cilium, los drivers CSI, ingress controller, cert-manager, Prometheus operator…). Registrá cuáles deben actualizarse **primero**.

### ✅ Checkpoint 4

- **Q4.1** — `apiserver_requested_deprecated_apis` muestra `removed_release="1.35"` para un grupo que usás. Estás actualizando a v1.34. ¿Es urgente? ¿Qué hacés con el hallazgo?
- **Q4.2** — Un `Deployment` fue creado hace años vía `apps/v1beta2`. Hoy `kubectl get deploy -o yaml` devuelve `apps/v1`. Explicá el mecanismo de storage-vs-serving que hace que esto sea así, y por qué el objeto sobrevive a la remoción de `apps/v1beta2` mientras que un manifest de Git no.
- **Q4.3** — ¿Por qué una `ValidatingWebhookConfiguration` es una potencial *caída de todo el cluster* durante una actualización, y qué campo controla el radio de impacto?
- **Q4.4** — Nombrá la razón relevante para la seguridad por la cual este ejercicio de "revisar APIs removidas" pertenece a un objetivo de **seguridad**, en lugar de estar sólo en un runbook de confiabilidad.

---

## Ejercicio 5 — Planificar la actualización (`kubeadm upgrade plan`)

`kubeadm` actualiza **de a una versión minor por vez**, y sólo instala la versión que coincide con su propio binario. Así que el paso de planificación son en realidad dos pasos: reapuntar el repositorio de paquetes, instalar el nuevo `kubeadm`, y *después* planificar.

### Pasos

1. Inspeccioná la definición actual del repositorio. En los repos comunitarios `pkgs.k8s.io`, **la versión minor está incrustada en la URL** — esta es la razón número uno de que `apt-cache madison kubeadm` no muestre un candidato v1.34:

   ```bash
   cat /etc/apt/sources.list.d/kubernetes.list
   ```

   ```
   deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /
   ```

2. Reapuntá el repositorio a v1.34 **y reimportá la clave de firma** (cada repo por versión minor se firma por separado):

   **Debian / Ubuntu**

   ```bash
   sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
     | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
     | sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update
   ```

   **RHEL / Fedora / CentOS**

   ```bash
   cat <<'EOF' | sudo tee /etc/yum.repos.d/kubernetes.repo
   [kubernetes]
   name=Kubernetes
   baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
   enabled=1
   gpgcheck=1
   gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
   exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
   EOF
   ```

3. Listá los parches disponibles y elegí uno concreto. Nunca instales sin fijar la versión:

   ```bash
   sudo apt-cache madison kubeadm | head
   # RPM: sudo dnf --showduplicates list kubeadm
   ```

   ```
      kubeadm | 1.34.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb/  Packages
      kubeadm | 1.34.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb/  Packages
   ```

4. Instalá **sólo** `kubeadm` por ahora, liberando y reaplicando el hold de versión:

   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get install -y kubeadm=1.34.1-1.1
   sudo apt-mark hold kubeadm
   sudo kubeadm version -o short
   ```

   ```
   kubeadm set on hold.
   v1.34.1
   ```

   **Equivalente RPM:**
   ```bash
   sudo dnf install -y kubeadm-1.34.1-150500.1.1 --disableexcludes=kubernetes
   ```

5. Ejecutá el plan. Leé cada línea — esta salida *es* el plan de cambios, y te dice explícitamente qué componentes kubeadm **no** va a manejar:

   ```bash
   sudo kubeadm upgrade plan
   ```

   ```
   [preflight] Running pre-flight checks.
   [upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [upgrade] Running cluster health checks
   [upgrade] Fetching available versions to upgrade to
   [upgrade/versions] Cluster version: v1.33.4
   [upgrade/versions] kubeadm version: v1.34.1
   [upgrade/versions] Target version: v1.34.1
   [upgrade/versions] Latest version in the v1.33 series: v1.33.6

   Components that must be upgraded manually after you have upgraded the control plane
   with 'kubeadm upgrade apply':
   COMPONENT   NODE   CURRENT   TARGET
   kubelet     cp01   v1.33.4   v1.34.1
   kubelet     w01    v1.33.4   v1.34.1
   kubelet     w02    v1.33.4   v1.34.1

   Upgrade to the latest stable version:

   COMPONENT                 NODE   CURRENT   TARGET
   kube-apiserver            cp01   v1.33.4   v1.34.1
   kube-controller-manager   cp01   v1.33.4   v1.34.1
   kube-scheduler            cp01   v1.33.4   v1.34.1
   kube-proxy                       1.33.4    v1.34.1
   CoreDNS                          v1.12.0   v1.12.1
   etcd                      cp01   3.6.4-0   3.6.4-0

   You can now apply the upgrade by executing the following command:

           kubeadm upgrade apply v1.34.1

   _____________________________________________________________________
   ```

   > Tus versiones objetivo exactas de `etcd` y `CoreDNS` van a diferir según la release; leelas de *tu* salida, no de esta página.

6. Ensayá sin modificar nada. `--dry-run` renderiza los nuevos manifests en un directorio temporal y ejecuta la misma lógica de preflight:

   ```bash
   sudo kubeadm upgrade apply v1.34.1 --dry-run
   ```

7. Notá que el plan reportó `v1.33.6` como "latest in the v1.33 series". Si tu único objetivo es cerrar un CVE corregido en v1.33.6, **esa es la actualización que deberías estar haciendo** (ver Q2.1).

### ✅ Checkpoint 5

- **Q5.1** — `apt-cache madison kubeadm` muestra sólo 1.33.x incluso después de `apt-get update`. ¿Cuál es la causa, y cuál el arreglo?
- **Q5.2** — ¿Por qué `kubeadm upgrade plan` lista los kubelets bajo *"must be upgraded manually"*? ¿Cuál es la razón de diseño por la que kubeadm se niega a hacerlo?
- **Q5.3** — ¿De qué te protege `apt-mark hold kubeadm`, y por qué es un control de *seguridad* y no sólo una comodidad operativa?
- **Q5.4** — Instalás `kubeadm=1.34.1-1.1` pero ejecutás `kubeadm upgrade apply v1.34.0`. ¿Qué pasa?
- **Q5.5** — En la salida del plan, `etcd` muestra `3.6.4-0 → 3.6.4-0`. ¿kubeadm reinicia igual el static Pod de etcd? ¿Qué flag usarías para dejar etcd intacto, y cuándo está justificado?

---

## Ejercicio 6 — Actualizar el primer nodo de control plane

El orden importa y no es negociable: **primero los componentes del control plane, después drain, después el `kubelet`/`kubectl` propios del nodo, después uncordon.**

### Pasos

1. Aplicá la actualización del control plane. Este es el único nodo donde ejecutás `apply`:

   ```bash
   sudo kubeadm upgrade apply v1.34.1
   ```

   ```
   [upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [preflight] Running pre-flight checks.
   [upgrade] Running cluster health checks
   [upgrade/version] You have chosen to change the cluster version to "v1.34.1"
   [upgrade/versions] Cluster version: v1.33.4
   [upgrade/versions] kubeadm version: v1.34.1
   [upgrade] Are you sure you want to proceed? [y/N]: y
   [upgrade/prepull] Pulling images required for setting up a Kubernetes cluster
   [upgrade/apply] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1" (timeout: 5m0s)...
   [upgrade/etcd] Upgrading etcd
   [upgrade/staticpods] Preparing for "etcd" upgrade
   [upgrade/staticpods] Writing new Static Pod manifests to "/etc/kubernetes/tmp/kubeadm-upgraded-manifests..."
   [upgrade/staticpods] Moving new manifest to "/etc/kubernetes/manifests/kube-apiserver.yaml"
   [upgrade/staticpods] Waiting for the kubelet to restart the component
   [apiclient] Found 1 Pods for label selector component=kube-apiserver
   [upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
   ...
   [upgrade/postupgrade] Removing the old taint ...
   [addons] Applied essential addon: CoreDNS
   [addons] Applied essential addon: kube-proxy

   [upgrade] SUCCESS! A control plane instance for this node was upgraded to "v1.34.1".

   [upgrade] Now please proceed with upgrading the kubelet on this node if you haven't already done so.
   ```

   Para corridas desatendidas agregá `-y`. Para saltear la confirmación interactiva *y* la actualización de etcd: `sudo kubeadm upgrade apply v1.34.1 -y --etcd-upgrade=false`.

2. Confirmá que el control plane realmente se movió, antes de tocar el kubelet:

   ```bash
   kubectl version | grep Server
   kubectl -n kube-system get pods -l tier=control-plane \
     -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   ```

   ```
   Server Version: v1.34.1
   POD                            IMAGE
   etcd-cp01                      registry.k8s.io/etcd:3.6.4-0
   kube-apiserver-cp01            registry.k8s.io/kube-apiserver:v1.34.1
   kube-controller-manager-cp01   registry.k8s.io/kube-controller-manager:v1.34.1
   kube-scheduler-cp01            registry.k8s.io/kube-scheduler:v1.34.1
   ```

   Notá que `kubectl get nodes` **sigue** mostrando `v1.33.4` para `cp01` — el kubelet todavía no fue tocado.

3. Drenar el nodo. `--ignore-daemonsets` es obligatorio en cualquier cluster real (el CNI y `kube-proxy` son DaemonSets y no pueden ser desalojados):

   ```bash
   kubectl drain cp01 --ignore-daemonsets
   ```

   ```
   node/cp01 cordoned
   Warning: ignoring DaemonSet-managed Pods: kube-system/calico-node-8x2vq, kube-system/kube-proxy-lm4rt
   evicting pod kube-system/coredns-6f9c7d8b4-h2kqz
   pod/coredns-6f9c7d8b4-h2kqz evicted
   node/cp01 drained
   ```

   Si se cuelga por almacenamiento local, agregá `--delete-emptydir-data`. Si se niega por un Pod suelto que no pertenece a un controlador, agregá `--force` — y entendé que `--force` **borra ese Pod permanentemente**, no lo reprograma.

4. Actualizá los paquetes `kubelet` y `kubectl` del nodo:

   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
   sudo apt-mark hold kubelet kubectl
   ```

   **RPM:**
   ```bash
   sudo dnf install -y kubelet-1.34.1-150500.1.1 kubectl-1.34.1-150500.1.1 --disableexcludes=kubernetes
   ```

5. Recargá systemd y reiniciá el kubelet. **`daemon-reload` es obligatorio** — el paquete puede haber cambiado la unit o sus drop-ins:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   sudo systemctl status kubelet --no-pager | head -12
   ```

6. Devolvé el nodo al servicio:

   ```bash
   kubectl uncordon cp01
   kubectl get nodes
   ```

   ```
   node/cp01 uncordoned
   NAME   STATUS   ROLES           AGE   VERSION
   cp01   Ready    control-plane   31d   v1.34.1
   w01    Ready    <none>          31d   v1.33.4
   w02    Ready    <none>          31d   v1.33.4
   ```

7. Confirmá el efecto secundario de renovación de certificados del Ejercicio 3:

   ```bash
   sudo kubeadm certs check-expiration | head -6
   ```

   ```
   CERTIFICATE   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   admin.conf    Jul 31, 2027 11:42 UTC   364d            no
   apiserver     Jul 31, 2027 11:42 UTC   364d            no
   ```

### ✅ Checkpoint 6

- **Q6.1** — ¿Por qué hay que drenar el nodo *antes* de `apt-get install kubelet`, y no después?
- **Q6.2** — Después de que el paso 1 tuvo éxito, `kubectl get nodes` sigue reportando `v1.33.4` para `cp01`. ¿Es un bug? Explicá con precisión qué cambió y qué no cambió `kubeadm upgrade apply`.
- **Q6.3** — Explicá el mecanismo por el cual escribir un archivo nuevo en `/etc/kubernetes/manifests/` actualiza `kube-apiserver`. ¿Qué componente realiza el reinicio?
- **Q6.4** — Durante el paso 1 el API server queda brevemente no disponible. ¿Los Pods de aplicación que corren en `w01` dejan de servir tráfico? Justificá.
- **Q6.5** — Te olvidás de `systemctl daemon-reload` y sólo ejecutás `systemctl restart kubelet`. ¿Qué clase de bug estás invitando?
- **Q6.6** — ¿Cuál es la diferencia exacta de efecto entre `--force` y `--delete-emptydir-data` en `kubectl drain`, y cuál puede causar pérdida permanente de datos?

---

## Ejercicio 7 — Nodos de control plane adicionales, y después los workers

El segundo nodo de control plane y todos los workers usan `kubeadm upgrade node`, **nunca** `apply`. `apply` es la operación "decidir la versión objetivo del cluster"; `node` es la operación "hacer que este nodo se ajuste a la versión ya decidida".

### Pasos

1. En cualquier nodo de control plane *adicional* (`cp02`), instalá el `kubeadm` correspondiente, y después:

   ```bash
   sudo kubeadm upgrade node
   ```

   ```
   [upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [upgrade] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1"...
   [upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
   [upgrade] The control plane instance for this node was successfully upgraded!
   ```

   Después drain → actualizar `kubelet`/`kubectl` → `daemon-reload` → `restart kubelet` → uncordon, exactamente como en el Ejercicio 6.

2. Antes de drenar el primer worker, buscá PodDisruptionBudgets que puedan bloquear el desalojo indefinidamente:

   ```bash
   kubectl get pdb -A
   ```

   ```
   NAMESPACE   NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
   payments    api-pdb       2               N/A               0                     14d
   ```

   `ALLOWED DISRUPTIONS: 0` significa que `kubectl drain` va a quedar en bucle para siempre sobre ese Pod. Arreglá la *causa* (escalá el Deployment, o corregí un PDB demasiado estricto) — no recurras a `--disable-eviction`.

3. En `w01`, instalá el nuevo `kubeadm` (reapuntar el repo + instalación con versión fijada, como en el Ejercicio 5), y después actualizá la configuración local del kubelet del nodo:

   ```bash
   sudo kubeadm upgrade node
   ```

   ```
   [upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [upgrade] Skipping phase. Not a control plane node.
   [upgrade] Upgrading kubelet configuration for this node
   [upgrade] The configuration for this node was successfully updated!
   [upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.
   ```

4. Desde el **nodo de control plane** (o donde sea que viva tu `kubectl`), drená el worker:

   ```bash
   kubectl drain w01 --ignore-daemonsets --delete-emptydir-data
   ```

5. De vuelta en `w01`, actualizá y reiniciá el kubelet:

   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
   sudo apt-mark hold kubelet kubectl
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

6. Hacé uncordon y **esperá a que el nodo esté genuinamente sano** antes de tocar `w02`:

   ```bash
   kubectl uncordon w01
   kubectl get nodes -w    # Ctrl-C when w01 is Ready at v1.34.1
   ```

7. Repetí los pasos 3–6 para `w02`. **Un nodo por vez.** Verificá que el DaemonSet `kube-proxy` se haya desplegado en cada nodo actualizado:

   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
   ```

### ✅ Checkpoint 7

- **Q7.1** — ¿Qué hace exactamente `kubeadm upgrade node` en un worker, dado que explícitamente *no* instala el binario del kubelet? ¿Por qué el paso no es salteable?
- **Q7.2** — Un drain está trabado hace 10 minutos en `payments/api-*`. `kubectl get pdb -A` muestra `ALLOWED DISRUPTIONS: 0`. Dá dos remediaciones correctas y una que un revisor debería rechazar.
- **Q7.3** — ¿Por qué `kubectl drain` nunca desaloja Pods de DaemonSet, y por qué eso hace que `--ignore-daemonsets` sea efectivamente obligatorio y no opcional?
- **Q7.4** — Actualizás `kubelet` en `w01` a v1.34.1 pero el DaemonSet `kube-proxy` sigue corriendo la imagen v1.33.4 porque salteaste el control plane. ¿Es un skew soportado? ¿Qué regla de orden rompiste?
- **Q7.5** — Explicá la razón práctica y relevante para la seguridad de hacer los workers estrictamente de a uno en lugar de drenarlos todos en paralelo.

---

## Ejercicio 8 — Verificar la actualización, y verificar los *artefactos* que instalaste

Una actualización no termina cuando `kubectl get nodes` se ve lindo. Quedan dos cosas: probar que el cluster está sano, y probar que lo que instalaste es lo que el proyecto Kubernetes efectivamente publicó (integridad de la cadena de suministro — la otra mitad de "actualizar para evitar vulnerabilidades").

### Pasos

1. Compará contra la línea base del Ejercicio 1:

   ```bash
   kubectl get nodes -o wide
   kubectl version
   kubectl -n kube-system get pods -l tier=control-plane \
     -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   ```

   Cada `VERSION` debería leer `v1.34.1`; cada tag de imagen del control plane debería leer `v1.34.1`.

2. Revisá los endpoints de salud del API server individualmente — `readyz?verbose` nombra el check que falla en lugar de simplemente devolver un no-200:

   ```bash
   kubectl get --raw='/readyz?verbose' | tail -20
   ```

   ```
   [+]etcd ok
   [+]etcd-readiness ok
   [+]informer-sync ok
   [+]poststarthook/start-kube-apiserver-admission-initializer ok
   [+]shutdown ok
   readyz check passed
   ```

3. Confirmá que nada esté trabado o en crash-loop a nivel de todo el cluster:

   ```bash
   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
   kubectl get events -A --sort-by=.lastTimestamp | tail -20
   ```

4. Volvé a ejecutar la métrica de APIs deprecadas del Ejercicio 4. Se resetea al reiniciar el API server, así que dejá correr tráfico real un rato primero:

   ```bash
   kubectl get --raw /metrics | grep -E '^apiserver_requested_deprecated_apis'
   ```

5. Volvé a correr tu benchmark CIS. Una actualización minor reescribe los manifests de static Pods, lo que puede resetear silenciosamente un flag de hardening que habías agregado a mano:

   ```bash
   kubectl run kube-bench --image=docker.io/aquasec/kube-bench:latest --rm -it --restart=Never \
     --overrides='{"spec":{"hostPID":true,"nodeName":"cp01","tolerations":[{"operator":"Exists"}],"volumes":[{"name":"etc","hostPath":{"path":"/etc"}},{"name":"var","hostPath":{"path":"/var"}}],"containers":[{"name":"kube-bench","image":"docker.io/aquasec/kube-bench:latest","command":["kube-bench","run","--targets","master"],"volumeMounts":[{"name":"etc","mountPath":"/etc","readOnly":true},{"name":"var","mountPath":"/var","readOnly":true}]}]}}'
   ```

6. **Verificá la integridad de los artefactos.** Si descargás binarios directamente en vez de vía paquetes, chequeá siempre el SHA-256 publicado:

   ```bash
   curl -LO "https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl"
   curl -LO "https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl.sha256"
   echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
   ```

   ```
   kubectl: OK
   ```

7. **Verificá las firmas.** Kubernetes firma las imágenes y binarios de release con Sigstore/cosign (keyless, registrado en Rekor):

   ```bash
   cosign verify registry.k8s.io/kube-apiserver:v1.34.1 \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com \
     | jq '.[0].optional.Subject'
   ```

   Las cadenas exactas de identidad/issuer son detalles de release engineering que cambian; tomalas de **https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/** en vez de de memoria.

8. Cerrá el círculo con el runtime y el kernel que Kubernetes no tocó:

   ```bash
   sudo apt-get install -y --only-upgrade containerd.io runc
   sudo systemctl restart containerd
   sudo crictl version
   # kernel CVEs require a reboot; schedule it with the same drain/uncordon discipline
   ```

9. Revisá de nuevo el CVE que motivó la actualización: confirmá que tu versión en ejecución esté en o por encima de la versión **fixed-in** del Ejercicio 2.

### ✅ Checkpoint 8

- **Q8.1** — Después de la actualización, `kubectl get --raw='/readyz?verbose'` muestra `[-]etcd failed: reason withheld`. Nombrá dos causas plausibles ligadas específicamente a la actualización que acabás de hacer.
- **Q8.2** — Habías agregado manualmente `--audit-log-path` a `/etc/kubernetes/manifests/kube-apiserver.yaml`. ¿`kubeadm upgrade apply` lo preserva? ¿Cuál es la forma duradera de hacer que ese flag sobreviva a todas las actualizaciones futuras?
- **Q8.3** — `sha256sum --check` pasa sobre un `kubectl` descargado. ¿Qué ataque derrota eso, y qué ataque **no** derrota? ¿Qué paso de este ejercicio cubre la brecha?
- **Q8.4** — ¿Por qué la métrica `apiserver_requested_deprecated_apis` marca `0` (o desaparece) inmediatamente después de la actualización, incluso en un cluster lleno de clientes legacy?
- **Q8.5** — Actualizaste Kubernetes a v1.34.1 para cerrar un CVE de escape de contenedor, pero el componente afectado según el aviso era `runc`. ¿La actualización de Kubernetes lo remedió? ¿Cuál es la acción correcta, y qué exige del nodo?

---

## Ejercicio 9 — Simulacro de falla: qué significa realmente "rollback"

No existe `kubeadm downgrade`. Ensayá una vez el camino real de recuperación, en el laboratorio, para no estar aprendiéndolo durante un incidente.

### Pasos

1. Simulá una actualización fallida: parás el kubelet a mitad de camino en un nodo descartable y observás el estado.

   ```bash
   sudo systemctl stop kubelet
   sudo kubeadm upgrade apply v1.34.1 -y   # will time out waiting for static Pods
   ```

   ```
   [upgrade/staticpods] Waiting for the kubelet to restart the component
   [kubelet-check] It seems like the kubelet isn't running or healthy.
   ...
   couldn't upgrade control plane. kubeadm has tried to recover everything into the earlier state.
   Errors faced: [timed out waiting for the condition]
   ```

2. Observá la recuperación propia de kubeadm: guarda los manifests anteriores bajo `/etc/kubernetes/tmp/`. Inspeccionalos:

   ```bash
   sudo ls -la /etc/kubernetes/tmp/
   sudo ls -la /etc/kubernetes/manifests/
   ```

3. Recuperá hacia adelante — arrancá el kubelet y dejá que los static Pods reconcilien:

   ```bash
   sudo systemctl start kubelet
   sudo crictl ps | grep -E 'apiserver|scheduler|controller'
   ```

4. Reintentá con `--force` sólo si kubeadm se niega por un desajuste de versión que registró a mitad de la falla:

   ```bash
   sudo kubeadm upgrade apply v1.34.1 --force -y
   ```

5. Ensayá el rollback completo (destructivo — sólo en laboratorio). Pará el control plane, restaurá el snapshot en un directorio de datos **nuevo**, y reapuntá etcd:

   ```bash
   sudo mv /etc/kubernetes/manifests /etc/kubernetes/manifests.off   # stop static Pods
   sudo etcdutl snapshot restore /var/backups/etcd-pre-1.34-2026-07-31.db \
     --data-dir /var/lib/etcd-restored
   sudo sed -i 's#path: /var/lib/etcd#path: /var/lib/etcd-restored#' \
     /etc/kubernetes/manifests.off/etcd.yaml
   ```

6. Bajá los paquetes a la versión fijada previa a la actualización, restaurá los manifests, y reiniciá:

   ```bash
   sudo apt-mark unhold kubeadm kubelet kubectl
   sudo apt-get install -y --allow-downgrades kubeadm=1.33.4-1.1 kubelet=1.33.4-1.1 kubectl=1.33.4-1.1
   sudo apt-mark hold kubeadm kubelet kubectl
   sudo mv /etc/kubernetes/manifests.off /etc/kubernetes/manifests
   sudo systemctl daemon-reload && sudo systemctl restart kubelet
   ```

   (También vas a necesitar reapuntar la URL del repositorio apt de vuelta a `v1.33`.)

7. Verificá, y anotá en tu runbook exactamente cuánto llevó esto.

### ✅ Checkpoint 9

- **Q9.1** — `kubeadm` reportó *"has tried to recover everything into the earlier state"*. ¿Qué restauró, y qué **no** restauró explícitamente?
- **Q9.2** — ¿Por qué `etcdutl snapshot restore` insiste en un `--data-dir` nuevo y vacío en lugar de sobrescribir `/var/lib/etcd`?
- **Q9.3** — Restaurar un snapshot de etcd tomado antes de la actualización descarta todo objeto escrito desde entonces. Nombrá dos categorías de objeto cuya pérdida sería operativamente grave y que son fáciles de olvidar.
- **Q9.4** — Dado que el rollback es así de caro, enunciá las dos prácticas de los Ejercicios 3–5 que más reducen la probabilidad de llegar a necesitarlo.

---

## Ejercicio 10 — Corrida cronometrada de examen

Memorizá esto. En el examen te van a dar una versión objetivo y te van a decir qué nodos tocar.

**En el nodo de control plane (`ssh cp01`):**

```bash
# 1. repoint repo to the target minor version + re-import key
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 2. kubeadm only
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm

# 3. plan + apply
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.34.1 -y

# 4. drain, upgrade kubelet+kubectl, restart, uncordon
kubectl drain cp01 --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon cp01
```

**En cada worker (`ssh node01`) — atención: `upgrade node`, no `apply`:**

```bash
# repo repoint (same as above), then:
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm
sudo kubeadm upgrade node
# from the control plane / wherever kubectl works:
kubectl drain node01 --ignore-daemonsets --delete-emptydir-data
# back on node01:
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon node01
```

**Los cinco errores que cuestan puntos:**

1. Olvidarse de reapuntar la URL del repositorio a la nueva versión minor (y después "el paquete no existe").
2. Ejecutar `kubeadm upgrade apply` en un worker en vez de `kubeadm upgrade node`.
3. Olvidarse de `--ignore-daemonsets` y concluir que el drain está roto.
4. Olvidarse de `systemctl daemon-reload` antes de `restart kubelet`.
5. Olvidarse de `kubectl uncordon` — la tarea no está completa mientras el nodo esté en `SchedulingDisabled`.

### ✅ Checkpoint 10

- **Q10.1** — La consigna del examen dice *"actualizá sólo el nodo de control plane; no actualices los nodos worker."* ¿Cuáles de los comandos de arriba ejecutás, y cuáles salteás deliberadamente?
- **Q10.2** — Al terminar, `kubectl get nodes` muestra `cp01 Ready,SchedulingDisabled v1.34.1`. ¿Completaste la tarea? ¿Cuál es el único comando que falta?

---

<details>
<summary><strong>📖 Respuestas — clic para desplegar</strong></summary>

### Checkpoint 1

**Q1.1** — Es la versión del **kubelet**, tal como la auto-reporta el nodo en `.status.nodeInfo.kubeletVersion`. Enfáticamente **no** es la versión de `kube-apiserver`. Inmediatamente después de `kubeadm upgrade apply` el API server está en la versión nueva mientras la columna `VERSION` sigue mostrando la vieja — las dos están desacopladas por diseño. Obtené la versión del API server con `kubectl version` (`Server Version:`) o del tag de imagen del static Pod.

**Q1.2** — `kubeadm` soporta actualizar **exactamente una versión minor por vez**. `kubeadm upgrade plan` / `apply` va a rechazar un salto v1.31 → v1.34 en el preflight. El camino correcto es secuencial: v1.31 → v1.32 → v1.33 → v1.34, cada salto con su propio binario `kubeadm`, su propia URL de repositorio, y su propio despliegue de kubelet. La restricción existe porque las migraciones de storage version, las remociones de API y las transiciones de feature gates sólo se validan entre minors adyacentes. Además, `kubeadm upgrade plan` en un cluster v1.31 nunca te va a ofrecer más que v1.32.

**Q1.3** — Sí, está soportado. El `kubelet` puede estar hasta **tres versiones minor más atrás** que `kube-apiserver` (desde v1.28; antes eran dos). **Nunca** debe ser más nuevo. Así que un apiserver v1.34.1 con kubelets v1.33.4 está bien, y en principio podría persistir durante tres minors — pero "soportado" no es "seguro": esos kubelets siguen cargando el CVE que actualizaste para corregir. Tratá el margen de skew como una ventana de despliegue medida en horas o días, no como un estado de reposo.

**Q1.4** — No está soportado. `kubectl` está soportado dentro de **una versión minor** de `kube-apiserver` (más viejo o más nuevo), así que v1.31 contra un servidor v1.34 son tres minors de diferencia. Síntomas esperados: campos faltantes o no reconocidos que se descartan silenciosamente en `apply`, subcomandos que fallan contra APIs que el cliente viejo no conoce, y `kubectl` advirtiendo `client version is older than server version`. Esto es peor que una caída porque falla *en silencio* — un `securityContext` recortado en un apply es una regresión de seguridad real.

**Q1.5** — La política de skew es asimétrica a propósito: los componentes pueden ser *más viejos* que el API server, nunca *más nuevos*. Un kubelet más nuevo va a intentar usar grupos de API, campos y subrecursos que el API server más viejo no sirve, produciendo fallas de registro, campos descartados y un nodo que puede no llegar nunca a `Ready`. El API server es la autoridad del esquema; todo lo demás debe ir detrás. Exactamente por eso `kubeadm upgrade apply` (control plane) precede a la instalación del paquete `kubelet` en cada nodo.

**Q1.6** — No. `kubeadm` gestiona `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`, `kube-proxy` y `CoreDNS`, más la *configuración* del kubelet. Nunca toca `containerd`, `runc`, los binarios del plugin CNI, ni el kernel. Dado que los CVEs de escape de contenedor de mayor severidad viven históricamente en `runc` y el kernel (por ejemplo, la clase de bugs de fuga de file descriptors en `runc`), un cluster puede estar totalmente parcheado a nivel Kubernetes y aun así ser trivialmente escapable. El parcheo del sistema operativo del nodo es una vía separada y obligatoria, con su propia disciplina de drain/reboot.

### Checkpoint 2

**Q2.1** — Actualizá a **v1.33.6**, el patch release de tu serie minor actual. Cierra el CVE sin cambiar nada de las superficies de API, feature gates, versiones de addons ni compatibilidad con terceros — el radio de impacto es un cambio de binario. Saltar a v1.34.1 también cierra el CVE pero al mismo tiempo trae toda una minor de remociones de API, cambios de valores por defecto y desvíos de comportamiento, con lo cual estarías acoplando una corrección de seguridad urgente a un cambio que requiere toda la revisión de compatibilidad del Ejercicio 4. La respuesta a incidentes de seguridad y la modernización de plataforma son cambios distintos y deberían ser ventanas de mantenimiento distintas.

**Q2.2** — v1.29 está fuera de la ventana de soporte de las tres minors más recientes, así que **no recibe ningún parche de seguridad**: todo CVE divulgado contra ella de ahora en más queda permanentemente sin corregir en esa rama, y la divulgación hace público el exploit. Correr un Kubernetes EOL es aceptar un conjunto ilimitado y monótonamente creciente de vulnerabilidades conocidas y explotables.

**Q2.3** — La columna `CONTAINER-RUNTIME` (`containerd://2.0.5`, y la versión de `runc` detrás) y `KERNEL-VERSION`. El feed de CVEs de Kubernetes sólo cubre CVEs del proyecto `kubernetes/kubernetes` y sus subproyectos; `runc`, `containerd` y el kernel de Linux son upstreams separados con avisos separados, seguidos por el feed de seguridad de tu distribución. La gran mayoría de los verdaderos *escapes de contenedor* se originan ahí, no en Kubernetes.

**Q2.4** — El feed se auto-genera a partir de issues de GitHub etiquetadas `official-cve-feed` en `kubernetes/kubernetes`, mantenidas por el Security Response Committee. Eso lo hace consumible programáticamente y de baja latencia — una entrada aparece apenas el SRC la registra, sin un paso de publicación separado que pueda quedar atrasado. La contrapartida: cubre sólo los CVEs que el proyecto Kubernetes *aceptó y registró*, así que es autoritativo para Kubernetes mismo y silencioso respecto de dependencias, distribuciones de proveedores y addons de terceros. Consumilo como una entrada más, no como todo tu panorama de vulnerabilidades.

**Q2.5** — Un patch release cambia sólo correcciones de bugs dentro de una superficie estable de API y feature gates; una release minor puede remover APIs (Ejercicio 4), activar feature gates por defecto, cambiar defaults de admission, subir `CoreDNS`/`etcd`, y romper controladores de terceros, drivers CSI y plugins CNI que se atan a una matriz de compatibilidad. Así que la actualización minor trae todo el beneficio de cerrar el CVE más un conjunto mucho más grande de maneras de provocar una caída — y las caídas ocurridas mientras respondés a un incidente de seguridad son el peor momento posible para descubrir una ruptura de compatibilidad.

### Checkpoint 3

**Q3.1** — kubeadm lo rechaza. Los downgrades no están soportados: `kubeadm upgrade apply` valida que la versión solicitada no sea más vieja que la versión actual del cluster y falla en el preflight. Tu único camino real de vuelta a v1.32 es una **restauración**: parar el control plane, restaurar el snapshot de etcd previo a la actualización en un directorio de datos nuevo, bajar los paquetes `kubeadm`/`kubelet`/`kubectl` (con el repositorio reapuntado a la minor vieja), restaurar los manifests de static Pods y la PKI viejos desde tu tarball de `/etc/kubernetes`, y reiniciar el kubelet. Precisamente por esto el Ejercicio 3 no es opcional.

**Q3.2** — Un desajuste de versión entre los datos en etcd (escritos por v1.33 con storage versions de v1.33) y un control plane v1.34, *y* el riesgo inverso: un API server v1.34 puede haber migrado objetos a storage versions que los datos restaurados no contienen, o los datos restaurados pueden contener objetos en serving versions que v1.34 ya no sirve. Esperá crash-loops del API server, objetos que fallan al decodificarse, y controladores que no pueden reconciliar. **Restaurá los manifests y los paquetes junto con los datos** — el snapshot y los binarios son una unidad atómica de estado.

**Q3.3** — `kubeadm upgrade apply` (y `kubeadm upgrade node`) renueva **todos los certificados del control plane gestionados por kubeadm** — `apiserver`, `apiserver-kubelet-client`, `apiserver-etcd-client`, `front-proxy-client`, `etcd-server`, `etcd-peer`, `etcd-healthcheck-client` — y los certificados de cliente embebidos en `admin.conf`, `controller-manager.conf` y `scheduler.conf`, cada uno por otro año. Se deshabilita con `--certificate-renewal=false`. Lo deshabilitarías cuando los certificados están **gestionados externamente** (emitidos por tu PKI corporativa, cert-manager o Vault), donde la renovación autofirmada de kubeadm reemplazaría un certificado emitido correctamente por uno que tu cadena de confianza no acepta.

**Q3.4** — `server.crt` es el certificado de *servicio* de etcd; identifica al servidor ante los clientes, y su clave nunca debe entregarse a un proceso cliente cualquiera. `healthcheck-client.crt` (como `apiserver-etcd-client.crt`) es un certificado de *cliente* firmado por la CA de etcd con EKU de client-auth, que es lo que la autenticación mutua TLS de etcd realmente valida en una conexión entrante. Usar la clave del servidor puede funcionar por accidente en algunas configuraciones, pero es un error de manejo de credenciales: esparce la clave de servicio a más lugares de los necesarios.

**Q3.5** — El cluster de etcd ya no está gestionado por kubeadm, así que: (a) `kubeadm upgrade plan` no va a mostrar una fila de etcd y `kubeadm upgrade apply` no va a actualizar ni reiniciar etcd; (b) tomás el snapshot contra los endpoints externos usando la CA y los certificados de cliente *externos*, no los de `/etc/kubernetes/pki/etcd/`; (c) actualizar etcd pasa a ser una tarea separada, secuenciada manualmente, con su propia verificación de compatibilidad de versiones contra la release de Kubernetes objetivo; (d) `--etcd-upgrade` es irrelevante. Ver https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/.

### Checkpoint 4

**Q4.1** — No es urgente para *esta* actualización — `removed_release="1.35"` significa que la API todavía funciona en v1.34, así que la actualización a v1.34 no la va a romper. Pero es un bloqueante duro para la *siguiente*, y tenés exactamente un ciclo de release para arreglarlo. Manejo correcto: registralo ahora con un responsable, identificá el cliente que llama desde `apiserver_request_total` (etiqueta `userAgent`) y los logs de auditoría, migrá los manifests a la versión de reemplazo con `kubectl convert` o a mano, y volvé a revisar la métrica antes de planificar v1.35. No dejes que se convierta en una sorpresa el día de v1.35.

**Q4.2** — Kubernetes distingue la **storage version** (la única versión con la que un objeto se persiste en etcd) de las **served versions** (todas las versiones a y desde las cuales el API server convierte según lo solicitado). El objeto se almacenó una vez bajo la storage version que correspondiera, y cada lectura se convierte al vuelo a la versión que pediste; `kubectl get -o yaml` muestra `apps/v1` porque esa es la served version preferida hoy. Así que el objeto vivo sobrevive a la remoción de `apps/v1beta2` — sólo fallan las *requests* que nombran la versión removida. Un archivo YAML en Git es una request esperando ocurrir: `kubectl apply -f` de un manifest `apps/v1beta2` falla duro después de la remoción. Esa asimetría es la razón por la cual escanear el cluster vivo no alcanza y tenés que escanear también tus fuentes de manifests.

**Q4.3** — Un webhook con `failurePolicy: Fail` que queda inalcanzable hace que el API server **rechace toda request que coincida**, y si sus `rules` son amplias (`apiGroups: ["*"]`, `resources: ["*"]`) eso significa que el cluster entero deja de aceptar escrituras — incluidas las escrituras necesarias para arreglar el webhook. Las actualizaciones disparan esto al reiniciar el API server, al reiniciar los Pods del propio webhook durante los drains, o porque la biblioteca cliente del webhook es incompatible con la nueva versión de `admissionregistration.k8s.io`. Los controles del radio de impacto son `failurePolicy`, el alcance de las `rules`, `namespaceSelector`/`objectSelector` (en particular excluyendo `kube-system`), y `timeoutSeconds`.

**Q4.4** — Porque una actualización rota se "arregla" rutinariamente bajo presión deshabilitando el control de seguridad que se rompió. Cuando un webhook de seguridad (OPA/Gatekeeper, Kyverno, un verificador de firmas de imágenes) falla después de una actualización, el camino más rápido de vuelta a un cluster funcional es poner `failurePolicy: Ignore` o borrar la configuración del webhook — y ese arreglo temporal se vuelve permanente, dejando al cluster admitiendo imágenes sin firmar y Pods privilegiados indefinidamente. Hacer la revisión de compatibilidad *antes* de la actualización es lo que previene el incidente que degrada tu postura de seguridad.

### Checkpoint 5

**Q5.1** — Los repositorios comunitarios `pkgs.k8s.io` son **por versión minor**: la URL `.../core:/stable:/v1.33/deb/` contiene sólo paquetes v1.33 y nunca va a servir v1.34, por más veces que corras `apt-get update`. Arreglo: reescribí `/etc/apt/sources.list.d/kubernetes.list` a `.../core:/stable:/v1.34/deb/`, reimportá la `Release.key` de ese repo en `/etc/apt/keyrings/kubernetes-apt-keyring.gpg` (cada repo se firma de forma independiente), y después `apt-get update`. Ver https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/. Este es el tropiezo más común en esta tarea del examen.

**Q5.2** — Porque el `kubelet` es un **paquete a nivel de sistema operativo y una unit de systemd en cada nodo**, no un contenedor que el control plane pueda reprogramar. kubeadm no tiene un canal de ejecución remota hacia tus nodos — es una herramienta local de bootstrapping, deliberadamente no un sistema de gestión de configuración. Hace lo que puede alcanzar: actualiza la *configuración* del kubelet del nodo (vía `kubeadm upgrade node`) y te dice que instales el binario vos mismo. Esa separación es la razón por la que el despliegue del kubelet es trabajo tuyo (o de Ansible, o de tu pipeline de imágenes), nodo por nodo.

**Q5.3** — Fija la versión instalada para que un `apt-get upgrade` no relacionado o una corrida automática de `unattended-upgrades` no puedan mover `kubelet`/`kubeadm`/`kubectl` por debajo tuyo. Relevancia de seguridad: un salto fuera de banda puede empujar silenciosamente un `kubelet` **más nuevo que el API server**, violando la política de skew y rompiendo el nodo; a la inversa, una actualización masiva sin fijar versiones a lo largo de la flota puede reiniciar todos los kubelets simultáneamente. El control de versiones sobre los componentes que hacen cumplir tu camino de autenticación, autorización y admisión es en sí mismo un control de seguridad — querés que las actualizaciones pasen en tu cronograma, en tu orden, con tu verificación.

**Q5.4** — Falla en el preflight. `kubeadm` se niega a aplicar una versión que no coincide con la de su propio binario, con un error del estilo *"the --version argument is invalid due to these errors: … kubeadm version v1.34.1 is not the same as the requested version v1.34.0"*. La regla es: instalá el parche exacto de `kubeadm` que pensás correr, y después pasá esa misma versión a `apply`. (`--force` puede anular algunas fallas de preflight pero no es una forma de esquivar esto — instalá el `kubeadm` correcto.)

**Q5.5** — Sí. `kubeadm upgrade apply` reescribe `/etc/kubernetes/manifests/etcd.yaml` como parte de la actualización aunque el tag de imagen no cambie, y cualquier escritura en ese archivo hace que el kubelet reinicie el static Pod. En un control plane de un solo nodo con etcd stacked eso es una breve caída de escritura de todo el cluster. Usá `--etcd-upgrade=false` para dejar etcd en paz; está justificado cuando etcd está gestionado externamente, cuando tenés una ventana de mantenimiento separada para etcd, o cuando estás minimizando deliberadamente el conjunto de cambios de una actualización de seguridad urgente a nivel de parche. Tomá el snapshot primero, en cualquier caso.

### Checkpoint 6

**Q6.1** — Porque `apt-get install kubelet` dispara un reinicio del kubelet, y en un nodo cargado eso interrumpe brevemente el proceso que supervisa a todos los contenedores. Drenar primero mueve las cargas de trabajo afuera y hace cordon del nodo para que el scheduler no coloque nuevas ahí, de modo que el reinicio ocurre sobre un nodo ocioso. Invertir el orden significa un reinicio en caliente bajo carga: desalojo de Pods que estaban en medio de una request, posibles reinicios de contenedores y — si el nuevo kubelet no arranca por una incompatibilidad de configuración — una caída de todo lo que todavía estaba corriendo ahí. En el nodo de control plane el mismo argumento aplica a `CoreDNS` y a cualquier otra carga que no sea DaemonSet programada ahí.

**Q6.2** — No es un bug; es el estado intermedio esperado. `kubeadm upgrade apply` reescribió los **manifests de static Pods** de `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` y `etcd`, actualizó los addons `kube-proxy` y `CoreDNS`, renovó los certificados, y actualizó los ConfigMaps `kubeadm-config` / `kubelet-config`. **No** instaló un binario `kubelet` nuevo en ningún nodo, incluido éste. `kubectl get nodes` reporta `.status.nodeInfo.kubeletVersion`, así que va a seguir mostrando `v1.33.4` hasta que instales el paquete y reinicies el servicio en los pasos 4–5.

**Q6.3** — Lo hace el **kubelet**. El kubelet vigila su `staticPodPath` (`/etc/kubernetes/manifests`, definido en `/var/lib/kubelet/config.yaml`) y trata cada manifest ahí como un Pod que le pertenece directamente, sin intervención del API server. Cuando kubeadm escribe un `kube-apiserver.yaml` nuevo con un tag de imagen actualizado, el kubelet nota el cambio del archivo, mata el contenedor viejo y arranca uno desde la imagen nueva. Por eso el control plane puede actualizarse incluso con el API server caído, y por eso un kubelet detenido (Ejercicio 9) hace que `kubeadm upgrade apply` se cuelgue y expire.

**Q6.4** — No — los Pods ya en ejecución siguen sirviendo. El API server es el punto de coordinación del control plane, no un componente del plano de datos: el `kubelet` sigue gestionando sus contenedores existentes, `kube-proxy` mantiene las reglas de iptables/IPVS que ya programó, y el dataplane del CNI queda intacto. Lo que se detiene es el *cambio*: nada de scheduling nuevo, nada de rollouts de Deployments, nada de actualizaciones de Service/Endpoint, nada de `kubectl`, y — importante — ninguna reacción ante fallas de Pods. Así que un Pod que crashee durante la ventana no va a ser reiniciado ni reprogramado hasta que el API server vuelva. Breve, pero no de riesgo cero.

**Q6.5** — systemd sigue corriendo la definición de unit **cacheada**. Si el paquete trajo un `kubelet.service` modificado o un drop-in nuevo bajo `/etc/systemd/system/kubelet.service.d/` (que es donde kubeadm pone `10-kubeadm.conf`), el kubelet reiniciado arranca con flags `ExecStart` obsoletos o una ruta `--config` desactualizada. Los síntomas van desde el kubelet fallando al registrarse, hasta correr silenciosamente con los flags de la release *anterior* — incluyendo, potencialmente, algunos relevantes para la seguridad como `--authorization-mode`, `--anonymous-auth` o la configuración TLS. Siempre `daemon-reload` antes de `restart`.

**Q6.6** — `--delete-emptydir-data` permite el desalojo de Pods que tienen un volumen `emptyDir`; el contenido del volumen se destruye junto con el Pod, pero el Pod en sí pertenece a un controlador y va a ser **recreado en otro lado**. `--force` permite borrar Pods que **no tienen controlador** (Pods sueltos, o Pods huérfanos de su owner); esos se borran y **nunca vuelven** — no existe nada que los recree. Por lo tanto `--force` es el que causa pérdida permanente de cargas de trabajo; `--delete-emptydir-data` causa pérdida permanente de *datos temporales*. Ambos deberían ser decisiones conscientes, y en un cluster productivo deberías saber qué Pods sueltos existen antes de tipear `--force`.

### Checkpoint 7

**Q7.1** — En un worker, `kubeadm upgrade node` descarga la nueva configuración de kubelet de alcance de cluster desde el ConfigMap `kubelet-config` en `kube-system` y la escribe en `/var/lib/kubelet/config.yaml`, y refresca el certificado de cliente / `kubelet.conf` gestionado por kubeadm del nodo según haga falta. No instala ningún binario. No es salteable porque el nuevo binario del kubelet espera el nuevo esquema de configuración: saltearlo puede dejar al nodo corriendo un kubelet v1.34 contra un archivo de configuración v1.33, lo que en el mejor caso ignora los nuevos defaults y en el peor no arranca. En nodos de control plane adicionales hace más — también actualiza los manifests de static Pods de ese nodo.

**Q7.2** — Correctas: (1) escalar el Deployment para que `ALLOWED DISRUPTIONS` pase a ser ≥1 y el desalojo pueda proceder mientras la garantía de disponibilidad del PDB sigue vigente; (2) corregir un PDB demasiado estricto o directamente mal — por ejemplo, `minAvailable: 2` en un Deployment de 2 réplicas prohíbe matemáticamente toda disrupción voluntaria, así que corregilo a `maxUnavailable: 1` o subí la cantidad de réplicas. Rechazar: `kubectl drain --disable-eviction`, que evita la API de eviction y **borra los Pods directamente**, derrotando en silencio la mismísima garantía de disponibilidad que el dueño de la aplicación codificó en el PDB. (`--force` tampoco es la respuesta acá — los Pods pertenecen a un controlador; el bloqueante es el budget, no la pertenencia.)

**Q7.3** — El contrato de drain es "mover las cargas de trabajo a otro nodo". Los Pods de DaemonSet son, por definición, uno por nodo y están fijados a *este* nodo — el controlador del DaemonSet recrearía inmediatamente en el mismo nodo cualquier Pod desalojado, así que el desalojo es un bucle sin efecto. Por eso `kubectl drain` se niega a proceder en vez de hacer algo fútil, a menos que lo reconozcas con `--ignore-daemonsets`. Como todo cluster real corre el plugin CNI y `kube-proxy` como DaemonSets, el flag es obligatorio en la práctica en todo drain — y debe serlo, porque esos Pods son exactamente lo que el nodo sigue necesitando mientras se drena.

**Q7.4** — No soportado en el sentido que importa. `kube-proxy` no debe ser más nuevo que `kube-apiserver` y debería mantenerse dentro de una minor respecto del kubelet de su nodo — pero la infracción más profunda es de orden: actualizaste un componente a nivel de nodo mientras el control plane sigue más viejo, que es la dirección prohibida. La regla es **control plane primero, siempre**: `kube-apiserver` → resto de los componentes del control plane → `kubelet`/`kube-proxy` en cada nodo. La imagen de `kube-proxy` está gestionada por el DaemonSet que `kubeadm upgrade apply` actualiza, así que en el orden correcto esto se resuelve solo. Consultá la tabla autoritativa en https://kubernetes.io/releases/version-skew-policy/.

**Q7.5** — Capacidad y radio de impacto. Drenar varios nodos a la vez puede dejar al cluster sin espacio para reprogramar los Pods desalojados, con lo cual las cargas quedan en `Pending` — y los PDBs que eran satisfacibles de a un nodo por vez se vuelven insatisfacibles en paralelo, trabando todos los drains simultáneamente. La parte relevante para la seguridad: un cluster en ese estado es uno donde el operador está bajo presión y recurre a `--force`, `--disable-eviction`, o "borrá el PDB y listo", cada uno de los cuales cambia una garantía de disponibilidad o de seguridad por velocidad. El despliegue serial mantiene toda falla recuperable con sólo detenerse.

### Checkpoint 8

**Q8.1** — (1) El static Pod de etcd fue reiniciado por la actualización (kubeadm reescribe `etcd.yaml` incluso con la versión sin cambios) y no terminó de volver — revisá `sudo crictl ps -a | grep etcd` y los logs del contenedor. (2) El certificado `apiserver-etcd-client` fue renovado por `kubeadm upgrade apply`, pero etcd sigue presentando o confiando en el material viejo porque su Pod se reinició en el momento equivocado, o porque tus certificados están gestionados externamente y la renovación reemplazó un certificado emitido correctamente por uno autofirmado por kubeadm. También plausible: un salto de versión de etcd con un desajuste de directorio de datos o de peer URLs. Diagnosticá con `sudo crictl logs $(sudo crictl ps -a --name etcd -q | head -1)`.

**Q8.2** — **No.** `kubeadm upgrade apply` regenera los manifests de static Pods a partir del ConfigMap `kubeadm-config` y sus propias plantillas, sobrescribiendo flags editados a mano. El arreglo duradero es poner el flag en la configuración del cluster en lugar del manifest: `apiServer.extraArgs` en la `ClusterConfiguration` (y `extraVolumes` para cualquier ruta del host que el flag necesite), aplicado con `kubeadm upgrade apply --config`, de modo que toda actualización futura regenere el manifest *con* tu flag. Esta es una preocupación de seguridad de primer orden — el audit logging, la lista de plugins de admission, la configuración de cifrado en reposo y los parámetros TLS viven todos en estos flags, y perder uno silenciosamente durante una actualización es una regresión de hardening por la que nadie recibe una alerta. Volver a correr `kube-bench` después de cada actualización es el control detectivo que lo caza.

**Q8.3** — Derrota la **corrupción y la manipulación en tránsito o en reposo en el mirror** — una descarga truncada, un proxy malicioso, un edge de CDN comprometido — *siempre que* el checksum haya venido de un canal confiable. **No** derrota a un atacante que controla el punto de distribución, porque publicaría un `.sha256` coincidente junto al binario malicioso; el checksum no es una prueba de identidad, sólo una prueba de integridad relativa a una URL en la que ya confiás. El paso 7 cubre la brecha: `cosign verify` verifica una firma criptográfica ligada a una identidad específica de release engineering y registrada en el log de transparencia Rekor, así que un artefacto falsificado necesitaría una firma válida de esa identidad y una entrada pública en el log que lo atestigüe.

**Q8.4** — Porque `apiserver_requested_deprecated_apis` es una métrica de Prometheus mantenida en la memoria del proceso del API server, y la actualización reinició ese proceso. Todos los contadores se resetean a cero. Sólo se repuebla a medida que los clientes vuelven a hacer llamadas deprecadas — y los llamadores poco frecuentes (un CronJob nocturno, un batch trimestral, una persona corriendo un script viejo) pueden no aparecer durante días o meses. Consecuencia: revisá esta métrica durante una ventana de observación larga *antes* de la actualización, y nunca leas una métrica limpia post-actualización como evidencia de que nada usa APIs deprecadas.

**Q8.5** — No. La actualización de Kubernetes reemplazó `kube-apiserver`, `kubelet` y compañía; no tocó el binario `runc` que efectivamente crea los contenedores, así que el escape sigue plenamente explotable. Acción correcta: actualizar `runc` (y normalmente `containerd` junto con él) mediante el gestor de paquetes del nodo, y después reiniciar `containerd`. Ese reinicio interrumpe el container runtime en el nodo, así que requiere la misma disciplina que una actualización del kubelet — drain, parchear, reiniciar, verificar, uncordon — y si la corrección está en el kernel, un reboot en la misma ventana de drain. El parcheo a nivel de nodo es una vía separada de `kubeadm upgrade` y debe planificarse explícitamente; asumir que las actualizaciones de Kubernetes lo cubren es una de las brechas más comunes en el mundo real.

### Checkpoint 9

**Q9.1** — Restauró los **manifests de static Pods** que acababa de reemplazar, desde las copias de respaldo que guarda bajo `/etc/kubernetes/tmp/kubeadm-backup-manifests-*`, de modo que el control plane vuelve a sus versiones de componentes previas. **No** revirtió nada fuera de esos archivos: los datos de `etcd` escritos durante el intento quedan escritos, las migraciones de storage version no se revierten, los addons (`CoreDNS`, `kube-proxy`) ya reaplicados en la versión nueva se quedan en la versión nueva, los cambios de ConfigMap en `kubeadm-config`/`kubelet-config` persisten, y los paquetes instalados quedan intactos. "Recuperado al estado anterior" significa los manifests, no el cluster.

**Q9.2** — Porque `snapshot restore` construye un **directorio de datos de miembro completamente nuevo** — incluyendo un member ID, cluster ID y WAL frescos — en lugar de fusionarse con uno existente. Escribir en un directorio que ya contiene el WAL y los archivos de snapshot de un miembro produciría una mezcla inconsistente de dos historias, y etcd se niega antes que arriesgar una corrupción silenciosa de datos. Exigir un destino vacío además preserva `/var/lib/etcd` intacto, así que una restauración fallida te deja exactamente a un `sed` de distancia de donde arrancaste.

**Q9.3** — Cualquiera de: (1) **Secrets y tokens de ServiceAccount** creados desde el snapshot — restaurar resucita credenciales rotadas/revocadas y destruye las recién emitidas, así que las aplicaciones se autentican con secrets que ya no existen, y credenciales que rotaste deliberadamente después de un incidente vuelven a la vida; (2) **cambios de RBAC** — un `RoleBinding` que eliminaste para revocar el acceso de alguien se restaura, reinstaurando ese acceso en silencio; (3) **CRs de operadores** (certificados emitidos por cert-manager, clusters de bases de datos, cronogramas de backup), donde la visión del mundo del operador y los recursos cloud reales divergen; (4) **bindings de PersistentVolume/PVC** creados desde el snapshot, dejando volúmenes reales huérfanos. Los casos de RBAC y Secrets son los críticos para la seguridad: una restauración de etcd es una *máquina del tiempo de credenciales y autorizaciones* y debe ir seguida de una re-auditoría deliberada.

**Q9.4** — (1) **Preferir actualizaciones de parche dentro de la minor actual** para responder a CVEs (Q2.1) — la misma corrección, una superficie de cambio drásticamente menor, mucho menos que pueda requerir un rollback. (2) **Ensayar con `kubeadm upgrade plan` y `--dry-run`, y completar primero la revisión de APIs removidas/compatibilidad del Ejercicio 4**, para que los modos de falla de la actualización se descubran antes de que se escriba un solo manifest. Adyacentes e igual de decisivas: actualizar un nodo por vez, y nunca empezar sin un snapshot de etcd verificado y guardado fuera del nodo.

### Checkpoint 10

**Q10.1** — Ejecutá todo el bloque del control plane: reapuntar el repositorio, `apt-mark unhold kubeadm` → instalar el `kubeadm` con versión fijada → `apt-mark hold kubeadm`, `kubeadm upgrade plan`, `kubeadm upgrade apply v1.34.1 -y`, después `kubectl drain cp01 --ignore-daemonsets`, instalar `kubelet`/`kubectl` con versión fijada, `systemctl daemon-reload && systemctl restart kubelet`, `kubectl uncordon cp01`. **Salteá todo el bloque de workers** — no hagas `ssh` a los workers, no ejecutes `kubeadm upgrade node`, no los drenes ni los actualices. Dejar los kubelets una minor atrás está dentro del skew soportado, que es exactamente por lo cual la tarea puede pedirlo.

**Q10.2** — No. `SchedulingDisabled` significa que el nodo todavía carga el taint `node.kubernetes.io/unschedulable` y el campo `spec.unschedulable: true` que dejó el `drain`; el cluster no va a colocar ningún Pod nuevo ahí, así que la tarea está incompleta y se va a calificar como tal. Ejecutá `kubectl uncordon cp01` y confirmá que el estado lea simplemente `Ready`.

</details>

---

## Fuentes de referencia

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum
- Upgrading kubeadm clusters — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Upgrading Linux nodes — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
- Changing the Kubernetes package repository — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/
- Version skew policy — https://kubernetes.io/releases/version-skew-policy/
- Patch releases and support window — https://kubernetes.io/releases/patch-releases/
- Official CVE feed — https://kubernetes.io/docs/reference/issues-security/official-cve-feed/
- Security and disclosure information — https://kubernetes.io/docs/reference/issues-security/security/
- Deprecated API migration guide — https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- API deprecation policy — https://kubernetes.io/docs/reference/using-api/deprecation-policy/
- `kubeadm upgrade` command reference — https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-upgrade/
- Certificate management with kubeadm — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Safely drain a node — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Disruptions and PodDisruptionBudgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Verify signed Kubernetes artifacts — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/