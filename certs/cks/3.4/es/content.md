# 3.4 — Actualizar Kubernetes para Evitar Vulnerabilidades

> **CKS v1.34 · Dominio 3: Cluster Hardening · Peso 3.75%**
> Audiencia: Platform Architects y SREs que operan Kubernetes autogestionado a escala de producción.

---

## 1. Motivación y el Problema Arquitectónico en Producción

### 1.1 El control plane del cluster es una Trusted Computing Base

Toda carga de trabajo de un cluster Kubernetes confía transitivamente en un conjunto pequeño de binarios: `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`, `kubelet`, `kube-proxy`, el container runtime y el kernel. Un defecto en cualquiera de ellos no es "un bug en una app" — es un defecto en el *sustrato que hace cumplir todos los demás controles que configuraste*. RBAC, NetworkPolicy, admission webhooks, Pod Security Standards, perfiles seccomp: todos ellos son aplicados por código que a su vez debe ser correcto.

Esto produce la asimetría central del cluster hardening:

> Podés escribir un modelo RBAC perfecto y aun así entregarle `cluster-admin` a un atacante si tu `kube-apiserver` es vulnerable a un bypass de autorización en el proxy-upgrade.

CVE-2018-1002105 es la demostración canónica. Una petición de upgrade manipulada hacia los endpoints de la aggregated API / exec dejaba abierta una conexión autenticada al backend, y *cualquier* petición posterior sobre esa conexión era enviada por proxy a un API server backend con las credenciales propias del API server — sin reautorización. Con el binding `system:discovery` por defecto disponible para usuarios no autenticados en las versiones afectadas, esto era un camino remoto, efectivamente pre-auth, hacia el compromiso total del cluster (CVSS 9.8). Ninguna cantidad de higiene de Role/RoleBinding lo mitigaba. Solo lo hacía un salto de versión.

### 1.2 Actualizar es necesario pero *no suficiente*

La idea equivocada más común a nivel CKS es que "parchear el cluster" es una respuesta completa a "evitar vulnerabilidades". No lo es. Las vulnerabilidades de Kubernetes caen en al menos cuatro clases, y solo una de ellas se cierra por completo instalando un binario más nuevo:

| Clase | Ejemplo | ¿Se cierra solo con actualizar? | Acción adicional requerida |
|---|---|---|---|
| **Defecto de código en un componente core** | CVE-2018-1002105 (bypass de authz en el proxy del apiserver), CVE-2019-11253 (DoS "billion laughs" de YAML en el apiserver) | ✅ Sí | Ninguna |
| **Defecto en una dependencia transitiva (Go stdlib, librerías)** | HTTP/2 Rapid Reset (CVE-2023-44487 / CVE-2023-39325) — mitigado en Kubernetes recompilando contra un toolchain de Go parcheado | ✅ Sí, vía patch release | Seguir las releases de *patch*, no solo las minors |
| **Debilidad de nivel de diseño sin arreglo de código** | CVE-2020-8554 — cualquier usuario que pueda crear un Service puede reclamar una IP arbitraria en `externalIPs` / status de LoadBalancer y hacer MITM del egress del cluster hacia esa IP | ❌ **No** | Admission control (ValidatingAdmissionPolicy / Kyverno / OPA) que restrinja `spec.externalIPs`; RBAC sobre la creación de Services |
| **Componente del ecosistema fuera del repo de k8s** | CVE-2025-1974 ("IngressNightmare") — RCE no autenticado en el admission controller de `ingress-nginx`, CVSS 9.8; runc CVE-2024-21626 ("Leaky Vessels") fuga de file descriptor → escape del contenedor; CVE-2019-5736 sobrescritura de `/proc/self/exe` del host en runc | ❌ **No** — un `kubeadm upgrade` no los toca | Pipelines de parcheo separados para CNI, ingress, CSI, runtime, kernel |

Diseñá el programa de actualizaciones alrededor de esta tabla. Un dashboard de "estamos en el último patch de 1.34" que está en verde mientras `ingress-nginx`, `containerd`, `runc` y el kernel del host quedan sin gestionar es *teatro de seguridad*.

### 1.3 La restricción real en producción: el MTTR de un CVE

La pregunta arquitectónica no es "¿deberíamos actualizar?" sino **"¿cuál es el tiempo de reloj desde la publicación del CVE hasta la remediación en toda la flota, y cuál es el radio de impacto de la remediación misma?"**

Dos modos de falla acotan el problema:

* **Actualizar demasiado poco.** Acumulás skew, salís de la ventana soportada, perdés el acceso a las patch releases por completo y terminás forzado a un salto de múltiples minors — la operación de mayor riesgo del ciclo de vida del cluster — *bajo la presión de un incidente*. Así es como un CVE Sev-3 se convierte en una caída Sev-1.
* **Actualizar sin cuidado.** Rompés cargas de trabajo sobre APIs eliminadas, violás una regla de version skew, agotás los márgenes de un `PodDisruptionBudget`, o dejás inservible un nodo del control plane con un certificado vencido. El daño a la disponibilidad producido por una actualización mala habitualmente supera la pérdida esperada del CVE que estabas parcheando.

Las plataformas maduras resuelven esto haciendo que las actualizaciones sean **aburridas, frecuentes y ensayadas**: deltas pequeños continuos en vez de grandes y esporádicos. La inversión de ingeniería está en el *pipeline*, no en la actualización individual.

### 1.4 La ventana de soporte es un límite arquitectónico duro

Kubernetes publica **tres releases minor por año** (aproximadamente cada cuatro meses). Cada release minor recibe **14 meses de soporte de parches**: 12 meses de soporte estándar más 2 meses en modo mantenimiento. Las patch releases se cortan según una cadencia mensual publicada, con una fecha límite de cherry-pick el viernes previo a cada patch tuesday.

La consecuencia: **en cualquier momento solo tres versiones minor reciben parches de seguridad.** Caer a n-3 significa que cuando aterrice el próximo CVE crítico no habrá parche para vos — la única remediación es una actualización minor, que es exactamente la operación que venías postergando.

| Minor | Release aproximada | Fin aproximado del soporte estándar | EOL aproximado (fin de mantenimiento) |
|---|---|---|---|
| 1.32 | Dic 2024 | ~Dic 2025 | ~Feb 2026 |
| 1.33 | Abr 2025 | ~Abr 2026 | ~Jun 2026 |
| **1.34** (objetivo del examen) | Ago 2025 | ~Ago 2026 | ~Oct 2026 |

> Las fechas son indicativas. **Confirmá siempre contra <https://kubernetes.io/releases/> y <https://kubernetes.io/releases/patch-releases/>** — esas son las fuentes autoritativas y se mueven.

Presupuestá una actualización minor por trimestre como compromiso permanente de plataforma. Tres por año es la tasa mínima sostenible; cualquier cosa más lenta es una decisión en cámara lenta de correr software sin soporte.

---

## 2. Saber *Qué* Parchear: El Pipeline de Ingesta de Vulnerabilidades

No podés parchear lo que no conocés. Kubernetes publica datos de vulnerabilidades legibles por máquina; una plataforma de producción los consume automáticamente.

### 2.1 Fuentes autoritativas

| Fuente | Tipo | URL | Uso |
|---|---|---|---|
| Feed oficial de CVEs (HTML) | Curado, humano | `https://kubernetes.io/docs/reference/issues-security/official-cve-feed/` | Revisión de triage |
| Feed oficial de CVEs (JSON) | Curado, máquina | `https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json` | Automatización / alertas |
| `kubernetes-security-announce` | Lista de correo, push | `https://groups.google.com/g/kubernetes-security-announce` | Notificación inmediata |
| Security Response Committee | Proceso/política | `https://github.com/kubernetes/committee-security-response` | Política de embargo, plazos de divulgación |
| CHANGELOG por minor | Detalle por release | `https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/README.md` | Versión exacta del fix, "Urgent Upgrade Notes" |
| Guía de migración de APIs deprecadas | Compatibilidad | `https://kubernetes.io/docs/reference/using-api/deprecation-guide/` | Gate previo a la actualización |

El feed JSON se genera a partir de issues de GitHub en `kubernetes/kubernetes` que llevan la etiqueta `official-cve-feed`, de modo que refleja únicamente los CVEs que el Security Response Committee aceptó como CVEs de Kubernetes. **No incluye** plugins CNI, `ingress-nginx`, drivers CSI, `containerd`/`runc`, ni tu sistema operativo host. Esos necesitan sus propias suscripciones.

### 2.2 Ingesta automatizada — manifiesto completo y desplegable

El siguiente CronJob consulta el feed oficial cada seis horas, filtra por umbral de CVSS y emite una alerta a un webhook. Es deliberadamente libre de dependencias (`curl` + `jq`) para poder correr en un namespace restringido bajo el Pod Security Standard `restricted`.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-security
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cve-watch
  namespace: platform-security
automountServiceAccountToken: false
---
apiVersion: v1
kind: Secret
metadata:
  name: cve-watch-webhook
  namespace: platform-security
type: Opaque
stringData:
  # Replace with your real alerting endpoint (Alertmanager, Slack, PagerDuty Events API).
  url: "https://alertmanager.platform.svc.cluster.local:9093/api/v2/alerts"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cve-watch-script
  namespace: platform-security
