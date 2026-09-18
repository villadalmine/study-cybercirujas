# 701.4 Continuous Integration and Continuous Delivery

**LPI DevOps Tools Engineer — Exam 701-100, version 2.0.0 · Weight: 5**

---

## 1. The architectural problem: integration debt and the release bottleneck

Before automated integration existed, teams worked on long-lived branches and merged "when the feature was done". The cost of that model is not the merge itself — it is the *divergence integral*. Every hour a branch lives without being reconciled against `main`, the probability that some other change has invalidated an assumption grows, and the cost of discovering it grows with it. Two developers touching the same module for three weeks produce a merge whose conflict surface is quadratic in the number of edits, and whose *semantic* conflicts (the code merges cleanly and is still wrong) are invisible to `git`.

This is **integration debt**. Continuous Integration is not "a build server". It is the operational discipline of paying that debt down continuously by merging every developer's work into the mainline at least daily and proving, mechanically, that the mainline still works.

The second bottleneck is release. A team that integrates continuously but ships quarterly still batches risk: each release carries hundreds of changes, so when the error budget is consumed, the *mean time to identify* which change did it is proportional to the batch size. This is why the DORA research programme measures **deployment frequency** and **change failure rate** together — they are not independent. Small batches deployed often have a lower change failure rate than large batches deployed rarely, because the blast radius of any single change is smaller and the rollback is unambiguous.

The production symptoms you will be asked to diagnose:

| Symptom in production | Root cause in the delivery system |
|---|---|
| "Works on my machine", fails in CI | Build is not hermetic: it depends on host toolchain, ambient `~/.m2`, or network state |
| Release night takes 6 hours and needs three people | Deployment is not automated; the runbook lives in a wiki, not in code |
| Rollback means "restore the database backup" | Deployment strategy has no immutable previous version to switch back to |
| Nobody knows which commit is in production | No artifact identity: images tagged `latest`, no provenance metadata |
| A flaky test is muted "temporarily" and never re-enabled | The pipeline is not trusted, so its signal is discarded — the worst failure mode of CI |
| Hotfix bypasses the pipeline "because it's urgent" | The pipeline is too slow; speed *is* a reliability property |

The last two matter most. A pipeline that nobody trusts, or that is slow enough to be worth bypassing, is worse than no pipeline: it provides the appearance of verification while the actual verification is a human deciding to skip it.

### 1.1 The three terms, precisely

The exam objectives distinguish three concepts that are routinely conflated in industry:

| Term | Definition | Ends at | Human gate? |
|---|---|---|---|
| **Continuous Integration** | Every change is merged to mainline frequently and automatically built and tested | A verified build artifact | No gate — the build either passes or the mainline is broken and fixing it is the top priority |
| **Continuous Delivery** | Every change that passes CI is automatically promoted through environments and is *always in a deployable state* | A release candidate sitting in production-ready form | **Yes** — a human decides *when* to push the button |
| **Continuous Deployment** | Every change that passes the full pipeline goes to production automatically | Production | **No** — the pipeline is the only gate |

The distinction between the last two is exactly one thing: whether a human approval step exists between "proven good" and "serving traffic". Everything else — the pipeline, the tests, the artifacts, the deployment automation — is identical. This means **Continuous Deployment is a policy decision on top of Continuous Delivery, not a different architecture**. Organisations that cannot do continuous deployment usually cannot because of regulatory change-control requirements, not technical ones.

A fourth term you will meet in real systems, not in the objectives: **Progressive Delivery** — continuous deployment where the release is *gradual and automatically evaluated* (canary with metric analysis, feature flags). Covered in §9.

---

## 2. Anatomy of a pipeline

A pipeline is a directed acyclic graph of stages, where each stage consumes the artifacts of its predecessors and either promotes them or fails the run. The canonical shape:

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

Three architectural invariants make this work, and violating any one of them is the usual root cause when a pipeline "passes but production breaks":

**Invariant 1 — Build once, promote the binary.** The artifact that is tested in staging must be bit-for-bit the artifact deployed to production. If the pipeline rebuilds per environment, staging has verified a *different* artifact than the one you shipped. Environment differences belong in configuration injected at deploy time (ConfigMaps, Secrets, environment variables), never in the build.

**Invariant 2 — The pipeline definition is versioned with the code.** `Jenkinsfile`, `.gitlab-ci.yml`, `.github/workflows/*.yml` live in the repository. A pipeline configured through a web UI cannot be reviewed, cannot be rolled back, and cannot differ per branch — which means you cannot change the build process in a feature branch without breaking everyone else's.

**Invariant 3 — Fail fast, ordered by cost.** Stages are ordered by (probability of catching a defect) ÷ (seconds spent). Compilation and linting run before unit tests; unit tests before integration tests; integration before end-to-end. A 40-minute end-to-end suite that runs before a 4-second linter wastes 40 minutes on every typo.

### 2.1 The test pyramid as a pipeline scheduling problem

| Layer | Scope | Typical count | Runtime budget | Where in the pipeline |
|---|---|---|---|---|
| Static analysis / lint | Single file | — | < 30 s | Pre-commit hook + first CI stage |
| Unit | Single class/function, no I/O | 10³–10⁴ | < 3 min total, parallelised | Stage 2, blocks everything |
| Integration | Component + real dependency (DB, broker) | 10²–10³ | < 15 min | After packaging, against ephemeral deps |
| Contract | API producer/consumer compatibility | 10¹–10² | < 5 min | Before deploying either side |
| End-to-end / acceptance | Whole system through the UI or public API | 10¹ | < 30 min | Staging only |
| Performance / soak | Whole system under load | 1–5 scenarios | Hours | Nightly or pre-release, not per commit |

The SRE reading of this table: **the pyramid is a latency budget, not a quality hierarchy.** An inverted pyramid (many E2E tests, few unit tests) produces a pipeline with a 90-minute feedback loop and a high flake rate, and the team responds rationally by ignoring it.

### 2.2 Trunk-based development vs. long-lived branches

| Property | Trunk-based (+ short-lived branches) | GitFlow / long-lived release branches |
|---|---|---|
| Branch lifetime | Hours to 2 days | Weeks to months |
| Merge conflict cost | Low, linear | High, superlinear |
| CI meaning | Mainline is always releasable | "develop" is releasable; `main` lags |
| Incomplete features | Hidden behind feature flags | Held in the branch |
| Rollback granularity | One commit | One release |
| Fits CD? | Yes, natively | Only with a release-branch pipeline; continuous deployment is impossible |
| Cost | Requires feature flags and discipline | Requires cherry-pick archaeology for hotfixes |

Continuous Integration in its strict definition (merge to mainline at least daily) is **incompatible** with long-lived feature branches. If your branches live for three weeks, you have automated builds — a useful thing — but you do not have CI.

---

## 3. Artifact repositories

An artifact repository is the boundary between "code" and "thing that runs". Its job is four-fold:

1. **Immutable identity.** Once `com.example:checkout:1.4.2` is published, its bytes never change. This is what makes "test in staging, ship to production" a meaningful sentence.
2. **Dependency proxy and cache.** Builds must not depend on the availability of Maven Central, npmjs.com or Docker Hub. A remote-proxy repository turns a third-party outage from a build outage into a cache hit, and protects you from rate limits.
3. **Promotion.** Artifacts move between repositories (`snapshots` → `staging` → `releases`) as they accumulate evidence. Promotion is a metadata operation, not a rebuild.
4. **Provenance and retention.** Who built it, from which commit, with which dependencies (SBOM), and when does it get garbage-collected.

| Concern | Sonatype Nexus Repository | JFrog Artifactory | OCI registry (Harbor / Quay / ECR) | Language-native (Maven Central, npmjs) |
|---|---|---|---|---|
| Format coverage | Maven, npm, PyPI, NuGet, Docker, raw, apt/yum | Same, plus Go, Conan, Helm, Debian, generic | OCI artifacts only (images, Helm charts, SBOMs, WASM) | One format |
| Deployment model | Self-hosted (OSS + Pro) | Self-hosted or SaaS | Self-hosted or cloud-managed | SaaS, public |
| High availability | Pro edition | Enterprise edition | Native (stateless + object storage) | N/A |
| Promotion model | Repository move / staging plugin | Build promotion API, properties | Tag copy or registry replication | None |
| Vulnerability scanning | IQ Server (separate product) | Xray (separate product) | Trivy/Clair built into Harbor | None |
| Metadata/provenance | Limited | Build-info (rich) | OCI referrers, cosign attestations | None |
| Best for | Java/polyglot shops, cost-sensitive | Large enterprises, heavy metadata needs | Container-native platforms | Publishing open source |

### 3.1 Snapshot vs. release semantics

In Maven terms — and the concept generalises — a **SNAPSHOT** version (`1.4.3-SNAPSHOT`) is mutable: every CI build overwrites it, and consumers resolve the newest. A **release** version (`1.4.2`) is immutable and must be rejected if re-deployed. Repository managers enforce this with a deployment policy:

| Repository | Version policy | Deployment policy | Purpose |
|---|---|---|---|
| `maven-snapshots` | Snapshot | Allow redeploy | CI feedback between teams, garbage-collected aggressively |
| `maven-releases` | Release | **Disable redeploy** | Immutable, retained indefinitely |
| `maven-central-proxy` | Mixed | Read-only proxy | Cache + outage insulation |
| `maven-public` (group) | — | — | Single URL clients point at; ordered union of the above |

The equivalent anti-pattern in container land is the tag `latest`, which is a mutable pointer. **Deploy by digest, not by tag**, in anything that must be reproducible:

```
$ crane digest ghcr.io/example/checkout:1.4.2
sha256:6c1e6ba8d2f2c8f0f5e4d1a9bd3c7b21b0f5a4d8e3c2b1a09f8e7d6c5b4a3921

$ kubectl -n prod set image deploy/checkout \
    checkout=ghcr.io/example/checkout@sha256:6c1e6ba8d2f2c8f0f5e4d1a9bd3c7b21b0f5a4d8e3c2b1a09f8e7d6c5b4a3921
deployment.apps/checkout image updated
```

### 3.2 Nexus repository configuration as code

Nexus exposes a Groovy scripting API (and, in recent versions, a REST API) so repository topology is not clicked into existence:

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

`WritePolicy.ALLOW_ONCE` is the invariant that makes releases immutable. Note the group's member order: hosted repositories are searched before the proxy, so a locally published artifact always wins over an upstream one of the same coordinates — the defence against dependency-confusion attacks.

Client side, the build must be pointed at the group URL and nothing else, so no build ever reaches the public internet directly:

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

Verification that the mirror is actually being used — a check worth putting in the pipeline, because a misconfigured mirror fails open:

```
$ mvn -B -s /etc/maven/settings.xml dependency:resolve 2>&1 | grep -c 'repo1.maven.org'
0
$ mvn -B -s /etc/maven/settings.xml dependency:resolve 2>&1 | grep -m1 'Downloaded from'
Downloaded from nexus: https://nexus.example.com/repository/maven-public/org/slf4j/slf4j-api/2.0.13/slf4j-api-2.0.13.jar (68 kB at 2.1 MB/s)
```

---

## 4. Jenkins architecture

Jenkins is the reference implementation the exam is built around. Understanding its architecture matters more than memorising menu paths.

### 4.1 Controller and agents

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

Key properties:

- **`JENKINS_HOME` is the entire state.** Job configs, build history, plugins, credentials, secrets keys. Backing up Jenkins means backing up this directory (minus `workspace/` and `caches/`). Losing `$JENKINS_HOME/secrets/master.key` and `hudson.util.Secret` makes every stored credential unrecoverable.
- **The controller must not build.** Set `numExecutors: 0`. A build running on the controller has filesystem access to `JENKINS_HOME`, i.e. to every credential Jenkins holds. This is the single most common Jenkins security failure.
- **Two connection directions.** *Outbound*: the controller SSHes into the agent and launches `remoting.jar` (`SSHLauncher`). *Inbound* (formerly "JNLP"): the agent initiates the connection to the controller's TCP port (default 50000) — required when agents are behind NAT or are ephemeral pods.
- **Executors** are the unit of concurrency. One executor runs one build at a time. Agent capacity = number of executors, not CPU count; over-provisioning executors turns a build queue into a thrashing machine.
- **Labels** are how a pipeline requests capability (`agent { label 'linux && docker' }`). Label expressions support `&&`, `||`, `!`.

### 4.2 Static agents vs. ephemeral agents

| Property | Static VM agents | Docker-based agents | Kubernetes pod agents |
|---|---|---|---|
| Build isolation | None — state leaks between builds | Per-container | Per-pod, plus namespace/RBAC isolation |
| Toolchain drift | High: someone `apt install`s something | None: image is the toolchain | None |
| Startup latency | Zero (always on) | ~2–5 s | ~10–40 s (image pull, scheduling) |
| Cost when idle | Full | Low | Zero |
| Scaling | Manual | Host-bound | Cluster autoscaler |
| Caching | Trivially warm | Volume mounts | PVC or remote cache (needs design) |
| Best for | Licensed tools, specialised hardware | Single-host installs | Anything at scale |

The dominant production pattern is Kubernetes pod agents: each build gets a fresh pod whose containers *are* the declared toolchain, and which is destroyed afterwards. Toolchain drift — the number one cause of "it built yesterday" — becomes structurally impossible.

