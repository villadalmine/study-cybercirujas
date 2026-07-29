# 1.3 Properly set up Ingress objects with TLS

**Domain:** Cluster Setup · **Exam weight:** 3

---

## 1. Why this matters for security

An `Ingress` is the front door of the cluster: it is the one object that deliberately exposes internal Services to traffic originating outside the cluster. Everything you learned about NetworkPolicies and node hardening is irrelevant if the entry point terminates plaintext HTTP, presents an expired certificate, or accepts SSLv3.

From a CKS point of view there are three distinct security goals:

| Goal | Mechanism |
|---|---|
| Confidentiality/integrity of client traffic | TLS termination at the Ingress with a valid certificate |
| No accidental plaintext path | HTTP → HTTPS redirect, HSTS |
| Proof of who is talking | Server certificate (always) + optional client certificate (mTLS) |

A fourth, frequently overlooked goal is protecting the **Ingress controller itself**, which runs with high privileges and has a history of serious CVEs. Section 10 covers that.

---

## 2. The moving parts

TLS on an Ingress requires four things to agree with each other. If any one of them disagrees, you get the controller's self-signed fallback certificate instead of yours — and *no error*, which is why this topic produces so much troubleshooting time on the exam.

```
                     must match
   ┌──────────────────────────────────────────────┐
   │                                              │
Client SNI ──► spec.tls[].hosts ──► Secret (tls.crt SAN) 
   │                                              
   └────────► spec.rules[].host ──► backend Service
```

1. **An Ingress controller** must be running and watching the right `IngressClass`. The `Ingress` object is inert data; without a controller nothing happens.
2. **A Secret of type `kubernetes.io/tls`** containing `tls.crt` (leaf + any intermediates) and `tls.key`, living **in the same namespace as the Ingress**.
3. **The `Ingress` object** referencing that Secret under `spec.tls`.
4. **A certificate whose SAN covers the hostname** the client requests via SNI.

---

## 3. Prerequisite: an Ingress controller

The exam environment normally has `ingress-nginx` pre-installed. Confirm before doing anything:

```bash
kubectl get pods -n ingress-nginx
kubectl get ingressclass
```

```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-7d4c8f96b4-x2vlq   1/1     Running   0          3d

NAME    CONTROLLER                      PARAMETERS   AGE
nginx   k8s.io/ingress-nginx            <none>       3d
```

If you must install it yourself:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/baremetal/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

> **Note on ingress-nginx.** The upstream `ingress-nginx` project has been placed in maintenance mode with a planned retirement, and *InGate* is being developed as the successor. Exam environments and most clusters in the field still ship `ingress-nginx`, so it remains the reference implementation for this objective — but verify which controller your cluster actually runs before copying annotations, since **annotations are controller-specific and are not part of the Ingress API**. The `spec.tls` block, by contrast, is portable across every controller.

---

## 4. Step 1 — obtain a certificate

For lab and exam purposes, generate a self-signed certificate with `openssl`. The critical part is the **subjectAltName**: modern clients ignore the CN entirely, so a certificate without a matching SAN will fail verification even if the CN looks right.

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout shop.key -out shop.crt \
  -subj "/CN=shop.example.com/O=teach-plat" \
  -addext "subjectAltName=DNS:shop.example.com"
```

```
..+.....+.......+..+.......+...+..+....+......+..+...+....+..+......+..
-----
```

Inspect what you produced — do this reflexively, it catches most mistakes:

```bash
openssl x509 -in shop.crt -noout -subject -issuer -dates -ext subjectAltName
```

```
subject=CN = shop.example.com, O = teach-plat
issuer=CN = shop.example.com, O = teach-plat
notBefore=Jul 29 09:14:02 2026 GMT
notAfter=Jul 29 09:14:02 2027 GMT
X509v3 Subject Alternative Name:
    DNS:shop.example.com
```

---

## 5. Step 2 — create the TLS Secret

The imperative form is the one to memorise; it is faster and it cannot get the key names wrong:

```bash
kubectl create secret tls shop-tls \
  --cert=shop.crt --key=shop.key \
  -n webshop
```

```
secret/shop-tls created
```

Verify the **type** and the **two required keys**. A Secret of type `Opaque`, or one whose keys are named `cert.pem`/`key.pem`, will be silently ignored by the controller:

```bash
kubectl get secret shop-tls -n webshop -o jsonpath='{.type}{"\n"}{range .data}{"\n"}{end}'
kubectl describe secret shop-tls -n webshop
```

```
kubernetes.io/tls