data:
  cve-watch.sh: |
    #!/bin/sh
    set -eu

    FEED_URL="https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json"
    MIN_CVSS="${MIN_CVSS:-7.0}"
    STATE_FILE="/state/seen.txt"

    touch "${STATE_FILE}"

    echo "[cve-watch] fetching ${FEED_URL}"
    if ! curl --fail --silent --show-error --max-time 30 \
              --proto '=https' --tlsv1.2 \
              -o /tmp/feed.json "${FEED_URL}"; then
      echo "[cve-watch] FATAL: feed fetch failed" >&2
      exit 1
    fi

    # The feed exposes an "items" array; each entry carries id, summary, url,
    # external_url and content_text. CVSS is not guaranteed to be present, so we
    # alert on every unseen CVE and let the human triage severity.
    jq -r '.items[] | [.id, (.summary // "no summary"), (.external_url // .url)] | @tsv' \
      /tmp/feed.json > /tmp/current.tsv

    NEW=0
    while IFS="$(printf '\t')" read -r id summary link; do
      if grep -qxF "${id}" "${STATE_FILE}"; then
        continue
      fi
      NEW=$((NEW + 1))
      echo "[cve-watch] NEW ${id}: ${summary} (${link})"

      payload=$(jq -n \
        --arg id "${id}" \
        --arg summary "${summary}" \
        --arg link "${link}" \
        --arg cluster "${CLUSTER_NAME}" \
        '[{
           labels: {
             alertname: "KubernetesCVEPublished",
             severity: "warning",
             cve: $id,
             cluster: $cluster
           },
           annotations: {
             summary: $summary,
             runbook_url: $link
           }
         }]')

      curl --fail --silent --show-error --max-time 15 \
           -H 'Content-Type: application/json' \
           -d "${payload}" "${WEBHOOK_URL}" \
        || echo "[cve-watch] WARN: alert delivery failed for ${id}" >&2

      echo "${id}" >> "${STATE_FILE}"
    done < /tmp/current.tsv

    echo "[cve-watch] done; ${NEW} new CVE(s)"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cve-watch-state
  namespace: platform-security
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cve-watch
  namespace: platform-security
spec:
  schedule: "17 */6 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 300
      template:
        spec:
          serviceAccountName: cve-watch
          automountServiceAccountToken: false
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: watch
              image: alpine/k8s:1.34.1
              command: ["/bin/sh", "/scripts/cve-watch.sh"]
              env:
                - name: CLUSTER_NAME
                  value: "prod-eu-west-1"
                - name: MIN_CVSS
                  value: "7.0"
                - name: WEBHOOK_URL
                  valueFrom:
                    secretKeyRef:
                      name: cve-watch-webhook
                      key: url
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 20m
                  memory: 64Mi
                limits:
                  memory: 128Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: state
                  mountPath: /state
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: scripts
              configMap:
                name: cve-watch-script
                defaultMode: 0555
            - name: state
              persistentVolumeClaim:
                claimName: cve-watch-state
            - name: tmp
              emptyDir:
                sizeLimit: 32Mi
```

### 2.3 SLA de triage — convertir la severidad en un plazo

| Banda CVSS | Clasificación | SLA de remediación (control plane) | SLA de remediación (nodos) | Control compensatorio mientras tanto |
|---|---|---|---|---|
| 9.0 – 10.0 | Crítica | 24 h | 72 h | Admission policy de emergencia / NetworkPolicy / deshabilitar feature gate; considerar sacar de línea el endpoint afectado |
| 7.0 – 8.9 | Alta | 7 días | 14 días | Restricción RBAC dirigida, admission policy |
| 4.0 – 6.9 | Media | Siguiente ciclo de parcheo programado (≤30 días) | Siguiente ciclo | Regla de detección sobre el audit log |
| 0.1 – 3.9 | Baja | Siguiente actualización minor | Siguiente minor | Documentar y aceptar |

Codificá esto como política, no como sentimiento. El número que importa en el scorecard de la plataforma es el **P95 del tiempo hasta el parche**, medido por CVE.

---

## 3. Version Skew: Las Reglas Que Hacen Posibles las Actualizaciones Rolling

Kubernetes se actualiza *in situ, componente por componente*, lo que significa que un cluster es intencionalmente heterogéneo durante la actualización. La **version skew policy** define exactamente cuán heterogéneo se le permite ser. Violarla produce comportamiento indefinido, no un error limpio — este es un tema de alto rendimiento tanto en el examen como en producción.

### 3.1 La matriz de skew (Kubernetes 1.34)

| Componente | ¿Puede ser **más nuevo** que `kube-apiserver`? | Retraso máximo respecto de `kube-apiserver` | Restricciones extra |
|---|---|---|---|
| `kube-apiserver` (pares en HA) | n/a | 1 minor entre la instancia más nueva y la más vieja | Durante la actualización hay transitoriamente una instancia en n+1 y el resto en n |
| `kube-controller-manager` | ❌ Nunca | 1 minor | En HA, no debe ser más nuevo que el `kube-apiserver` **más viejo** al que pueda llegar |
| `kube-scheduler` | ❌ Nunca | 1 minor | Misma salvedad de HA |
| `cloud-controller-manager` | ❌ Nunca | 1 minor | Misma salvedad de HA |
| `kubelet` | ❌ Nunca | **3 minors** (extendido desde 2 en 1.28) | No debe ser más nuevo que el `kube-apiserver` alcanzable más viejo |
| `kube-proxy` | ❌ Nunca | 3 minors | Además debe estar dentro de ±1 minor respecto del **kubelet del mismo nodo** |
| `kubectl` | ✅ Hasta 1 minor más nuevo | 1 minor | Efectivamente una ventana de ±1 alrededor de `kube-apiserver` |
| `kubeadm` | — | — | Actualiza **solo de a un minor por vez**; `kubeadm` debe coincidir con la versión objetivo |

Referencia autoritativa: <https://kubernetes.io/releases/version-skew-policy/>

### 3.2 El orden obligatorio de actualización

El orden se deriva de las reglas de skew — no es una preferencia de estilo:

```
1. etcd                      (independent lifecycle; upgrade first, one minor at a time)
2. kube-apiserver            (all HA instances; oldest must reach the target minor)
3. kube-controller-manager
   kube-scheduler
   cloud-controller-manager  (never ahead of the API server)
