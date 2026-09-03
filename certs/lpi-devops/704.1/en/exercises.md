# 704.1 Cloud Native Security — Guided Exercises

> **Exam:** LPI DevOps Tools Engineer 701-100, v2.0.0 — Objective 704.1 (weight 6.67)
> **Official objective list:** <https://www.lpi.org/our-certifications/exam-701-objectives/>
>
> These exercises are hands-on. Every step is meant to be typed and its output read. The questions after each block are not rhetorical — if you cannot answer them from what you just saw on screen, re-run the step before moving on.

---

## Lab environment

You need a Linux host (kernel ≥ 5.8 for the eBPF exercise), with:

| Tool | Minimum | Purpose |
|---|---|---|
| `podman` or `docker` | 4.x / 24.x | container runtime exercises |
| `kind` | 0.23+ | throwaway Kubernetes cluster |
| `kubectl` | matching the cluster minor | cluster exercises |
| `trivy` | 0.50+ | vulnerability + misconfig scanning |
| `syft` / `grype` | 1.x / 0.7x | SBOM generation and consumption |
| `cosign` | 2.x | signing and verification |
| `helm` | 3.x | Kyverno / Falco installation |
| `jq`, `capsh` (`libcap`), `openssl` | — | inspection |

### Step 0 — build the cluster

The default `kind` CNI (`kindnetd`) does **not** enforce `NetworkPolicy`. Exercise 7 depends on enforcement, so the cluster is built without a CNI and Calico is installed instead.

```bash
cat > kind-704.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
  - role: worker
EOF

kind create cluster --name sec704 --config kind-704.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
kubectl get nodes
```

Expected:

```
NAME                  STATUS   ROLES           AGE   VERSION
sec704-control-plane  Ready    control-plane   96s   v1.31.0
sec704-worker         Ready    <none>          72s   v1.31.0
```

> Reference: <https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart>

---

## Exercise 1 — Mapping the attack surface with the 4Cs

Cloud Native security is layered: **Cloud → Cluster → Container → Code**. Each layer can only be as secure as the one beneath it. This exercise establishes the baseline you will harden in the rest of the document.

**Steps**

1. Start an unhardened container and look at who you are inside it:

   ```bash
   podman run --rm -it docker.io/library/nginx:1.27 id
   ```

   ```
   uid=0(root) gid=0(root) groups=0(root)
   ```

2. Inspect the effective capability set of PID 1 inside a *rootful* Docker container:

   ```bash
   docker run --rm docker.io/library/nginx:1.27 grep Cap /proc/1/status
   ```

   ```
   CapInh: 0000000000000000
   CapPrm: 00000000a80425fb
   CapEff: 00000000a80425fb
   CapBnd: 00000000a80425fb
   CapAmb: 0000000000000000
   ```

3. Decode that bitmask into names:

   ```bash
   capsh --decode=00000000a80425fb
   ```

   ```
   0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,
   cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,
   cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
   ```

4. Repeat with Podman and compare:

   ```bash
   podman run --rm docker.io/library/nginx:1.27 grep CapEff /proc/1/status
   ```

   ```
   CapEff: 00000000800405fb
   ```

5. Now break the container boundary on purpose, to see what "privileged" really means:

   ```bash
   docker run --rm --privileged docker.io/library/alpine:3.20 \
     sh -c 'ls /dev/ | head -5; grep CapEff /proc/1/status'
   ```

   ```
   autofs
   bsg
   btrfs-control
   bus
   console
   CapEff: 000001ffffffffff
   ```

6. Demonstrate the host filesystem is one flag away:

   ```bash
   docker run --rm -v /:/host:ro docker.io/library/alpine:3.20 \
     cat /host/etc/shadow | head -2
   ```

**Check your understanding**

- **Q1.1** — Step 2 shows 14 capabilities, not the full 40+. Which security principle does that default represent, and why is it still *not* enough for a production workload?
- **Q1.2** — Podman's effective set in step 4 differs from Docker's. Which capabilities are missing, and what practical consequence does dropping `CAP_NET_RAW` have?
- **Q1.3** — In step 5, `CapEff` is all bits set *and* the host device nodes are visible. Name two additional isolation mechanisms that `--privileged` disables besides capabilities.
- **Q1.4** — Step 6 mounts the host root read-only, yet it is still a critical finding. Map this to one of the 4Cs and explain which control (not which tool) should have prevented it.

---

## Exercise 2 — Reducing the image attack surface

You cannot patch a vulnerability in a package that is not installed. This exercise measures that claim.

**Steps**

1. Create a trivially insecure image:

   ```bash
   mkdir -p ~/lab/app && cd ~/lab/app
   cat > main.go <<'EOF'
   package main

   import (
       "fmt"
       "net/http"
   )

   func main() {
       http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
           fmt.Fprintln(w, "ok")
       })
       http.ListenAndServe(":8080", nil)
   }
   EOF

   cat > Containerfile.bad <<'EOF'
   FROM golang:1.22
   WORKDIR /src
   COPY main.go .
   RUN go mod init app && go build -o /app .
   EXPOSE 8080
   CMD ["/app"]
   EOF

   podman build -f Containerfile.bad -t localhost/app:bad .
   ```

2. Rewrite it as a multi-stage build on a distroless base with a numeric non-root user:

   ```bash
   cat > Containerfile.good <<'EOF'
   FROM golang:1.22 AS build
   WORKDIR /src
   COPY main.go .
   RUN go mod init app && \
       CGO_ENABLED=0 GOFLAGS=-trimpath go build -ldflags="-s -w" -o /app .

   FROM gcr.io/distroless/static-debian12:nonroot
   COPY --from=build /app /app
   USER 65532:65532
   EXPOSE 8080
   ENTRYPOINT ["/app"]
   EOF

   podman build -f Containerfile.good -t localhost/app:good .
   ```

3. Compare size and content:

   ```bash
   podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep localhost/app
   ```

   ```
   localhost/app:bad     897 MB
   localhost/app:good    6.42 MB
   ```

4. Try to get an interactive shell in each:

   ```bash
   podman run --rm -it localhost/app:bad  /bin/sh -c 'id; which curl wget apt'
   podman run --rm -it localhost/app:good /bin/sh
   ```

   The second fails:

   ```
   Error: crun: executable file `/bin/sh` not found in $PATH: No such file or directory: OCI runtime attempted to invoke a command that was not found
   ```

5. Confirm the runtime identity of the hardened image:

   ```bash
   podman inspect localhost/app:good --format '{{.Config.User}}'
   ```

   ```
   65532:65532
   ```

6. Pin by digest instead of by tag — record the immutable reference:

   ```bash
   podman image inspect localhost/app:good --format '{{index .RepoDigests 0}}' 2>/dev/null || \
     podman inspect localhost/app:good --format '{{.Digest}}'
   ```

   ```
   sha256:0a5b1f6e0b9c4c4d5c4b8a2d4b8f8c1a9d3e6f2b7c8d9e0f1a2b3c4d5e6f7a8b
   ```

**Check your understanding**

- **Q2.1** — Step 4's failure is often reported as a bug by developers. Explain, in incident-response terms, why the absence of `/bin/sh` is a *feature*, and name one debugging technique that still works.
- **Q2.2** — Why does the `Containerfile.good` build set `CGO_ENABLED=0`, and what would break in the distroless `static` base if it were left at the default?
- **Q2.3** — `USER 65532:65532` uses a numeric UID rather than `USER nonroot`. Which Kubernetes admission check depends on that distinction? (You will confirm this empirically in Exercise 10.)
- **Q2.4** — Both images contain the same application binary. If a CVE is published for `libssl` tomorrow, which of the two images is affected, and what does that tell you about "vulnerability count" as a KPI?

---

## Exercise 3 — SBOM, scanning, and a CI quality gate

**Steps**

1. Scan the unhardened image and read the summary:

   ```bash
   trivy image --severity HIGH,CRITICAL localhost/app:bad
   ```

   ```
   localhost/app:bad (debian 12.6)
   Total: 71 (HIGH: 68, CRITICAL: 3)

   ┌──────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
   │   Library    │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
   ├──────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
   │ libc-bin     │ CVE-2024-2961  │ HIGH     │ fixed  │ 2.36-9+deb12u4    │ 2.36-9+deb12u7│
   ...
   ```

2. Scan the hardened image:

   ```bash
   trivy image --severity HIGH,CRITICAL localhost/app:good
   ```

   ```
   localhost/app:good (debian 12.6)
   Total: 0 (HIGH: 0, CRITICAL: 0)
   ```

3. Generate an SBOM in two standard formats:

   ```bash
   syft localhost/app:good -o spdx-json=sbom.spdx.json
   trivy image --format cyclonedx --output sbom.cdx.json localhost/app:good

   jq -r '.packages | length' sbom.spdx.json
   jq -r '.components[].name' sbom.cdx.json | head
   ```

4. Consume the SBOM instead of the image — the pattern used by an offline security team:

   ```bash
   grype sbom:./sbom.spdx.json --fail-on high
   echo "exit=$?"
   ```

   ```
   No vulnerabilities found
   exit=0
   ```

5. Build a gate that fails a pipeline. Note `--ignore-unfixed`, which is the difference between an actionable gate and an ignored one:

   ```bash
   trivy image --severity HIGH,CRITICAL \
                --ignore-unfixed \
                --exit-code 1 \
                --format table \
                localhost/app:bad
   echo "exit=$?"
   ```

   ```
   exit=1
   ```

6. Scan the *source tree*, not the image — misconfigurations and hardcoded secrets:

   ```bash
   printf 'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' > .env
   trivy fs --scanners misconfig,secret --severity MEDIUM,HIGH,CRITICAL .
   ```

   ```
   .env (secrets)
   Total: 1 (MEDIUM: 0, HIGH: 0, CRITICAL: 1)

   CRITICAL: AWS (aws-secret-access-key)
   Reason: AWS Secret Access Key
   ```

7. Record a time-boxed, justified exception:

   ```bash
   cat > .trivyignore <<'EOF'
   # Vulnerable code path is unreachable: the CLI parser is never invoked.
   # Owner: platform-sec  Review: 2026-10-15
   CVE-2024-2961 exp:2026-10-15
   EOF
   trivy image --severity HIGH,CRITICAL --ignorefile .trivyignore localhost/app:bad | head -3
   ```