Name:         shop-tls
Namespace:    webshop
Type:         kubernetes.io/tls

Data
====
tls.crt:  1298 bytes
tls.key:  1704 bytes
```

The declarative equivalent, if you are asked to produce a manifest:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: shop-tls
  namespace: webshop
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...   # base64 of the full chain
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t...   # base64 of the private key
```

Generate the base64 without line wrapping — wrapped base64 is a classic source of "invalid certificate" errors:

```bash
kubectl create secret tls shop-tls --cert=shop.crt --key=shop.key \
  --dry-run=client -o yaml > shop-tls.yaml
```

**Chain order matters.** `tls.crt` must contain the leaf certificate *first*, followed by any intermediates, and normally *not* the root. A missing intermediate produces a certificate that works in a browser with a cached chain and fails in `curl` — test with `openssl s_client`, not with your browser.

---

## 6. Step 3 — the Ingress object

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: webshop
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - shop.example.com
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop-svc
                port:
                  number: 8080
```

```bash
kubectl apply -f shop-ingress.yaml
kubectl get ingress -n webshop
```

```
NAME   CLASS   HOSTS              ADDRESS        PORTS     AGE
shop   nginx   shop.example.com   10.98.144.27   80, 443   12s
```

The `PORTS` column showing `80, 443` is the quickest confirmation that the `tls` block was accepted. If it shows only `80`, your `spec.tls` is missing or malformed.

The imperative shortcut creates the rules but **not** the TLS block — you still have to edit or patch it in:

```bash
kubectl create ingress shop -n webshop \
  --class=nginx \
  --rule="shop.example.com/*=shop-svc:8080,tls=shop-tls"
```

The `,tls=<secret>` suffix on `--rule` *does* populate `spec.tls`, and is worth memorising for speed.

---

## 7. How the controller picks a certificate (SNI)

The controller builds one nginx `server` block per host. At handshake time it selects the certificate using the **SNI** value sent by the client, not the HTTP `Host` header — the certificate is chosen before any HTTP is parsed.

Consequences you must internalise:

- If the client sends no SNI (raw IP access, old tooling), the controller serves the **default certificate**.
- If the SNI host has no matching `spec.tls[].hosts` entry, you get the default certificate.
- The default certificate, unless configured, is a self-signed one identifying itself as `Kubernetes Ingress Controller Fake Certificate`. **Seeing that string is the canonical symptom of a broken TLS wiring** — the Ingress is working, but your Secret was not matched.

Diagnose exactly that:

```bash
openssl s_client -connect 10.98.144.27:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

Broken:
```
subject=O = Acme Co, CN = Kubernetes Ingress Controller Fake Certificate
issuer=O = Acme Co, CN = Kubernetes Ingress Controller Fake Certificate
```

Correct:
```
subject=CN = shop.example.com, O = teach-plat
issuer=CN = shop.example.com, O = teach-plat
notBefore=Jul 29 09:14:02 2026 GMT
notAfter=Jul 29 09:14:02 2027 GMT
```

To set a cluster-wide default certificate instead of the fake one, pass a flag to the controller Deployment:

```yaml
        args:
          - /nginx-ingress-controller
          - --default-ssl-certificate=ingress-nginx/default-tls
```

---

## 8. Forcing HTTPS

By default `ingress-nginx` already issues a `308` redirect from HTTP to HTTPS **for hosts that have TLS configured**. Two annotations control the behaviour:

```yaml
metadata:
  annotations:
    # redirect HTTP→HTTPS (default true when spec.tls covers the host)
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # redirect even when TLS is terminated upstream (LB/proxy) and the
    # controller receives plain HTTP with X-Forwarded-Proto
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

Verify:

```bash
curl -sI --resolve shop.example.com:80:10.98.144.27 http://shop.example.com/
```

```
HTTP/1.1 308 Permanent Redirect
Date: Wed, 29 Jul 2026 09:31:44 GMT
Content-Type: text/html
Location: https://shop.example.com
```

Add **HSTS** so browsers refuse plaintext on subsequent visits. HSTS is enabled by default in `ingress-nginx`, but the max-age and subdomain flags are worth setting explicitly in the controller ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  hsts: "true"
  hsts-max-age: "31536000"          # 1 year
  hsts-include-subdomains: "true"
```

Only enable `hsts-include-subdomains` when you genuinely serve every subdomain over TLS — it is effectively irreversible for the max-age duration.

---

## 9. Hardening the TLS configuration