4. kubelet                   (node by node, drained)
5. kube-proxy                (typically a DaemonSet updated with the control plane by kubeadm)
6. kubectl and cluster addons (CoreDNS, CNI, CSI, metrics-server)
```

La regla para memorizar: **el control plane primero, de arriba hacia abajo; nunca dejes que un componente cliente vaya por delante del API server.**

### 3.3 Por qué el skew extendido del kubelet importa arquitectónicamente

La ventana n-3 del kubelet (un año completo de releases minor) existe específicamente para que las flotas de nodos puedan parchearse con una *cadencia distinta y más lenta* que el control plane. Esta es la primitiva que habilita el modelo de "nodo inmutable": actualizás el control plane cada trimestre y rotás las imágenes de nodo en tu propio calendario — por ejemplo, guiado por CVEs de kernel/runtime en vez de por los minors de Kubernetes.

**No trates n-3 como un objetivo.** Es margen para emergencias y despliegues escalonados. Una deriva en estado estacionario más allá de n-1 significa que cada respuesta a un CVE del control plane queda condicionada a una flota de nodos que no ejercitás desde hace meses.

---

## 4. Estrategias de Actualización: Comparación de Compromisos

### 4.1 Los cuatro arquetipos

| Dimensión | **Rolling in-place** (`kubeadm upgrade`) | **Reemplazo de nodo inmutable** (surge / rotación de node pool) | **Cluster blue/green** | **Control plane gestionado** (EKS / GKE / AKS) |
|---|---|---|---|---|
| Mecanismo del control plane | Manifiestos de static pods reescritos en disco | Se unen nodos CP nuevos, se retiran los viejos | Se construye un cluster enteramente nuevo | Operado por el proveedor, opaco |
| Mecanismo de nodos | drain → actualizar kubelet → uncordon | Se une un nodo nuevo → drain del viejo → borrar el viejo | N/A (las cargas se redesplegan) | Node groups gestionados por el proveedor |
| Rollback | **Difícil.** `kubeadm` no soporta downgrade; la recuperación = restaurar snapshot de etcd | Fácil — conservá la imagen vieja, hacé roll forward hacia ella | Trivial — devolvés el tráfico | Depende del proveedor; usualmente solo hacia adelante |
| Radio de impacto | Todo el cluster; una mala actualización del CP afecta todo | Por nodo / por pool | Cero en el cluster vivo hasta el cutover | Todo el cluster, pero probado por el proveedor |
| Deriva de configuración | **Alta** — los nodos acumulan estado mutable durante años | **Cero** — los nodos se reconstruyen desde una imagen dorada | Cero | Cero (nodos), n/a (CP) |
| Tiempo para parchear un CVE de kernel/runtime | Lento — requiere orquestación de reinicios aparte | Rápido — horneás una imagen nueva y la rotás | Lento | Rápido (actualización de nodos gestionada) |
| Costo de infraestructura extra | Ninguno | ~1 nodo de surge por pool, transitorio | **2× cluster completo**, transitorio | Tarifa del proveedor |
| ¿Maneja PVs locales / estado afín al nodo? | Sí (se preserva la identidad del nodo) | ❌ Pobre — requiere migración de datos | ❌ Pobre | Pobre |
| Disrupción de cargas stateful | Un drain por nodo | Un drain por nodo | Redespliegue completo + migración de datos | Un drain por nodo |
| Complejidad operativa | Media (runbook bien documentado) | Media-alta (requiere pipeline de imágenes) | Alta (cutover de DNS/ingress/datos) | Baja |
| **Relevancia para el examen CKS** | **★★★ — esto es lo que se evalúa** | ★ | ★ | ★ |
| Mejor encaje | Bare metal, flotas chicas/medianas, examen | Flotas cloud/IaaS, alta cadencia de parcheo | Saltos de versión mayores, cambios de CNI/runtime, cutovers regulados | Equipos que optimizan por headcount |

### 4.2 Guía del arquitecto

* **Control plane: in-place con `kubeadm`.** El control plane es chico (3–5 nodos), etcd es afín al nodo, y `kubeadm upgrade` es el único camino que el proyecto soporta y prueba. Reconstruir nodos del control plane es posible pero agrega rotación de membresía de etcd sin beneficio de seguridad.
* **Workers: reemplazo inmutable.** Ahí está el volumen, ahí aterrizan los CVEs de kernel y runtime, y ahí se acumula la deriva. Reemplazar un nodo es la única forma confiable de garantizar que el kernel, `containerd`, `runc` y el kubelet estén todos en versiones conocidas como buenas al mismo tiempo. Además te da un rollback que el parcheo in-place no puede dar.
* **Blue/green: reservalo para discontinuidades** — un reemplazo de CNI, una migración de cgroup v1→v2, un salto de múltiples minors en un cluster que se cayó del soporte. Es la respuesta correcta cuando el riesgo del camino in-place supera el costo de un segundo cluster.

### 4.3 Dónde vive la superficie de ataque *real*

| Capa | Parcheada por | CVE típico | ¿Independiente de `kubeadm upgrade`? |
|---|---|---|---|
| Kernel del host | Gestor de paquetes del SO + **reinicio** | CVE-2022-0847 (Dirty Pipe) — escritura arbitraria en archivos de solo lectura, escala trivialmente desde un contenedor | ✅ Independiente |
| `runc` | Gestor de paquetes del SO | CVE-2019-5736 (sobrescritura del binario `runc` del host), CVE-2024-21626 (Leaky Vessels, fuga de fd → escape) | ✅ Independiente |
| `containerd` / CRI-O | Gestor de paquetes del SO | CVE-2022-23648 (lectura arbitraria de archivos del host vía volúmenes de imagen) | ✅ Independiente |
| Configuración de cgroups | Kernel + configuración del runtime | CVE-2022-0492 (escape vía `release_agent` de cgroups v1) | ✅ Independiente |
| `kubelet` / `kube-proxy` | `kubeadm` + gestor de paquetes | CVE-2021-25741 (intercambio de symlink en subpath → acceso al FS del host) | ⚠️ Parcialmente — kubeadm actualiza los manifiestos, **vos** actualizás el paquete del kubelet |
| Componentes del control plane | `kubeadm upgrade apply` | CVE-2018-1002105, CVE-2022-3172 | ✅ Cubierto |
| Ingress controller | Su propio chart de Helm / manifiestos | CVE-2025-1974 (IngressNightmare, RCE sin autenticación, CVSS 9.8) | ✅ Independiente |
| Plugins CNI / CSI | Sus propios canales de release | Varía | ✅ Independiente |

**Implicancia de diseño:** necesitás *al menos tres* pipelines de parcheo — cluster (kubeadm), imagen del SO del nodo (kernel + runtime) y addons (Helm/GitOps). Tratarlos como uno solo es la brecha estructural más común en plataformas reales.

---

## 5. Gates Previos a la Actualización: Detectar Qué Se Va a Romper

Una actualización que parchea un CVE y simultáneamente tira abajo la plataforma es una pérdida neta. Condicioná cada actualización minor a las siguientes verificaciones, automatizadas en CI.

### 5.1 APIs eliminadas y deprecadas

Kubernetes garantiza una ventana de deprecación (APIs GA: 12 meses o 3 releases, lo que sea más largo), pero la eliminación *sí* ocurre y rompe `kubectl apply`, controladores y releases de Helm almacenadas en el cluster.

Eliminaciones históricamente significativas:

| Eliminada en | API |
|---|---|
| 1.22 | Ingress `extensions/v1beta1` y `networking.k8s.io/v1beta1`; CRD `apiextensions.k8s.io/v1beta1`; webhooks `admissionregistration.k8s.io/v1beta1` |
| 1.25 | **PodSecurityPolicy** `policy/v1beta1` (reemplazada por Pod Security Admission); CronJob `batch/v1beta1` |
| 1.26 | HPA `autoscaling/v2beta2`; `flowcontrol.apiserver.k8s.io/v1beta1` |
| 1.29 | `flowcontrol.apiserver.k8s.io/v1beta2` |
| 1.32 | `flowcontrol.apiserver.k8s.io/v1beta3` |

Consultá siempre la lista autoritativa para tu objetivo exacto: <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>

**El mejor detector es el propio API server.** `kube-apiserver` expone una métrica que cuenta peticiones *en vivo* a APIs deprecadas, etiquetada con la release en la que serán eliminadas:

```
$ kubectl get --raw /metrics | grep -E '^apiserver_requested_deprecated_apis'
apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.32",resource="flowschemas",subresource="",version="v1beta3"} 1
apiserver_requested_deprecated_apis{group="autoscaling",removed_release="1.32",resource="horizontalpodautoscalers",subresource="",version="v2beta2"} 1
```

Combinala con `apiserver_request_total` para identificar al cliente infractor por `user_agent`:

```promql
sum by (group, version, resource, removed_release, user_agent) (
  increase(apiserver_request_total[7d])
  * on (group, version, resource, subresource) group_left(removed_release)
    apiserver_requested_deprecated_apis
)
```

Esto encuentra los llamadores *en tiempo de ejecución* — incluyendo controladores y jobs de CI — que un escaneo estático de manifiestos no va a detectar.

Complementalo con escaneo estático de tus manifiestos de Git y de las releases de Helm instaladas:

```
$ kubent --cluster --helm3 --target-version 1.34.0
6:12PM INF >>> Kube No Trouble `kubent` <<<
6:12PM INF version 0.7.3 (git sha b2b2b2b)
6:12PM INF Initializing collectors and retrieving data
6:12PM INF Target K8s version is 1.34.0
6:12PM INF Retrieved 412 resources from collector name=Cluster
6:12PM INF Retrieved 37 resources from collector name=Helm v3
__________________________________________________________________________________________
>>> Deprecated APIs removed in 1.32 <<<
------------------------------------------------------------------------------------------
KIND                      NAMESPACE     NAME                 API_VERSION                              REPLACE_WITH (SINCE)
FlowSchema                <undefined>   legacy-tenant-flow   flowcontrol.apiserver.k8s.io/v1beta3     flowcontrol.apiserver.k8s.io/v1 (1.29.0)
HorizontalPodAutoscaler   payments      checkout-hpa         autoscaling/v2beta2                      autoscaling/v2 (1.23.0)
```

Reescribí los manifiestos infractores con `kubectl convert`:

```
$ kubectl convert -f ./deploy/checkout-hpa.yaml --output-version autoscaling/v2 > ./deploy/checkout-hpa.v2.yaml
$ kubectl apply --dry-run=server -f ./deploy/checkout-hpa.v2.yaml
horizontalpodautoscaler.autoscaling/checkout-hpa configured (server dry run)
```

### 5.2 Comparación de herramientas de detección de deprecaciones

| Herramienta | Alcance | Detecta llamadores en runtime | Detecta manifiestos almacenados en Helm | Detecta manifiestos de Git | Apta para CI | Notas |
|---|---|---|---|---|---|---|
| Métrica `apiserver_requested_deprecated_apis` | Cluster vivo | ✅ **Sí** | Indirectamente | ❌ | ✅ | Verdad de campo; solo ve lo que efectivamente se llamó |
| `kubent` (kube-no-trouble) | Cluster + Helm2/3 + archivos | ❌ | ✅ | ✅ | ✅ | El mejor escaneo previo a la actualización de una sola pasada |
| `pluto` (Fairwinds) | Archivos + Helm | ❌ | ✅ | ✅ | ✅ | Fuerte para escaneo de repo/CI; base de deprecaciones versionada |
| `kubectl convert` | Manifiesto individual | ❌ | ❌ | ✅ | ✅ | Remediación, no detección; descarga de plugin aparte |
| Audit log del API server (filtro `v1beta1`) | Cluster vivo | ✅ | ❌ | ❌ | ⚠️ | Máxima fidelidad, máximo volumen |

### 5.3 Feature gates y versiones de compatibilidad (emuladas)

Más allá de la eliminación de APIs, una actualización minor cambia el *comportamiento*: los gates alpha gradúan a beta activados por defecto, los gates beta pasan a GA y los defaults se corren. Enumerá qué cambia antes de actualizar:

```
$ kube-apiserver --help | grep -A2 'feature-gates'
      --feature-gates mapStringBool  A set of key=value pairs that describe feature gates for
                                     alpha/experimental features. Options are:
                                     APIResponseCompression=true|false (BETA - default=true)
                                     ...
```

Kubernetes viene incorporando **versiones de compatibilidad (emuladas)** (KEP-4330) precisamente para desacoplar "correr el binario nuevo" de "adoptar el comportamiento nuevo". Con `--emulated-version`, un binario `kube-apiserver` recién instalado puede presentar la superficie de API y los defaults del minor *anterior*, de modo que podés instalar un binario con el parche de seguridad de inmediato y habilitar el comportamiento nuevo después, como un cambio separado y revertible de forma independiente:

```
# Install the 1.34 binary but keep 1.33 API behaviour, then flip the emulation
# forward once workloads are validated.
--emulated-version=1.33
```

Esta es una postura de seguridad materialmente mejor: **el parcheo de binarios deja de estar acoplado al riesgo de comportamiento.** La madurez del feature gate de esta capacidad varía según la release — confirmá disponibilidad y sintaxis para tu versión exacta contra el KEP y la referencia de componentes (<https://github.com/kubernetes/enhancements/issues/4330>) antes de depender de ella en producción.

### 5.4 Checklist previo a la actualización (condicioná el pipeline a todos estos puntos)

```
[ ] Target patch version confirmed against https://kubernetes.io/releases/patch-releases/
[ ] CHANGELOG "Urgent Upgrade Notes" for the target minor read end to end
[ ] Removed-API scan clean (kubent/pluto + apiserver_requested_deprecated_apis == 0)
[ ] etcd snapshot taken AND restore rehearsed in a scratch cluster
[ ] /etc/kubernetes and /var/lib/kubelet backed up on every control-plane node
[ ] Certificate expiry checked: kubeadm certs check-expiration
[ ] PodDisruptionBudgets audited: no PDB with minAvailable == replicas
[ ] Sufficient scheduling headroom to absorb one drained node
[ ] Addon compatibility verified (CNI, CSI, ingress, metrics-server, cert-manager)
[ ] Upgrade rehearsed on a staging cluster of the same topology
[ ] Container images pre-pulled (kubeadm config images pull) — critical if air-gapped
[ ] Rollback decision tree written and the on-call engineer briefed
```

---

## 6. Verificar Antes de Instalar: Integridad de Cadena de Suministro de los Artefactos de Actualización

Una actualización es el momento en que ejecutás deliberadamente binarios privilegiados nuevos en cada nodo. Es por lo tanto el momento en que más importa la verificación de la cadena de suministro — un binario `kubectl`/`kubelet` comprometido es un implante equivalente a root, entregado por tu propio proceso de cambios.

Kubernetes publica digests SHA-256 para cada binario de release y firma los artefactos de release con **Sigstore/cosign** usando firma keyless (Fulcio/Rekor).

```
$ VERSION=v1.34.1
$ ARCH=linux/amd64
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl"
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl.sha256"
$ echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
kubectl: OK
```

Verificación de firma (más fuerte — prueba *quién* lo construyó, no simplemente que los bytes coinciden con un digest servido desde el mismo origen):

```
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl.sig"
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl.cert"
$ cosign verify-blob kubectl \
    --signature kubectl.sig \
    --certificate kubectl.cert \
    --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
    --certificate-oidc-issuer https://accounts.google.com
Verified OK
```

Las imágenes de contenedor se firman de la misma manera:

```
$ cosign verify registry.k8s.io/kube-apiserver:v1.34.1 \
    --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
    --certificate-oidc-issuer https://accounts.google.com \
  | jq '.[0].optional.Bundle.Payload.body' -r | head -c 80
eyJhcGlWZXJzaW9uIjoiMC4wLjEiLCJraW5kIjoiaGFzaGVkcmVrb3JkIiwic3BlYyI6eyJkYXRh
```

> Los valores de `--certificate-identity` son cuentas de tooling de release y pueden cambiar entre ciclos de release. Tomalos de <https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/> en el momento de la actualización en vez de dejarlos hardcodeados indefinidamente.

Para instalaciones basadas en paquetes, los repositorios comunitarios en `pkgs.k8s.io` están firmados con GPG; la clave de firma debe instalarse como keyring y la línea del repositorio debe quedar anclada a ella con `signed-by=`. Nunca uses una entrada de repositorio sin firmar o con `[trusted=yes]` — eso deshabilita la única verificación de integridad del camino de apt.

---

## 7. El Runbook Completo de Actualización con `kubeadm` (v1.33.4 → v1.34.1)

Topología de referencia: tres nodos de control plane (`cp-1`, `cp-2`, `cp-3`) con etcd apilado (stacked), y nodos worker (`w-1` … `w-n`). Debian/Ubuntu con el repositorio comunitario `pkgs.k8s.io`.

### 7.0 Establecer la línea base

```
$ kubectl get nodes -o wide
NAME   STATUS   ROLES           AGE    VERSION   INTERNAL-IP     OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
cp-1   Ready    control-plane   214d   v1.33.4   10.20.0.11      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
cp-2   Ready    control-plane   214d   v1.33.4   10.20.0.12      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
cp-3   Ready    control-plane   214d   v1.33.4   10.20.0.13      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
w-1    Ready    <none>          214d   v1.33.4   10.20.0.21      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
w-2    Ready    <none>          214d   v1.33.4   10.20.0.22      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4

$ kubectl version
Client Version: v1.33.4
Kustomize Version: v5.6.0
Server Version: v1.34.0
```

Confirmá la salud del control plane *antes* de tocar nada:

```
$ kubectl get --raw='/readyz?verbose' | tail -20
[+]poststarthook/start-kube-apiserver-admission-initializer ok
[+]poststarthook/start-apiextensions-informers ok
[+]poststarthook/start-apiextensions-controllers ok
[+]poststarthook/crd-informer-synced ok
[+]poststarthook/bootstrap-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]poststarthook/priority-and-fairness-config-producer ok
[+]poststarthook/start-cluster-authentication-info-controller ok
[+]shutdown ok
readyz check passed

$ kubectl get pods -n kube-system -o wide | grep -E 'etcd|apiserver|controller|scheduler'
etcd-cp-1                      1/1   Running   3   214d   10.20.0.11   cp-1
etcd-cp-2                      1/1   Running   2   214d   10.20.0.12   cp-2
etcd-cp-3                      1/1   Running   2   214d   10.20.0.13   cp-3
kube-apiserver-cp-1            1/1   Running   3   214d   10.20.0.11   cp-1
kube-apiserver-cp-2            1/1   Running   2   214d   10.20.0.12   cp-2
kube-apiserver-cp-3            1/1   Running   2   214d   10.20.0.13   cp-3
kube-controller-manager-cp-1   1/1   Running   9   214d   10.20.0.11   cp-1
kube-scheduler-cp-1            1/1   Running   8   214d   10.20.0.11   cp-1
```

### 7.1 Respaldar etcd — innegociable

`kubeadm` **no tiene camino de downgrade**. Un snapshot de etcd es tu único rollback ante una actualización fallida del control plane.

```
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/backups/etcd-pre-1.34.1.db
{"level":"info","ts":"2026-03-11T09:04:12.118Z","caller":"snapshot/v3_snapshot.go:65","msg":"created temporary db file","path":"/var/backups/etcd-pre-1.34.1.db.part"}
{"level":"info","ts":"2026-03-11T09:04:12.140Z","caller":"snapshot/v3_snapshot.go:73","msg":"fetching snapshot","endpoint":"https://127.0.0.1:2379"}
{"level":"info","ts":"2026-03-11T09:04:13.902Z","caller":"snapshot/v3_snapshot.go:88","msg":"fetched snapshot","endpoint":"https://127.0.0.1:2379","size":"148 MB","took":"1.783 seconds"}
Snapshot saved at /var/backups/etcd-pre-1.34.1.db

$ sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/backups/etcd-pre-1.34.1.db
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 8f1c2d9a |  9481223 |      14907 |     148 MB |
+----------+----------+------------+------------+
```

Respaldá también la configuración del control plane y la PKI en cada nodo CP:

```
$ sudo tar czf /var/backups/k8s-etc-pre-1.34.1-$(hostname).tgz \
    /etc/kubernetes /var/lib/kubelet/config.yaml
$ sudo ls -lh /var/backups/
-rw-r--r-- 1 root root 148M Mar 11 09:04 etcd-pre-1.34.1.db
-rw-r--r-- 1 root root  84K Mar 11 09:05 k8s-etc-pre-1.34.1-cp-1.tgz
```

Copiá ambos fuera del nodo. Un respaldo que vive únicamente en la máquina que estás por romper no es un respaldo.

### 7.2 Verificar el vencimiento de certificados

`kubeadm upgrade apply` renueva los certificados del control plane por defecto, lo que es un efecto secundario útil — pero los certificados que ya están *vencidos* bloquearán la actualización porque `kubeadm` no puede hablar con el API server.

```
$ sudo kubeadm certs check-expiration
[check-expiration] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...

CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Aug 11, 2026 08:14 UTC   152d            ca                      no
apiserver                  Aug 11, 2026 08:14 UTC   152d            ca                      no
apiserver-etcd-client      Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
apiserver-kubelet-client   Aug 11, 2026 08:14 UTC   152d            ca                      no
controller-manager.conf    Aug 11, 2026 08:14 UTC   152d            ca                      no
etcd-healthcheck-client    Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
etcd-peer                  Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
etcd-server                Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
front-proxy-client         Aug 11, 2026 08:14 UTC   152d            front-proxy-ca          no
scheduler.conf             Aug 11, 2026 08:14 UTC   152d            ca                      no
super-admin.conf           Aug 11, 2026 08:14 UTC   152d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Feb 20, 2035 08:14 UTC   8y              no
etcd-ca                 Feb 20, 2035 08:14 UTC   8y              no
front-proxy-ca          Feb 20, 2035 08:14 UTC   8y              no
```

> **Nota arquitectónica:** el tiempo de vida de un año de los certificados hoja es una *característica*. Significa que un cluster que nunca se actualiza eventualmente deja de funcionar — un chequeo de vitalidad forzado sobre tu proceso de parcheo. Los clusters que se saltean actualizaciones durante 13 meses lo descubren por las malas.

### 7.3 Actualizar `kubeadm` en el primer nodo del control plane

Apuntá el repositorio de paquetes al nuevo minor. Este es el paso que más se olvida — el repo está versionado por minor, así que sin editarlo `apt` solo va a ofrecerte parches de 1.33.

```
$ cat /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /

$ sudo sed -i 's|/core:/stable:/v1\.33/|/core:/stable:/v1.34/|' /etc/apt/sources.list.d/kubernetes.list

$ curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

$ sudo apt-get update
Get:1 https://pkgs.k8s.io/core:/stable:/v1.34/deb  InRelease [1186 B]
Get:2 https://pkgs.k8s.io/core:/stable:/v1.34/deb  Packages [6082 B]
Fetched 7268 B in 1s (7104 B/s)
Reading package lists... Done

$ apt-cache madison kubeadm | head -5
   kubeadm | 1.34.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb  Packages
   kubeadm | 1.34.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb  Packages
```

Instalá exactamente la versión objetivo y volvé a aplicar el hold (el hold evita que un `apt upgrade` no relacionado viole el skew en silencio):

```
$ sudo apt-mark unhold kubeadm
Canceled hold on kubeadm.
$ sudo apt-get install -y kubeadm=1.34.1-1.1
Reading package lists... Done
The following packages will be upgraded:
  kubeadm
1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
Setting up kubeadm (1.34.1-1.1) ...
$ sudo apt-mark hold kubeadm
kubeadm set on hold.

$ kubeadm version
kubeadm version: &version.Info{Major:"1", Minor:"34", GitVersion:"v1.34.1", GitCommit:"3c4e4c9c1b3d5f4b2a1e0d9c8b7a6f5e4d3c2b1a", GitTreeState:"clean", BuildDate:"2026-02-18T10:22:41Z", GoVersion:"go1.24.6", Compiler:"gc", Platform:"linux/amd64"}
```

### 7.4 Planificar la actualización

```
$ sudo kubeadm upgrade plan
[preflight] Running pre-flight checks.
[upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade] Running cluster health checks
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: 1.33.4
[upgrade/versions] kubeadm version: v1.34.1
I0311 09:11:44.882014   18422 version.go:261] remote version is much newer: v1.34.1; falling back to: stable-1.34
[upgrade/versions] Target version: v1.34.1
[upgrade/versions] Latest version in the v1.33 series: v1.33.6

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE   CURRENT   TARGET
kubelet     cp-1   v1.33.4   v1.34.1
kubelet     cp-2   v1.33.4   v1.34.1
kubelet     cp-3   v1.33.4   v1.34.1
kubelet     w-1    v1.33.4   v1.34.1
kubelet     w-2    v1.33.4   v1.34.1

Upgrade to the latest stable version:

COMPONENT                 NODE   CURRENT    TARGET
kube-apiserver            cp-1   v1.33.4    v1.34.1
kube-apiserver            cp-2   v1.33.4    v1.34.1
kube-apiserver            cp-3   v1.33.4    v1.34.1
kube-controller-manager   cp-1   v1.33.4    v1.34.1
kube-controller-manager   cp-2   v1.33.4    v1.34.1
kube-controller-manager   cp-3   v1.33.4    v1.34.1
kube-scheduler            cp-1   v1.33.4    v1.34.1
kube-scheduler            cp-2   v1.33.4    v1.34.1
kube-scheduler            cp-3   v1.33.4    v1.34.1
etcd                      cp-1   3.5.21-0   3.6.4-0
etcd                      cp-2   3.5.21-0   3.6.4-0
etcd                      cp-3   3.5.21-0   3.6.4-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.34.1

_____________________________________________________________________

The table below shows the current state of component configs as understood by this version of kubeadm.
Configs that have a "yes" mark in the "MANUAL UPGRADE REQUIRED" column require manual config upgrade or
resetting to kubeadm defaults before a successful upgrade can be performed. The version to manually
upgrade to is denoted in the "PREFERRED VERSION" column.

API GROUP                 CURRENT VERSION   PREFERRED VERSION   MANUAL UPGRADE REQUIRED
kubeproxy.config.k8s.io   v1alpha1          v1alpha1            no
kubelet.config.k8s.io     v1beta1           v1beta1             no
_____________________________________________________________________
```

Previsualizá los cambios exactos a los manifiestos de static pods antes de confirmar — este es el chequeo de seguridad más subutilizado de todo el runbook:

```
$ sudo kubeadm upgrade diff v1.34.1 --context-lines 3
[upgrade/diff] Reading configuration from the cluster...
--- /etc/kubernetes/manifests/kube-apiserver.yaml
+++ new manifest
@@ -33,7 +33,7 @@
     - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
     - --service-cluster-ip-range=10.96.0.0/12
     - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
-    image: registry.k8s.io/kube-apiserver:v1.33.4
+    image: registry.k8s.io/kube-apiserver:v1.34.1
     imagePullPolicy: IfNotPresent
     livenessProbe:
       failureThreshold: 8
```

Descargá las imágenes por adelantado para que el control plane no quede fuera de línea esperando a un registry (obligatorio en entornos air-gapped):

```
$ sudo kubeadm config images list --kubernetes-version v1.34.1
registry.k8s.io/kube-apiserver:v1.34.1
registry.k8s.io/kube-controller-manager:v1.34.1
registry.k8s.io/kube-scheduler:v1.34.1
registry.k8s.io/kube-proxy:v1.34.1
registry.k8s.io/coredns/coredns:v1.12.1
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.6.4-0

$ sudo kubeadm config images pull --kubernetes-version v1.34.1
[config/images] Pulled registry.k8s.io/kube-apiserver:v1.34.1
[config/images] Pulled registry.k8s.io/kube-controller-manager:v1.34.1
[config/images] Pulled registry.k8s.io/kube-scheduler:v1.34.1
[config/images] Pulled registry.k8s.io/kube-proxy:v1.34.1
[config/images] Pulled registry.k8s.io/coredns/coredns:v1.12.1
[config/images] Pulled registry.k8s.io/pause:3.10
[config/images] Pulled registry.k8s.io/etcd:3.6.4-0
```

### 7.5 Aplicar en el primer nodo del control plane

```
$ sudo kubeadm upgrade apply v1.34.1
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[preflight] Running preflight checks.
[upgrade] Running cluster health checks
[upgrade/version] You have chosen to change the cluster version to "v1.34.1"
[upgrade/versions] Cluster version: v1.33.4
[upgrade/versions] kubeadm version: v1.34.1
[upgrade] Are you sure you want to proceed? [y/N]: y
[upgrade/prepull] Pulling images required for setting up a Kubernetes cluster
[upgrade/prepull] This might take a minute or two, depending on the speed of your internet connection
[upgrade/apply] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1"
[upgrade/etcd] Upgrading to TLS for etcd
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
[upgrade/staticpods] Renewing etcd-peer certificate
[upgrade/staticpods] Renewing etcd-healthcheck-client certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/etcd.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/etcd.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[upgrade/staticpods] This can take up to 5m0s
[apiclient] Found 3 Pods for label selector component=etcd
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/etcd] Waiting for etcd to become available
[upgrade/staticpods] Writing new Static Pod manifests to "/etc/kubernetes/tmp/kubeadm-upgraded-manifests1284917823"
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Renewing apiserver certificate
[upgrade/staticpods] Renewing apiserver-kubelet-client certificate
[upgrade/staticpods] Renewing front-proxy-client certificate
[upgrade/staticpods] Renewing apiserver-etcd-client certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/kube-apiserver.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/kube-apiserver.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[apiclient] Found 3 Pods for label selector component=kube-apiserver
[upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-controller-manager" upgrade
[upgrade/staticpods] Renewing controller-manager.conf certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/kube-controller-manager.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/kube-controller-manager.yaml"
[upgrade/staticpods] Component "kube-controller-manager" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-scheduler" upgrade
[upgrade/staticpods] Renewing scheduler.conf certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/kube-scheduler.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/kube-scheduler.yaml"
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade/postupgrade] Removing the old taint &Taint{Key:node-role.kubernetes.io/control-plane,Value:,Effect:NoSchedule,} from all control plane Nodes
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system with the configuration for the kubelets in the cluster
[bootstrap-token] Configured RBAC rules to allow Node Bootstrap tokens to get nodes
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

[upgrade] SUCCESS! Your cluster was upgraded to "v1.34.1". Enjoy!

[upgrade] Now that your control plane is upgraded, please proceed with upgrading your kubelets if you haven't already done so.
```

Dos detalles que vale la pena internalizar:

* **Los certificados se renovaron automáticamente** (controlalo con `--certificate-renewal=false` si una PKI externa los gestiona).
* **Los manifiestos viejos quedaron respaldados** en `/etc/kubernetes/tmp/kubeadm-backup-manifests-<timestamp>/`. Combinados con el snapshot de etcd, ese es tu kit de recuperación manual.

### 7.6 Configuración declarativa de la actualización (v1beta4)

Las actualizaciones guiadas por flags no son reproducibles. `kubeadm` v1beta4 (disponible desde 1.31 en adelante) introduce un kind `UpgradeConfiguration` para que toda la operación sea un artefacto revisable en Git:

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: UpgradeConfiguration
apply:
  # Target version. Must be exactly one minor above the current cluster version.
  kubernetesVersion: v1.34.1
  # Renew all control-plane certificates as part of the upgrade.
  certificateRenewal: true
  # Upgrade the stacked etcd static pod alongside the control plane.
  etcdUpgrade: true
  # Never force past a failed preflight check in production.
  forceUpgrade: false
  imagePullPolicy: IfNotPresent
  # Pull images one at a time to bound disk/network pressure on the CP node.
  imagePullSerial: true
  printConfig: true
  # Strategic-merge / JSON patches applied to the generated static pod manifests.
  patches:
    directory: /etc/kubernetes/patches
  skipPhases: []
node:
  certificateRenewal: true
  etcdUpgrade: true
  skipPhases: []
  patches:
    directory: /etc/kubernetes/patches
diff:
  contextLines: 5
plan: {}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.1
clusterName: prod-eu-west-1
controlPlaneEndpoint: "k8s-api.internal.example.com:6443"
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.k8s.io
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    # v1beta4: extraArgs is a LIST of name/value pairs, not a map.
    # This is a breaking change from v1beta3 and a common upgrade trap.
    extraArgs:
      - name: auto-compaction-retention
        value: "1h"
      - name: quota-backend-bytes
        value: "8589934592"
apiServer:
  certSANs:
    - k8s-api.internal.example.com
    - 10.20.0.10
  extraArgs:
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: anonymous-auth
      value: "false"
    - name: profiling
      value: "false"
    - name: request-timeout
      value: "60s"
    - name: tls-min-version
      value: "VersionTLS12"
    - name: tls-cipher-suites
      value: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305"
    - name: encryption-provider-config
      value: /etc/kubernetes/enc/encryption-config.yaml
    - name: encryption-provider-config-automatic-reload
      value: "true"
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-logs
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: DirectoryOrCreate
    - name: encryption-config
      hostPath: /etc/kubernetes/enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: profiling
      value: "false"
    - name: terminated-pod-gc-threshold
      value: "500"
    - name: bind-address
      value: "127.0.0.1"
scheduler:
  extraArgs:
    - name: profiling
      value: "false"
    - name: bind-address
      value: "127.0.0.1"
```

Aplicala:

```
$ sudo kubeadm upgrade apply --config /etc/kubernetes/upgrade-config.yaml --yes
```

Migrar hacia adelante un archivo de configuración viejo es una operación de primera clase — hacé esto *antes* de la actualización, en un PR:

```
$ sudo kubeadm config migrate --old-config /etc/kubernetes/kubeadm-v1beta3.yaml \
                              --new-config /etc/kubernetes/kubeadm-v1beta4.yaml
$ sudo kubeadm config validate --config /etc/kubernetes/kubeadm-v1beta4.yaml
ok
```

Confirmá siempre el conjunto de campos que tu build realmente acepta en vez de confiar en un ejemplo copiado:

```
$ kubeadm config print upgrade-defaults
```

### 7.7 Actualizar el kubelet y kubectl en `cp-1`

`kubeadm upgrade apply` actualizó los *static pods*. El kubelet es un proceso del host y lo actualizás vos.

```
$ kubectl drain cp-1 --ignore-daemonsets --delete-emptydir-data --timeout=300s
node/cp-1 cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kube-proxy-7xk2l, kube-system/cilium-jd9wq
evicting pod kube-system/coredns-668d6bf9bc-4h2xq
evicting pod monitoring/prometheus-node-exporter-p8wq2
pod/coredns-668d6bf9bc-4h2xq evicted
node/cp-1 drained

$ sudo apt-mark unhold kubelet kubectl
$ sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
$ sudo apt-mark hold kubelet kubectl

$ sudo systemctl daemon-reload
$ sudo systemctl restart kubelet

$ systemctl is-active kubelet
active

$ kubectl uncordon cp-1
node/cp-1 uncordoned
```

Verificá antes de seguir:

```
$ kubectl get node cp-1 -o jsonpath='{.status.nodeInfo.kubeletVersion}{"\n"}'
v1.34.1
```

### 7.8 Nodos restantes del control plane

En `cp-2` y `cp-3` el comando es `kubeadm upgrade node` — **no** `apply`. `apply` es una operación única, a nivel de cluster, que se realiza solo en el primer nodo del control plane.

```
$ sudo sed -i 's|/core:/stable:/v1\.33/|/core:/stable:/v1.34/|' /etc/apt/sources.list.d/kubernetes.list
$ sudo apt-get update && sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm

$ sudo kubeadm upgrade node
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[preflight] Running pre-flight checks
[preflight] Skipping prepull. Not a control plane node.
[upgrade] Skipping prepull. Not a control plane node.
[upgrade] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1"
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/etcd.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-31-40/etcd.yaml"
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-controller-manager" upgrade
[upgrade/staticpods] Component "kube-controller-manager" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-scheduler" upgrade
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade] The control plane instance for this node was successfully updated!
[upgrade] Reading kubelet configuration from the "kubelet-config" ConfigMap in namespace kube-system...
[upgrade] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade] The configuration for this node was successfully updated!
[upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.
```

Después hacé drain / actualización de kubelet+kubectl / reinicio / uncordon exactamente como en §7.7. **Un nodo del control plane por vez**, confirmando siempre el quórum de etcd antes de continuar:

```
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://10.20.0.11:2379,https://10.20.0.12:2379,https://10.20.0.13:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| https://10.20.0.11:2379   | 3d1a9f0e2b7c4d51 |   3.6.4 |  148 MB |     false |      false |        14 |    9481409 |            9481409 |        |
| https://10.20.0.12:2379   | 8b2c4e6a1f9d3072 |   3.6.4 |  148 MB |      true |      false |        14 |    9481409 |            9481409 |        |
| https://10.20.0.13:2379   | c9f7a3d5e8b16204 |  3.5.21 |  148 MB |     false |      false |        14 |    9481409 |            9481409 |        |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
```

Una columna `ERRORS` vacía y valores idénticos de `RAFT APPLIED INDEX` entre los miembros es la señal de go/no-go.

### 7.9 Nodos worker

```
# From the admin workstation
$ kubectl drain w-1 --ignore-daemonsets --delete-emptydir-data --timeout=600s --grace-period=60
node/w-1 cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/cilium-2kd8x, kube-system/kube-proxy-9wq4t, monitoring/node-exporter-fk2ml
evicting pod payments/checkout-7d9f8c6b54-x2n4k
evicting pod payments/ledger-6b7c8d9e01-p9m3s
error when evicting pods/"ledger-6b7c8d9e01-p9m3s" -n "payments" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod payments/ledger-6b7c8d9e01-p9m3s
pod/checkout-7d9f8c6b54-x2n4k evicted
pod/ledger-6b7c8d9e01-p9m3s evicted
node/w-1 drained

# On the node
$ sudo sed -i 's|/core:/stable:/v1\.33/|/core:/stable:/v1.34/|' /etc/apt/sources.list.d/kubernetes.list
$ sudo apt-get update
$ sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm

$ sudo kubeadm upgrade node
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[preflight] Running pre-flight checks
[preflight] Skipping prepull. Not a control plane node.
[upgrade] Skipping phase. Not a control plane node.
[upgrade] Reading kubelet configuration from the "kubelet-config" ConfigMap in namespace kube-system...
[upgrade] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade] The configuration for this node was successfully updated!
[upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.

$ sudo apt-mark unhold kubelet kubectl
$ sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
$ sudo apt-mark hold kubelet kubectl
$ sudo systemctl daemon-reload && sudo systemctl restart kubelet

# From the admin workstation
$ kubectl uncordon w-1
node/w-1 uncordoned
```

Fijate en la línea `[upgrade] Skipping phase. Not a control plane node.` — en un worker, `kubeadm upgrade node` solo refresca `/var/lib/kubelet/config.yaml` a partir del ConfigMap `kubelet-config` y rota el certificado de cliente del kubelet. **No** instala binarios. Por eso saltearse el paso `apt-get install kubelet` deja al nodo silenciosamente en la versión vieja.

### 7.10 Proteger la disponibilidad durante los drains

Todo drain desaloja pods. Sin `PodDisruptionBudget`s correctos, o te comés una caída o quedás colgado para siempre. Ambos modos de falla son evitables:

```yaml
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ledger-pdb
  namespace: payments
spec:
  # CORRECT: with 5 replicas this permits exactly one voluntary disruption at a
  # time. NEVER set minAvailable equal to the replica count — that makes every
  # drain block forever and turns a routine upgrade into an incident.
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: ledger
  # Do not let Pending/unschedulable pods block eviction of Running ones.
  unhealthyPodEvictionPolicy: AlwaysAllow
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: payments
spec:
  # Percentage form scales with the Deployment; rounds UP for maxUnavailable.
  maxUnavailable: 25%
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  unhealthyPodEvictionPolicy: IfHealthyBudget
```

Auditá el caso patológico antes de cada actualización:

```
$ kubectl get pdb -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,MIN:.spec.minAvailable,MAX:.spec.maxUnavailable,ALLOWED:.status.disruptionsAllowed,EXPECTED:.status.expectedPods
NS         NAME           MIN   MAX     ALLOWED   EXPECTED
payments   ledger-pdb     4     <none>  1         5
payments   checkout-pdb   <none> 25%    2         8
legacy     monolith-pdb   1     <none>  0         1     # <-- WILL BLOCK EVERY DRAIN
```

Cualquier fila con `ALLOWED: 0` es una mina. Arreglala (escalá hacia arriba, o relajá el presupuesto) *antes* de la ventana de actualización — no recurras a `kubectl drain --disable-eviction`, que borra los pods salteándose los PDBs por completo y anula la protección que configuraste.

### 7.11 Verificación posterior a la actualización

```
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,STATUS:.status.conditions[-1].type,KUBELET:.status.nodeInfo.kubeletVersion,PROXY:.status.nodeInfo.kubeProxyVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KERNEL:.status.nodeInfo.kernelVersion
NAME   STATUS   KUBELET   PROXY     RUNTIME               KERNEL
cp-1   Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
cp-2   Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
cp-3   Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
w-1    Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
w-2    Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic

$ kubectl version
Client Version: v1.34.1
Kustomize Version: v5.7.1
Server Version: v1.34.1

$ kubectl get --raw='/livez?verbose' | tail -3
[+]poststarthook/apiservice-openapiv3-controller ok
[+]shutdown ok
livez check passed

$ kubectl get componentstatuses 2>/dev/null || \
  kubectl get pods -n kube-system -l tier=control-plane -o wide
NAME                           READY   STATUS    RESTARTS      AGE   IP           NODE
kube-apiserver-cp-1            1/1     Running   0             18m   10.20.0.11   cp-1
kube-apiserver-cp-2            1/1     Running   0             11m   10.20.0.12   cp-2
kube-apiserver-cp-3            1/1     Running   0             4m    10.20.0.13   cp-3
kube-controller-manager-cp-1   1/1     Running   1 (17m ago)   18m   10.20.0.11   cp-1
kube-scheduler-cp-1            1/1     Running   1 (17m ago)   18m   10.20.0.11   cp-1

$ kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
No resources found

# Prove the fix is actually deployed — verify image digests, not just tags.
$ kubectl get pods -n kube-system -l component=kube-apiserver \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
cp-1	registry.k8s.io/kube-apiserver@sha256:9b1c...e4f7
cp-2	registry.k8s.io/kube-apiserver@sha256:9b1c...e4f7
cp-3	registry.k8s.io/kube-apiserver@sha256:9b1c...e4f7

$ kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep kubernetesVersion
kubernetesVersion: v1.34.1
```

Confirmá que los certificados fueron efectivamente renovados:

```
$ sudo kubeadm certs check-expiration | head -6
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Mar 11, 2027 09:18 UTC   364d            ca                      no
apiserver                  Mar 11, 2027 09:18 UTC   364d            ca                      no
apiserver-etcd-client      Mar 11, 2027 09:18 UTC   364d            ca                      no
apiserver-kubelet-client   Mar 11, 2027 09:18 UTC   364d            ca                      no
```

Corré una prueba de humo que ejercite scheduling, DNS, red de servicios y admission:

```
$ kubectl run upgrade-smoke --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
    --restart=Never --rm -it --command -- \
    /bin/sh -c 'getent hosts kubernetes.default.svc.cluster.local && echo DNS_OK'
10.96.0.1       kubernetes.default.svc.cluster.local
DNS_OK
pod "upgrade-smoke" deleted
```

---

## 8. Verificación Continua: Alertar Sobre la Deriva de Versiones

Una actualización verificada se degrada. Codificá los invariantes como alertas para que la deriva y el EOL los detecte el monitoreo, no un auditor.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubernetes-version-hygiene
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: platform
spec:
  groups:
    - name: kubernetes-upgrade-hygiene
      interval: 5m
      rules:
        # ------------------------------------------------------------------
        # 1. Version skew: any node whose kubelet minor differs from the
        #    control-plane minor. Steady-state target is zero.
        # ------------------------------------------------------------------
        - alert: KubeletVersionSkew
          expr: |
            count by (cluster) (
              count by (cluster, git_version) (
                kubernetes_build_info{job="kubelet"}
              )
            ) > 1
          for: 2h
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Mixed kubelet versions in {{ $labels.cluster }}"
            description: >-
              More than one kubelet git_version is reported. This is expected
              during an upgrade window but must converge. Sustained skew means
              a node was missed by the rollout.
            runbook_url: "https://kubernetes.io/releases/version-skew-policy/"

        # ------------------------------------------------------------------
        # 2. Deprecated API usage — the pre-upgrade blocker. Any non-zero
        #    value means the next minor upgrade will break a client.
        # ------------------------------------------------------------------
        - alert: DeprecatedAPIInUse
          expr: |
            group by (group, version, resource, removed_release) (
              apiserver_requested_deprecated_apis == 1
            )
          for: 30m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Deprecated API {{ $labels.group }}/{{ $labels.version }} {{ $labels.resource }} in use"
            description: >-
              Removed in Kubernetes {{ $labels.removed_release }}. Identify the
              caller by joining apiserver_request_total on user_agent, migrate
              the manifests, and re-verify before upgrading.
            runbook_url: "https://kubernetes.io/docs/reference/using-api/deprecation-guide/"

        # ------------------------------------------------------------------
        # 3. Control-plane certificates approaching expiry. Certificates are
        #    renewed by `kubeadm upgrade apply`; firing this alert means the
        #    cluster has not been upgraded in roughly nine months.
        # ------------------------------------------------------------------
        - alert: ControlPlaneCertificateExpiringSoon
          expr: |
            (apiserver_client_certificate_expiration_seconds_count > 0)
            and on (job)
            histogram_quantile(0.01,
              sum by (job, le) (
                rate(apiserver_client_certificate_expiration_seconds_bucket[10m])
              )
            ) < 60 * 60 * 24 * 45
          for: 1h
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Client certificates expiring within 45 days"
            description: >-
              Run `kubeadm certs check-expiration` on every control-plane node.
              Either upgrade (which renews automatically) or run
              `kubeadm certs renew all` followed by a static-pod restart.
            runbook_url: "https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/"

        # ------------------------------------------------------------------
        # 4. Cluster running an unsupported minor. Maintain the recorded
        #    threshold below as part of the quarterly upgrade ritual.
        # ------------------------------------------------------------------
        - alert: ClusterVersionOutOfSupport
          expr: |
            max by (cluster) (
              label_replace(
                kubernetes_build_info{job="apiserver"},
                "minor_num", "$1", "minor", "([0-9]+).*"
              )
            ) < 0
          for: 24h
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Cluster {{ $labels.cluster }} may be outside the supported window"
            description: >-
              Compare the reported minor against the supported releases list.
              Only three minors receive security patches at any time; outside
              that window there is no remediation path for a new CVE.
            runbook_url: "https://kubernetes.io/releases/"
```

> La expresión de `ClusterVersionOutOfSupport` es un esqueleto de marcador: PromQL no tiene noción de "los minors soportados hoy". En producción, alimentala desde una recording rule o un gauge estático exportado por tu job de vigilancia de CVEs que codifique la tabla de EOL actual, en vez de intentar calcularlo en PromQL.

---

## 9. Diagnóstico de Fallas

### 9.1 Tabla de referencia de modos de falla

| # | Síntoma | Causa raíz | Diagnóstico | Remediación |
|---|---|---|---|---|
| 1 | `kubeadm upgrade plan` → `could not fetch a Kubernetes version from the internet` | Air-gapped / egress bloqueado hacia `dl.k8s.io` | `curl -v https://dl.k8s.io/release/stable.txt` | Pasá la versión explícitamente: `kubeadm upgrade apply v1.34.1`; descargá las imágenes por adelantado |
| 2 | `[preflight] Some fatal errors occurred: ... etcd cluster is not healthy` | Quórum de etcd perdido o un miembro caído | `etcdctl endpoint health --cluster` | Restaurá el quórum *antes* de actualizar. Nunca uses `--force` acá |
| 3 | `error execution phase preflight: [preflight] ... Specified version to upgrade to v1.35.0 is at least one minor version higher` | Se intentó un salto de múltiples minors | `kubectl version`, `kubeadm version` | Actualizá de a un minor por vez: 1.33 → 1.34 → 1.35 |
| 4 | `Unable to connect to the server: x509: certificate has expired or is not yet valid` | Certificados del control plane vencidos (cluster ocioso >12 meses) | `sudo kubeadm certs check-expiration` | `sudo kubeadm certs renew all`, reiniciá los static pods y luego refrescá `admin.conf` |
| 5 | Nodo `NotReady` tras actualizar el kubelet; `journalctl` muestra `failed to run Kubelet: misconfiguration: kubelet cgroup driver: "cgroupfs" is different from docker cgroup driver: "systemd"` | Desajuste del cgroup driver entre kubelet y runtime | `journalctl -u kubelet -n 100 --no-pager` | Poné `cgroupDriver: systemd` en `/var/lib/kubelet/config.yaml` **y** `SystemdCgroup = true` en `/etc/containerd/config.toml`; reiniciá ambos |
| 6 | `kube-apiserver` nunca vuelve; ningún pod visible | Manifiesto de static pod inválido, o imagen ausente | `sudo crictl ps -a \| head`, `sudo crictl logs <id>`, `journalctl -u kubelet -f` | Restaurá desde `/etc/kubernetes/tmp/kubeadm-backup-manifests-*/` |
| 7 | `kubectl drain` se cuelga para siempre, repitiendo `Cannot evict pod as it would violate the pod's disruption budget` | Un PDB con `disruptionsAllowed: 0` | `kubectl get pdb -A` | Escalá la carga hacia arriba o relajá el PDB. `--disable-eviction` es un último recurso que ignora los PDBs |
| 8 | Las cargas fallan tras la actualización con `no matches for kind "X" in version "Y"` | Una API eliminada | `kubectl api-resources`, `kubent` | `kubectl convert`; hacé roll forward de los manifiestos. Revertir el cluster es mucho más caro |
| 9 | Nodo actualizado pero `kubectl get nodes` sigue mostrando la versión vieja | Se corrió `kubeadm upgrade node` pero no se instaló el **paquete** del kubelet, o no se reinició el kubelet | `kubelet --version` en el nodo vs. el objeto Node | `apt-get install kubelet=<ver>` y después `systemctl daemon-reload && systemctl restart kubelet` |
| 10 | `apt-get install kubeadm=1.34.1-1.1` → `Version '1.34.1-1.1' for 'kubeadm' was not found` | El repositorio `pkgs.k8s.io` sigue anclado al minor viejo | `cat /etc/apt/sources.list.d/kubernetes.list` | Actualizá la URL del repo a `v1.34`, reimportá la clave de firma, `apt-get update` |
| 11 | El `kubelet` registra `Unable to register node ... Unauthorized` después de una interrupción larga | El certificado de cliente rotado del kubelet venció mientras el nodo estaba caído | `openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate` | Regenerá el kubeconfig de bootstrap: `kubeadm token create --print-join-command`, o reemití `/etc/kubernetes/kubelet.conf` y reiniciá |
| 12 | CoreDNS en `CrashLoopBackOff` tras la actualización | Incompatibilidad de versión del addon o directiva de plugin obsoleta en el `Corefile` | `kubectl -n kube-system logs -l k8s-app=kube-dns --previous` | Reconciliá el ConfigMap de CoreDNS; `kubeadm` imprime advertencias de migración durante `apply` |
| 13 | Pods atascados en `ContainerCreating` tras la actualización, errores de CNI en los eventos | El plugin CNI no soporta el nuevo minor | `kubectl -n kube-system logs ds/<cni>`; revisá `/etc/cni/net.d` | Actualizá el CNI **antes** del minor de Kubernetes; consultá su matriz de compatibilidad |

### 9.2 Referencia de comandos de diagnóstico

```
# --- kubelet: the single most useful log during any upgrade ---
$ sudo journalctl -u kubelet -f --no-pager
$ sudo journalctl -u kubelet --since "10 min ago" -p err --no-pager

# --- Static pods bypass the API server: inspect them at the CRI layer ---
$ sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
CONTAINER      IMAGE          CREATED         STATE      NAME                      ATTEMPT   POD ID
a1b2c3d4e5f6   9b1c8d7e6f5a   2 minutes ago   Running    kube-apiserver            1         f0e1d2c3b4a5
9f8e7d6c5b4a   1a2b3c4d5e6f   2 minutes ago   Exited     kube-apiserver            0         f0e1d2c3b4a5

$ sudo crictl logs 9f8e7d6c5b4a 2>&1 | tail -30
I0311 09:19:02.114 1 flags.go:64] FLAG: --anonymous-auth="false"
E0311 09:19:02.882 1 run.go:74] "command failed" err="error creating self-signed certificates: open /etc/kubernetes/pki/apiserver.crt: permission denied"

# --- kubelet's own view of static pods and node config ---
$ sudo cat /var/lib/kubelet/config.yaml | grep -E 'cgroupDriver|staticPodPath|rotateCertificates'
cgroupDriver: systemd
staticPodPath: /etc/kubernetes/manifests
rotateCertificates: true

# --- kubeadm's saved state ---
$ sudo ls -1 /etc/kubernetes/tmp/
kubeadm-backup-manifests-2026-03-11-09-18-02
kubeadm-backup-etcd-2026-03-11-09-18-02
kubeadm-upgraded-manifests1284917823

# --- Cluster-recorded config (what kubeadm believes the cluster is) ---
$ kubectl -n kube-system get cm kubeadm-config -o yaml | head -40

# --- Which client is calling a deprecated API? ---
$ kubectl get --raw /metrics \
  | grep 'apiserver_request_total' \
  | grep 'version="v1beta3"' \
  | head -5
```

### 9.3 Recuperar una actualización fallida del control plane

Orden de escalamiento — probá siempre primero lo más barato:

```
# 1. Restore the previous static pod manifests (fastest, no data loss).
$ sudo cp /etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/*.yaml \
          /etc/kubernetes/manifests/
$ sudo systemctl restart kubelet
$ sudo crictl ps | grep kube-apiserver

# 2. If etcd itself is corrupted, restore the snapshot.
#    Stop the control plane on ALL CP nodes first by moving the manifests away.
$ sudo mkdir -p /etc/kubernetes/manifests.disabled
$ sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests.disabled/
$ sudo crictl ps            # confirm the control plane is fully stopped

$ sudo mv /var/lib/etcd /var/lib/etcd.broken
$ sudo ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd-pre-1.34.1.db \
    --name cp-1 \
    --initial-cluster cp-1=https://10.20.0.11:2380,cp-2=https://10.20.0.12:2380,cp-3=https://10.20.0.13:2380 \
    --initial-cluster-token etcd-cluster-prod \
    --initial-advertise-peer-urls https://10.20.0.11:2380 \
    --data-dir /var/lib/etcd
2026-03-11T10:02:19Z	info	snapshot/v3_snapshot.go:260	restoring snapshot	{"path": "/var/backups/etcd-pre-1.34.1.db", "wal-dir": "/var/lib/etcd/member/wal", "data-dir": "/var/lib/etcd", "snap-dir": "/var/lib/etcd/member/snap"}
2026-03-11T10:02:21Z	info	membership/cluster.go:421	added member	{"cluster-id": "7f4e2a1b", "local-member-id": "0", "added-peer-id": "3d1a9f0e2b7c4d51"}
2026-03-11T10:02:21Z	info	snapshot/v3_snapshot.go:287	restored snapshot	{"path": "/var/backups/etcd-pre-1.34.1.db", "data-dir": "/var/lib/etcd"}

# Repeat the restore on cp-2 and cp-3 with their own --name and peer URL,
# from the SAME snapshot file and the SAME --initial-cluster-token.

$ sudo mv /etc/kubernetes/manifests.disabled/*.yaml /etc/kubernetes/manifests/
$ sudo systemctl restart kubelet
```