### 4.3 Jenkins on Kubernetes: complete manifests

Controller `StatefulSet` plus the RBAC the Kubernetes plugin needs to create agent pods:

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

Note `-Djenkins.install.runSetupWizard=false`: without it the controller boots into the "unlock Jenkins" screen and JCasC never applies.

### 4.4 Configuration as Code (JCasC)

The `jenkins-casc` ConfigMap referenced above. This replaces the entire "Manage Jenkins" UI with a reviewable file — the same Invariant 2 applied to the CI server itself:

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

`${JENKINS_ADMIN_PASSWORD}` and `${NEXUS_PASSWORD}` are resolved by JCasC from environment variables or from files in a directory pointed at by `SECRETS` — never committed literally.

Applying and verifying:

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

If the file is malformed, JCasC fails *loudly* and Jenkins refuses the configuration rather than partially applying it — which is the behaviour you want:

```
2026-09-18 09:20:44.118+0000 [id=41]  SEVERE  i.j.p.casc.ConfigurationAsCode#configureWith:
io.jenkins.plugins.casc.ConfiguratorException: No configurator for the following root elements clods
```

---

## 5. Jenkins jobs and the Jenkinsfile

### 5.1 Job types

| Job type | Definition lives in | Multi-branch | When to use |
|---|---|---|---|
| Freestyle | Jenkins UI/`config.xml` | No | Legacy only; unreviewable |
| Pipeline | `Jenkinsfile` in SCM (or inline) | No | Single-branch pipelines |
| Multibranch Pipeline | `Jenkinsfile` per branch | Yes — auto-discovers branches and PRs | **Default choice** |
| Organization Folder | `Jenkinsfile` per repo | Yes — auto-discovers repos | Whole GitHub org / GitLab group |
| Matrix (multi-configuration) | UI | No | Superseded by declarative `matrix` |

A Multibranch Pipeline scans the repository, creates a job for every branch containing a `Jenkinsfile`, and deletes it when the branch disappears. This is what makes "the pipeline is versioned with the code" operational: a feature branch can change its own build without affecting `main`.

### 5.2 Declarative vs. scripted pipeline

Both are Groovy running on the **CPS (Continuation Passing Style)** engine, which is what allows a pipeline to survive a controller restart: the execution state is serialised to disk at every step boundary. This is also the source of Jenkins' most confusing errors — non-serialisable local variables (`java.io.NotSerializableException`) and non-CPS-transformable constructs.

| Aspect | Declarative | Scripted |
|---|---|---|
| Entry point | `pipeline { }` | `node { }` |
| Structure | Fixed schema, validated before execution | Arbitrary Groovy |
| Validation | `declarative-linter` catches errors pre-run | Errors appear at runtime |
| Error handling | `post { always / success / failure / unstable / aborted / cleanup }` | `try/catch/finally` |
| Restart from stage | Supported | Not supported |
| Blue Ocean editor | Supported | Read-only |
| Escape hatch | `script { }` block | N/A — it's all script |
| Recommended for | Everything | Complex dynamic logic, shared library internals |

**Use declarative.** Push complexity into a shared library, not into `script { }` blocks.

### 5.3 A complete production Jenkinsfile

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

Points that separate this from a tutorial pipeline:

- `agent none` at the top plus per-stage agents: no executor is held while waiting at the `input` step. A pipeline that holds an agent through a 24-hour approval gate will deadlock the queue.
- `disableConcurrentBuilds(abortPrevious: true)`: a new push supersedes the in-flight build for the same branch.
- The image is published by tag but **deployed by digest** (`env.IMAGE_DIGEST`) — Invariant 1 enforced mechanically.
- `credentials('nexus')` in `environment` binds `NEXUS_CREDS_USR` and `NEXUS_CREDS_PSW`, and Jenkins masks both in the console log.
- `post { cleanup }` runs regardless of outcome, including on abort.

### 5.4 The `matrix` directive

For cross-platform or cross-version builds, declarative `matrix` replaces the old multi-configuration job:

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

The matrix expands to |JDK| × |DB| − |excludes| = 3 × 2 − 1 = 5 parallel cells.

### 5.5 Shared libraries

The `deployToEnvironment` step above is not a plugin — it is a shared library global variable. Layout of the library repository:

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

This is how a platform team gives fifty repositories the same deployment semantics without fifty copies of the same 200 lines. Versioning is by Git ref (`@Library('platform-pipeline@v3')`), so a library change cannot silently alter every pipeline at once.

### 5.6 Blue Ocean (awareness)

Blue Ocean is an alternative Jenkins UI focused on pipeline visualisation: stages rendered as a horizontal graph, per-stage logs, parallel branches shown side by side, and inline display of test failures and SCM changes. It also ships a visual Jenkinsfile editor for **declarative** pipelines (scripted pipelines are read-only in it) and first-class handling of multibranch projects and pull requests.

Operationally, Blue Ocean is **feature-complete but no longer actively developed**; the Jenkins project recommends the modernised classic UI and the Pipeline Graph View plugin for new installations. For the exam, know what it is and what it shows; for production, do not build a workflow that depends on it.

```
$ curl -s -u "$JENKINS_AUTH" \
    "$JENKINS_URL/blue/rest/organizations/jenkins/pipelines/checkout/branches/main/runs/?start=0&limit=2"
```

---

## 6. Triggering the pipeline: Git hooks and webhooks

### 6.1 The hook taxonomy

Git hooks are executable files in `$GIT_DIR/hooks/` (client) or on the server. They are **not** versioned with the repository by default — `.git/hooks/` is outside the working tree — which is why teams use `core.hooksPath` or a manager like `pre-commit` to distribute them.

| Hook | Runs on | When | Can abort? | Typical CI use |
|---|---|---|---|---|
| `pre-commit` | Client | Before the commit message editor | Yes | Format, lint, secret scan |
| `commit-msg` | Client | After the message is written | Yes | Enforce Conventional Commits / ticket ID |
| `pre-push` | Client | Before objects are sent | Yes | Run the fast unit subset |
| `pre-receive` | **Server** | Once, before any ref is updated | Yes (rejects the whole push) | Policy: signed commits, protected branches, file size |
| `update` | Server | Once **per ref** | Yes (rejects that ref) | Per-branch permissions |
| `post-receive` | Server | After all refs are updated | No | **Trigger CI**, notify, mirror |

The exam-relevant architectural point: **client-side hooks are advisory, server-side hooks are policy.** Any developer can bypass a client hook with `git commit --no-verify`. Only `pre-receive`/`update` can actually enforce anything.

### 6.2 A production `pre-receive` hook

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

| Property | `pollSCM` | Webhook (`post-receive` / GitHub / GitLab) |
|---|---|---|
| Latency | Up to the poll interval | Seconds |
| Load on SCM | O(jobs × polls) — thousands of `git ls-remote` per hour | O(pushes) |
| Fires when nothing changed | Yes (a request per interval) | No |
| Works behind a firewall | Yes | Needs inbound reachability or a relay |
| Failure mode | Silent delay | Silent *never* — a dropped webhook means no build at all |

Use webhooks as the primary trigger and a wide-interval `pollSCM` as the safety net, exactly as in the Jenkinsfile above. `H/15 * * * *` — the `H` is Jenkins' hash-based spread, which distributes the poll across the interval per-job so five hundred jobs do not all hit the SCM at `:00`.

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

## 7. Alternative CI/CD tools

| Tool | Execution model | Config file | Runners | Self-hosted | Distinguishing property |
|---|---|---|---|---|---|
| **Jenkins** | Controller + agents, plugin-driven | `Jenkinsfile` (Groovy) | Any: SSH, Docker, K8s | Yes (only) | ~1 900 plugins; can build anything, including 30-year-old toolchains. Cost: plugin supply chain and upgrade risk |
| **GitLab CI/CD** | Coordinator inside GitLab + runners | `.gitlab-ci.yml` (YAML) | Docker, shell, K8s, VM | Yes or SaaS | Tightest SCM integration: MR pipelines, environments, registry, review apps in one product |
| **GitHub Actions** | GitHub-hosted or self-hosted runners | `.github/workflows/*.yml` | GitHub-hosted, self-hosted | Runners yes, control plane no (unless GHES) | Marketplace of reusable actions; OIDC federation to cloud IAM without long-lived keys |
| **CircleCI** | SaaS orchestrator | `.circleci/config.yml` | Cloud (Docker/VM/macOS), self-hosted runners | Runners only | Orbs (reusable config packages), strong caching and test splitting primitives |
| **Travis CI** | SaaS | `.travis.yml` | Cloud | `travis-ci.com` only | The original hosted CI for open source; largely displaced by Actions. Know it exists — the exam names it |
| **Tekton** | Kubernetes CRDs; each step is a container | `Task` / `Pipeline` CRs | Kubernetes pods | Yes | Cloud-native primitive, not a product: no UI, no SCM. A building block for a platform |
| **Argo Workflows** | Kubernetes CRDs, DAG engine | `Workflow` CRs | Kubernetes pods | Yes | General workflow engine (CI is one use); excellent fan-out/fan-in |
| **Drone / Woodpecker** | Container-native, lightweight | `.drone.yml` | Docker, K8s | Yes | Minimal footprint; every step is a container, no plugin runtime |

**How to choose, as an architect:**

- *You already live in one forge* (GitLab, GitHub) → use its native CI. The integration value (MR status, environments, secrets, package registry) exceeds any feature gap.
- *You need heterogeneous build environments* — Windows, macOS, mainframe, licensed EDA tools → Jenkins, because the agent model is transport-agnostic.
- *You are building a platform other teams consume* → Tekton or Argo Workflows underneath your own abstraction; you want CRDs and RBAC, not a UI.
- *You need audited approval gates and change records* → Jenkins or GitLab with protected environments; SaaS-only tools often cannot satisfy on-prem audit requirements.

### 7.1 The same pipeline in GitLab CI

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

`when: manual` on `deploy-production` is exactly the Continuous Delivery gate from §1.1. Remove it and the same file becomes Continuous Deployment.

### 7.2 The same shape in GitHub Actions

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

Note `id-token: write`: it enables OIDC, letting the job exchange a short-lived GitHub token for cloud credentials instead of storing a static access key — the modern answer to "where do CI secrets live".

---

## 8. Deployment strategies

This is where CD stops being about builds and becomes about availability. The choice of strategy determines your blast radius, your rollback time, and your infrastructure cost.

| Strategy | Versions live at once | Downtime | Rollback time | Extra capacity | Traffic control needed | Blast radius during rollout |
|---|---|---|---|---|---|---|
| **Recreate** | 1 | Yes (full) | Redeploy old (minutes) | 0 % | None | 100 % during the gap |
| **Rolling update** | 2 (mixed) | No | Reverse rollout (minutes) | `maxSurge` (e.g. 25 %) | None | Grows to 100 % if the new version is broken |
| **Blue-green** | 2 (only one serving) | No | **Instant** (flip the selector) | 100 % | Service selector / LB switch | 0 % until the flip, then 100 % |
| **Canary** | 2 (both serving, weighted) | No | Instant (weight → 0) | Small (1 pod) | Weighted routing (Ingress/mesh) | Bounded by the weight |
| **A/B testing** | 2+ (routed by attribute) | No | Instant | Small | Header/cookie routing | Bounded by the cohort |
| **Shadow / dark launch** | 2 (one receives mirrored traffic, returns nothing) | No | Stop mirroring | 100 % of the shadow's load | Traffic mirroring | 0 % — responses are discarded |

The two that matter most in the exam and in practice:

**Blue-green** gives you an instantaneous, binary rollback, at the cost of running two full environments. Its hidden trap is *state*: the database is not blue-green. Schema changes must be **backward compatible** so that blue and green can both run against it — the expand/contract (parallel change) pattern: add the new column, deploy code that writes both and reads the new, backfill, deploy code that reads only the new, drop the old column. Four deployments to rename a column, and there is no shortcut if you want a working rollback.

**Canary** gives you *bounded* blast radius and a real signal, at the cost of needing weighted traffic routing and enough traffic volume for the metrics to be statistically meaningful. A canary at 1 % of 100 requests/day tells you nothing.

### 8.1 Rolling update, fully specified

The default in Kubernetes, and the one most often misconfigured. The parameters that actually matter:

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

Why each non-obvious field is there:

- `maxUnavailable: 0` + `maxSurge: 2` — capacity never dips below `replicas` during the rollout. With `maxUnavailable: 1` (the default is 25 %) you deliberately run degraded during every deploy.
- `minReadySeconds: 20` — a pod must stay Ready for 20 s before the rollout counts it. Catches the container that passes its first probe and then crashes.
- `progressDeadlineSeconds: 600` — after 10 minutes without progress the Deployment is marked `Failed`, which is what `kubectl rollout status` waits on. Without it, a stuck rollout hangs your pipeline until the job timeout.
- `preStop: sleep 10` + `terminationGracePeriodSeconds: 60` — endpoint removal and SIGTERM race each other. The sleep lets every proxy/kube-proxy/ingress observe the endpoint removal *before* the process starts shutting down. This is the fix for the "a few 502s on every deploy" ticket.
- The PDB protects the same workload from *voluntary* disruption (node drains), which is a different axis from the rollout.

### 8.2 Blue-green with a Service selector flip

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