Protocol and cipher selection is a **controller-level** setting, not per-Ingress. Edit the controller's ConfigMap:

```bash
kubectl edit configmap ingress-nginx-controller -n ingress-nginx
```

```yaml
data:
  ssl-protocols: "TLSv1.2 TLSv1.3"
  ssl-ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
  ssl-prefer-server-ciphers: "true"
  ssl-session-tickets: "false"       # avoid weakening forward secrecy
```

Notes:

- `ssl-protocols` is the control that removes TLS 1.0/1.1. Dropping them is the single highest-value hardening item here.
- `ssl-ciphers` applies to **TLS 1.2 and below**; TLS 1.3 cipher suites are fixed by the protocol and all of them are considered safe.
- Changes are picked up by nginx reload; no pod restart is needed, but confirm it happened:

```bash
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | tail -3
```

```
I0729 09:40:12.114  7 controller.go:213] "Configuration changes detected, backend reload required"
I0729 09:40:12.398  7 controller.go:230] "Backend successfully reloaded"
```

Confirm from the outside that a weak protocol is actually refused:

```bash
openssl s_client -connect 10.98.144.27:443 -servername shop.example.com -tls1_1 </dev/null
```

```
140234...:SSL alert number 70
no peer certificate available
```

---

## 10. Re-encrypting to the backend

By default, `ingress-nginx` terminates TLS and forwards **plaintext HTTP** inside the cluster. For workloads with real confidentiality requirements — or when the pod itself serves HTTPS — re-encrypt:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
    nginx.ingress.kubernetes.io/proxy-ssl-secret: "webshop/backend-ca"
    nginx.ingress.kubernetes.io/proxy-ssl-name: "shop-svc.webshop.svc"
```

Without `proxy-ssl-verify: "on"` the controller encrypts but does **not** validate the backend certificate — that is encryption without authentication, and it is the default. Expect this distinction to be examined.

---

## 11. Client certificate authentication (mTLS)

Requiring clients to present a certificate turns the Ingress into an authentication boundary. Create a Secret holding the CA that signed the client certificates:

```bash
kubectl create secret generic client-ca -n webshop --from-file=ca.crt=client-ca.crt
```

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
    nginx.ingress.kubernetes.io/auth-tls-secret: "webshop/client-ca"
    nginx.ingress.kubernetes.io/auth-tls-verify-depth: "1"
    nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream: "true"
```

Values for `auth-tls-verify-client`: `on` (required), `optional` (request, allow either, backend decides), `optional_no_ca` (request, do not validate — useful only when the backend does the validation), `off`.

Test:

```bash
# no client cert
curl -s -o /dev/null -w '%{http_code}\n' --cacert shop.crt \
  --resolve shop.example.com:443:10.98.144.27 https://shop.example.com/
```
```
400
```

```bash
# with client cert
curl -s -o /dev/null -w '%{http_code}\n' --cacert shop.crt \
  --cert client.crt --key client.key \
  --resolve shop.example.com:443:10.98.144.27 https://shop.example.com/
```
```
200
```

The Secret key **must** be named `ca.crt`. It must live in the namespace named in the annotation.

---

## 12. Automating certificates with cert-manager

Self-signed certificates are fine for the exam, but production hygiene means short-lived, auto-renewed certificates. `cert-manager` watches Ingress objects and creates the TLS Secret for you:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: webshop
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["shop.example.com"]
      secretName: shop-tls        # created and renewed by cert-manager
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: shop-svc, port: { number: 8080 } }
```

Security benefit worth stating explicitly: nobody handles the private key, and a 90-day certificate limits the blast radius of a key compromise.

---

## 13. Securing the Ingress controller itself

This is the part candidates skip and examiners like. The controller is a privileged, internet-facing component.

**Disable configuration snippets.** Snippet annotations let anyone who can create an Ingress inject arbitrary nginx configuration — including reading files from the controller pod. Modern versions default `allow-snippet-annotations` to `false`; make it explicit:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  allow-snippet-annotations: "false"
  annotation-value-word-blocklist: "load_module,lua_package,_by_lua,root,serviceaccount,{,},',\""
```

**Patch known CVEs.** The *IngressNightmare* cluster of vulnerabilities (CVE-2025-1974 plus CVE-2025-1097, CVE-2025-1098, CVE-2025-24513, CVE-2025-24514) allowed unauthenticated RCE against the `ingress-nginx` **admission webhook**, leading to full cluster secret disclosure. Fixed in 1.11.5 and 1.12.1. Check your version:

```bash
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- \
  /nginx-ingress-controller --version
```