> **`kubeadm` no tiene comando de downgrade.** Si los binarios nuevos escribieron datos incompatibles en etcd, restaurar el snapshot es el *único* camino de vuelta. Precisamente por eso §7.1 es innegociable y por eso la restauración debe ensayarse, no solo documentarse.

---

## 10. SO del Nodo, Runtime y Kernel: La Actualización Que Kubernetes No Hace

`kubeadm upgrade` nunca toca el kernel, `containerd` ni `runc`. Varios de los CVEs de seguridad de contenedores de mayor impacto viven exactamente ahí.

```
# Current runtime and kernel posture
$ containerd --version
containerd github.com/containerd/containerd/v2 v2.0.4 sha:af0d0e8...
$ runc --version
runc version 1.2.5
spec: 1.2.0
go: go1.23.6
libseccomp: 2.5.5
$ uname -r
6.8.0-52-generic

# Is a reboot pending after kernel patching? (Debian/Ubuntu)
$ test -f /var/run/reboot-required && cat /var/run/reboot-required
*** System restart required ***

# Patch runtime + kernel on a drained node
$ kubectl drain w-1 --ignore-daemonsets --delete-emptydir-data --timeout=600s
$ sudo apt-get update && sudo apt-get install -y containerd.io runc linux-image-generic
$ sudo systemctl restart containerd
$ sudo reboot
# after the node returns:
$ kubectl uncordon w-1
```

A nivel de flota, **no** orquestes esto a mano. Dos patrones viables:

| Patrón | Mecanismo | Ventajas | Desventajas |
|---|---|---|---|
| **Coordinador de reinicios** (p. ej. Kured) | Un DaemonSet vigila `/var/run/reboot-required`, toma un lock a nivel de cluster, hace cordon + drain + reboot de un nodo por vez | Funciona con nodos mutables; no requiere pipeline de imágenes | Los nodos siguen siendo mutables; la deriva persiste; el lock de reinicio es un punto único de serialización |
| **Rotación de imagen inmutable** | Horneás una imagen de nodo nueva con kernel/runtime/kubelet parcheados; rotás el node pool; borrás los nodos viejos | Elimina la deriva; rollback atómico revirtiendo la imagen; un solo mecanismo parchea kernel + runtime + kubelet a la vez | Requiere un pipeline de build de imágenes; mal encaje para estado local afín al nodo |

Para cualquier flota de más de unas pocas decenas de nodos, la rotación inmutable es la arquitectura correcta. Colapsa tres pipelines de parcheo en uno y te da el rollback que el parcheo in-place estructuralmente no puede dar.

---

## 11. Notas para el Examen CKS

El examen te da un cluster y una versión objetivo y espera la actualización completada correcta y rápidamente. Puntos de alto rendimiento:

1. **Leé la tarea con atención para determinar el alcance.** "Actualizar solo el nodo del control plane" significa que *no* debés actualizar los workers — y viceversa. Las tareas de alcance parcial son comunes.
2. **`apply` vs `node`.** `kubeadm upgrade apply <version>` solo en el primer nodo del control plane. `kubeadm upgrade node` en todos los demás nodos (control plane y worker).
3. **`ssh` y `sudo`.** La mayor parte del trabajo de actualización pasa en el nodo, no en el jump host. Acordate de `sudo -i` y de hacer `exit` para volver antes de correr comandos `kubectl` contra el cluster.
4. **El baile de tres partes por nodo:** `drain` → `kubeadm upgrade node` + instalar los paquetes `kubelet`/`kubectl` + `systemctl daemon-reload && systemctl restart kubelet` → `uncordon`. Olvidarse del `uncordon` pierde puntos aun cuando la versión sea correcta.
5. **La URL del repositorio debe cambiarse para una actualización minor.** Si `apt-cache madison kubeadm` no lista la versión objetivo, esta es la razón.
6. **`--ignore-daemonsets` casi siempre es necesario** para `kubectl drain`; `--delete-emptydir-data` también suele serlo.
7. **No actualices addons salvo que te lo pidan.** `kubeadm upgrade apply` se ocupa de CoreDNS y kube-proxy; si la tarea dice saltearlos, usá `--skip-phases=addon/coredns,addon/kube-proxy`.
8. **Verificá con `kubectl get nodes`** al final. La columna `VERSION` refleja el kubelet, así que solo cambia después de instalar el paquete del kubelet *y* reiniciar el servicio.

Secuencia mínima de comandos para tener en la memoria muscular:

```
# control plane
sudo -i
sed -i 's|v1.33|v1.34|' /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y --allow-change-held-packages kubeadm=1.34.1-1.1
kubeadm upgrade plan
kubeadm upgrade apply v1.34.1 -y
exit
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
sudo -i
apt-get install -y --allow-change-held-packages kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
systemctl daemon-reload && systemctl restart kubelet
exit
kubectl uncordon <node>

# every other node
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh <node>
sudo -i
sed -i 's|v1.33|v1.34|' /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y --allow-change-held-packages kubeadm=1.34.1-1.1
kubeadm upgrade node
apt-get install -y --allow-change-held-packages kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
systemctl daemon-reload && systemctl restart kubelet
exit; exit
kubectl uncordon <node>
```

---

## 12. Resumen Arquitectónico

* **El control plane es parte de tu TCB.** Un `kube-apiserver` desactualizado invalida todos los demás controles de hardening que configuraste.
* **Actualizar es necesario pero no suficiente.** Los problemas de nivel de diseño (CVE-2020-8554), los componentes del ecosistema (`ingress-nginx`, CVE-2025-1974) y la capa de runtime/kernel (`runc` CVE-2024-21626) necesitan sus propios controles y sus propios pipelines de parcheo.
* **La ventana de soporte de 14 meses y la cadencia de tres releases por año son restricciones arquitectónicas, no sugerencias de calendario.** Presupuestá una actualización minor por trimestre, de forma permanente.
* **La version skew policy es lo que hace posibles las actualizaciones rolling.** Control plane primero, de arriba hacia abajo; la ventana n-3 del kubelet es margen de emergencia, no un objetivo.
* **Condicioná cada actualización minor** a un escaneo de APIs eliminadas, a la sanidad de los `PodDisruptionBudget`, a una restauración de etcd *ensayada* y a una corrida en staging con la misma topología.
* **Verificá los artefactos antes de instalarlos.** Una actualización es un despliegue masivo de binarios privilegiados; SHA-256 más verificación con cosign cuesta segundos.
* **`kubeadm` no puede hacer downgrade.** El snapshot de etcd es el rollback. Tomalo, copialo fuera del nodo y practicá restaurarlo.
* **Medí el P95 del tiempo hasta el parche.** Es la única métrica que captura si este control realmente funciona.

---

## Referencias

**Ingeniería de releases y política de soporte**
- Kubernetes Releases and supported versions — <https://kubernetes.io/releases/>
- Patch release cadence and schedule — <https://kubernetes.io/releases/patch-releases/>
- Version Skew Policy — <https://kubernetes.io/releases/version-skew-policy/>
- Release history and CHANGELOGs — <https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/README.md>
- SIG Release patch release documentation — <https://github.com/kubernetes/sig-release/blob/master/releases/patch-releases.md>

**Seguridad e ingesta de vulnerabilidades**
- Official Kubernetes CVE feed — <https://kubernetes.io/docs/reference/issues-security/official-cve-feed/>
- Machine-readable CVE feed (JSON) — <https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json>
- Kubernetes security and disclosure information — <https://kubernetes.io/docs/reference/issues-security/security/>
- Security Response Committee — <https://github.com/kubernetes/committee-security-response>
- `kubernetes-security-announce` mailing list — <https://groups.google.com/g/kubernetes-security-announce>

**Procedimientos de actualización**
- Upgrading kubeadm clusters — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>
- Upgrading Linux nodes — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/>
- `kubeadm upgrade` command reference — <https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-upgrade/>
- Reconfiguring a kubeadm cluster — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/>
- kubeadm configuration API (v1beta4) — <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>
- Certificate management with kubeadm — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/>
- Operating etcd clusters for Kubernetes — <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- etcd upgrade documentation — <https://etcd.io/docs/v3.5/upgrades/>

**Compatibilidad y deprecación**
- Deprecated API migration guide — <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>
- Kubernetes deprecation policy — <https://kubernetes.io/docs/reference/using-api/deprecation-policy/>
- Feature gates — <https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/>
- KEP-4330: Compatibility Versions — <https://github.com/kubernetes/enhancements/issues/4330>
- kube-no-trouble (`kubent`) — <https://github.com/doitintl/kube-no-trouble>
- Pluto — <https://github.com/FairwindsOps/pluto>

**Disponibilidad durante las actualizaciones**
- Safely drain a node — <https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/>
- Specifying a Disruption Budget — <https://kubernetes.io/docs/tasks/run-application/configure-pdb/>
- Disruptions concept — <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/>

**Cadena de suministro**
- Verify signed Kubernetes artifacts — <https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/>
- Community package repositories (`pkgs.k8s.io`) — <https://kubernetes.io/blog/2023/08/15/pkgs-k8s-io-introduction/>
- Installing kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
- Sigstore cosign — <https://docs.sigstore.dev/cosign/signing/overview/>

**Certificación**
- CKS Curriculum v1.34 — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
- CNCF curriculum repository — <https://github.com/cncf/curriculum>