The cutover and its rollback are one command each:

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

Rollback latency here is the Service endpoint propagation time — single-digit seconds — versus minutes for a reverse rolling update. That difference is the entire justification for the doubled capacity.

### 8.3 Automated canary with Argo Rollouts

Manual canaries do not scale: someone has to watch a dashboard. Progressive delivery controllers evaluate the metrics themselves and abort:

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

The three PromQL lines and the four `histogram_quantile` lines are all indented to the same column inside the `|` block scalar — a single line indented less would terminate the scalar and make the document invalid.

Watching it run:

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

When analysis fails, the controller aborts without human intervention:

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

Exit code 1 is what makes it a pipeline gate: the deploy stage fails, Slack fires, and production is already back on the stable version.

### 8.4 GitOps: push vs. pull

| | Push (CI deploys) | Pull (GitOps) |
|---|---|---|
| Who talks to the cluster | The CI runner | An in-cluster controller (Argo CD, Flux) |
| Credentials | Cluster admin kubeconfig stored in CI | None outbound; the controller has in-cluster RBAC |
| Drift detection | None — manual `kubectl edit` persists | Continuous reconciliation, drift reverted |
| Source of truth | Whatever last ran | The Git repository |
| Audit trail | CI build logs | Git history |
| Rollback | Re-run an old pipeline | `git revert` |
| Failure mode | Runner network path to every cluster | Controller must reach Git and the registry |

The security argument is decisive at scale: push mode requires your CI system — a machine that executes arbitrary code from pull requests — to hold production cluster credentials. Pull mode inverts it. The pipeline's last step becomes a commit to a manifests repository:

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

## 9. Verification and failure diagnosis

### 9.1 Verifying the Jenkins installation

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

Checking that the controller has no executors (the security invariant from §4.1):

```
$ curl -s -u "$JENKINS_AUTH" "$JENKINS_URL/computer/(master)/api/json?tree=numExecutors" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["numExecutors"])'
0
```

Validating a Jenkinsfile *before* pushing — this belongs in a `pre-push` hook:

```
$ java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" declarative-linter < Jenkinsfile
Jenkinsfile successfully validated.

$ java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth "$JENKINS_AUTH" declarative-linter < Jenkinsfile
Errors encountered validating Jenkinsfile:
WorkflowScript: 58: Expected one of "steps", "stages", "parallel", or "matrix" for stage "Deploy" @ line 58, column 9.
           stage('Deploy') {
           ^
```

Or over HTTP, when the CLI jar is not available:

```
$ CRUMB=$(curl -s -u "$JENKINS_AUTH" "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
$ curl -s -u "$JENKINS_AUTH" -H "$CRUMB" \
    -X POST -F "jenkinsfile=<Jenkinsfile" \
    "$JENKINS_URL/pipeline-model-converter/validate"
Jenkinsfile successfully validated.
```

### 9.2 Diagnosing agent connection failures

Symptom: builds sit in the queue forever with "waiting for next available executor on 'maven'".

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

The decision table for agent failures:

| Observation | Cause | Fix |
|---|---|---|
| Agent pod stays `Pending` | Unschedulable: resource requests, taints, no node | Check `describe pod` events; reduce requests or add capacity |
| Pod `Running` but Jenkins shows the node offline | Agent cannot reach `jenkinsTunnel` on :50000 | Verify the `jenkins-agent` Service and any NetworkPolicy |
| `ImagePullBackOff` on the agent image | Registry rate limit or missing pull secret | Use a proxy/mirror registry; add `imagePullSecrets` |
| `SEVERE: Connection refused` in agent log | Wrong `jenkinsUrl` in the cloud config | Must be the in-cluster Service DNS, not the public Ingress |
| Agent connects then immediately disconnects | Remoting version mismatch controller ↔ agent | Align the `inbound-agent` image with the controller LTS |
| Pods created but capped | `containerCapStr` reached | Raise the cap or fix leaked pods |

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

### 9.3 Diagnosing a failed deployment

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

That trace is the expand/contract failure from §8: application code shipped ahead of the migration. The systemic fix is not "be more careful" — it is to make the pipeline run migrations as a separate, backward-compatible, previously-deployed step.

### 9.4 The pipeline failure decision table