```
NGINX Ingress controller
  Release:       v1.12.1
  Build:         ...
  Repository:    https://github.com/kubernetes/ingress-nginx
```

Mitigations when patching is not immediately possible: restrict network access to the admission webhook port (`8443`) with a NetworkPolicy so only the API server can reach it, or disable the admission controller.

**Constrain who can create Ingresses.** `Ingress` creation is effectively the power to route external traffic to any Service in the namespace, and — via `auth-tls-secret` / `proxy-ssl-secret` style annotations — to reference Secrets. Scope RBAC accordingly, and restrict Secret `get` permissions so a compromised workload cannot read `tls.key`.

**Restrict the Secret itself.** The private key sits in etcd as base64. Enable encryption at rest for Secrets (covered in the Cluster Hardening domain) and audit `get`/`list` on Secrets in the ingress namespaces.

---

## 14. Troubleshooting checklist

Work through this in order; it resolves nearly every failure.

```bash
# 1. Is the Ingress admitted and does it show 443?
kubectl get ingress -n webshop -o wide

# 2. Any events? (wrong secret name shows up here)
kubectl describe ingress shop -n webshop

# 3. Does the Secret exist, in the right namespace, with the right type?
kubectl get secret -n webshop shop-tls -o jsonpath='{.type}'

# 4. Did the controller load it?
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | grep -i ssl

# 5. What is actually served on the wire?
openssl s_client -connect <ADDRESS>:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates

# 6. End-to-end with verification enabled
curl -v --cacert shop.crt --resolve shop.example.com:443:<ADDRESS> https://shop.example.com/
```

Typical `describe` output when the Secret is missing:

```
Events:
  Type     Reason  Age   From                      Message
  ----     ------  ----  ----                      -------
  Warning  Sync    10s   nginx-ingress-controller  Error obtaining X.509 certificate:
                                                   secret webshop/shop-tls was not found
```

Successful `curl` handshake:

```
* Server certificate:
*  subject: CN=shop.example.com; O=teach-plat
*  start date: Jul 29 09:14:02 2026 GMT
*  expire date: Jul 29 09:14:02 2027 GMT
*  SSL certificate verify ok.
> GET / HTTP/2
< HTTP/2 200
< strict-transport-security: max-age=31536000; includeSubDomains
```

---

## 15. Common exam pitfalls

| Symptom | Cause |
|---|---|
| Fake Certificate served | Host in SNI not present in `spec.tls[].hosts`, or Secret in the wrong namespace |
| `PORTS` shows only `80` | `spec.tls` missing or the whole block indented under the wrong key |
| Secret ignored | Type is `Opaque` instead of `kubernetes.io/tls`, or keys not named `tls.crt`/`tls.key` |
| Works in browser, fails in `curl` | Missing intermediate certificate in `tls.crt` |
| Nothing happens at all | `spec.ingressClassName` omitted or misspelled; no controller claims the object |
| `curl` complains about the name | Certificate has a CN but no matching SAN |
| Cipher/protocol change has no effect | Edited the Ingress annotations instead of the controller ConfigMap |
| mTLS rejects everyone | CA Secret key not named `ca.crt`, or `auth-tls-secret` missing the `namespace/` prefix |

**Speed tips:** the Secret must be in the *workload* namespace, not `ingress-nginx`. Use `kubectl create ingress ... --rule="host/path=svc:port,tls=secret"` to generate a correct skeleton, then `kubectl explain ingress.spec.tls` if you forget a field name — `explain` is available in the exam and is faster than the docs site.

---

## Referencias

- Kubernetes — Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/#tls
- Kubernetes — Ingress Controllers: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Kubernetes — TLS Secrets: https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
- Kubernetes — `kubectl create ingress`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-ingress-em-
- ingress-nginx — TLS/HTTPS user guide: https://kubernetes.github.io/ingress-nginx/user-guide/tls/
- ingress-nginx — Annotations reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- ingress-nginx — ConfigMap reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
- ingress-nginx — Hardening guide: https://kubernetes.github.io/ingress-nginx/deploy/hardening-guide/
- ingress-nginx — Client certificate authentication: https://kubernetes.github.io/ingress-nginx/examples/auth/client-certs/
- Kubernetes blog — "Ingress-nginx CVE-2025-1974: What You Need to Know": https://kubernetes.io/blog/2025/03/24/ingress-nginx-cve-2025-1974/
- cert-manager — Securing Ingress resources: https://cert-manager.io/docs/usage/ingress/
- CNCF — CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf