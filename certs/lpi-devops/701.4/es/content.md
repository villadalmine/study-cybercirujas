# 701.4 Integración Continua y Entrega Continua

**LPI DevOps Tools Engineer — Examen 701-100, versión 2.0.0 · Peso: 5**

---

## 1. El problema arquitectónico: deuda de integración y el cuello de botella del release

Antes de que existiera la integración automatizada, los equipos trabajaban en ramas de larga vida y hacían merge "cuando la funcionalidad estaba terminada". El costo de ese modelo no es el merge en sí — es la *integral de divergencia*. Cada hora que una rama vive sin ser reconciliada contra `main`, crece la probabilidad de que algún otro cambio haya invalidado una suposición, y con ella crece el costo de descubrirlo. Dos desarrolladores tocando el mismo módulo durante tres semanas producen un merge cuya superficie de conflicto es cuadrática en el número de ediciones, y cuyos conflictos *semánticos* (el código mergea limpio y aun así está mal) son invisibles para `git`.

Esto es **deuda de integración**. La Integración Continua no es "un servidor de build". Es la disciplina operativa de pagar esa deuda continuamente, mergeando el trabajo de cada desarrollador a la línea principal al menos una vez por día y demostrando, mecánicamente, que la línea principal sigue funcionando.

El segundo cuello de botella es el release. Un equipo que integra continuamente pero publica trimestralmente sigue agrupando riesgo en lotes: cada release lleva cientos de cambios, así que cuando se consume el presupuesto de error, el *tiempo medio para identificar* qué cambio lo causó es proporcional al tamaño del lote. Por eso el programa de investigación DORA mide **frecuencia de despliegue** y **tasa de fallos de cambio** juntas — no son independientes. Lotes pequeños desplegados seguido tienen una tasa de fallos de cambio menor que lotes grandes desplegados rara vez, porque el radio de impacto de cualquier cambio individual es menor y el rollback no es ambiguo.

Los síntomas en producción que te van a pedir diagnosticar:

| Síntoma en producción | Causa raíz en el sistema de entrega |
|---|---|
| "Funciona en mi máquina", falla en CI | El build no es hermético: depende del toolchain del host, del `~/.m2` ambiente, o del estado de la red |
| La noche del release toma 6 horas y necesita tres personas | El despliegue no está automatizado; el runbook vive en un wiki, no en código |
| Rollback significa "restaurar el backup de la base de datos" | La estrategia de despliegue no tiene una versión anterior inmutable a la cual volver |
| Nadie sabe qué commit está en producción | Sin identidad de artefacto: imágenes etiquetadas `latest`, sin metadatos de procedencia |
| Un test flaky se silencia "temporalmente" y nunca se rehabilita | El pipeline no es confiable, así que su señal se descarta — el peor modo de falla de CI |
| Un hotfix se saltea el pipeline "porque es urgente" | El pipeline es demasiado lento; la velocidad *es* una propiedad de confiabilidad |

Los dos últimos son los que más importan. Un pipeline en el que nadie confía, o que es lo bastante lento como para que valga la pena saltearlo, es peor que no tener pipeline: provee la apariencia de verificación mientras la verificación real es una persona decidiendo omitirla.

### 1.1 Los tres términos, con precisión

Los objetivos del examen distinguen tres conceptos que la industria confunde rutinariamente:

| Término | Definición | Termina en | ¿Compuerta humana? |
|---|---|---|---|
| **Integración Continua** | Cada cambio se mergea a la línea principal con frecuencia y se construye y prueba automáticamente | Un artefacto de build verificado | Sin compuerta — el build pasa, o la línea principal está rota y arreglarla es la máxima prioridad |
| **Entrega Continua** | Cada cambio que pasa CI se promueve automáticamente a través de los entornos y está *siempre en estado desplegable* | Un release candidate en forma lista para producción | **Sí** — una persona decide *cuándo* apretar el botón |
| **Despliegue Continuo** | Cada cambio que pasa el pipeline completo va a producción automáticamente | Producción | **No** — el pipeline es la única compuerta |

La distinción entre los dos últimos es exactamente una cosa: si existe un paso de aprobación humana entre "probado bueno" y "sirviendo tráfico". Todo lo demás — el pipeline, los tests, los artefactos, la automatización del despliegue — es idéntico. Esto significa que **el Despliegue Continuo es una decisión de política por encima de la Entrega Continua, no una arquitectura distinta**. Las organizaciones que no pueden hacer despliegue continuo generalmente no pueden por requisitos regulatorios de control de cambios, no por razones técnicas.

Un cuarto término que vas a encontrar en sistemas reales, no en los objetivos: **Progressive Delivery** — despliegue continuo donde el release es *gradual y evaluado automáticamente* (canary con análisis de métricas, feature flags). Cubierto en §9.

---

## 2. Anatomía de un pipeline

Un pipeline es un grafo acíclico dirigido de etapas, donde cada etapa consume los artefactos de sus predecesoras y o bien los promueve o hace fallar la corrida. La forma canónica:

```
 commit ──▶ [ build ] ──▶ [ unit test ] ──▶ [ static analysis ] ──▶ [ package ]
                                                                        │
                                                                        ▼
                                                             [ artifact repository ]
                                                                        │
              ┌─────────────────────────────────────────────────────────┤
              ▼                            ▼                            ▼
      [ deploy: dev ]            [ integration test ]           [ security scan ]
              │                            │                            │
              └──────────────┬─────────────┴────────────────────────────┘
                             ▼
                     [ deploy: staging ] ──▶ [ acceptance / perf test ]
                             │
                             ▼
                    ( approval gate )  ──▶  [ deploy: production ] ──▶ [ verify / rollback ]
```

Tres invariantes arquitectónicas hacen que esto funcione, y violar cualquiera de ellas es la causa raíz habitual cuando un pipeline "pasa pero producción se rompe":

**Invariante 1 — Construir una vez, promover el binario.** El artefacto que se prueba en staging debe ser bit a bit el artefacto desplegado a producción. Si el pipeline reconstruye por entorno, staging verificó un artefacto *distinto* del que enviaste. Las diferencias de entorno pertenecen a la configuración inyectada en tiempo de despliegue (ConfigMaps, Secrets, variables de entorno), nunca al build.

**Invariante 2 — La definición del pipeline está versionada junto con el código.** `Jenkinsfile`, `.gitlab-ci.yml`, `.github/workflows/*.yml` viven en el repositorio. Un pipeline configurado a través de una UI web no se puede revisar, no se puede revertir, y no puede diferir por rama — lo que significa que no podés cambiar el proceso de build en una rama de feature sin romperlo para todos los demás.

**Invariante 3 — Fallar rápido, ordenado por costo.** Las etapas se ordenan por (probabilidad de atrapar un defecto) ÷ (segundos gastados). La compilación y el linting corren antes que los tests unitarios; los unitarios antes que los de integración; integración antes que end-to-end. Una suite end-to-end de 40 minutos que corre antes de un linter de 4 segundos desperdicia 40 minutos en cada typo.

### 2.1 La pirámide de tests como problema de planificación del pipeline

| Capa | Alcance | Cantidad típica | Presupuesto de tiempo | Dónde en el pipeline |
|---|---|---|---|---|
| Análisis estático / lint | Un solo archivo | — | < 30 s | Hook pre-commit + primera etapa de CI |
| Unitario | Una clase/función, sin I/O | 10³–10⁴ | < 3 min en total, paralelizado | Etapa 2, bloquea todo |
| Integración | Componente + dependencia real (DB, broker) | 10²–10³ | < 15 min | Después del empaquetado, contra dependencias efímeras |
| Contrato | Compatibilidad productor/consumidor de la API | 10¹–10² | < 5 min | Antes de desplegar cualquiera de los dos lados |
| End-to-end / aceptación | Todo el sistema a través de la UI o la API pública | 10¹ | < 30 min | Solo staging |
| Rendimiento / soak | Todo el sistema bajo carga | 1–5 escenarios | Horas | Nocturno o pre-release, no por commit |

La lectura SRE de esta tabla: **la pirámide es un presupuesto de latencia, no una jerarquía de calidad.** Una pirámide invertida (muchos tests E2E, pocos unitarios) produce un pipeline con un ciclo de feedback de 90 minutos y una tasa de flakes alta, y el equipo responde racionalmente ignorándolo.

### 2.2 Desarrollo basado en trunk vs. ramas de larga vida

| Propiedad | Trunk-based (+ ramas de vida corta) | GitFlow / ramas de release de larga vida |
|---|---|---|
| Vida de la rama | Horas a 2 días | Semanas a meses |
| Costo del conflicto de merge | Bajo, lineal | Alto, superlineal |
| Significado de CI | La línea principal siempre es publicable | "develop" es publicable; `main` va atrás |
| Funcionalidades incompletas | Ocultas detrás de feature flags | Retenidas en la rama |
| Granularidad de rollback | Un commit | Un release |
| ¿Encaja con CD? | Sí, nativamente | Solo con un pipeline de rama de release; el despliegue continuo es imposible |
| Costo | Requiere feature flags y disciplina | Requiere arqueología de cherry-pick para los hotfixes |

La Integración Continua en su definición estricta (mergear a la línea principal al menos una vez por día) es **incompatible** con ramas de feature de larga vida. Si tus ramas viven tres semanas, tenés builds automatizados — algo útil — pero no tenés CI.

---

## 3. Repositorios de artefactos

Un repositorio de artefactos es la frontera entre "código" y "cosa que se ejecuta". Su trabajo es cuádruple:

1. **Identidad inmutable.** Una vez que `com.example:checkout:1.4.2` se publica, sus bytes nunca cambian. Eso es lo que hace de "probar en staging, enviar a producción" una oración con sentido.
2. **Proxy y caché de dependencias.** Los builds no deben depender de la disponibilidad de Maven Central, npmjs.com o Docker Hub. Un repositorio remote-proxy convierte una caída de un tercero de una caída del build en un acierto de caché, y te protege de los límites de tasa.
3. **Promoción.** Los artefactos se mueven entre repositorios (`snapshots` → `staging` → `releases`) a medida que acumulan evidencia. La promoción es una operación de metadatos, no una reconstrucción.
4. **Procedencia y retención.** Quién lo construyó, desde qué commit, con qué dependencias (SBOM), y cuándo se recolecta como basura.

| Aspecto | Sonatype Nexus Repository | JFrog Artifactory | Registro OCI (Harbor / Quay / ECR) | Nativo del lenguaje (Maven Central, npmjs) |
|---|---|---|---|---|
| Cobertura de formatos | Maven, npm, PyPI, NuGet, Docker, raw, apt/yum | Igual, más Go, Conan, Helm, Debian, genérico | Solo artefactos OCI (imágenes, charts de Helm, SBOMs, WASM) | Un formato |
| Modelo de despliegue | Self-hosted (OSS + Pro) | Self-hosted o SaaS | Self-hosted o gestionado en la nube | SaaS, público |
| Alta disponibilidad | Edición Pro | Edición Enterprise | Nativa (stateless + almacenamiento de objetos) | N/A |
| Modelo de promoción | Movimiento de repositorio / plugin de staging | API de promoción de build, propiedades | Copia de tag o replicación de registro | Ninguno |
| Escaneo de vulnerabilidades | IQ Server (producto aparte) | Xray (producto aparte) | Trivy/Clair integrados en Harbor | Ninguno |
| Metadatos/procedencia | Limitados | Build-info (rico) | Referrers OCI, atestaciones de cosign | Ninguno |
| Mejor para | Tiendas Java/poliglota, sensibles al costo | Grandes empresas, necesidades pesadas de metadatos | Plataformas container-native | Publicar open source |

### 3.1 Semántica de snapshot vs. release

En términos de Maven — y el concepto generaliza — una versión **SNAPSHOT** (`1.4.3-SNAPSHOT`) es mutable: cada build de CI la sobrescribe, y los consumidores resuelven la más nueva. Una versión **release** (`1.4.2`) es inmutable y debe rechazarse si se redespliega. Los gestores de repositorios lo imponen con una política de despliegue:

| Repositorio | Política de versión | Política de despliegue | Propósito |
|---|---|---|---|
| `maven-snapshots` | Snapshot | Permitir redespliegue | Feedback de CI entre equipos, recolectado agresivamente |
| `maven-releases` | Release | **Deshabilitar redespliegue** | Inmutable, retenido indefinidamente |
| `maven-central-proxy` | Mixta | Proxy de solo lectura | Caché + aislamiento ante caídas |
| `maven-public` (grupo) | — | — | URL única a la que apuntan los clientes; unión ordenada de las anteriores |

El antipatrón equivalente en el mundo de los contenedores es el tag `latest`, que es un puntero mutable. **Desplegá por digest, no por tag**, en cualquier cosa que deba ser reproducible:

```
$ crane digest ghcr.io/example/checkout:1.4.2
sha256:6c1e6ba8d2f2c8f0f5e4d1a9bd3c7b21b0f5a4d8e3c2b1a09f8e7d6c5b4a3921

$ kubectl -n prod set image deploy/checkout \
    checkout=ghcr.io/example/checkout@sha256:6c1e6ba8d2f2c8f0f5e4d1a9bd3c7b21b0f5a4d8e3c2b1a09f8e7d6c5b4a3921
deployment.apps/checkout image updated
```

### 3.2 Configuración del repositorio Nexus como código

Nexus expone una API de scripting en Groovy (y, en versiones recientes, una API REST) para que la topología de repositorios no se cree a fuerza de clics:

```groovy
// provision-repos.groovy — executed via the Nexus scripting API
import org.sonatype.nexus.blobstore.api.BlobStoreManager

repository.createMavenProxy(
        'maven-central-proxy',
        'https://repo1.maven.org/maven2/',
        BlobStoreManager.DEFAULT_BLOBSTORE_NAME,
        true)

repository.createMavenHosted(
        'maven-releases',
        BlobStoreManager.DEFAULT_BLOBSTORE_NAME,
        true,
        org.sonatype.nexus.repository.maven.VersionPolicy.RELEASE,
        org.sonatype.nexus.repository.storage.WritePolicy.ALLOW_ONCE,
        org.sonatype.nexus.repository.maven.LayoutPolicy.STRICT)

repository.createMavenHosted(
        'maven-snapshots',
        BlobStoreManager.DEFAULT_BLOBSTORE_NAME,
        true,
        org.sonatype.nexus.repository.maven.VersionPolicy.SNAPSHOT,
        org.sonatype.nexus.repository.storage.WritePolicy.ALLOW,
        org.sonatype.nexus.repository.maven.LayoutPolicy.STRICT)

repository.createMavenGroup(
        'maven-public',
        ['maven-releases', 'maven-snapshots', 'maven-central-proxy'],
        BlobStoreManager.DEFAULT_BLOBSTORE_NAME)
```

`WritePolicy.ALLOW_ONCE` es la invariante que hace inmutables a los releases. Prestá atención al orden de los miembros del grupo: los repositorios hosted se buscan antes que el proxy, así que un artefacto publicado localmente siempre le gana a uno upstream con las mismas coordenadas — la defensa contra los ataques de dependency confusion.

Del lado del cliente, el build debe apuntar a la URL del grupo y a nada más, de modo que ningún build llegue nunca directamente a la internet pública:

```xml
<!-- ~/.m2/settings.xml, mounted into the CI agent -->
<settings>
  <mirrors>
    <mirror>
      <id>nexus</id>
      <mirrorOf>*</mirrorOf>
      <url>https://nexus.example.com/repository/maven-public/</url>
    </mirror>
  </mirrors>
  <servers>
    <server>
      <id>nexus-releases</id>
      <username>${env.NEXUS_USER}</username>
      <password>${env.NEXUS_PASSWORD}</password>
    </server>
  </servers>
</settings>
```

Verificación de que el mirror se está usando realmente — un chequeo que vale la pena poner en el pipeline, porque un mirror mal configurado falla en abierto:

```
$ mvn -B -s /etc/maven/settings.xml dependency:resolve 2>&1 | grep -c 'repo1.maven.org'
0
$ mvn -B -s /etc/maven/settings.xml dependency:resolve 2>&1 | grep -m1 'Downloaded from'
Downloaded from nexus: https://nexus.example.com/repository/maven-public/org/slf4j/slf4j-api/2.0.13/slf4j-api-2.0.13.jar (68 kB at 2.1 MB/s)
```

---

## 4. Arquitectura de Jenkins

Jenkins es la implementación de referencia alrededor de la cual está construido el examen. Entender su arquitectura importa más que memorizar rutas de menú.

### 4.1 Controlador y agentes

```
                     ┌────────────────────────────────────────────┐
                     │            Jenkins controller              │
                     │                                            │
   HTTP :8080 ───────┤  • Web UI + REST API + CLI endpoint        │
                     │  • Job configuration, build queue          │
   Inbound :50000 ───┤  • Pipeline execution engine (CPS)         │
   (JNLP/TCP)        │  • Plugin runtime, credentials store       │
                     │  • JENKINS_HOME  ← the only stateful part  │
                     └──────────┬──────────────┬──────────────────┘
                                │              │
             outbound SSH ──────┘              └────── inbound (agent connects)
                     │                                     │
          ┌──────────▼─────────┐                ┌──────────▼──────────┐
          │ static agent (VM)  │                │ ephemeral agent      │
          │ remoting.jar       │                │ (Kubernetes pod)     │
          │ 4 executors        │                │ 1 executor, dies     │
          │ labels: linux maven│                │ after the build      │
          └────────────────────┘                └──────────────────────┘
```

Propiedades clave:

- **`JENKINS_HOME` es todo el estado.** Configuraciones de jobs, historial de builds, plugins, credenciales, claves de secretos. Hacer backup de Jenkins significa hacer backup de este directorio (menos `workspace/` y `caches/`). Perder `$JENKINS_HOME/secrets/master.key` y `hudson.util.Secret` hace irrecuperable toda credencial almacenada.
- **El controlador no debe construir.** Configurá `numExecutors: 0`. Un build corriendo en el controlador tiene acceso al sistema de archivos de `JENKINS_HOME`, es decir, a cada credencial que Jenkins guarda. Esta es la falla de seguridad de Jenkins más común de todas.
- **Dos direcciones de conexión.** *Saliente*: el controlador entra por SSH al agente y lanza `remoting.jar` (`SSHLauncher`). *Entrante* (antes "JNLP"): el agente inicia la conexión hacia el puerto TCP del controlador (por defecto 50000) — requerido cuando los agentes están detrás de NAT o son pods efímeros.
- **Los executors** son la unidad de concurrencia. Un executor corre un build a la vez. Capacidad del agente = cantidad de executors, no cantidad de CPU; sobreaprovisionar executors convierte una cola de builds en una máquina de thrashing.
- **Los labels** son la forma en que un pipeline solicita una capacidad (`agent { label 'linux && docker' }`). Las expresiones de label soportan `&&`, `||`, `!`.

### 4.2 Agentes estáticos vs. agentes efímeros

| Propiedad | Agentes en VM estática | Agentes basados en Docker | Agentes pod de Kubernetes |
|---|---|---|---|
| Aislamiento del build | Ninguno — el estado se filtra entre builds | Por contenedor | Por pod, más aislamiento de namespace/RBAC |
| Deriva del toolchain | Alta: alguien hace `apt install` de algo | Ninguna: la imagen es el toolchain | Ninguna |
| Latencia de arranque | Cero (siempre encendido) | ~2–5 s | ~10–40 s (descarga de imagen, scheduling) |
| Costo en reposo | Completo | Bajo | Cero |
| Escalado | Manual | Limitado al host | Autoscaler del clúster |
| Caché | Trivialmente caliente | Montajes de volumen | PVC o caché remota (requiere diseño) |
| Mejor para | Herramientas licenciadas, hardware especializado | Instalaciones de un solo host | Cualquier cosa a escala |

El patrón dominante en producción son los agentes pod de Kubernetes: cada build obtiene un pod fresco cuyos contenedores *son* el toolchain declarado, y que se destruye después. La deriva del toolchain — la causa número uno de "ayer compilaba" — se vuelve estructuralmente imposible.

### 4.3 Jenkins en Kubernetes: manifiestos completos