| Failure mode | Discriminating evidence | Remediation |
|---|---|---|
| Build passes locally, fails in CI | CI agent has a different toolchain | Pin the toolchain in a container image; make the build hermetic |
| Build fails only in CI intermittently | Shared mutable state between builds (workspace, cache, port) | Ephemeral agents; unique ports; `cleanWs()` |
| Test passes alone, fails in the suite | Test order dependence / shared fixture | Randomise test order in CI to surface it deliberately |
| Same commit, different results | Unpinned dependency (`^1.2.0`, `:latest`) | Lockfiles; deploy by digest |
| Build hangs at 100 % of the timeout | Deadlock, or a step waiting on stdin | `timeout` option per stage; never run interactive tools |
| `java.io.NotSerializableException` in a pipeline | A non-serialisable object held across a CPS step boundary | Wrap in a `@NonCPS` method or scope it inside `script { }` and null it |
| Secrets appear in the console log | Value not bound through the credentials store | Use `withCredentials`/`credentials()`; Jenkins masks only what it injected |
| Pipeline succeeds, production breaks | Staging is not production-like, or config drifted | Same artifact, config as code, GitOps reconciliation |
| Everything is slow after 6 months | Build history / workspaces / Docker layer cache growth | `buildDiscarder`, agent image GC, monitor `JENKINS_HOME` size |

```
$ kubectl -n jenkins exec jenkins-0 -- du -sh /var/jenkins_home/* 2>/dev/null | sort -rh | head -6
58G	/var/jenkins_home/jobs
12G	/var/jenkins_home/workspace
2.1G	/var/jenkins_home/caches
340M	/var/jenkins_home/plugins
96M	/var/jenkins_home/war
12M	/var/jenkins_home/logs
```

58 GB under `jobs/` means build history retention was never configured. `buildDiscarder(logRotator(numToKeepStr: '30'))` in `options` is not cosmetic — an oversized `JENKINS_HOME` makes controller restarts take tens of minutes because Jenkins lazily indexes build records at startup.

### 9.5 The four signals a delivery system must expose

If you cannot answer these from a dashboard, you are operating blind:

| Signal | Query | Target (DORA "elite") |
|---|---|---|
| Deployment frequency | Count of production deploy events per day | On demand, multiple per day |
| Lead time for change | `deploy_timestamp − commit_timestamp`, p50 and p90 | < 1 hour |
| Change failure rate | Deploys followed by a rollback or incident ÷ total deploys | 0–15 % |
| Time to restore service | Incident start → resolution | < 1 hour |

Plus two CI-internal ones: **pipeline duration p90** (the number the team actually feels) and **flake rate** (tests failing on retry with no code change). A flake rate above ~1 % destroys trust in the pipeline, and a distrusted pipeline gets bypassed — which returns you to §1.

---

## 10. Exam-focused summary

- **CI** = merge to mainline frequently + automatic build and test. **CD (Delivery)** = always deployable, human decides when. **CD (Deployment)** = the pipeline decides.
- Pipeline stages, in order: build → test → package → deploy → verify. Build once, promote the same artifact.
- **Artifact repositories** (Nexus, Artifactory) give artifacts immutable identity, proxy upstream registries, and support promotion between snapshot and release repositories.
- **Jenkins architecture**: a controller holding all state in `JENKINS_HOME`, plus agents connected outbound (SSH) or inbound (port 50000). Executors are the unit of concurrency; labels are how jobs select agents. The controller must have zero executors.
- **Jenkins jobs**: Freestyle (legacy), Pipeline, Multibranch Pipeline (discovers branches and PRs), Organization Folder.
- **Jenkinsfile**: declarative (`pipeline { agent / stages / steps / post }`) or scripted (`node { }`). Declarative is validated before execution and supports restart-from-stage.
- **Plugins** are how Jenkins does everything: `git`, `workflow-aggregator` (Pipeline), `kubernetes` (dynamic agents), `credentials-binding`, `junit`, `blueocean`, `configuration-as-code`.
- **Blue Ocean** is the pipeline-focused alternative UI with a visual editor for declarative pipelines; feature-complete, not actively developed.
- **Git hooks**: client-side (`pre-commit`, `commit-msg`, `pre-push`) are bypassable with `--no-verify`; server-side (`pre-receive`, `update`, `post-receive`) are enforceable. `post-receive` is the classic CI trigger; webhooks beat polling.
- **Alternatives**: GitLab CI (`.gitlab-ci.yml`), GitHub Actions (`.github/workflows/`), CircleCI (`.circleci/config.yml`), Travis CI (`.travis.yml`), Tekton and Argo Workflows (Kubernetes-native).
- **Deployment strategies**: recreate, rolling, blue-green (instant rollback, double capacity), canary (bounded blast radius, needs traffic weighting), A/B, shadow.

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