> References: <https://trivy.dev/latest/docs/>, <https://github.com/anchore/syft>, <https://spdx.dev/>, <https://cyclonedx.org/>

**Check your understanding**

- **Q3.1** — Why does step 5 use `--ignore-unfixed`? Describe the failure mode of a gate that omits it.
- **Q3.2** — Step 4 scans an SBOM, not an image. Give two operational advantages of storing the SBOM as a build artefact rather than re-scanning the image later.
- **Q3.3** — A scan that returned `Total: 0` last week returns `Total: 12` today, with no rebuild. What changed, and what does this imply about *when* a gate should run?
- **Q3.4** — Step 7 pins an expiry date in `.trivyignore`. What is the concrete risk of an ignore entry with no expiry, and who should own the review?

---

## Exercise 4 — Signing images and verifying provenance

Scanning tells you *what is inside* an image. Signing tells you *where it came from*. They are different guarantees.

**Steps**

1. Run a local registry so the lab stays offline:

   ```bash
   podman run -d --name reg -p 5000:5000 docker.io/library/registry:2
   podman tag localhost/app:good localhost:5000/app:1.0.0
   podman push --tls-verify=false localhost:5000/app:1.0.0
   ```

2. Generate a key pair and sign **by digest**:

   ```bash
   export COSIGN_PASSWORD=lab
   cosign generate-key-pair

   DIGEST=$(podman image inspect localhost:5000/app:1.0.0 --format '{{.Digest}}')
   echo "$DIGEST"
   cosign sign --key cosign.key --tlog-upload=false --yes \
     "localhost:5000/app@${DIGEST}"
   ```

   ```
   Pushing signature to: localhost:5000/app
   ```

3. Verify, and then verify a tag you did not sign:

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog=true \
     "localhost:5000/app@${DIGEST}" | jq -r '.[0].critical.image'
   ```

   ```json
   { "docker-manifest-digest": "sha256:0a5b1f6e..." }
   ```

   ```bash
   podman tag docker.io/library/alpine:3.20 localhost:5000/evil:1.0.0
   podman push --tls-verify=false localhost:5000/evil:1.0.0
   cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5000/evil:1.0.0
   ```

   ```
   Error: no matching signatures:
   main.go:74: error during command execution: no matching signatures:
   ```

4. Attach the SBOM as a signed attestation, not as a loose file:

   ```bash
   cosign attest --key cosign.key --tlog-upload=false --yes \
     --type cyclonedx --predicate sbom.cdx.json \
     "localhost:5000/app@${DIGEST}"

   cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
     --type cyclonedx "localhost:5000/app@${DIGEST}" \
     | jq -r '.payload' | base64 -d | jq -r '.predicateType'
   ```

   ```
   https://cyclonedx.org/bom
   ```

5. Inspect what keyless signing would look like in CI (do not run it here — it needs an OIDC token):

   ```bash
   # In GitHub Actions with id-token: write
   # cosign sign --yes ghcr.io/org/app@sha256:...
   # Verification then asserts *identity*, not a key:
   # cosign verify \
   #   --certificate-identity-regexp '^https://github.com/org/app/.github/workflows/.*' \
   #   --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
   #   ghcr.io/org/app@sha256:...
   ```

> References: <https://docs.sigstore.dev/>, <https://github.com/sigstore/cosign>, <https://slsa.dev/spec/v1.0/levels>

**Check your understanding**

- **Q4.1** — Step 2 signs a digest, not the tag `1.0.0`. What attack becomes possible if you sign and verify by tag?
- **Q4.2** — Step 4 produces an *attestation* rather than a plain SBOM file in the artefact store. What property does the attestation add?
- **Q4.3** — In the keyless flow of step 5, no private key is stored anywhere. What replaces the key as the root of trust, and what is the corresponding new failure mode?
- **Q4.4** — A signature verifies successfully on an image with 40 CRITICAL CVEs. Is the verification useful? Justify with reference to what each control actually asserts.

---

## Exercise 5 — Kernel-level container hardening

**Steps**

1. Show the default is permissive: escalate privileges inside a container via a setuid binary.

   ```bash
   cat > Containerfile.suid <<'EOF'
   FROM docker.io/library/debian:12-slim
   RUN useradd -u 1001 -m appuser && \
       cp /bin/bash /usr/local/bin/rootbash && \
       chmod u+s /usr/local/bin/rootbash
   USER 1001
   CMD ["sleep", "infinity"]
   EOF
   podman build -f Containerfile.suid -t localhost/suid:demo .

   podman run --rm localhost/suid:demo /usr/local/bin/rootbash -p -c id
   ```

   ```
   uid=1001(appuser) gid=1001 euid=0(root) groups=1001
   ```

2. Block the escalation:

   ```bash
   podman run --rm --security-opt no-new-privileges \
     localhost/suid:demo /usr/local/bin/rootbash -p -c id
   ```

   ```
   uid=1001(appuser) gid=1001 groups=1001
   ```

3. Drop every capability and add back only what the workload proves it needs:

   ```bash
   podman run --rm --cap-drop=ALL docker.io/library/nginx:1.27 \
     grep CapEff /proc/1/status
   ```

   ```
   CapEff: 0000000000000000
   ```

   ```bash
   podman run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
     docker.io/library/nginx:1.27 grep CapEff /proc/1/status
   ```

   ```
   CapEff: 0000000000000400
   ```

4. Write a seccomp profile that denies `chmod`-family syscalls, and prove it is enforced:

   ```bash
   cat > seccomp-nochmod.json <<'EOF'
   {
     "defaultAction": "SCMP_ACT_ALLOW",
     "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
     "syscalls": [
       {
         "names": ["chmod", "fchmod", "fchmodat", "fchmodat2"],
         "action": "SCMP_ACT_ERRNO",
         "errnoRet": 1
       }
     ]
   }
   EOF

   podman run --rm --security-opt seccomp=seccomp-nochmod.json \
     docker.io/library/alpine:3.20 sh -c 'touch /tmp/f && chmod 777 /tmp/f'
   ```

   ```
   chmod: /tmp/f: Operation not permitted
   ```

5. Make the root filesystem read-only and give the process an explicit writable area:

   ```bash
   podman run --rm --read-only docker.io/library/alpine:3.20 \
     sh -c 'touch /oops' ; echo "exit=$?"
   ```

   ```
   touch: /oops: Read-only file system
   exit=1
   ```

   ```bash
   podman run --rm --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
     docker.io/library/alpine:3.20 sh -c 'touch /tmp/ok && ls -l /tmp/ok'
   ```

   ```
   -rw-r--r--    1 root     root             0 Sep  3 10:14 /tmp/ok
   ```

6. Verify user-namespace remapping in rootless Podman — the strongest of the boundaries in this exercise:

   ```bash
   id -u
   podman unshare cat /proc/self/uid_map
   podman run --rm docker.io/library/alpine:3.20 sh -c 'id -u; readlink /proc/self/ns/user'
   ```

   ```
   1000
            0       1000          1
            1     100000      65536
   0
   user:[4026532567]
   ```

> References: <https://man7.org/linux/man-pages/man7/capabilities.7.html>, <https://docs.docker.com/engine/security/>, <https://kubernetes.io/docs/tutorials/security/seccomp/>

**Check your understanding**

- **Q5.1** — In step 6, `id -u` inside the container returns `0` while the host UID is `1000`. Explain what the process is actually allowed to do on the host filesystem, and why "root in the container" is not "root on the host" here.
- **Q5.2** — Step 2 stops the setuid escalation but does *not* remove the setuid bit. What layer of defence is `no_new_privs`, and what does it *not* protect against?
- **Q5.3** — The profile in step 4 uses `SCMP_ACT_ERRNO`. Compare it with `SCMP_ACT_KILL` and `SCMP_ACT_LOG` and state which you would deploy first when profiling an unknown application.
- **Q5.4** — Why is `--read-only` combined with a `tmpfs` mounted `noexec,nosuid` rather than a plain writable volume?
- **Q5.5** — After step 3, `nginx:1.27` starts successfully with only `NET_BIND_SERVICE`. What change to the image would let you drop even that capability?

---

## Exercise 6 — Pod Security Admission

**Steps**

1. Create two namespaces with different postures and inspect the labels:

   ```bash
   kubectl create namespace legacy
   kubectl label namespace legacy \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=latest \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted

   kubectl create namespace prod
   kubectl label namespace prod \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=latest

   kubectl get ns legacy prod -o custom-columns=\
   'NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'
   ```

   ```
   NS       ENFORCE
   legacy   baseline
   prod     restricted
   ```

2. Try an unhardened pod in `prod`:

   ```bash
   cat > pod-bad.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
   spec:
     containers:
       - name: app
         image: nginx:1.27
   EOF

   kubectl -n prod apply -f pod-bad.yaml
   ```

   ```
   Error from server (Forbidden): error when creating "pod-bad.yaml": pods "web" is forbidden:
   violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false
   (container "app" must set securityContext.allowPrivilegeEscalation=false),
   unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
   seccompProfile (pod or container "app" must set securityContext.seccompProfile.type
   to "RuntimeDefault" or "Localhost")
   ```

3. Apply the same manifest in `legacy` and read the *warning*:

   ```bash
   kubectl -n legacy apply -f pod-bad.yaml
   ```

   ```
   Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
   pod/web created
   ```

4. Write a `restricted`-compliant pod:

   ```bash
   cat > pod-good.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 101
       runAsGroup: 101
       fsGroup: 101
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:1.27-alpine
         ports:
           - containerPort: 8080
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
         volumeMounts:
           - { name: cache,   mountPath: /var/cache/nginx }
           - { name: run,     mountPath: /var/run }
           - { name: tmp,     mountPath: /tmp }
     volumes:
       - { name: cache, emptyDir: {} }
       - { name: run,   emptyDir: {} }
       - { name: tmp,   emptyDir: {} }
   EOF

   kubectl -n prod apply -f pod-good.yaml
   kubectl -n prod get pod web -o wide
   ```

   ```
   pod/web created
   NAME   READY   STATUS    RESTARTS   AGE   IP              NODE
   web    1/1     Running   0          8s    192.168.44.12   sec704-worker
   ```

5. Confirm the runtime state matches the declaration:

   ```bash
   kubectl -n prod exec web -- id
   kubectl -n prod exec web -- grep CapEff /proc/1/status
   kubectl -n prod exec web -- sh -c 'touch /oops' ; echo "exit=$?"
   ```

   ```
   uid=101(nginx) gid=101(nginx) groups=101(nginx)
   CapEff: 0000000000000000
   touch: /oops: Read-only file system
   exit=1
   ```

6. Dry-run the whole cluster against `restricted` before rolling it out — the safe migration path:

   ```bash
   kubectl label --dry-run=server --overwrite ns --all \
     pod-security.kubernetes.io/enforce=restricted 2>&1 | grep -i warn | head
   ```

> References: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>, <https://kubernetes.io/docs/concepts/security/pod-security-admission/>

**Check your understanding**

- **Q6.1** — PSA has three modes: `enforce`, `audit`, `warn`. Describe the rollout order you would use to move a live namespace from `privileged` to `restricted` without breaking running workloads.
- **Q6.2** — `enforce-version=latest` was used above. Why is pinning to an explicit version such as `v1.31` the more defensible choice for a production cluster?
- **Q6.3** — In step 3 the pod was **created** despite the warning. Which mode produced the message, and where does the corresponding `audit` record end up?
- **Q6.4** — PSA is a namespace-level control. Name a class of privilege escalation it cannot stop, and the control that does.
- **Q6.5** — Step 4 replaced `nginx:1.27` with `nginx-unprivileged`. Explain why `readOnlyRootFilesystem: true` forced the three `emptyDir` volumes.

---

## Exercise 7 — Default-deny network policy

**Steps**

1. Build a two-tier namespace:

   ```bash
   kubectl create namespace shop
   kubectl -n shop run api  --image=nginxinc/nginx-unprivileged:1.27-alpine \
     --port=8080 --labels=app=api
   kubectl -n shop expose pod api --port=8080
   kubectl -n shop run client --image=curlimages/curl:8.8.0 --labels=app=client \
     --command -- sleep infinity
   kubectl -n shop wait --for=condition=Ready pod --all --timeout=90s
   ```

2. Prove flat connectivity is the default:

   ```bash
   kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://api:8080/
   kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\n' https://example.com/
   ```

   ```
   200
   200
   ```

3. Apply a default-deny policy for both directions:

   ```bash
   cat > netpol-deny.yaml <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: shop
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
   EOF
   kubectl apply -f netpol-deny.yaml

   kubectl -n shop exec client -- curl -s --max-time 5 http://api:8080/ ; echo "exit=$?"
   ```

   ```
   exit=28
   ```

4. Restore *only* DNS, then only the required east-west path:

   ```bash
   cat > netpol-allow.yaml <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-dns, namespace: shop }
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
           - { protocol: UDP, port: 53 }
           - { protocol: TCP, port: 53 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: client-to-api, namespace: shop }
   spec:
     podSelector:
       matchLabels: { app: client }
     policyTypes: ["Egress"]
     egress:
       - to:
           - podSelector:
               matchLabels: { app: api }
         ports:
           - { protocol: TCP, port: 8080 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: api-from-client, namespace: shop }
   spec:
     podSelector:
       matchLabels: { app: api }
     policyTypes: ["Ingress"]
     ingress:
       - from:
           - podSelector:
               matchLabels: { app: client }
         ports:
           - { protocol: TCP, port: 8080 }
   EOF
   kubectl apply -f netpol-allow.yaml
   ```

5. Verify the allow-list is exactly as narrow as intended:

   ```bash
   kubectl -n shop exec client -- curl -s -o /dev/null -w 'api=%{http_code}\n' --max-time 5 http://api:8080/
   kubectl -n shop exec client -- curl -s -o /dev/null -w 'ext=%{http_code}\n' --max-time 5 https://example.com/ ; echo "exit=$?"
   ```

   ```
   api=200
   exit=28
   ```

6. Read the policies back the way an auditor would:

   ```bash
   kubectl -n shop get networkpolicy
   kubectl -n shop describe networkpolicy default-deny-all | sed -n '1,20p'
   ```

> Reference: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>

**Check your understanding**

- **Q7.1** — Step 3 broke DNS as well as HTTP. Why does an egress default-deny almost always require an explicit DNS rule, and what symptom does a missing one produce in application logs?
- **Q7.2** — `NetworkPolicy` is additive: rules union, they never subtract. Given that, explain precisely how `default-deny-all` still takes effect in step 5.
- **Q7.3** — The exit code in steps 3 and 5 is `28` (timeout), not "connection refused". What does that difference tell a troubleshooter about *where* the packet died?
- **Q7.4** — If this cluster had kept `kindnetd`, every policy above would have applied cleanly and enforced nothing. What single command would you run to detect that class of silent failure in a new cluster?
- **Q7.5** — The `allow-dns` rule matches `kubernetes.io/metadata.name: kube-system`. Where does that label come from, and why is it preferable to labelling the namespace yourself?

---

## Exercise 8 — RBAC least privilege and ServiceAccount tokens

**Steps**

1. Create a scoped identity:

   ```bash
   kubectl create namespace app
   kubectl -n app create serviceaccount reader

   cat > rbac.yaml <<'EOF'
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata: { name: pod-reader, namespace: app }
   rules:
     - apiGroups: [""]
       resources: ["pods", "pods/log"]
       verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata: { name: reader-binds-pod-reader, namespace: app }
   subjects:
     - kind: ServiceAccount
       name: reader
       namespace: app
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: pod-reader
   EOF
   kubectl apply -f rbac.yaml
   ```

2. Test the boundary without ever holding the credential:

   ```bash
   for verb_res in "get pods" "list secrets" "create pods" "get pods -n prod"; do
     printf '%-22s ' "$verb_res"
     kubectl auth can-i $verb_res --as=system:serviceaccount:app:reader -n app
   done
   ```

   ```
   get pods               yes
   list secrets           no
   create pods            no
   get pods -n prod       no
   ```

3. Enumerate everything the identity can do — the review command:

   ```bash
   kubectl auth can-i --list --as=system:serviceaccount:app:reader -n app
   ```

   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   pods                                            []                  []               [get list watch]
   pods/log                                        []                  []               [get list watch]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   ...
   ```

4. Mint a short-lived, audience-bound token and dissect it:

   ```bash
   TOKEN=$(kubectl -n app create token reader --duration=10m)
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```

   ```json
   {
     "aud": ["https://kubernetes.default.svc.cluster.local"],
     "exp": 1788000000,
     "iss": "https://kubernetes.default.svc.cluster.local",
     "kubernetes.io": {
       "namespace": "app",
       "serviceaccount": { "name": "reader", "uid": "4f0c..." }
     },
     "sub": "system:serviceaccount:app:reader"
   }
   ```

5. Turn off token projection where the workload does not call the API at all:

   ```bash
   cat > pod-noapi.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: { name: noapi, namespace: app }
   spec:
     serviceAccountName: reader
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 65532
       seccompProfile: { type: RuntimeDefault }
     containers:
       - name: c
         image: curlimages/curl:8.8.0
         command: ["sleep", "infinity"]
         securityContext:
           allowPrivilegeEscalation: false
           capabilities: { drop: ["ALL"] }
   EOF
   kubectl apply -f pod-noapi.yaml
   kubectl -n app wait --for=condition=Ready pod/noapi --timeout=60s
   kubectl -n app exec noapi -- ls /var/run/secrets/kubernetes.io/serviceaccount/ ; echo "exit=$?"
   ```

   ```
   ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
   exit=1
   ```

6. Hunt for the anti-pattern that undoes all of the above:

   ```bash
   kubectl get clusterrolebindings -o json | jq -r '
     .items[] | select(.roleRef.name=="cluster-admin")
     | .metadata.name + " -> " + ([.subjects[]? | .kind + "/" + .name] | join(","))'
   ```

> References: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>, <https://kubernetes.io/docs/concepts/security/service-accounts/>

**Check your understanding**

- **Q8.1** — Step 4's token carries `aud` and `exp`. Contrast this with the legacy `Secret`-backed ServiceAccount token and state the concrete blast-radius difference if the token leaks.
- **Q8.2** — `kubectl auth can-i --list` reported `selfsubjectaccessreviews … create`, which nobody granted. Where does that permission come from?
- **Q8.3** — Why is `--as=` more reliable for RBAC verification than building a kubeconfig from the token and retrying by hand?
- **Q8.4** — A `Role` grants `get` on `pods` but the application also reads `pods/log`. Explain why that is a separate rule and what that reveals about subresources in RBAC.
- **Q8.5** — Step 6 lists `cluster-admin` bindings. Beyond `cluster-admin` itself, name two permissions that are effectively cluster-admin in disguise.

---

## Exercise 9 — Secrets: what Kubernetes does and does not protect

**Steps**

1. Create a Secret and observe the encoding:

   ```bash
   kubectl -n app create secret generic db \
     --from-literal=username=svc_orders \
     --from-literal=password='S3cr3t-Rotate-Me'

   kubectl -n app get secret db -o jsonpath='{.data.password}' ; echo
   kubectl -n app get secret db -o jsonpath='{.data.password}' | base64 -d ; echo
   ```

   ```
   UzNjcjN0LVJvdGF0ZS1NZQ==
   S3cr3t-Rotate-Me
   ```

2. Read it straight out of etcd, unencrypted, from the control-plane node:

   ```bash
   docker exec sec704-control-plane sh -c '
     ETCDCTL_API=3 etcdctl \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/secrets/app/db' | strings | grep -i rotate
   ```

   ```
   S3cr3t-Rotate-Me
   ```

3. Enable encryption at rest. Write the provider config on the node:

   ```bash
   KEY=$(head -c 32 /dev/urandom | base64)
   docker exec -i sec704-control-plane sh -c "cat > /etc/kubernetes/enc.yaml" <<EOF
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources: ["secrets"]
       providers:
         - aescbc:
             keys:
               - name: key1
                 secret: ${KEY}
         - identity: {}
   EOF
   ```

4. Add the flag and the mount to the static pod manifest:

   ```bash
   docker exec sec704-control-plane sh -c '
     sed -i "s|    - kube-apiserver|    - kube-apiserver\n    - --encryption-provider-config=/etc/kubernetes/enc.yaml|" \
       /etc/kubernetes/manifests/kube-apiserver.yaml'
   # /etc/kubernetes is already host-mounted into the apiserver static pod on kubeadm clusters.
   sleep 60
   kubectl -n kube-system get pod -l component=kube-apiserver
   ```

5. Prove that existing Secrets are **not** retroactively encrypted, then rewrite them:

   ```bash
   docker exec sec704-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/app/db' | strings | grep -i rotate   # still plaintext

   kubectl get secrets --all-namespaces -o json | kubectl replace -f -

   docker exec sec704-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/app/db' | head -c 120
   ```

   ```
   /registry/secrets/app/dbk8s:enc:aescbc:v1:key1:^Z...
   ```

6. Compare the two consumption paths — environment variable versus projected file:

   ```bash
   cat > pod-secret.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: { name: consumer, namespace: app }
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 65532
       fsGroup: 65532
       seccompProfile: { type: RuntimeDefault }
     containers:
       - name: c
         image: curlimages/curl:8.8.0
         command: ["sleep", "infinity"]
         env:
           - name: DB_USER
             valueFrom: { secretKeyRef: { name: db, key: username } }
         volumeMounts:
           - { name: db, mountPath: /etc/db, readOnly: true }
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities: { drop: ["ALL"] }
     volumes:
       - name: db
         secret:
           secretName: db
           defaultMode: 0400
   EOF
   kubectl apply -f pod-secret.yaml
   kubectl -n app wait --for=condition=Ready pod/consumer --timeout=60s

   kubectl -n app exec consumer -- cat /proc/1/environ | tr '\0' '\n' | grep DB_USER
   kubectl -n app exec consumer -- ls -l /etc/db/
   ```

   ```
   DB_USER=svc_orders
   -r--------    1 65532    65532           16 Sep  3 10:41 password
   -r--------    1 65532    65532           10 Sep  3 10:41 username
   ```

7. See who can read Secrets cluster-wide:

   ```bash
   kubectl auth can-i list secrets --all-namespaces --as=system:serviceaccount:app:reader
   kubectl get rolebindings,clusterrolebindings -A -o json \
     | jq -r '.items[] | select(.roleRef.name | test("secret|admin|edit"; "i")) | .metadata.name'
   ```

> References: <https://kubernetes.io/docs/concepts/configuration/secret/>, <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>

**Check your understanding**

- **Q9.1** — Step 1 shows base64. In one sentence, state exactly what security property base64 provides to a Kubernetes Secret.
- **Q9.2** — Step 5 shows that turning on encryption does nothing to existing objects. Explain the mechanism behind `kubectl get secrets -o json | kubectl replace -f -`.
- **Q9.3** — Contrast the `env` and the volume path in step 6 in terms of (a) rotation without restart, and (b) accidental exposure in crash dumps or `/proc`.
- **Q9.4** — The `aescbc` provider stores the key in a file on the control-plane node. Under what threat model does that still help, and which provider removes that limitation?
- **Q9.5** — Why does `defaultMode: 0400` matter, and what must be true about the container's UID for it to be readable at all?

---

## Exercise 10 — Policy as code: Kyverno and ValidatingAdmissionPolicy

**Steps**

1. Install Kyverno:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
   kubectl -n kyverno get pods
   ```

2. Enforce digest pinning and forbid `:latest`, in `Audit` first:

   ```bash
   cat > pol-images.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: image-hygiene
   spec:
     validationFailureAction: Audit
     background: true
     rules:
       - name: no-latest-tag
         match:
           any:
             - resources:
                 kinds: ["Pod"]
                 namespaces: ["prod", "app"]
         validate:
           message: "Images must not use the ':latest' tag: {{ request.object.metadata.name }}"
           pattern:
             spec:
               containers:
                 - image: "!*:latest"
       - name: registry-allowlist
         match:
           any:
             - resources:
                 kinds: ["Pod"]
                 namespaces: ["prod"]
         validate:
           message: "Images must come from an approved registry."
           pattern:
             spec:
               containers:
                 - image: "registry.internal/* | ghcr.io/myorg/*"
   EOF
   kubectl apply -f pol-images.yaml
   ```

3. Trigger it and read the report rather than an error:

   ```bash
   kubectl -n prod run bad --image=nginx:latest --dry-run=server -o name
   kubectl -n prod get policyreport -o wide 2>/dev/null | head
   ```

4. Flip to enforcement and observe the rejection:

   ```bash
   kubectl patch clusterpolicy image-hygiene --type=merge \
     -p '{"spec":{"validationFailureAction":"Enforce"}}'

   kubectl -n prod run bad --image=nginx:latest
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/prod/bad was blocked due to the following policies

   image-hygiene:
     no-latest-tag: 'validation error: Images must not use the '':latest'' tag: bad.'
     registry-allowlist: 'validation error: Images must come from an approved registry.'
   ```

5. Now do the same thing with **no external webhook**, using in-tree CEL:

   ```bash
   cat > vap.yaml <<'EOF'
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: require-digest-pinning
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups: [""]
           apiVersions: ["v1"]
           operations: ["CREATE", "UPDATE"]
           resources: ["pods"]
     validations:
       - expression: >-
           object.spec.containers.all(c, c.image.contains('@sha256:'))
         message: "every container image must be pinned by digest (@sha256:...)"
         reason: Invalid
   ---
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: require-digest-pinning-prod
   spec:
     policyName: require-digest-pinning
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           kubernetes.io/metadata.name: prod
   EOF
   kubectl apply -f vap.yaml

   kubectl -n prod run tagged --image=ghcr.io/myorg/app:1.0.0
   ```

   ```
   The pods "tagged" is invalid: : ValidatingAdmissionPolicy 'require-digest-pinning'
   with binding 'require-digest-pinning-prod' denied request:
   every container image must be pinned by digest (@sha256:...)
   ```

6. Reproduce the classic non-numeric-user failure predicted in Exercise 2:

   ```bash
   cat > Containerfile.namedu <<'EOF'
   FROM docker.io/library/alpine:3.20
   RUN adduser -D -u 10001 appuser
   USER appuser
   CMD ["sleep", "infinity"]
   EOF
   podman build -f Containerfile.namedu -t localhost:5000/namedu:1 . && \
     podman push --tls-verify=false localhost:5000/namedu:1

   # In the cluster, referencing an equivalent image with a NAMED user:
   kubectl -n app run namedu --image=<your-registry>/namedu:1 \
     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true}}}'
   kubectl -n app describe pod namedu | grep -A3 'Warning\|Error'
   ```

   ```
   Warning  Failed  3s (x2 over 5s)  kubelet
     Error: container has runAsNonRoot and image has non-numeric user (appuser),
     cannot verify user is non-root
   ```

> References: <https://kyverno.io/docs/>, <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>, <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>

**Check your understanding**

- **Q10.1** — Kyverno's `failurePolicy` (implicit in the webhook name `validate.kyverno.svc-fail`) is `Fail`. Describe the availability incident that follows if every Kyverno pod is down, and the trade-off against `Ignore`.
- **Q10.2** — `ValidatingAdmissionPolicy` in step 5 needs no webhook, no pods, and no certificates. Given that, why would you still run Kyverno or Gatekeeper?
- **Q10.3** — Step 2 started in `Audit`. What does the `PolicyReport` give you that a rejection does not, and why does that matter for an existing cluster?
- **Q10.4** — Step 6's error comes from the **kubelet**, not from admission. Explain why the check happens there, and give the one-line Containerfile change that fixes it permanently.
- **Q10.5** — Digest pinning improves supply-chain integrity but complicates patching. Describe the tooling pattern that reconciles the two.

---

## Exercise 11 — Runtime detection with Falco

Admission control decides what is *allowed to start*. Runtime detection tells you what a running container is *actually doing*.

**Steps**

1. Install Falco with the modern eBPF driver (no kernel module build):

   ```bash
   helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update
   helm install falco falcosecurity/falco -n falco --create-namespace \
     --set driver.kind=modern_ebpf \
     --set tty=true \
     --wait
   kubectl -n falco get pods
   ```

2. Follow the event stream in one terminal:

   ```bash
   kubectl -n falco logs -f -l app.kubernetes.io/name=falco | grep -i --line-buffered 'Warning\|Notice\|Critical'
   ```

3. In a second terminal, perform the single most common post-exploitation action:

   ```bash
   kubectl -n legacy exec -it web -- /bin/bash -c 'cat /etc/shadow; id'
   ```

   Falco emits:

   ```
   Notice A shell was spawned in a container with an attached terminal
   (evt_type=execve user=root user_uid=0 proc_exepath=/usr/bin/bash
   container_id=8f2b9c1a4e77 container_image=docker.io/library/nginx:1.27
   k8s_ns=legacy k8s_pod_name=web)
   Warning Sensitive file opened for reading by non-trusted program
   (file=/etc/shadow proc_exepath=/usr/bin/cat container_id=8f2b9c1a4e77 ...)
   ```

4. Trigger a write below a binary directory:

   ```bash
   kubectl -n legacy exec web -- sh -c 'cp /bin/ls /usr/local/bin/ls-copy'
   ```

   ```
   Error Write below binary dir (file=/usr/local/bin/ls-copy ... k8s_pod_name=web)
   ```

5. Add a rule for something Falco does not ship by default — reading the projected ServiceAccount token:

   ```bash
   cat > custom-rules.yaml <<'EOF'
   customRules:
     sa-token.yaml: |-
       - rule: Read Kubernetes ServiceAccount Token
         desc: A process read the projected ServiceAccount token file.
         condition: >
           open_read and container
           and fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount
           and not proc.name in (kubelet, kube-proxy)
         output: >
           SA token read (proc=%proc.name cmd=%proc.cmdline file=%fd.name
           pod=%k8s.pod.name ns=%k8s.ns.name image=%container.image.repository)
         priority: WARNING
         tags: [k8s, credentials, mitre_credential_access]
   EOF
   helm upgrade falco falcosecurity/falco -n falco -f custom-rules.yaml --wait

   kubectl -n legacy exec web -- cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
   ```

   ```
   Warning SA token read (proc=cat cmd=cat /var/run/secrets/... pod=web ns=legacy
   image=docker.io/library/nginx)
   ```

> Reference: <https://falco.org/docs/>

**Check your understanding**

- **Q11.1** — Falco sees the `exec` in step 3 even though the pod passed admission control. Which layer of defence-in-depth is this, and what does it buy you that PSA cannot?
- **Q11.2** — The rule in step 5 excludes `kubelet` and `kube-proxy`. What would happen operationally if that exclusion were omitted?
- **Q11.3** — Falco reads syscalls via eBPF at the node level. What does that imply about coverage on a managed control plane you do not own, and about a DaemonSet's required privileges?
- **Q11.4** — Falco is a *detection* control, not a *prevention* control. Name the seccomp/AppArmor equivalent for each of the three events triggered above, and explain when detection is preferable to prevention.

---

## Exercise 12 — Diagnostic drill: a pod that will not start

You are on call. A deployment that has run for months fails after the namespace was migrated to `restricted`.

**Steps**

1. Reproduce the incident:

   ```bash
   kubectl create namespace payments
   kubectl label ns payments \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.31

   cat > legacy-deploy.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: ledger, namespace: payments }
   spec:
     replicas: 2
     selector: { matchLabels: { app: ledger } }
     template:
       metadata: { labels: { app: ledger } }
       spec:
         containers:
           - name: ledger
             image: nginx:1.27
             securityContext:
               privileged: true
   EOF
   kubectl apply -f legacy-deploy.yaml
   ```

2. Observe that the Deployment reports success while nothing runs:

   ```bash
   kubectl -n payments get deploy,rs,pods
   ```

   ```
   NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/ledger   0/2     0            0           12s

   NAME                                DESIRED   CURRENT   READY   AGE
   replicaset.apps/ledger-6c8f9d7b54   2         0         0       12s

   No resources found in payments namespace.
   ```

3. Find the real error — it is not on the Deployment:

   ```bash
   kubectl -n payments describe replicaset -l app=ledger | sed -n '/Events/,$p'
   ```

   ```
   Events:
     Type     Reason        Age   From                   Message
     ----     ------        ----  ----                   -------
     Warning  FailedCreate  14s   replicaset-controller  Error creating: pods "ledger-6c8f9d7b54-" is
       forbidden: violates PodSecurity "restricted:v1.31": privileged (container "ledger" must not set
       securityContext.privileged=true), allowPrivilegeEscalation != false, unrestricted capabilities,
       runAsNonRoot != true, seccompProfile
   ```

4. Confirm with the API-server audit trail equivalent:

   ```bash
   kubectl -n payments get events --sort-by=.lastTimestamp | tail -5
   ```

5. Determine whether the workload actually needs privilege before granting an exemption:

   ```bash
   kubectl -n payments get deploy ledger -o jsonpath='{.spec.template.spec.containers[0].securityContext}' ; echo
   # Ask: which syscalls / devices / host paths does it use? Test in a lower namespace:
   kubectl -n legacy run probe --image=nginx:1.27 --restart=Never -- \
     sh -c 'nginx -t 2>&1'
   ```

6. Apply the fix, with the least privilege that keeps it working:

   ```bash
   kubectl -n payments patch deploy ledger --type=merge -p '{
     "spec": { "template": { "spec": {
       "securityContext": { "runAsNonRoot": true, "runAsUser": 101,
                            "fsGroup": 101, "seccompProfile": { "type": "RuntimeDefault" } },
       "containers": [ { "name": "ledger",
         "image": "nginxinc/nginx-unprivileged:1.27-alpine",
         "securityContext": { "privileged": false, "allowPrivilegeEscalation": false,
                              "readOnlyRootFilesystem": true,
                              "capabilities": { "drop": ["ALL"] } },
         "volumeMounts": [ {"name":"cache","mountPath":"/var/cache/nginx"},
                           {"name":"run","mountPath":"/var/run"},
                           {"name":"tmp","mountPath":"/tmp"} ] } ],
       "volumes": [ {"name":"cache","emptyDir":{}},
                    {"name":"run","emptyDir":{}},
                    {"name":"tmp","emptyDir":{}} ]
     } } } }'

   kubectl -n payments rollout status deploy/ledger --timeout=120s
   ```

   ```
   deployment "ledger" successfully rolled out
   ```

7. Prove the fix at runtime, not on paper:

   ```bash
   POD=$(kubectl -n payments get pod -l app=ledger -o name | head -1)
   kubectl -n payments exec "$POD" -- id
   kubectl -n payments exec "$POD" -- grep CapEff /proc/1/status
   kubectl -n payments exec "$POD" -- sh -c 'grep Seccomp: /proc/1/status'
   ```

   ```
   uid=101(nginx) gid=101(nginx)
   CapEff: 0000000000000000
   Seccomp:	2
   ```

**Check your understanding**

- **Q12.1** — In step 2 the Deployment exists and reports no error, yet zero pods were created. Explain the controller chain and why the diagnostic lives on the ReplicaSet.
- **Q12.2** — PSA rejected the pod at *creation*. Which other Kubernetes objects that create pods indirectly exhibit this same "silent" failure, and what is the general troubleshooting rule?
- **Q12.3** — `Seccomp: 2` in `/proc/1/status`. What do values `0`, `1` and `2` mean, and which one corresponds to `seccompProfile: RuntimeDefault`?
- **Q12.4** — Suppose the investigation in step 5 had shown the workload genuinely needs `CAP_NET_ADMIN`. Describe the correct resolution under PSA, and why blanket-labelling the namespace `privileged` is the wrong answer.

---

## Cleanup

```bash
kind delete cluster --name sec704
podman rm -f reg
rm -f cosign.key cosign.pub sbom.*.json .trivyignore .env
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — The 14-capability default is *least privilege by default*: the runtime removes the ~26 most dangerous capabilities (`CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_SYS_MODULE`, `CAP_NET_ADMIN`, …) from the bounding set, so even a full compromise of PID 1 cannot load a kernel module or mount a filesystem. It is not enough because the remainder is still exploitable: `CAP_DAC_OVERRIDE` bypasses all file permission checks on any mounted host path, `CAP_SETUID`/`CAP_SETGID` allow switching to any UID, `CAP_NET_RAW` enables ARP/DNS spoofing on the pod network and raw-socket scanning, and `CAP_CHOWN`/`CAP_FOWNER` allow tampering with ownership on writable mounts. Production baseline is `drop: ["ALL"]` plus an explicit, justified add list.

**A1.2** — Podman's `00000000800405fb` drops `CAP_NET_RAW`, `CAP_MKNOD` and `CAP_AUDIT_WRITE` relative to Docker's default. Dropping `CAP_NET_RAW` means the container cannot open raw or packet sockets: `ping` (using raw ICMP) fails, and — more importantly — the container cannot forge ARP replies, poison the pod-network neighbour cache, or run `tcpdump`-style sniffing. Modern `iputils` on many distros uses `SOCK_DGRAM` ICMP, so `ping` may still work depending on the image; that is an image detail, not a capability grant.

**A1.3** — `--privileged` additionally: (a) disables the seccomp filter (the default profile blocking ~44 syscalls is not applied, so `mount`, `unshare`, `keyctl`, `bpf`, `ptrace` on other namespaces become reachable); (b) disables AppArmor/SELinux confinement for the container; (c) mounts `/sys` and the whole `/dev` read-write with all host device nodes, so raw block devices such as `/dev/sda` are directly accessible; and (d) removes the cgroup device controller restriction. Any *one* of these is sufficient for a full host takeover — capabilities are the least of it.

**A1.4** — This is the **Container** C failing because of a **Cluster**/**Cloud** control gap. The read-only mount still exposes `/etc/shadow`, TLS private keys under `/etc/kubernetes/pki`, cloud instance credentials, and every other container's rootfs under `/var/lib/containers`. Read-only prevents *modification*, not *disclosure*, and confidentiality is the property that matters for credentials. The control that should have stopped it is admission-time policy — Pod Security Standards `baseline`/`restricted` forbid `hostPath` volumes entirely (Exercise 6) — not a scanner and not developer discipline.

### Exercise 2

**A2.1** — During an incident, an attacker who achieves remote code execution in a distroless container has no interpreter to pivot with: no `sh`, no `curl`/`wget` to stage a second-stage payload, no `apt` to install tooling, no `nc` to open a reverse shell. It converts many RCE primitives into a dead end. Debugging still works via **ephemeral containers**: `kubectl debug -it <pod> --image=busybox:1.36 --target=<container> -- sh` attaches a fully-equipped container that shares the target's process and network namespaces without changing the running image. On a plain runtime, `nsenter`/`podman exec` from a debug container achieves the same.

**A2.2** — `CGO_ENABLED=0` produces a statically linked binary with Go's pure-Go `net` and `os/user` implementations. The `distroless/static` base contains only CA certificates, `/etc/passwd`, timezone data and `tmp` — it has **no** `libc`, no dynamic loader (`ld-linux-x86-64.so.2`). A cgo-enabled binary would fail at exec time with `no such file or directory` (the misleading error for a missing interpreter). The alternative is `distroless/base`, which ships glibc.

**A2.3** — The kubelet's `runAsNonRoot: true` check. The kubelet must decide, *before* starting the container, whether the effective UID is non-zero. It can do so only if the image config's `User` field is numeric; a name like `nonroot` would require resolving `/etc/passwd` inside the image, which the kubelet does not do. With a named user it refuses to start the container with `container has runAsNonRoot and image has non-numeric user (...), cannot verify user is non-root` — reproduced in Exercise 10, step 6.

**A2.4** — Only `localhost/app:bad` is affected: the distroless `static` base has no OpenSSL at all (the Go binary uses `crypto/tls`). This is the central point about vulnerability counts — a count is a property of the *bill of materials*, not of the risk. Reducing the BOM reduces the count without any patching, and a "0 CVE" image with a reachable, unauthenticated application flaw is far more dangerous than a "40 CVE" image whose findings are all in unreachable code. Use counts to compare an image against *its own history*, never as an absolute quality bar.

### Exercise 3

**A3.1** — `--ignore-unfixed` suppresses vulnerabilities for which the distribution has published no fixed version. Without it, the gate fails on findings the team is structurally unable to remediate — there is no package to upgrade to. The predictable outcome is that the gate gets bypassed: someone adds `|| true`, or `--exit-code 0`, or an ever-growing ignore file, and from that day forward the gate detects nothing including the fixable criticals. A gate must only fail on *actionable* findings; unfixed ones belong in a report with an owner and an SLA.

**A3.2** — (a) The SBOM records what was *actually built*, at build time, including build-time-only and vendored dependencies that may not be visible from the final image layers. (b) Rescanning an SBOM is free, offline and instant, so you can re-evaluate your whole historic fleet against a new CVE in seconds without pulling hundreds of images or contacting the registry — the exact workload after a zero-day like Log4Shell. It also lets a security team scan artefacts they are not authorised to pull, and lets you answer "which of our 400 services ship this library?" with a query rather than a rebuild.

**A3.3** — The image is byte-identical; the **vulnerability database** changed. New CVEs were published, or existing ones were assigned to packages in that image. This is why a build-time gate is necessary but not sufficient: you also need **continuous re-scanning of what is deployed** (`trivy k8s --report summary cluster`, or a registry-side scanner), because the risk of an artefact changes long after its last build.

**A3.4** — An ignore entry with no expiry is permanent by accident. The justification ("unreachable code path") is true for one version of the application; the next refactor may make the path reachable, and nothing re-evaluates the decision. The entry silently suppresses the finding forever, in every scan, including the one after the code changed. Ownership must be a named team, and the expiry must be short enough that the review actually happens — Trivy's `exp:` syntax makes the entry stop suppressing automatically, which is the point.

### Exercise 4

**A4.1** — Tags are **mutable**. If you sign `app:1.0.0` and verify `app:1.0.0`, an attacker (or a careless CI job) who can push to the registry can re-point that tag at a different manifest after signing. The verifier then either fails (best case) or, if the attacker also has a valid signature for their own build, succeeds on the wrong artefact. Signing a digest binds the signature to immutable content: `sha256:…` *is* the content hash, so a substituted image produces a different digest and cannot be presented under the same reference. The full production pattern is: resolve tag → digest once, sign the digest, and deploy the digest.

**A4.2** — Integrity and authenticated origin. A plain `sbom.json` in an artefact store is an unsigned assertion — anyone with write access can edit it to remove a component, and there is no cryptographic link between it and the image. `cosign attest` wraps the SBOM in an in-toto statement whose `subject` is the image digest, signs it, and stores it in the registry alongside the image. Verification then proves *this SBOM describes exactly this image, and was produced by the holder of this key / this OIDC identity*. That is the difference between a document and evidence.

**A4.3** — The root of trust becomes the **OIDC identity** plus the transparency log: Fulcio issues a short-lived (10-minute) X.509 certificate binding the ephemeral key to the workload identity (e.g. a GitHub Actions workflow), and Rekor records the signature immutably so the expired certificate remains verifiable. The new failure modes are (a) compromise of the identity provider or of the CI account itself — if an attacker can run a workflow in your repo, they can produce a legitimately-signed malicious image, which is why verification must pin `--certificate-identity-regexp` to specific workflow paths and not merely to the org; and (b) dependence on the availability and integrity of the public good instances of Fulcio/Rekor.

**A4.4** — Yes, it is useful, but it answers a different question. The signature asserts *provenance*: this artefact was produced by an authorised builder and has not been altered since. It says nothing about *content quality*. The scan asserts the reverse: here is what is inside, with no claim about who built it. You need both, plus admission-time enforcement of both — a signed image with 40 criticals should fail the scan gate, and an unsigned image with 0 criticals should fail the signature gate.

### Exercise 5

**A5.1** — In rootless Podman the container runs inside a **user namespace** where container UID 0 is mapped to host UID 1000 (the invoking user) and container UIDs 1–65536 map to the subordinate range 100000–165535 from `/etc/subuid`. Every capability the process holds is scoped to that namespace. On the host filesystem it can therefore touch only what host UID 1000 (or the subuid range) can touch — writing to `/etc` or reading `/etc/shadow` fails with `EACCES`, and the kernel enforces this at the VFS layer, not via a policy that can be misconfigured. "Root in the container" means it can `chown` files it owns *within its own mapping* and bind low ports inside its network namespace. This is the strongest boundary in the exercise because it is enforced by UID translation rather than by capability bookkeeping.

**A5.2** — `no_new_privs` is a per-process kernel flag (`PR_SET_NO_NEW_PRIVS`) that is inherited across `execve` and cannot be cleared. It causes the kernel to ignore setuid/setgid bits and file capabilities on subsequently executed binaries. It is a *containment* layer: it does not remove the setuid bit, does not fix the image, and does not stop escalation that comes from anywhere else — an over-permissive `hostPath`, a granted capability like `CAP_SYS_ADMIN`, a kernel vulnerability, or a compromised credential mounted into the pod. It closes exactly one path. In Kubernetes it is `allowPrivilegeEscalation: false`, which `restricted` mandates.

**A5.3** — `SCMP_ACT_ERRNO` returns an error code (here `EPERM`) to the caller — the syscall fails but the process lives, which surfaces the denial as a normal, handleable error. `SCMP_ACT_KILL` (and `SCMP_ACT_KILL_PROCESS`) terminates the process immediately with `SIGSYS`, giving you a hard stop but a very unhelpful crash and no partial function. `SCMP_ACT_LOG` allows the syscall and records it to the audit log. When profiling an unknown application you deploy **`SCMP_ACT_LOG` first** as the default action, collect real syscall usage under production load for a full business cycle (including startup, rotation, and error paths), then generate a profile and switch to `ERRNO`, and only consider `KILL` once you are confident the allow-list is complete.

**A5.4** — A writable volume would allow an attacker who achieves file-write to drop and execute a payload, or to plant a setuid binary. `noexec` makes the kernel refuse to `execve` anything on that mount; `nosuid` makes it ignore setuid/setgid bits there. `tmpfs` also means the data is memory-backed and disappears with the container, so nothing persists across a restart and there is no host disk footprint to forensically recover or for an attacker to reuse. Combined with `--read-only`, the writable surface is reduced to exactly the paths the application declared it needs, and even those cannot host executable code. `size=64m` prevents a memory-exhaustion DoS via the tmpfs.

**A5.5** — Change the image to listen on an unprivileged port (≥ 1024) and run as a non-root user — exactly what `nginxinc/nginx-unprivileged` does by listening on 8080. `CAP_NET_BIND_SERVICE` exists only to allow binding below 1024; once the port is 8080 there is nothing to grant. The Service can still expose port 80 externally and target 8080, so nothing changes for clients. The alternative — setting `net.ipv4.ip_unprivileged_port_start` via a sysctl — moves the problem to a node-level setting and is worse.

### Exercise 6

**A6.1** — Three phases, no gaps: (1) label the namespace `warn=restricted` and `audit=restricted` while leaving `enforce` at its current level — clients now see warnings and the API server writes audit annotations, but nothing is blocked; (2) collect for a full deployment cycle (including CronJobs, which may run weekly, and DaemonSets, which only reconcile on node changes), fix each violating workload, and confirm the warning stream is clean; (3) only then set `enforce=restricted`. Critically, **PSA is evaluated at pod creation, not on existing pods**, so flipping `enforce` does not evict anything — the breakage appears later, at the next rollout, node drain, or autoscaling event, which is the worst possible time to discover it. That delayed-fuse property is exactly why the audit phase is mandatory.

**A6.2** — `latest` means "whatever the current API server version defines", so the standard can become stricter under you during a cluster upgrade — a new check added in the next minor version starts rejecting pods that were compliant yesterday, with no change on your side and no deploy to correlate against. Pinning `enforce-version: v1.31` freezes the ruleset: after upgrading the cluster you deliberately re-evaluate against the new version (using `warn`/`audit` at the newer version first), then bump the pin. It converts an unplanned incident into a scheduled task.

**A6.3** — The message came from the `warn=restricted` label; `enforce` was `baseline`, and the pod satisfies `baseline` (it is not privileged and requests no host namespaces), so it was admitted. Warnings are returned to the client in the HTTP `Warning` header — they are visible to whoever ran `kubectl`, and to nobody else. The `audit=restricted` label is what makes the violation durable: the API server adds a `pod-security.kubernetes.io/audit-violations` annotation to the audit event, which lands in the **API server audit log** (only if an audit policy is configured to record it at `Metadata` level or above). This is the mechanism you query to build the inventory of violating workloads across a cluster, because warnings are ephemeral.

**A6.4** — PSA cannot stop escalation through the **RBAC** and **API** layer, because it only validates pod specs. A user with `create` on `deployments` in a namespace enforcing `restricted` still cannot run a privileged pod — but a user with `escalate`/`bind` on RBAC objects, or `create` on `clusterrolebindings`, or `update` on a `MutatingWebhookConfiguration`, or `create` on `nodes/proxy`, or the ability to modify a namespace's own PSA labels, can escalate to cluster-admin without ever violating a Pod Security Standard. RBAC least privilege (Exercise 8) is the control, and specifically: nobody who deploys workloads should be able to edit the namespace labels that constrain them.

**A6.5** — `readOnlyRootFilesystem: true` makes the container's entire root filesystem immutable, but nginx must write at runtime: proxy/cache buffers under `/var/cache/nginx`, the PID file under `/var/run` (or `/tmp` in the unprivileged image), and client-body temporary files under `/tmp`. Each of those paths therefore needs a writable mount — `emptyDir` gives an ephemeral, per-pod volume that dies with the pod. The stock `nginx:1.27` image additionally cannot satisfy `runAsNonRoot` because its entrypoint starts as root to bind port 80 and drop privileges afterwards; `nginx-unprivileged` is built to start as UID 101 on port 8080 and needs neither root nor `CAP_NET_BIND_SERVICE`.

### Exercise 7

**A7.1** — `policyTypes: ["Egress"]` with no `egress` rules denies **all** outbound traffic, including UDP/TCP 53 to CoreDNS in `kube-system`. Since virtually every application resolves a name before connecting, the first symptom is not "connection refused" but resolver failure: `Temporary failure in name resolution`, `getaddrinfo EAI_AGAIN`, `no such host`, or — most confusingly — a 5-second stall per lookup followed by a timeout, because the stub resolver retries against each `nameserver` in `/etc/resolv.conf` and `ndots:5` in the pod's default DNS config multiplies the number of queries. Teams routinely misdiagnose this as a DNS outage. Every default-deny egress policy needs a companion DNS allow rule.

**A7.2** — There is no "deny" in the `NetworkPolicy` API. The semantics are: *if any policy selects a pod for a given direction, all traffic in that direction is denied except what some selecting policy explicitly allows.* `default-deny-all` has `podSelector: {}`, so it selects every pod in `shop` for both directions, flipping them from "allow all" (the default when no policy selects a pod) to "deny unless allowed". The three rules in step 4 then union in the specific permitted flows. Remove `default-deny-all` and the other three policies would still select their pods, so the effect on `client` and `api` would be unchanged — but any *other* pod in the namespace, selected by nothing, would revert to unrestricted. That is the value of the empty-selector policy: it makes the namespace closed by construction, so a newly deployed pod is denied by default rather than open by default.

**A7.3** — Exit 28 is curl's `CURLE_OPERATION_TIMEDOUT`: the SYN went out and **nothing came back**. A `NetworkPolicy` implemented as a packet filter silently drops the packet; there is no RST and no ICMP unreachable, so the client waits for the connect timeout. `Connection refused` (exit 7, `ECONNREFUSED`) would mean the packet *did* reach a host that returned a TCP RST — i.e. the network path is fine and the problem is at the destination: no process listening, wrong port, or a Service with no ready endpoints. So: **timeout ⇒ suspect network policy, security group, or routing; refused ⇒ suspect the application, port or endpoint selection.** This one distinction eliminates half the search space immediately.

**A7.4** — Deploy the policy and test it: apply a default-deny in a scratch namespace and confirm that traffic is actually blocked, e.g.

```bash
kubectl create ns npcheck && kubectl -n npcheck apply -f netpol-deny.yaml
kubectl -n npcheck run t --image=curlimages/curl:8.8.0 --restart=Never --command -- \
  curl -s --max-time 5 https://example.com/
kubectl -n npcheck logs t   # empty + non-zero exit ⇒ enforced; content ⇒ NOT enforced
```

The API server accepts `NetworkPolicy` objects unconditionally — it is a plain CRD-like resource with no admission-time check for a CNI that implements it — so `kubectl get netpol` showing your policies proves only that they are *stored*. Never infer enforcement from a successful `apply`.

**A7.5** — `kubernetes.io/metadata.name` is set and maintained automatically by the API server on every Namespace object (via the `NamespaceDefaultLabelName` behaviour, GA since 1.21); its value is always the namespace name and it cannot drift. Labelling namespaces yourself is worse because the label is mutable by anyone with `update` on namespaces — including, in many clusters, the same people who deploy workloads — so a policy keyed on a hand-managed label can be bypassed by relabelling a namespace. Keying on the automatic label ties the rule to identity rather than to a convention.

### Exercise 8

**A8.1** — Step 4's token is a **bound** token: it carries `aud` (only accepted by the API server audience), `exp` (here 10 minutes; the default projected-token lifetime is 1 hour with automatic kubelet refresh), and `kubernetes.io` claims that bind it to the specific Pod and ServiceAccount UID, so the API server rejects it once the Pod is deleted. The legacy `Secret`-backed token was a JWT with **no expiry**, no audience and no pod binding — valid forever, from anywhere, until the Secret was manually deleted and every consumer rotated. Blast radius: a leaked bound token gives an attacker minutes and only against the API server; a leaked legacy token gives permanent access, is accepted by any service that trusts the cluster's JWKS, and is typically discovered years later in a git history or a log aggregator.

**A8.2** — From the `system:basic-user` ClusterRole, bound to the `system:authenticated` group by the `system:basic-user` ClusterRoleBinding, which the API server bootstraps and reconciles on every start. Every authenticated identity in the cluster gets it. It grants `create` on `selfsubjectaccessreviews` and `selfsubjectrulesreviews` — the ability to ask "what may *I* do?" — which is precisely what `kubectl auth can-i` calls. This is why aggregated permissions always include entries you did not write: the default `system:*` roles apply to everyone, and any review of an identity's effective permissions must account for them.

**A8.3** — `--as=` uses the API server's **impersonation** feature: the request is authorised exactly as if it came from that subject, through the same authorisation chain (RBAC, plus Node/ABAC/webhook authorizers if configured), and returns the definitive verdict. Building a kubeconfig by hand introduces failure modes that have nothing to do with the RBAC you are testing — a truncated token, the wrong CA bundle, a missing `--server`, an expired token, a shell that mangled the JWT — so a `Forbidden` may reflect your typing rather than your policy, and worse, a `yes` obtained with a stale admin context can look like a successful test. `--as=` also needs no credential to exist at all, so you can validate a Role before creating the ServiceAccount, and it works for users and groups (`--as-group=`) that have no token by definition.

**A8.4** — In RBAC, subresources are named `parent/subresource` in the `resources` list and are authorised independently of the parent. Granting `get` on `pods` does **not** grant `get` on `pods/log`, `pods/exec`, `pods/portforward`, `pods/attach` or `pods/ephemeralcontainers`. This separation is the whole point: it lets you grant read-only visibility of pod metadata while withholding the ability to read application logs (which routinely contain credentials and PII) and, far more importantly, to `exec` into a container — `pods/exec` is a full shell in every pod in scope and is effectively equivalent to owning whatever those pods can reach, including their ServiceAccount tokens. Audit `pods/exec` and `pods/portforward` grants as if they were admin.

**A8.5** — Several, any of which is a full cluster takeover:
- `escalate` or `bind` on `roles`/`clusterroles`, which lifts the normal privilege-escalation prevention and lets a subject grant itself anything.
- `create` on `clusterrolebindings` (or `rolebindings` referencing a powerful ClusterRole) — bind yourself to `cluster-admin`.
- `create` on `pods` in `kube-system`, or anywhere a privileged ServiceAccount lives: schedule a pod with that SA, or with `hostPath: /`, or on a control-plane node, and read the admin kubeconfig.
- `create` on `pods/exec` against a pod running with a privileged SA.
- `update` on `mutatingwebhookconfigurations` / `validatingwebhookconfigurations` — intercept and rewrite every object in the cluster.
- `get`/`list` on `secrets` cluster-wide — every credential in the cluster, including SA tokens.
- `create` on `nodes/proxy` — direct kubelet API access, i.e. exec into any pod on the node.
- `impersonate` on users/groups/serviceaccounts.
- `approve` on `certificatesigningrequests` plus `create` on CSRs — mint a client certificate for `system:masters`.

### Exercise 9

**A9.1** — None whatsoever. Base64 is a transport encoding that allows arbitrary binary values to be stored in a JSON/YAML string field; it is trivially reversible by anyone and provides no confidentiality. A Secret is distinguished from a ConfigMap by *how the rest of the system treats it* — it can be encrypted at rest, it is excluded from some logs, it is a separate RBAC resource, and the kubelet stores it in `tmpfs` — not by any transformation of its contents.

**A9.2** — Encryption is applied by the API server on the **write** path only. Objects already in etcd stay in whatever form they were written; the `identity: {}` provider listed after `aescbc` is what makes them still readable (providers are tried in order for decryption, and `identity` means "stored as plaintext"). `kubectl get secrets -o json | kubectl replace -f -` reads every Secret and writes it back unchanged, which forces the API server to re-serialise it through the now-active encryption provider. The same procedure is what you run after a **key rotation**, and the ordering rule is the crux: to rotate, add the new key as the *second* entry (so it can decrypt but not yet encrypt), restart all API servers, then promote it to *first*, restart again, then rewrite all Secrets, and only then remove the old key. Removing the old key before the rewrite makes every un-rewritten Secret permanently unreadable.

**A9.3** — (a) **Rotation:** a mounted Secret volume is updated in place by the kubelet when the Secret changes (within roughly one sync period plus cache TTL, by default up to ~1 minute; not at all if `subPath` is used), so an application that re-reads the file picks up the new value with no restart. An `env` value is materialised into the process environment at exec time and is immutable for the life of the process — rotation requires a pod restart, which is why env-injected credentials tend never to be rotated at all. (b) **Exposure:** environment variables leak far more readily — they appear in `/proc/<pid>/environ` (readable by any process with the same UID in the container, and by anything that can enter the namespace), are inherited by every child process, are commonly dumped verbatim in crash handlers, stack traces, APM payloads and debug endpoints, and are printed by `kubectl describe pod` if set inline rather than via `secretKeyRef`. A file mounted `0400` is read by one process at one moment and is not inherited. Prefer files; prefer short-lived dynamic credentials over both.

**A9.4** — `aescbc` (and `secretbox`) protect against **offline** compromise of the etcd data: a stolen etcd backup, a snapshot copied to object storage, a decommissioned disk, or an attacker with read access to etcd's data directory or to the etcd client API without the API server's config file. It does **not** protect against an attacker who has root on the control-plane node, since the key sits in `/etc/kubernetes/enc.yaml` right beside the ciphertext — the two are compromised together. The `kms` v2 provider removes that limitation: the data-encryption keys are wrapped by a key-encryption key held in an external KMS/HSM (a cloud KMS, Vault Transit), so the node never stores anything that decrypts on its own, key rotation and revocation are centralised, and use of the KEK is independently audited. Note that either way the API server holds plaintext in memory, so this is at-rest protection only.

**A9.5** — `defaultMode: 0400` makes each projected file readable only by its owner and not writable by anyone, so a compromised sidecar or a second process running under a different UID in the pod cannot read the credential, and nothing can tamper with it. For the owning process to read it, the file's owner must match: for a Secret volume the files are owned by root with the group set from `fsGroup`, so a container running as UID 65532 needs `fsGroup` to apply group ownership and the mode to permit group read (`0440`), **or** the pod's `runAsUser` must match the file owner. With `0400` and a non-root `runAsUser` but no matching ownership, the container gets `Permission denied` — a very common and very confusing failure. In practice: set `fsGroup` to the container's group and use `0440`, and remember `fsGroup` does not apply to `subPath` mounts.

### Exercise 10

**A10.1** — With `failurePolicy: Fail`, the API server treats an unreachable webhook as a rejection. If all Kyverno pods are down, **every** create/update matching the webhook's rules is denied cluster-wide: deployments cannot roll, the HPA cannot scale, failed pods cannot be recreated, and — the vicious part — Kyverno itself may be unable to restart if its own namespace is in scope. This is a well-known way to take down a healthy cluster with a security tool. `Ignore` inverts the risk: during an outage, unvalidated objects are admitted, so the window is a *security* gap rather than an *availability* one. The standard mitigations are to run the admission controller highly available across nodes with a PodDisruptionBudget, exclude `kube-system` and the policy engine's own namespace via `namespaceSelector`, set a short `timeoutSeconds` (5s or less), and reserve `Fail` for the policies whose bypass would be genuinely unacceptable while leaving the rest on `Ignore`.

**A10.2** — `ValidatingAdmissionPolicy` only *validates*. It cannot **mutate** (inject sidecars, add default `securityContext` fields, set `imagePullPolicy`), cannot **generate** (create a default NetworkPolicy or ResourceQuota in every new namespace), cannot **clean up**, and cannot perform actions requiring external state — notably `verifyImages`, which must fetch a signature from a registry and check it against a key or a Fulcio identity. It also has no background scanning of pre-existing resources and no `PolicyReport` output. CEL expressions are evaluated against the object in the request only. So the pattern is complementary: push the simple, high-volume, structural rules into `ValidatingAdmissionPolicy` — no pods, no certificates, no availability risk, in-process evaluation — and keep Kyverno/Gatekeeper for mutation, generation, image verification and reporting.

**A10.3** — A rejection tells you about one object at the moment someone tried to create it. A `PolicyReport` tells you about **everything that already exists**, because `background: true` makes Kyverno evaluate the policy against current cluster state on a schedule. On an existing cluster this is the difference between knowing your exposure and discovering it one broken deploy at a time: you get a complete inventory of violating workloads, per namespace and per owner, that you can triage, assign and burn down *before* switching to `Enforce`. Going straight to `Enforce` on a running cluster does not block existing pods — they keep running — it blocks the next rollout, which means the policy's blast radius arrives at an unpredictable moment, most likely during an unrelated incident. Audit first, always.

**A10.4** — The check happens in the kubelet because that is the first component that has the **image configuration**. Admission control runs against the PodSpec long before any node is selected or any image is pulled; the API server does not know, and must not have to contact a registry to learn, what `USER` the image declares. Only after the pull can the runtime read the OCI image config's `User` field and compare it with `runAsNonRoot`. If that field is a *name*, resolving it would require reading `/etc/passwd` from inside the image, which the kubelet deliberately does not do — so it fails closed. The fix is one line in the Containerfile: declare the user numerically.

```dockerfile
USER 10001:10001        # instead of: USER appuser
```

Alternatively set `runAsUser: 10001` explicitly in the PodSpec, which also satisfies the check — but fixing the image is better, because it makes every consumer of that image correct by default.

**A10.5** — An automated dependency-update bot that treats the digest as source: Renovate or Dependabot watch the upstream tag, and when a new image is published they open a pull request that rewrites the pinned `image: ghcr.io/org/app@sha256:…` line to the new digest (Renovate's `helm-values`/`kubernetes` managers do this natively, keeping a `# tag` comment for readability). The digest stays immutable in the deployed manifest, while the *update* becomes a reviewable, testable, revertable commit that runs through the same CI gates — scanning, signature verification, staged rollout — as any code change. The anti-pattern is a floating tag plus `imagePullPolicy: Always`, which "patches" by silently changing what runs, with no record of what changed, no review, and no ability to roll back to a known artefact.

### Exercise 11

**A11.1** — This is **runtime detection**, the layer that assumes prevention has already failed. PSA, RBAC and admission policy all make decisions *before* a workload starts, based on declared intent; once the pod is running and compliant, they are silent. Falco observes actual behaviour — syscalls — so it catches what no admission check can: an application-level RCE in a fully `restricted`-compliant pod, a legitimate operator doing something illegitimate, credential theft, cryptominer execution, or exploitation of a zero-day in a signed, scanned, unprivileged image. It also produces the evidence trail (process, command line, image, pod, namespace, user) that incident response needs and that admission logs cannot provide.

**A11.2** — `kubelet` and `kube-proxy` legitimately read those paths constantly: the kubelet projects and refreshes the token into every pod's `tmpfs` mount, and both components read their own credentials. Without the exclusion the rule would fire continuously on every node, producing thousands of events per hour of pure noise. The operational consequence is alert fatigue followed by the rule being muted or deleted — at which point the real detection is gone. This is the central discipline of runtime detection: a rule's value is determined by its false-positive rate, not by its coverage, and every rule needs a tuning pass against real traffic before it is allowed to page anyone.

**A11.3** — eBPF programs attach to kernel tracepoints on the node, so Falco sees only what happens on nodes where its DaemonSet runs. On a managed control plane (EKS, GKE, AKS) you cannot schedule pods on the master nodes, so **API server, scheduler and controller-manager activity is invisible to Falco** — that visibility has to come from the cloud provider's API server audit log instead, which is a separate pipeline you must enable. On the node side, the DaemonSet needs substantial privilege to do its job: `hostPID`, host mounts of `/proc` and `/sys`, and `CAP_BPF` + `CAP_PERFMON` (or `CAP_SYS_ADMIN` on older kernels) to load the programs. That makes Falco itself a high-value target and a genuine exception to the `restricted` standard — it must be deployed in a dedicated namespace with a documented PSA exemption, tightly scoped RBAC, and images verified by signature, because compromising the security tool compromises the node.

**A11.4** — Preventive equivalents:
- *Shell spawned in container* → a seccomp profile denying `execve` of new binaries is impractical, but the effective prevention is an image with no shell (Exercise 2) plus RBAC denying `pods/exec` (Exercise 8); AppArmor can also deny execution of `/bin/*`.
- *Reading `/etc/shadow`* → AppArmor or SELinux file rules denying read on sensitive paths, `readOnlyRootFilesystem`, and running as a non-root UID that simply cannot read the file.
- *Write below binary dir* → `readOnlyRootFilesystem: true`, which makes the write impossible rather than merely noticed.

Detection is preferable when prevention would break the workload or cannot be specified in advance: when you do not yet know the application's legitimate behaviour, when the policy would have an unacceptable false-positive cost (killing a production process on an unexpected syscall), during the profiling phase before a preventive policy is written, and for behaviour that is legitimate in itself but suspicious in context — an `exec` by an on-call engineer at 03:00 is not something you want to block, but it is absolutely something you want recorded. In practice detection also covers the gap for third-party and legacy workloads you cannot modify.

### Exercise 12

**A12.1** — The chain is Deployment → ReplicaSet → Pod, and each controller only reports on the object it directly manages. The deployment-controller's job is to create and scale a ReplicaSet; it did that successfully, so the Deployment has no error to report — it merely shows `0/2` ready, which reads like a slow rollout. The replicaset-controller's job is to create Pods, and *its* `POST /api/v1/pods` is what PSA rejected, so the `FailedCreate` event is recorded on the ReplicaSet. And because the Pod was never admitted, no Pod object exists — `kubectl get pods` returns nothing and `kubectl describe pod` has nothing to describe. The rule: **when a workload has zero pods, the error is on the object one level down, not on the pod and not on the top-level controller.**

**A12.2** — Everything that creates pods through a controller rather than directly: `Deployment` (via ReplicaSet), `StatefulSet`, `DaemonSet`, `Job`, and `CronJob` (via Job — two levels down, so you may need `describe job` after `describe cronjob`), plus `ReplicationController` and anything driven by an operator's custom resource. The general rule is to walk the ownership chain downward until you find the object whose controller is doing the failing API call, and read `.status.conditions` and the events there:

```bash
kubectl -n <ns> describe replicaset -l <selector>     # or: describe job / describe statefulset
kubectl -n <ns> get events --sort-by=.lastTimestamp
kubectl -n <ns> get deploy <name> -o jsonpath='{.status.conditions}' | jq .
```

`ReplicaFailure` in the Deployment's conditions is the specific signal that pod creation — not pod scheduling or pod startup — is failing. Note the same pattern applies to quota rejections, missing ServiceAccounts, and admission webhook denials, not just PSA.

**A12.3** — The `Seccomp` field in `/proc/<pid>/status` reports the process's seccomp mode: `0` = disabled (no filter), `1` = strict mode (`SECCOMP_MODE_STRICT`, only `read`, `write`, `_exit`, `sigreturn` — essentially never used by container runtimes), `2` = filter mode (`SECCOMP_MODE_FILTER`, a BPF program is attached). `seccompProfile: { type: RuntimeDefault }` produces **`2`**, as does `type: Localhost` with a custom profile — the field tells you a filter is *active*, not *which* filter. `type: Unconfined`, or omitting `seccompProfile` on a cluster without the default, gives `0`. So `Seccomp: 2` confirms enforcement is on; to know which profile, check `Seccomp_filters` (the number of attached filters) and the PodSpec. This is the only way to verify from inside the container that the declared profile actually took effect.

**A12.4** — The correct resolution is a **narrowly scoped exemption**, not a weakened namespace. Move that single workload to its own dedicated namespace labelled `enforce=baseline` (which permits added capabilities that `restricted` forbids) while everything else stays `restricted`; grant only `CAP_NET_ADMIN` via `capabilities: { drop: ["ALL"], add: ["NET_ADMIN"] }`, keeping `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` and `seccompProfile: RuntimeDefault`; restrict who can deploy into that namespace with RBAC; and add a Kyverno/VAP rule asserting that the exemption applies to that one workload's ServiceAccount and image, so nothing else can drift into the hole. Document the justification and an expiry for review.

Labelling the namespace `privileged` is wrong for three reasons: it is a *namespace*-scoped decision applied to fix a *workload*-scoped problem, so every current and future pod in that namespace inherits the exemption; `privileged` permits far more than `NET_ADMIN` — host namespaces, `hostPath`, `privileged: true`, arbitrary sysctls — so the granted privilege bears no relation to the demonstrated need; and it is invisible in review, because nothing in the workload's manifest records that it is running unconfined. Exemptions should be as small as the requirement and as legible as possible.

</details>