`StatefulSet` del controlador más el RBAC que el plugin de Kubernetes necesita para crear pods de agente:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins
---
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins-agents
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agent-manager
  namespace: jenkins-agents
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["pods/log", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agent-manager
  namespace: jenkins-agents
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-agent-manager
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: jenkins
---
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: jenkins
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: jenkins
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: jenkins-agent
  namespace: jenkins
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: jenkins
  ports:
    - name: inbound
      port: 50000
      targetPort: 50000
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: jenkins
  namespace: jenkins
spec:
  serviceName: jenkins
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: jenkins
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jenkins
    spec:
      serviceAccountName: jenkins
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      initContainers:
        - name: install-plugins
          image: "jenkins/jenkins:2.492.1-lts-jdk21"
          command: ["jenkins-plugin-cli"]
          args:
            - "--plugin-file"
            - "/var/jenkins_config/plugins.txt"
            - "--verbose"
          env:
            - name: JENKINS_UC
              value: "https://updates.jenkins.io"
            - name: PLUGIN_DIR
              value: "/var/jenkins_plugins"
          volumeMounts:
            - name: plugin-dir
              mountPath: /var/jenkins_plugins
            - name: jenkins-config
              mountPath: /var/jenkins_config
      containers:
        - name: jenkins
          image: "jenkins/jenkins:2.492.1-lts-jdk21"
          env:
            - name: JAVA_OPTS
              value: "-Djenkins.install.runSetupWizard=false -Dhudson.model.DirectoryBrowserSupport.CSP=\"sandbox; default-src 'self'\" -XX:+UseG1GC -XX:MaxRAMPercentage=70"
            - name: CASC_JENKINS_CONFIG
              value: "/var/jenkins_config/jenkins.yaml"
            - name: JENKINS_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jenkins-admin
                  key: password
          ports:
            - name: http
              containerPort: 8080
            - name: inbound
              containerPort: 50000
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              memory: "4Gi"
          livenessProbe:
            httpGet:
              path: /login
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 20
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /login
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
          volumeMounts:
            - name: jenkins-home
              mountPath: /var/jenkins_home
            - name: jenkins-config
              mountPath: /var/jenkins_config
            - name: plugin-dir
              mountPath: /usr/share/jenkins/ref/plugins
      volumes:
        - name: jenkins-config
          configMap:
            name: jenkins-casc
        - name: plugin-dir
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: jenkins-home
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
```

Notá `-Djenkins.install.runSetupWizard=false`: sin eso el controlador arranca en la pantalla "unlock Jenkins" y JCasC nunca se aplica.

### 4.4 Configuration as Code (JCasC)

El ConfigMap `jenkins-casc` referenciado arriba. Esto reemplaza toda la UI de "Manage Jenkins" por un archivo revisable — la misma Invariante 2 aplicada al propio servidor de CI:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: jenkins-casc
  namespace: jenkins
data:
  plugins.txt: |
    configuration-as-code:latest
    kubernetes:latest
    workflow-aggregator:latest
    git:latest
    github-branch-source:latest
    pipeline-stage-view:latest
    blueocean:latest
    credentials-binding:latest
    matrix-auth:latest
    job-dsl:latest
    junit:latest
    warnings-ng:latest
    timestamper:latest
    build-timeout:latest
  jenkins.yaml: |
    jenkins:
      systemMessage: "Managed by JCasC. UI changes are reverted on restart."
      numExecutors: 0
      mode: EXCLUSIVE
      quietPeriod: 5
      scmCheckoutRetryCount: 3
      labelAtoms:
        - name: "kubernetes"
      securityRealm:
        local:
          allowsSignup: false
          users:
            - id: "admin"
              password: "${JENKINS_ADMIN_PASSWORD}"
      authorizationStrategy:
        roleBased:
          roles:
            global:
              - name: "admin"
                permissions:
                  - "Overall/Administer"
                entries:
                  - user: "admin"
              - name: "developer"
                permissions:
                  - "Overall/Read"
                  - "Job/Build"
                  - "Job/Read"
                  - "Job/Cancel"
                entries:
                  - group: "developers"
      clouds:
        - kubernetes:
            name: "k8s"
            serverUrl: "https://kubernetes.default.svc"
            namespace: "jenkins-agents"
            jenkinsUrl: "http://jenkins.jenkins.svc.cluster.local:8080"
            jenkinsTunnel: "jenkins-agent.jenkins.svc.cluster.local:50000"
            credentialsId: ""
            containerCapStr: "40"
            maxRequestsPerHostStr: "32"
            retentionTimeout: 5
            connectTimeout: 10
            readTimeout: 30
            podLabels:
              - key: "jenkins"
                value: "agent"
            templates:
              - name: "maven"
                label: "maven jdk21"
                namespace: "jenkins-agents"
                serviceAccount: "jenkins-agent"
                idleMinutes: 2
                yamlMergeStrategy: "override"
                yaml: |
                  apiVersion: v1
                  kind: Pod
                  spec:
                    securityContext:
                      runAsUser: 1000
                      fsGroup: 1000
                    containers:
                      - name: maven
                        image: maven:3.9.9-eclipse-temurin-21
                        command: ["sleep"]
                        args: ["infinity"]
                        resources:
                          requests:
                            cpu: "1"
                            memory: 2Gi
                          limits:
                            memory: 4Gi
                        volumeMounts:
                          - name: m2-cache
                            mountPath: /root/.m2/repository
                          - name: maven-settings
                            mountPath: /etc/maven
                    volumes:
                      - name: m2-cache
                        persistentVolumeClaim:
                          claimName: maven-cache
                      - name: maven-settings
                        configMap:
                          name: maven-settings
    unclassified:
      location:
        url: "https://jenkins.example.com/"
        adminAddress: "platform-sre@example.com"
      globalLibraries:
        libraries:
          - name: "platform-pipeline"
            defaultVersion: "v3"
            implicit: false
            retriever:
              modernSCM:
                scm:
                  git:
                    remote: "https://git.example.com/platform/jenkins-library.git"
                    credentialsId: "git-readonly"
      timestamper:
        allPipelines: true
    security:
      queueItemAuthenticator:
        authenticators:
          - global:
              strategy: "triggeringUsersAuthorizationStrategy"
    credentials:
      system:
        domainCredentials:
          - credentials:
              - usernamePassword:
                  scope: GLOBAL
                  id: "nexus"
                  username: "ci-publisher"
                  password: "${NEXUS_PASSWORD}"
                  description: "Nexus deployment account"
```

`${JENKINS_ADMIN_PASSWORD}` y `${NEXUS_PASSWORD}` los resuelve JCasC desde variables de entorno o desde archivos en un directorio apuntado por `SECRETS` — nunca se commitean literalmente.

Aplicar y verificar:

```
$ kubectl -n jenkins apply -f jenkins-casc.yaml
configmap/jenkins-casc configured

$ kubectl -n jenkins rollout restart statefulset/jenkins
statefulset.apps/jenkins restarted

$ kubectl -n jenkins logs jenkins-0 -c jenkins | grep -i casc
2026-09-18 09:14:02.331+0000 [id=41]  INFO  i.j.p.casc.ConfigurationAsCode#init: Configuration-as-Code version 1932.v75cb_b_f1b_698d
2026-09-18 09:14:05.887+0000 [id=41]  INFO  i.j.p.casc.ConfigurationAsCode#configureWith: Loading the configuration from file:/var/jenkins_config/jenkins.yaml
2026-09-18 09:14:11.204+0000 [id=41]  INFO  i.j.p.casc.ConfigurationAsCode#configureWith: Configuration loaded from file:/var/jenkins_config/jenkins.yaml
```

Si el archivo está malformado, JCasC falla *ruidosamente* y Jenkins rechaza la configuración en lugar de aplicarla parcialmente — que es el comportamiento que querés:

```
2026-09-18 09:20:44.118+0000 [id=41]  SEVERE  i.j.p.casc.ConfigurationAsCode#configureWith:
io.jenkins.plugins.casc.ConfiguratorException: No configurator for the following root elements clods
```

---

## 5. Jobs de Jenkins y el Jenkinsfile

### 5.1 Tipos de job

| Tipo de job | La definición vive en | Multi-rama | Cuándo usarlo |
|---|---|---|---|
| Freestyle | UI de Jenkins/`config.xml` | No | Solo legado; no revisable |
| Pipeline | `Jenkinsfile` en SCM (o inline) | No | Pipelines de una sola rama |
| Multibranch Pipeline | `Jenkinsfile` por rama | Sí — descubre ramas y PRs automáticamente | **Opción por defecto** |
| Organization Folder | `Jenkinsfile` por repo | Sí — descubre repos automáticamente | Organización de GitHub / grupo de GitLab completos |
| Matrix (multi-configuración) | UI | No | Superado por el `matrix` declarativo |

Un Multibranch Pipeline escanea el repositorio, crea un job para cada rama que contenga un `Jenkinsfile`, y lo borra cuando la rama desaparece. Esto es lo que vuelve operativo el "el pipeline está versionado junto con el código": una rama de feature puede cambiar su propio build sin afectar a `main`.

### 5.2 Pipeline declarativo vs. scripted

Ambos son Groovy corriendo sobre el motor **CPS (Continuation Passing Style)**, que es lo que permite que un pipeline sobreviva a un reinicio del controlador: el estado de ejecución se serializa a disco en cada frontera de paso. Esta también es la fuente de los errores más confusos de Jenkins — variables locales no serializables (`java.io.NotSerializableException`) y construcciones no transformables por CPS.

| Aspecto | Declarativo | Scripted |
|---|---|---|
| Punto de entrada | `pipeline { }` | `node { }` |
| Estructura | Esquema fijo, validado antes de la ejecución | Groovy arbitrario |
| Validación | `declarative-linter` detecta errores antes de correr | Los errores aparecen en tiempo de ejecución |
| Manejo de errores | `post { always / success / failure / unstable / aborted / cleanup }` | `try/catch/finally` |
| Reinicio desde una etapa | Soportado | No soportado |
| Editor Blue Ocean | Soportado | Solo lectura |
| Vía de escape | Bloque `script { }` | N/A — todo es script |
| Recomendado para | Todo | Lógica dinámica compleja, internals de bibliotecas compartidas |

**Usá declarativo.** Empujá la complejidad a una biblioteca compartida, no a bloques `script { }`.

### 5.3 Un Jenkinsfile de producción completo

```groovy
@Library('platform-pipeline@v3') _

pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds(abortPrevious: true)
        timestamps()
        ansiColor('xterm')
        skipDefaultCheckout(true)
    }

    environment {
        REGISTRY    = 'ghcr.io/example'
        IMAGE       = 'checkout'
        NEXUS_CREDS = credentials('nexus')
    }

    triggers {
        // Fallback only: the primary trigger is the SCM webhook.
        pollSCM('H/15 * * * *')
    }

    stages {

        stage('Checkout') {
            agent { label 'maven' }
            steps {
                checkout scm
                script {
                    env.GIT_SHA   = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
                    env.VERSION   = sh(returnStdout: true, script: "git describe --tags --always --dirty").trim()
                    env.IMAGE_REF = "${env.REGISTRY}/${env.IMAGE}:${env.VERSION}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.VERSION}"
                }
                stash name: 'source', includes: '**', excludes: '.git/**'
            }
        }

        stage('Fast feedback') {
            agent { label 'maven' }
            steps {
                unstash 'source'
                sh 'mvn -B -s /etc/maven/settings.xml -o validate compile'
                sh 'mvn -B -s /etc/maven/settings.xml checkstyle:check spotbugs:check'
            }
            post {
                always {
                    recordIssues(
                        enabledForFailure: true,
                        tools: [checkStyle(pattern: 'target/checkstyle-result.xml'),
                                spotBugs(pattern: 'target/spotbugsXml.xml')],
                        qualityGates: [[threshold: 1, type: 'TOTAL_HIGH', unstable: false]]
                    )
                }
            }
        }

        stage('Test') {
            parallel {
                stage('Unit') {
                    agent { label 'maven' }
                    steps {
                        unstash 'source'
                        sh 'mvn -B -s /etc/maven/settings.xml test'
                    }
                    post {
                        always {
                            junit testResults: 'target/surefire-reports/*.xml',
                                  skipPublishingChecks: false,
                                  allowEmptyResults: false
                            recordCoverage(tools: [[parser: 'JACOCO',
                                                    pattern: 'target/site/jacoco/jacoco.xml']],
                                           qualityGates: [[metric: 'LINE', threshold: 75.0,
                                                           baseline: 'PROJECT', criticality: 'UNSTABLE']])
                        }
                    }
                }
                stage('Integration') {
                    agent { label 'maven' }
                    steps {
                        unstash 'source'
                        sh 'mvn -B -s /etc/maven/settings.xml -Pintegration verify -DskipUnitTests'
                    }
                    post {
                        always {
                            junit 'target/failsafe-reports/*.xml'
                        }
                    }
                }
                stage('Dependency audit') {
                    agent { label 'maven' }
                    steps {
                        unstash 'source'
                        sh 'mvn -B -s /etc/maven/settings.xml org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=8'
                    }
                }
            }
        }

        stage('Package and publish') {
            agent { label 'kaniko' }
            when {
                anyOf {
                    branch 'main'
                    buildingTag()
                }
            }
            steps {
                unstash 'source'
                container('kaniko') {
                    sh """
                        /kaniko/executor \
                          --context=\$(pwd) \
                          --dockerfile=Dockerfile \
                          --destination=${env.IMAGE_REF} \
                          --destination=${env.REGISTRY}/${env.IMAGE}:${env.GIT_SHA} \
                          --build-arg=VERSION=${env.VERSION} \
                          --label=org.opencontainers.image.revision=${env.GIT_COMMIT} \
                          --label=org.opencontainers.image.source=${env.GIT_URL} \
                          --reproducible \
                          --digest-file=/workspace/digest.txt
                    """
                    script {
                        env.IMAGE_DIGEST = readFile('/workspace/digest.txt').trim()
                    }
                }
                echo "Published ${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST}"
            }
        }

        stage('Sign and attest') {
            agent { label 'cosign' }
            when { branch 'main' }
            steps {
                withCredentials([file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY')]) {
                    sh "cosign sign --key \$COSIGN_KEY --yes ${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST}"
                    sh "syft ${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST} -o spdx-json > sbom.json"
                    sh "cosign attest --key \$COSIGN_KEY --yes --type spdxjson --predicate sbom.json ${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST}"
                }
                archiveArtifacts artifacts: 'sbom.json', fingerprint: true
            }
        }

        stage('Deploy: staging') {
            agent { label 'deployer' }
            when { branch 'main' }
            steps {
                deployToEnvironment(
                    environment: 'staging',
                    image: "${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST}",
                    strategy: 'rolling'
                )
                sh "./scripts/smoke-test.sh https://checkout.staging.example.com"
            }
        }

        stage('Approval') {
            when { branch 'main' }
            options { timeout(time: 24, unit: 'HOURS') }
            steps {
                script {
                    env.APPROVER = input(
                        message: "Promote ${env.VERSION} to production?",
                        ok: 'Promote',
                        submitter: 'release-managers',
                        submitterParameter: 'APPROVER'
                    )
                }
            }
        }

        stage('Deploy: production') {
            agent { label 'deployer' }
            when { branch 'main' }
            steps {
                echo "Approved by ${env.APPROVER}"
                deployToEnvironment(
                    environment: 'production',
                    image: "${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST}",
                    strategy: 'canary'
                )
            }
        }
    }

    post {
        success {
            slackSend channel: '#deploys',
                      color: 'good',
                      message: "${env.JOB_NAME} ${env.VERSION} deployed (<${env.BUILD_URL}|build>)"
        }
        failure {
            slackSend channel: '#deploys',
                      color: 'danger',
                      message: "${env.JOB_NAME} ${env.VERSION} FAILED at stage '${env.STAGE_NAME}' (<${env.BUILD_URL}console|log>)"
        }
        unstable {
            slackSend channel: '#deploys', color: 'warning',
                      message: "${env.JOB_NAME} ${env.VERSION} unstable — check test results"
        }
        cleanup {
            node('maven') { cleanWs() }
        }
    }
}
```

Puntos que separan esto de un pipeline de tutorial:

- `agent none` arriba de todo más agentes por etapa: no se retiene ningún executor mientras se espera en el paso `input`. Un pipeline que retiene un agente durante una compuerta de aprobación de 24 horas va a trabar la cola.
- `disableConcurrentBuilds(abortPrevious: true)`: un push nuevo reemplaza al build en vuelo de la misma rama.
- La imagen se publica por tag pero **se despliega por digest** (`env.IMAGE_DIGEST`) — la Invariante 1 impuesta mecánicamente.
- `credentials('nexus')` en `environment` liga `NEXUS_CREDS_USR` y `NEXUS_CREDS_PSW`, y Jenkins enmascara ambos en el log de consola.
- `post { cleanup }` corre sin importar el resultado, incluso ante un aborto.

### 5.4 La directiva `matrix`

Para builds multiplataforma o multiversión, el `matrix` declarativo reemplaza al viejo job multi-configuración:

```groovy
stage('Compatibility matrix') {
    matrix {
        axes {
            axis {
                name 'JDK'
                values '17', '21', '25'
            }
            axis {
                name 'DB'
                values 'postgres-15', 'postgres-16'
            }
        }
        excludes {
            exclude {
                axis { name 'JDK';  values '17' }
                axis { name 'DB';   values 'postgres-16' }
            }
        }
        agent { label "maven-jdk${JDK}" }
        stages {
            stage('Verify') {
                steps {
                    unstash 'source'
                    sh "mvn -B verify -Ddb.image=${DB}"
                }
            }
        }
    }
}
```

La matriz se expande a |JDK| × |DB| − |excludes| = 3 × 2 − 1 = 5 celdas paralelas.

### 5.5 Bibliotecas compartidas

El paso `deployToEnvironment` de arriba no es un plugin — es una variable global de una biblioteca compartida. Estructura del repositorio de la biblioteca:

```
jenkins-library/
├── vars/
│   ├── deployToEnvironment.groovy      # global step: deployToEnvironment(...)
│   └── standardJavaPipeline.groovy     # whole-pipeline template
├── src/
│   └── com/example/ci/
│       ├── Semver.groovy
│       └── KubeClient.groovy
└── resources/
    └── com/example/ci/deploy-template.yaml
```

```groovy
// vars/deployToEnvironment.groovy
def call(Map config) {
    assert config.environment : 'environment is required'
    assert config.image       : 'image is required'

    String strategy = config.get('strategy', 'rolling')
    String ns       = "app-${config.environment}"

    withCredentials([file(credentialsId: "kubeconfig-${config.environment}", variable: 'KUBECONFIG')]) {
        sh """
            kubectl -n ${ns} set image deployment/checkout checkout=${config.image}
            kubectl -n ${ns} annotate deployment/checkout \
                kubernetes.io/change-cause='build ${env.BUILD_NUMBER} strategy=${strategy}' --overwrite
            kubectl -n ${ns} rollout status deployment/checkout --timeout=300s
        """
    }
}
```

Así es como un equipo de plataforma le da a cincuenta repositorios la misma semántica de despliegue sin cincuenta copias de las mismas 200 líneas. El versionado es por ref de Git (`@Library('platform-pipeline@v3')`), así que un cambio en la biblioteca no puede alterar silenciosamente todos los pipelines a la vez.

### 5.6 Blue Ocean (conocimiento general)

Blue Ocean es una UI alternativa de Jenkins enfocada en la visualización de pipelines: etapas renderizadas como un grafo horizontal, logs por etapa, ramas paralelas mostradas lado a lado, y despliegue inline de fallos de tests y cambios del SCM. También trae un editor visual de Jenkinsfile para pipelines **declarativos** (los scripted son de solo lectura ahí) y manejo de primera clase de proyectos multibranch y pull requests.

Operativamente, Blue Ocean está **completo en funcionalidad pero ya no se desarrolla activamente**; el proyecto Jenkins recomienda la UI clásica modernizada y el plugin Pipeline Graph View para instalaciones nuevas. Para el examen, sabé qué es y qué muestra; para producción, no construyas un flujo de trabajo que dependa de él.

```
$ curl -s -u "$JENKINS_AUTH" \
    "$JENKINS_URL/blue/rest/organizations/jenkins/pipelines/checkout/branches/main/runs/?start=0&limit=2"
```

---

## 6. Disparar el pipeline: hooks de Git y webhooks

### 6.1 La taxonomía de hooks

Los hooks de Git son archivos ejecutables en `$GIT_DIR/hooks/` (cliente) o en el servidor. **No** están versionados con el repositorio por defecto — `.git/hooks/` está fuera del árbol de trabajo — que es la razón por la cual los equipos usan `core.hooksPath` o un gestor como `pre-commit` para distribuirlos.

| Hook | Corre en | Cuándo | ¿Puede abortar? | Uso típico en CI |
|---|---|---|---|---|
| `pre-commit` | Cliente | Antes del editor del mensaje de commit | Sí | Formateo, lint, escaneo de secretos |
| `commit-msg` | Cliente | Después de escribir el mensaje | Sí | Imponer Conventional Commits / ID de ticket |
| `pre-push` | Cliente | Antes de enviar los objetos | Sí | Correr el subconjunto rápido de unitarios |
| `pre-receive` | **Servidor** | Una vez, antes de actualizar cualquier ref | Sí (rechaza el push entero) | Política: commits firmados, ramas protegidas, tamaño de archivo |
| `update` | Servidor | Una vez **por ref** | Sí (rechaza esa ref) | Permisos por rama |
| `post-receive` | Servidor | Después de actualizar todas las refs | No | **Disparar CI**, notificar, espejar |

El punto arquitectónico relevante para el examen: **los hooks del lado del cliente son consultivos, los del lado del servidor son política.** Cualquier desarrollador puede saltear un hook de cliente con `git commit --no-verify`. Solo `pre-receive`/`update` pueden imponer algo de verdad.

### 6.2 Un hook `pre-receive` de producción

```bash
#!/usr/bin/env bash
# /srv/git/checkout.git/hooks/pre-receive
# Rejects the push if any incoming commit violates policy.
set -euo pipefail

ZERO="0000000000000000000000000000000000000000"
MAX_BLOB_BYTES=$((5 * 1024 * 1024))
STATUS=0

while read -r oldrev newrev refname; do
    # Branch deletion: nothing to inspect.
    [ "$newrev" = "$ZERO" ] && continue

    if [ "$oldrev" = "$ZERO" ]; then
        range="$newrev"
        commits=$(git rev-list "$newrev" --not --all)
    else
        range="$oldrev..$newrev"
        commits=$(git rev-list "$range")
    fi

    # 1. Protected branches accept only fast-forward updates.
    case "$refname" in
        refs/heads/main|refs/heads/release/*)
            if [ "$oldrev" != "$ZERO" ] && ! git merge-base --is-ancestor "$oldrev" "$newrev"; then
                echo "POLICY: non-fast-forward push to $refname is not allowed" >&2
                STATUS=1
            fi
            ;;
    esac

    for commit in $commits; do
        subject=$(git log -1 --format=%s "$commit")

        # 2. Conventional Commits with a mandatory ticket reference.
        if ! printf '%s' "$subject" | grep -Eq '^(feat|fix|docs|refactor|test|chore|perf)(\([a-z0-9-]+\))?!?: .+ \(#[0-9]+\)$'; then
            echo "POLICY: ${commit:0:8} subject does not match 'type(scope): summary (#123)'" >&2
            echo "        got: $subject" >&2
            STATUS=1
        fi

        # 3. No oversized blobs.
        while read -r _mode type sha _size path; do
            [ "$type" = "blob" ] || continue
            size=$(git cat-file -s "$sha")
            if [ "$size" -gt "$MAX_BLOB_BYTES" ]; then
                echo "POLICY: ${commit:0:8} adds $path ($size bytes) over the ${MAX_BLOB_BYTES} byte limit" >&2
                STATUS=1
            fi
        done < <(git diff-tree -r --no-commit-id "$commit" 2>/dev/null | awk '{print $2, $3, $4, 0, $6}')
    done
done

if [ "$STATUS" -ne 0 ]; then
    echo "" >&2
    echo "Push rejected. Fix the commits and retry; see https://wiki.example.com/git-policy" >&2
fi
exit "$STATUS"
```

```
$ git push origin main
Enumerating objects: 9, done.
Counting objects: 100% (9/9), done.
Writing objects: 100% (5/5), 512 bytes | 512.00 KiB/s, done.
remote: POLICY: 7f3a91c2 subject does not match 'type(scope): summary (#123)'
remote:         got: wip fixing stuff
remote:
remote: Push rejected. Fix the commits and retry; see https://wiki.example.com/git-policy
To git.example.com:platform/checkout.git
 ! [remote rejected]   main -> main (pre-receive hook declined)
error: failed to push some refs to 'git.example.com:platform/checkout.git'
```

### 6.3 Polling vs. webhooks

| Propiedad | `pollSCM` | Webhook (`post-receive` / GitHub / GitLab) |
|---|---|---|
| Latencia | Hasta el intervalo de sondeo | Segundos |
| Carga sobre el SCM | O(jobs × sondeos) — miles de `git ls-remote` por hora | O(pushes) |
| Se dispara cuando no cambió nada | Sí (una petición por intervalo) | No |
| Funciona detrás de un firewall | Sí | Necesita alcanzabilidad entrante o un relay |
| Modo de falla | Retraso silencioso | *Nunca* silencioso — un webhook perdido significa que no hay build en absoluto |

Usá webhooks como disparador primario y un `pollSCM` de intervalo amplio como red de seguridad, exactamente como en el Jenkinsfile de más arriba. `H/15 * * * *` — la `H` es la dispersión basada en hash de Jenkins, que distribuye el sondeo a lo largo del intervalo por job, para que quinientos jobs no golpeen todos el SCM a las `:00`.

```bash
#!/usr/bin/env bash
# hooks/post-receive — notify Jenkins (Git plugin endpoint)
set -euo pipefail
REPO_URL="ssh://git@git.example.com/platform/checkout.git"
curl -sS --max-time 10 --retry 3 \
     --get "https://jenkins.example.com/git/notifyCommit" \
     --data-urlencode "url=${REPO_URL}" \
     >/dev/null || echo "WARN: Jenkins notification failed; polling will pick it up" >&2
```

---

## 7. Herramientas alternativas de CI/CD

| Herramienta | Modelo de ejecución | Archivo de configuración | Runners | Self-hosted | Propiedad distintiva |
|---|---|---|---|---|---|
| **Jenkins** | Controlador + agentes, impulsado por plugins | `Jenkinsfile` (Groovy) | Cualquiera: SSH, Docker, K8s | Sí (únicamente) | ~1 900 plugins; puede construir cualquier cosa, incluidos toolchains de 30 años. Costo: cadena de suministro de plugins y riesgo de actualización |
| **GitLab CI/CD** | Coordinador dentro de GitLab + runners | `.gitlab-ci.yml` (YAML) | Docker, shell, K8s, VM | Sí o SaaS | La integración más estrecha con el SCM: pipelines de MR, entornos, registry, review apps en un solo producto |
| **GitHub Actions** | Runners hospedados por GitHub o propios | `.github/workflows/*.yml` | Hospedados por GitHub, propios | Runners sí, plano de control no (salvo GHES) | Marketplace de actions reutilizables; federación OIDC hacia el IAM de la nube sin claves de larga vida |
| **CircleCI** | Orquestador SaaS | `.circleci/config.yml` | Nube (Docker/VM/macOS), runners propios | Solo runners | Orbs (paquetes de configuración reutilizables), primitivas fuertes de caché y división de tests |
| **Travis CI** | SaaS | `.travis.yml` | Nube | Solo `travis-ci.com` | El CI hospedado original para open source; en gran medida desplazado por Actions. Sabé que existe — el examen lo nombra |
| **Tekton** | CRDs de Kubernetes; cada paso es un contenedor | CRs `Task` / `Pipeline` | Pods de Kubernetes | Sí | Primitiva cloud-native, no un producto: sin UI, sin SCM. Un bloque de construcción para una plataforma |
| **Argo Workflows** | CRDs de Kubernetes, motor de DAG | CRs `Workflow` | Pods de Kubernetes | Sí | Motor de workflows general (CI es un uso); excelente fan-out/fan-in |
| **Drone / Woodpecker** | Container-native, liviano | `.drone.yml` | Docker, K8s | Sí | Huella mínima; cada paso es un contenedor, sin runtime de plugins |

**Cómo elegir, como arquitecto:**

- *Ya vivís dentro de una forja* (GitLab, GitHub) → usá su CI nativo. El valor de la integración (estado de MR, entornos, secretos, registro de paquetes) supera cualquier brecha de funcionalidad.
- *Necesitás entornos de build heterogéneos* — Windows, macOS, mainframe, herramientas EDA licenciadas → Jenkins, porque el modelo de agentes es agnóstico del transporte.
- *Estás construyendo una plataforma que otros equipos consumen* → Tekton o Argo Workflows por debajo de tu propia abstracción; querés CRDs y RBAC, no una UI.
- *Necesitás compuertas de aprobación auditadas y registros de cambios* → Jenkins o GitLab con entornos protegidos; las herramientas solo-SaaS a menudo no pueden satisfacer requisitos de auditoría on-prem.

### 7.1 El mismo pipeline en GitLab CI

```yaml
stages:
  - build
  - test
  - package
  - deploy

default:
  image: "maven:3.9.9-eclipse-temurin-21"
  interruptible: true
  retry:
    max: 2
    when:
      - runner_system_failure
      - stuck_or_timeout_failure

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
  MAVEN_CLI_OPTS: "-B -s /etc/maven/settings.xml --no-transfer-progress"
  IMAGE: "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"

cache:
  key:
    files:
      - pom.xml
  paths:
    - .m2/repository
  policy: pull-push

compile:
  stage: build
  script:
    - mvn $MAVEN_CLI_OPTS compile
  artifacts:
    paths:
      - target/classes
    expire_in: 1 hour

unit-test:
  stage: test
  script:
    - mvn $MAVEN_CLI_OPTS test
  artifacts:
    when: always
    reports:
      junit: "target/surefire-reports/TEST-*.xml"
    expire_in: 1 week

integration-test:
  stage: test
  services:
    - name: "postgres:16-alpine"
      alias: db
  variables:
    POSTGRES_PASSWORD: "ci-only"
    POSTGRES_DB: "checkout"
    DB_URL: "jdbc:postgresql://db:5432/checkout"
  script:
    - mvn $MAVEN_CLI_OPTS -Pintegration verify

container:
  stage: package
  image:
    name: "gcr.io/kaniko-project/executor:v1.23.2-debug"
    entrypoint: [""]
  script:
    - /kaniko/executor
      --context "$CI_PROJECT_DIR"
      --dockerfile "$CI_PROJECT_DIR/Dockerfile"
      --destination "$IMAGE"
      --digest-file /tmp/digest.txt
    - echo "IMAGE_DIGEST=$(cat /tmp/digest.txt)" >> package.env
  artifacts:
    reports:
      dotenv: package.env
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'

deploy-staging:
  stage: deploy
  image: "bitnami/kubectl:1.32"
  needs:
    - job: container
      artifacts: true
  environment:
    name: staging
    url: "https://checkout.staging.example.com"
  script:
    - kubectl -n app-staging set image deploy/checkout "checkout=$CI_REGISTRY_IMAGE@$IMAGE_DIGEST"
    - kubectl -n app-staging rollout status deploy/checkout --timeout=300s
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'

deploy-production:
  stage: deploy
  image: "bitnami/kubectl:1.32"
  needs:
    - job: deploy-staging
    - job: container
      artifacts: true
  environment:
    name: production
    url: "https://checkout.example.com"
  when: manual
  allow_failure: false
  script:
    - kubectl -n app-prod set image deploy/checkout "checkout=$CI_REGISTRY_IMAGE@$IMAGE_DIGEST"
    - kubectl -n app-prod rollout status deploy/checkout --timeout=600s
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
```

`when: manual` en `deploy-production` es exactamente la compuerta de Entrega Continua de §1.1. Quitalo y el mismo archivo se convierte en Despliegue Continuo.

### 7.2 La misma forma en GitHub Actions

```yaml
name: ci
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["main"]

permissions:
  contents: read
  packages: write
  id-token: write

concurrency:
  group: "ci-${{ github.ref }}"
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        jdk: ["17", "21", "25"]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: ${{ matrix.jdk }}
          cache: maven
      - name: Run tests
        run: mvn -B --no-transfer-progress verify

  publish:
    needs: test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: build
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: "ghcr.io/${{ github.repository }}:${{ github.sha }}"
          provenance: true
          sbom: true
```

Notá `id-token: write`: habilita OIDC, permitiendo que el job intercambie un token de GitHub de corta vida por credenciales de nube en lugar de almacenar una clave de acceso estática — la respuesta moderna a "dónde viven los secretos de CI".

---

## 8. Estrategias de despliegue

Acá es donde CD deja de tratarse de builds y pasa a tratarse de disponibilidad. La elección de la estrategia determina tu radio de impacto, tu tiempo de rollback y tu costo de infraestructura.

| Estrategia | Versiones vivas a la vez | Downtime | Tiempo de rollback | Capacidad extra | ¿Requiere control de tráfico? | Radio de impacto durante el rollout |
|---|---|---|---|---|---|---|
| **Recreate** | 1 | Sí (completo) | Redesplegar la vieja (minutos) | 0 % | Ninguno | 100 % durante el hueco |
| **Rolling update** | 2 (mezcladas) | No | Rollout inverso (minutos) | `maxSurge` (ej. 25 %) | Ninguno | Crece al 100 % si la nueva versión está rota |
| **Blue-green** | 2 (solo una sirviendo) | No | **Instantáneo** (cambiar el selector) | 100 % | Selector de Service / cambio de LB | 0 % hasta el cambio, luego 100 % |
| **Canary** | 2 (ambas sirviendo, ponderadas) | No | Instantáneo (peso → 0) | Pequeña (1 pod) | Enrutamiento ponderado (Ingress/mesh) | Acotado por el peso |
| **A/B testing** | 2+ (enrutadas por atributo) | No | Instantáneo | Pequeña | Enrutamiento por header/cookie | Acotado por la cohorte |
| **Shadow / dark launch** | 2 (una recibe tráfico espejado, no devuelve nada) | No | Dejar de espejar | 100 % de la carga de la sombra | Espejado de tráfico | 0 % — las respuestas se descartan |

Las dos que más importan en el examen y en la práctica:

**Blue-green** te da un rollback instantáneo y binario, al costo de correr dos entornos completos. Su trampa oculta es el *estado*: la base de datos no es blue-green. Los cambios de esquema deben ser **retrocompatibles** para que blue y green puedan correr ambos contra ella — el patrón expand/contract (cambio paralelo): agregar la columna nueva, desplegar código que escribe en ambas y lee la nueva, hacer backfill, desplegar código que lee solo la nueva, eliminar la columna vieja. Cuatro despliegues para renombrar una columna, y no hay atajo si querés un rollback que funcione.

**Canary** te da un radio de impacto *acotado* y una señal real, al costo de necesitar enrutamiento ponderado de tráfico y suficiente volumen de tráfico para que las métricas sean estadísticamente significativas. Un canary al 1 % de 100 peticiones/día no te dice nada.

### 8.1 Rolling update, completamente especificado

El predeterminado en Kubernetes, y el más frecuentemente mal configurado. Los parámetros que realmente importan:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: app-prod
  annotations:
    kubernetes.io/change-cause: "build 4471 image 1.4.2"
spec:
  replicas: 10
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
  minReadySeconds: 20
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 0
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
        version: "1.4.2"
    spec:
      terminationGracePeriodSeconds: 60
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: checkout
      containers:
        - name: checkout
          image: "ghcr.io/example/checkout@sha256:6c1e6ba8d2f2c8f0f5e4d1a9bd3c7b21b0f5a4d8e3c2b1a09f8e7d6c5b4a3921"
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: production
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 10
            failureThreshold: 6
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 10"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout
  namespace: app-prod
spec:
  minAvailable: 8
  selector:
    matchLabels:
      app: checkout
```

Por qué está cada campo no obvio:

- `maxUnavailable: 0` + `maxSurge: 2` — la capacidad nunca baja de `replicas` durante el rollout. Con `maxUnavailable: 1` (el predeterminado es 25 %) corrés deliberadamente degradado durante cada despliegue.
- `minReadySeconds: 20` — un pod debe permanecer Ready durante 20 s antes de que el rollout lo cuente. Atrapa al contenedor que pasa su primer probe y después crashea.
- `progressDeadlineSeconds: 600` — después de 10 minutos sin progreso el Deployment se marca `Failed`, que es lo que `kubectl rollout status` espera. Sin esto, un rollout trabado cuelga tu pipeline hasta el timeout del job.
- `preStop: sleep 10` + `terminationGracePeriodSeconds: 60` — la remoción del endpoint y el SIGTERM compiten entre sí. El sleep le permite a cada proxy/kube-proxy/ingress observar la remoción del endpoint *antes* de que el proceso empiece a apagarse. Esta es la solución al ticket de "unos pocos 502 en cada despliegue".
- El PDB protege a la misma carga de trabajo de la disrupción *voluntaria* (drenajes de nodo), que es un eje distinto del rollout.

### 8.2 Blue-green con un cambio de selector de Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-blue
  namespace: app-prod
  labels:
    app: checkout
    slot: blue
spec:
  replicas: 10
  selector:
    matchLabels:
      app: checkout
      slot: blue
  template:
    metadata:
      labels:
        app: checkout
        slot: blue
    spec:
      containers:
        - name: checkout
          image: "ghcr.io/example/checkout:1.4.1"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-green
  namespace: app-prod
  labels:
    app: checkout
    slot: green
spec:
  replicas: 10
  selector:
    matchLabels:
      app: checkout
      slot: green
  template:
    metadata:
      labels:
        app: checkout
        slot: green
    spec:
      containers:
        - name: checkout
          image: "ghcr.io/example/checkout:1.4.2"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: app-prod
spec:
  selector:
    app: checkout
    slot: blue
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-preview
  namespace: app-prod
spec:
  selector:
    app: checkout
    slot: green
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

El cambio de tráfico y su rollback son un comando cada uno:

```
$ kubectl -n app-prod run smoke --rm -it --image=curlimages/curl:8.11.0 --restart=Never -- \
    curl -sf http://checkout-preview/actuator/health
{"status":"UP","groups":["liveness","readiness"]}
pod "smoke" deleted

$ kubectl -n app-prod patch service checkout \
    -p '{"spec":{"selector":{"app":"checkout","slot":"green"}}}'
service/checkout patched

$ kubectl -n app-prod get endpointslices -l kubernetes.io/service-name=checkout \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' | wc -l
10

# Rollback, if the error rate moves:
$ kubectl -n app-prod patch service checkout \
    -p '{"spec":{"selector":{"app":"checkout","slot":"blue"}}}'
service/checkout patched
```

La latencia de rollback acá es el tiempo de propagación de los endpoints del Service — segundos de un solo dígito — contra minutos de un rolling update inverso. Esa diferencia es toda la justificación de la capacidad duplicada.

### 8.3 Canary automatizado con Argo Rollouts

Los canaries manuales no escalan: alguien tiene que mirar un dashboard. Los controladores de progressive delivery evalúan las métricas ellos mismos y abortan:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
  namespace: app-prod
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: checkout
  strategy:
    canary:
      canaryService: checkout-canary
      stableService: checkout-stable
      maxSurge: "25%"
      maxUnavailable: 0
      trafficRouting:
        nginx:
          stableIngress: checkout
      analysis:
        templates:
          - templateName: error-rate
        startingStep: 2
        args:
          - name: service-name
            value: "checkout-canary.app-prod.svc.cluster.local"
      steps:
        - setWeight: 5
        - pause:
            duration: 5m
        - setWeight: 20
        - pause:
            duration: 10m
        - setWeight: 50
        - pause:
            duration: 10m
        - setWeight: 100
  template:
    metadata:
      labels:
        app: checkout
    spec:
      containers:
        - name: checkout
          image: "ghcr.io/example/checkout:1.4.2"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: error-rate
  namespace: app-prod
spec:
  args:
    - name: service-name
  metrics:
    - name: error-rate
      interval: 1m
      count: 10
      successCondition: "result[0] < 0.01"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            sum(rate(http_server_requests_seconds_count{service="{{args.service-name}}",status=~"5.."}[2m]))
            /
            sum(rate(http_server_requests_seconds_count{service="{{args.service-name}}"}[2m]))
    - name: p99-latency
      interval: 1m
      count: 10
      successCondition: "result[0] < 0.75"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            histogram_quantile(0.99,
              sum by (le) (
                rate(http_server_requests_seconds_bucket{service="{{args.service-name}}"}[2m])
              )
            )
```

Las tres líneas de PromQL y las cuatro líneas de `histogram_quantile` están todas indentadas a la misma columna dentro del escalar de bloque `|` — una sola línea indentada menos terminaría el escalar y volvería inválido al documento.

Mirándolo correr:

```
$ kubectl argo rollouts get rollout checkout -n app-prod --watch
Name:            checkout
Namespace:       app-prod
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/7
  SetWeight:     20
  ActualWeight:  20
Images:          ghcr.io/example/checkout:1.4.1 (stable)
                 ghcr.io/example/checkout:1.4.2 (canary)
Replicas:
  Desired:       10
  Current:       12
  Updated:       2
  Ready:         12
  Available:     12

NAME                                  KIND        STATUS     AGE    INFO
⟳ checkout                            Rollout     ॥ Paused   6m12s
├──# revision:2
│  ├──⧉ checkout-7d9c4b8f6            ReplicaSet  ✔ Healthy  6m12s  canary
│  │  ├──□ checkout-7d9c4b8f6-h2xkq   Pod         ✔ Running  6m10s  ready:1/1
│  │  └──□ checkout-7d9c4b8f6-p9fz4   Pod         ✔ Running  6m10s  ready:1/1
│  └──α checkout-7d9c4b8f6-2          AnalysisRun ✔ Successful 5m2s  ✔ 5
└──# revision:1
   └──⧉ checkout-5f4b9d2a1            ReplicaSet  ✔ Healthy  14d   stable
```

Cuando el análisis falla, el controlador aborta sin intervención humana:

```
$ kubectl argo rollouts get rollout checkout -n app-prod
Name:            checkout
Status:          ✖ Degraded
Message:         RolloutAborted: Rollout aborted update to revision 2: metric "error-rate" assessed Failed
Strategy:        Canary
  Step:          0/7
  SetWeight:     0
  ActualWeight:  0

$ kubectl argo rollouts status checkout -n app-prod
Degraded
$ echo $?
1
```

El código de salida 1 es lo que lo convierte en una compuerta del pipeline: la etapa de despliegue falla, Slack se dispara, y producción ya está de vuelta en la versión estable.

### 8.4 GitOps: push vs. pull

| | Push (CI despliega) | Pull (GitOps) |
|---|---|---|
| Quién le habla al clúster | El runner de CI | Un controlador dentro del clúster (Argo CD, Flux) |
| Credenciales | Kubeconfig de admin del clúster guardado en CI | Ninguna saliente; el controlador tiene RBAC dentro del clúster |
| Detección de drift | Ninguna — un `kubectl edit` manual persiste | Reconciliación continua, drift revertido |
| Fuente de verdad | Lo que se haya ejecutado último | El repositorio Git |
| Rastro de auditoría | Logs de builds de CI | Historial de Git |
| Rollback | Volver a correr un pipeline viejo | `git revert` |
| Modo de falla | Ruta de red del runner hacia cada clúster | El controlador debe alcanzar Git y el registro |

El argumento de seguridad es decisivo a escala: el modo push requiere que tu sistema de CI — una máquina que ejecuta código arbitrario proveniente de pull requests — tenga credenciales del clúster de producción. El modo pull lo invierte. El último paso del pipeline pasa a ser un commit a un repositorio de manifiestos:

```groovy
stage('Promote') {
    steps {
        withCredentials([sshUserPrivateKey(credentialsId: 'gitops-deploy-key', keyFileVariable: 'KEY')]) {
            sh """
                export GIT_SSH_COMMAND="ssh -i \$KEY -o StrictHostKeyChecking=accept-new"
                rm -rf gitops && git clone git@git.example.com:platform/gitops.git gitops
                cd gitops
                yq -i '.spec.template.spec.containers[0].image = "${env.REGISTRY}/${env.IMAGE}@${env.IMAGE_DIGEST}"' \
                    apps/checkout/overlays/production/deployment.yaml
                git -c user.email=ci@example.com -c user.name=jenkins \
                    commit -am 'checkout: promote ${env.VERSION} to production'
                git push origin main
            """
        }
    }
}
```

---

## 9. Verificación y diagnóstico de fallos

### 9.1 Verificar la instalación de Jenkins

```
$ kubectl -n jenkins get pods,svc,pvc
NAME             READY   STATUS    RESTARTS   AGE
pod/jenkins-0    1/1     Running   0          22m

NAME                    TYPE        CLUSTER-IP      PORT(S)     AGE
service/jenkins         ClusterIP   10.96.41.207    8080/TCP    22m
service/jenkins-agent   ClusterIP   10.96.188.12    50000/TCP   22m

NAME                                       STATUS   VOLUME     CAPACITY   AGE
persistentvolumeclaim/jenkins-home-jenkins-0  Bound  pvc-7a1c   100Gi      22m

$ export JENKINS_URL=https://jenkins.example.com
$ export JENKINS_AUTH="svc-ci:$(kubectl -n jenkins get secret ci-token -o jsonpath='{.data.token}' | base64 -d)"

$ java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" who-am-i
Authenticated as: svc-ci
Authorities:
  authenticated

$ java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" version
2.492.1

$ curl -s -u "$JENKINS_AUTH" "$JENKINS_URL/computer/api/json?tree=computer[displayName,offline,numExecutors]&pretty=true"
```

Verificar que el controlador no tiene executors (la invariante de seguridad de §4.1):

```
$ curl -s -u "$JENKINS_AUTH" "$JENKINS_URL/computer/(master)/api/json?tree=numExecutors" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["numExecutors"])'
0
```

Validar un Jenkinsfile *antes* de pushear — esto pertenece a un hook `pre-push`:

```
$ java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" declarative-linter < Jenkinsfile
Jenkinsfile successfully validated.

$ java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" declarative-linter < Jenkinsfile
Errors encountered validating Jenkinsfile:
WorkflowScript: 58: Expected one of "steps", "stages", "parallel", or "matrix" for stage "Deploy" @ line 58, column 9.
           stage('Deploy') {
           ^
```

O por HTTP, cuando el jar de la CLI no está disponible:

```
$ CRUMB=$(curl -s -u "$JENKINS_AUTH" "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
$ curl -s -u "$JENKINS_AUTH" -H "$CRUMB" \
    -X POST -F "jenkinsfile=<Jenkinsfile" \
    "$JENKINS_URL/pipeline-model-converter/validate"
Jenkinsfile successfully validated.
```

### 9.2 Diagnosticar fallos de conexión de agentes

Síntoma: los builds quedan en la cola para siempre con "waiting for next available executor on 'maven'".

```
$ curl -s -u "$JENKINS_AUTH" "$JENKINS_URL/queue/api/json?pretty=true&tree=items[why,task[name],inQueueSince]"
```

```
$ kubectl -n jenkins-agents get pods
NAME                    READY   STATUS             RESTARTS   AGE
maven-9kx2f-qz4rt       0/2     ImagePullBackOff   0          3m18s

$ kubectl -n jenkins-agents describe pod maven-9kx2f-qz4rt | tail -8
Events:
  Type     Reason   Age                From     Message
  ----     ------   ----               ----     -------
  Normal   Pulling  3m                 kubelet  Pulling image "maven:3.9.9-eclipse-temurin-21"
  Warning  Failed   2m45s              kubelet  Failed to pull image: rpc error: code = Unknown
           desc = failed to pull and unpack image: 429 Too Many Requests - Server message: toomanyrequests
  Warning  Failed   2m45s              kubelet  Error: ErrImagePull
```

La tabla de decisión para fallos de agentes:

| Observación | Causa | Solución |
|---|---|---|
| El pod del agente queda en `Pending` | No se puede planificar: requests de recursos, taints, sin nodo | Revisá los eventos de `describe pod`; reducí los requests o agregá capacidad |
| Pod `Running` pero Jenkins muestra el nodo offline | El agente no puede alcanzar `jenkinsTunnel` en :50000 | Verificá el Service `jenkins-agent` y cualquier NetworkPolicy |
| `ImagePullBackOff` en la imagen del agente | Límite de tasa del registro o falta el pull secret | Usá un registro proxy/mirror; agregá `imagePullSecrets` |
| `SEVERE: Connection refused` en el log del agente | `jenkinsUrl` incorrecto en la configuración de la nube | Debe ser el DNS del Service dentro del clúster, no el Ingress público |
| El agente conecta y se desconecta inmediatamente | Desajuste de versión de remoting controlador ↔ agente | Alineá la imagen `inbound-agent` con el LTS del controlador |
| Se crean pods pero se topan con un tope | Se alcanzó `containerCapStr` | Subí el tope o arreglá los pods filtrados |

```
$ kubectl -n jenkins-agents logs maven-9kx2f-qz4rt -c jnlp
INFO: Using /home/jenkins/agent/remoting as a remoting work directory
INFO: Locating server among [http://jenkins.jenkins.svc.cluster.local:8080/]
INFO: Agent discovery successful
  Agent address: jenkins-agent.jenkins.svc.cluster.local
  Agent port:    50000
  Identity:      3c:9f:11:b0:4d:2e:77:aa:15:cc:08:9b:6f:31:d4:2a
INFO: Handshaking
INFO: Connecting to jenkins-agent.jenkins.svc.cluster.local:50000
INFO: Remote identity confirmed: 3c:9f:11:b0:4d:2e:77:aa:15:cc:08:9b:6f:31:d4:2a
INFO: Connected
```

### 9.3 Diagnosticar un despliegue fallido

```
$ kubectl -n app-prod rollout status deployment/checkout --timeout=300s
Waiting for deployment "checkout" rollout to finish: 4 out of 10 new replicas have been updated...
error: deployment "checkout" exceeded its progress deadline

$ kubectl -n app-prod rollout history deployment/checkout
deployment.apps/checkout
REVISION  CHANGE-CAUSE
6         build 4468 image 1.4.0
7         build 4470 image 1.4.1
8         build 4471 image 1.4.2

$ kubectl -n app-prod get pods -l app=checkout --field-selector=status.phase!=Running
NAME                        READY   STATUS             RESTARTS   AGE
checkout-7d9c4b8f6-h2xkq    0/1     CrashLoopBackOff   5          4m21s

$ kubectl -n app-prod logs checkout-7d9c4b8f6-h2xkq --previous --tail=20
Caused by: org.postgresql.util.PSQLException: ERROR: column "customer_tier" does not exist
	at org.postgresql.core.v3.QueryExecutorImpl.receiveErrorResponse(QueryExecutorImpl.java:2725)

$ kubectl -n app-prod rollout undo deployment/checkout --to-revision=7
deployment.apps/checkout rolled back

$ kubectl -n app-prod rollout status deployment/checkout
deployment "checkout" successfully rolled out
```

Esa traza es la falla de expand/contract de §8: el código de la aplicación se envió por delante de la migración. La solución sistémica no es "ser más cuidadoso" — es hacer que el pipeline corra las migraciones como un paso separado, retrocompatible y desplegado previamente.

### 9.4 La tabla de decisión de fallos del pipeline

| Modo de falla | Evidencia discriminante | Remediación |
|---|---|---|
| El build pasa localmente, falla en CI | El agente de CI tiene un toolchain distinto | Fijá el toolchain en una imagen de contenedor; hacé hermético el build |
| El build falla solo en CI, intermitentemente | Estado mutable compartido entre builds (workspace, caché, puerto) | Agentes efímeros; puertos únicos; `cleanWs()` |
| El test pasa solo, falla en la suite | Dependencia del orden de los tests / fixture compartido | Aleatorizá el orden de los tests en CI para que aflore deliberadamente |
| Mismo commit, resultados distintos | Dependencia sin fijar (`^1.2.0`, `:latest`) | Lockfiles; desplegar por digest |
| El build se cuelga al 100 % del timeout | Deadlock, o un paso esperando en stdin | Opción `timeout` por etapa; nunca correr herramientas interactivas |
| `java.io.NotSerializableException` en un pipeline | Un objeto no serializable retenido a través de una frontera de paso CPS | Envolvelo en un método `@NonCPS` o acotalo dentro de `script { }` y anulalo |
| Aparecen secretos en el log de consola | El valor no fue ligado a través del almacén de credenciales | Usá `withCredentials`/`credentials()`; Jenkins solo enmascara lo que inyectó |
| El pipeline tiene éxito, producción se rompe | Staging no se parece a producción, o la configuración derivó | Mismo artefacto, configuración como código, reconciliación GitOps |
| Todo está lento después de 6 meses | Crecimiento del historial de builds / workspaces / caché de capas Docker | `buildDiscarder`, GC de imágenes de agentes, monitorear el tamaño de `JENKINS_HOME` |

```
$ kubectl -n jenkins exec jenkins-0 -- du -sh /var/jenkins_home/* 2>/dev/null | sort -rh | head -6
58G	/var/jenkins_home/jobs
12G	/var/jenkins_home/workspace
2.1G	/var/jenkins_home/caches
340M	/var/jenkins_home/plugins
96M	/var/jenkins_home/war
12M	/var/jenkins_home/logs
```

58 GB bajo `jobs/` significa que la retención del historial de builds nunca se configuró. `buildDiscarder(logRotator(numToKeepStr: '30'))` en `options` no es cosmético — un `JENKINS_HOME` sobredimensionado hace que los reinicios del controlador tarden decenas de minutos, porque Jenkins indexa los registros de builds de forma perezosa al arrancar.

### 9.5 Las cuatro señales que un sistema de entrega debe exponer

Si no podés responder esto desde un dashboard, estás operando a ciegas:

| Señal | Consulta | Objetivo (DORA "elite") |
|---|---|---|
| Frecuencia de despliegue | Cantidad de eventos de despliegue a producción por día | Bajo demanda, varios por día |
| Lead time del cambio | `deploy_timestamp − commit_timestamp`, p50 y p90 | < 1 hora |
| Tasa de fallos de cambio | Despliegues seguidos de un rollback o incidente ÷ despliegues totales | 0–15 % |
| Tiempo de restauración del servicio | Inicio del incidente → resolución | < 1 hora |

Más dos internas de CI: **duración del pipeline p90** (el número que el equipo realmente siente) y **tasa de flakes** (tests que fallan al reintentar sin cambios de código). Una tasa de flakes por encima de ~1 % destruye la confianza en el pipeline, y un pipeline en el que no se confía se saltea — lo que te devuelve a §1.

---

## 10. Resumen enfocado al examen

- **CI** = mergear a la línea principal con frecuencia + build y test automáticos. **CD (Delivery)** = siempre desplegable, una persona decide cuándo. **CD (Deployment)** = decide el pipeline.
- Etapas del pipeline, en orden: build → test → package → deploy → verify. Construir una vez, promover el mismo artefacto.
- **Los repositorios de artefactos** (Nexus, Artifactory) le dan a los artefactos identidad inmutable, hacen de proxy de los registros upstream, y soportan la promoción entre repositorios snapshot y release.
- **Arquitectura de Jenkins**: un controlador que guarda todo el estado en `JENKINS_HOME`, más agentes conectados de forma saliente (SSH) o entrante (puerto 50000). Los executors son la unidad de concurrencia; los labels son la forma en que los jobs seleccionan agentes. El controlador debe tener cero executors.
- **Jobs de Jenkins**: Freestyle (legado), Pipeline, Multibranch Pipeline (descubre ramas y PRs), Organization Folder.
- **Jenkinsfile**: declarativo (`pipeline { agent / stages / steps / post }`) o scripted (`node { }`). El declarativo se valida antes de la ejecución y soporta reinicio desde una etapa.
- **Los plugins** son la forma en que Jenkins hace todo: `git`, `workflow-aggregator` (Pipeline), `kubernetes` (agentes dinámicos), `credentials-binding`, `junit`, `blueocean`, `configuration-as-code`.
- **Blue Ocean** es la UI alternativa enfocada en pipelines con un editor visual para pipelines declarativos; completa en funcionalidad, sin desarrollo activo.
- **Hooks de Git**: los del lado del cliente (`pre-commit`, `commit-msg`, `pre-push`) son salteables con `--no-verify`; los del lado del servidor (`pre-receive`, `update`, `post-receive`) son imponibles. `post-receive` es el disparador clásico de CI; los webhooks le ganan al polling.
- **Alternativas**: GitLab CI (`.gitlab-ci.yml`), GitHub Actions (`.github/workflows/`), CircleCI (`.circleci/config.yml`), Travis CI (`.travis.yml`), Tekton y Argo Workflows (nativos de Kubernetes).
- **Estrategias de despliegue**: recreate, rolling, blue-green (rollback instantáneo, capacidad duplicada), canary (radio de impacto acotado, requiere ponderación de tráfico), A/B, shadow.

---

## Referencias

**Exam objectives**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, 701-100 v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Jenkins**
- Jenkins User Documentation: https://www.jenkins.io/doc/book/
- Pipeline — Syntax reference (declarative and scripted): https://www.jenkins.io/doc/book/pipeline/syntax/
- Pipeline — Getting started and Jenkinsfile: https://www.jenkins.io/doc/book/pipeline/jenkinsfile/
- Pipeline — Shared Libraries: https://www.jenkins.io/doc/book/pipeline/shared-libraries/
- Using Jenkins agents: https://www.jenkins.io/doc/book/using/using-agents/
- Managing nodes and distributed builds: https://www.jenkins.io/doc/book/managing/nodes/
- Blue Ocean documentation: https://www.jenkins.io/doc/book/blueocean/
- Configuration as Code plugin: https://www.jenkins.io/projects/jcasc/
- Kubernetes plugin: https://plugins.jenkins.io/kubernetes/
- Jenkins CLI: https://www.jenkins.io/doc/book/managing/cli/
- Securing Jenkins: https://www.jenkins.io/doc/book/security/
- Backing up Jenkins: https://www.jenkins.io/doc/book/system-administration/backing-up/

**Git**
- Git — Customizing Git: Git Hooks: https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks
- `githooks(5)` manual page: https://git-scm.com/docs/githooks
- Git — An Example Git-Enforced Policy: https://git-scm.com/book/en/v2/Customizing-Git-An-Example-Git-Enforced-Policy

**Artifact repositories**
- Sonatype Nexus Repository documentation: https://help.sonatype.com/en/sonatype-nexus-repository.html
- JFrog Artifactory documentation: https://jfrog.com/help/r/jfrog-artifactory-documentation
- Apache Maven — Repositories and deployment: https://maven.apache.org/guides/introduction/introduction-to-repositories.html
- OCI Distribution Specification: https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- Sigstore / cosign documentation: https://docs.sigstore.dev/

**Kubernetes deployment**
- Kubernetes — Deployments and update strategies: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — Configure liveness, readiness and startup probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod lifecycle and termination: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Argo Rollouts documentation: https://argo-rollouts.readthedocs.io/en/stable/
- Argo CD documentation: https://argo-cd.readthedocs.io/en/stable/

**Alternative CI/CD tools**
- GitLab CI/CD documentation: https://docs.gitlab.com/ee/ci/
- GitLab `.gitlab-ci.yml` keyword reference: https://docs.gitlab.com/ee/ci/yaml/
- GitHub Actions documentation: https://docs.github.com/en/actions
- GitHub Actions — Workflow syntax: https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions
- CircleCI configuration reference: https://circleci.com/docs/configuration-reference/
- Travis CI documentation: https://docs.travis-ci.com/
- Tekton Pipelines documentation: https://tekton.dev/docs/pipelines/
- Argo Workflows documentation: https://argo-workflows.readthedocs.io/en/latest/

**Practice and measurement**
- Google Cloud — DORA DevOps capabilities and metrics: https://dora.dev/capabilities/
- Google SRE Book — Release Engineering: https://sre.google/sre-book/release-engineering/
- OWASP Dependency-Check: https://owasp.org/www-project-dependency-check/