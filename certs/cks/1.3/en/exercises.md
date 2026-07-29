# CKS 1.3 — Properly Set Up Ingress Objects with TLS

**Domain:** Cluster Setup · **Exam weight of this task:** 3 · **Exam version:** CKS v1.34

These are hands-on guided exercises. Run every step in a scratch cluster (kind, minikube, kubeadm) where you are free to break things. Each block ends with comprehension questions; all answers are collapsed at the bottom.

---

## Lab prerequisites

You need:

- A working cluster and `kubectl` context (`kubectl get nodes` returns `Ready`).
- `openssl` and `curl` on your workstation.
- An ingress controller. These exercises use **ingress-nginx**, because it is the controller most commonly present in CKS-style environments. The concepts (TLS Secret, `spec.tls`, SNI, mTLS) are portable; the *annotations* are not.

> **Note on ingress-nginx lifecycle:** the Kubernetes project has announced that ingress-nginx is winding down in favour of a successor project. Exam environments lag behind announcements, so keep practising with it, but check the controller version in front of you (`kubectl -n ingress-nginx get deploy ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].image}'`) before assuming an annotation exists.

---

## Exercise 0 — Prepare the environment

1. Install the ingress-nginx controller (skip if your cluster already has one):

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
   ```

2. Wait until the controller pod is ready:

   ```bash
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
   kubectl -n ingress-nginx get pods -o wide
   ```

3. Confirm that an `IngressClass` was registered and note whether it is the default:

   ```bash
   kubectl get ingressclass -o wide
   kubectl get ingressclass nginx -o jsonpath='{.metadata.annotations}' ; echo
   ```

4. Find out how to reach the controller from your shell. Record the node IP and the HTTPS node port:

   ```bash
   kubectl -n ingress-nginx get svc ingress-nginx-controller

   export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
   export HTTPS_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
     -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
   export HTTP_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
     -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
   echo "$NODE_IP  http=$HTTP_PORT  https=$HTTPS_PORT"
   ```

   If the Service is `LoadBalancer` with a real external IP, use that IP with ports 80/443 instead.

5. Hit the controller directly, with no Ingress defined yet, and inspect the certificate it presents:

   ```bash
   curl -kv "https://$NODE_IP:$HTTPS_PORT/" 2>&1 | grep -E "subject|issuer|HTTP/"
   ```

6. Create the working namespace:

   ```bash
   kubectl create namespace shop
   ```

### Comprehension check — Block 0

- **Q0.1** In step 5, before you created any Ingress, the controller still completed a TLS handshake. Which certificate did it serve, and what does that tell you about how nginx handles a request whose SNI matches no Ingress?
- **Q0.2** What is the difference between `IngressClass` and the legacy `kubernetes.io/ingress.class` annotation, and which one should you use on `networking.k8s.io/v1` objects?
- **Q0.3** From a security standpoint, why is it a problem to leave the controller's built-in fake certificate in place for production traffic, even though clients could technically ignore the warning?

---

## Exercise 1 — Build a private CA and a server certificate

You will act as your own CA so you can later reuse it for client-certificate authentication.

1. Create a lab directory and generate the CA key and self-signed CA certificate:

   ```bash
   mkdir -p ~/cks13 && cd ~/cks13

   openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
     -keyout ca.key -out ca.crt \
     -subj "/CN=cks-lab-ca/O=cks-lab"
   ```

2. Generate the server key and a CSR for `shop.cks.lab`:

   ```bash
   openssl req -nodes -newkey rsa:2048 \
     -keyout shop.key -out shop.csr \
     -subj "/CN=shop.cks.lab/O=cks-lab"
   ```

3. Sign the CSR with your CA, adding the extensions a modern client requires:

   ```bash
   openssl x509 -req -in shop.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out shop.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:shop.cks.lab\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
   ```

4. Inspect what you produced:

   ```bash
   openssl x509 -in shop.crt -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage
   ```

5. Verify the chain locally before you ever push it to the cluster:

   ```bash
   openssl verify -CAfile ca.crt shop.crt
   ```

6. Confirm the key and the certificate actually belong together (the single most common cause of a broken Ingress):

   ```bash
   openssl x509 -in shop.crt -noout -pubkey | openssl sha256
   openssl pkey -in shop.key -pubout      | openssl sha256
   ```

   The two digests must match.

### Comprehension check — Block 1

- **Q1.1** You omitted `subjectAltName` on a first attempt and `curl` still refused the certificate even though `CN=shop.cks.lab` was correct. Why?
- **Q1.2** What does `extendedKeyUsage=serverAuth` restrict, and what would you set instead for a certificate that a client presents to the Ingress?
- **Q1.3** In step 6 you compared two SHA-256 digests. What symptom would you see at request time if they did not match?
- **Q1.4** Why is `-nodes` (no DES / unencrypted private key) acceptable here but questionable outside a lab? How does Kubernetes constrain your choice?

---

## Exercise 2 — Create the TLS Secret and the Ingress

1. Deploy a trivial backend to route to:

   ```bash
   kubectl -n shop create deployment shop --image=nginx:1.27-alpine --replicas=2
   kubectl -n shop expose deployment shop --port=80 --target-port=80
   kubectl -n shop get svc shop
   ```

2. Create the TLS Secret. Learn both the imperative form (fast in the exam) and the manifest form:

   ```bash
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=shop.key

   # the same thing as YAML, useful when you must edit before applying
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=shop.key \
     --dry-run=client -o yaml > shop-tls-secret.yaml
   ```

3. Inspect the object that was created:

   ```bash
   kubectl -n shop get secret shop-tls -o jsonpath='{.type}{"\n"}'
   kubectl -n shop get secret shop-tls -o jsonpath='{.data}' | tr ',' '\n'
   kubectl -n shop get secret shop-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | \
     openssl x509 -noout -subject -dates
   ```

4. Write the Ingress:

   ```yaml
   # shop-ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: shop
     namespace: shop
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - shop.cks.lab
       secretName: shop-tls
     rules:
     - host: shop.cks.lab
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: shop
               port:
                 number: 80
   ```

   ```bash
   kubectl apply -f shop-ingress.yaml
   kubectl -n shop describe ingress shop
   ```

5. Test TLS termination. `--resolve` fakes DNS so the SNI and Host header are correct without editing `/etc/hosts`:

   ```bash
   curl -v --cacert ca.crt \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/"
   ```

   You should see `SSL certificate verify ok`, `subject: CN=shop.cks.lab`, and `HTTP/2 200`.

6. Now request the same IP with a *different* hostname and observe the fallback:

   ```bash
   curl -kv --resolve "other.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://other.cks.lab:$HTTPS_PORT/" 2>&1 | grep -E "subject:|issuer:|HTTP/"
   ```

7. Break it deliberately, then fix it. Copy the Secret into the wrong namespace and point the Ingress at it:

   ```bash
   kubectl create namespace shop-certs
   kubectl -n shop get secret shop-tls -o yaml \
     | sed 's/namespace: shop/namespace: shop-certs/' \
     | kubectl apply -f -

   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"replace","path":"/spec/tls/0/secretName","value":"shop-certs/shop-tls"}]'

   curl -kv --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/" 2>&1 | grep -E "subject:|issuer:"

   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=30 | grep -i secret
   ```

   Restore the correct value:

   ```bash
   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"replace","path":"/spec/tls/0/secretName","value":"shop-tls"}]'
   ```

### Comprehension check — Block 2

- **Q2.1** What exactly does `kubectl create secret tls` do that `kubectl create secret generic` does not? Name the resulting `type` and the two mandatory keys.
- **Q2.2** In step 6, a request for `other.cks.lab` was still answered over TLS. Which certificate was served, and why is this behaviour a fingerprinting/enumeration concern?
- **Q2.3** Step 7 failed even though the Secret existed and contained a valid certificate. State the rule about Secret placement relative to the Ingress object.
- **Q2.4** `spec.tls[].hosts` and `spec.rules[].host` are separate fields. What breaks if you list a host under `rules` but forget it under `tls`?
- **Q2.5** `kubectl get secret shop-tls -o yaml` shows the private key base64-encoded. Is that encryption? What cluster-level control actually protects it at rest, and what protects it from other users?

---

## Exercise 3 — Force HTTPS and remove the plaintext path

1. Confirm that plain HTTP currently works or redirects. Observe the default behaviour:

   ```bash
   curl -v --resolve "shop.cks.lab:$HTTP_PORT:$NODE_IP" \
        "http://shop.cks.lab:$HTTP_PORT/" 2>&1 | grep -E "^< HTTP|^< Location"
   ```

2. Disable the redirect explicitly to see the insecure state, then restore it:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/ssl-redirect="false" --overwrite

   curl -s --resolve "shop.cks.lab:$HTTP_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "http://shop.cks.lab:$HTTP_PORT/"
   ```

3. Turn the redirect back on and make it unconditional:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/ssl-redirect="true" \
     nginx.ingress.kubernetes.io/force-ssl-redirect="true" --overwrite

   curl -v --resolve "shop.cks.lab:$HTTP_PORT:$NODE_IP" \
        "http://shop.cks.lab:$HTTP_PORT/" 2>&1 | grep -E "^< HTTP|^< Location"
   ```

4. Add HSTS so browsers refuse plaintext on their own, cluster-wide:

   ```bash
   kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{
     "data": {
       "hsts": "true",
       "hsts-max-age": "31536000",
       "hsts-include-subdomains": "true"
     }
   }'
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

5. Verify the header is present on the HTTPS response:

   ```bash
   curl -sI --cacert ca.crt --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/" | grep -i strict-transport
   ```

### Comprehension check — Block 3

- **Q3.1** What is the practical difference between `ssl-redirect` and `force-ssl-redirect`? When does the plain `ssl-redirect` silently do nothing?
- **Q3.2** A 308 redirect still means the first request travelled in cleartext. What does the attacker learn from it, and which mechanism closes that first-request window on *subsequent* visits?
- **Q3.3** Why is HSTS with `includeSubDomains` and a one-year max-age dangerous to enable casually on a shared domain?
- **Q3.4** You set `hsts` in a ConfigMap rather than an annotation. Which scope does each change affect, and why does the ConfigMap route require a controller reload check?

---

## Exercise 4 — Multiple hosts, SNI, and a default certificate

1. Generate a second certificate, this time a wildcard for `*.api.cks.lab`:

   ```bash
   cd ~/cks13
   openssl req -nodes -newkey rsa:2048 -keyout api.key -out api.csr \
     -subj "/CN=*.api.cks.lab/O=cks-lab"

   openssl x509 -req -in api.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out api.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:*.api.cks.lab,DNS:api.cks.lab\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

   kubectl -n shop create secret tls api-tls --cert=api.crt --key=api.key
   ```

2. Add a second host to the Ingress with its own TLS entry:

   ```yaml
   # shop-ingress-multi.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: shop
     namespace: shop
     annotations:
       nginx.ingress.kubernetes.io/ssl-redirect: "true"
       nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - shop.cks.lab
       secretName: shop-tls
     - hosts:
       - v1.api.cks.lab
       secretName: api-tls
     rules:
     - host: shop.cks.lab
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: shop
               port:
                 number: 80
     - host: v1.api.cks.lab
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: shop
               port:
                 number: 80
   ```

   ```bash
   kubectl apply -f shop-ingress-multi.yaml
   ```

3. Prove that SNI selects the certificate, not the IP:

   ```bash
   for H in shop.cks.lab v1.api.cks.lab; do
     echo "--- $H"
     curl -s --cacert ca.crt --resolve "$H:$HTTPS_PORT:$NODE_IP" \
          -o /dev/null -w "%{http_code}\n" "https://$H:$HTTPS_PORT/"
     openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername "$H" </dev/null 2>/dev/null \
       | openssl x509 -noout -subject
   done
   ```

4. Now repeat without SNI to see what an old client or a scanner receives:

   ```bash
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -noservername </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -issuer
   ```

5. Replace the controller's fallback certificate with one you control:

   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
     -keyout default.key -out default.crt \
     -subj "/CN=invalid.cks.lab/O=cks-lab" \
     -addext "subjectAltName=DNS:invalid.cks.lab"

   kubectl -n ingress-nginx create secret tls default-tls \
     --cert=default.crt --key=default.key

   kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type=json -p='[
     {"op":"add","path":"/spec/template/spec/containers/0/args/-",
      "value":"--default-ssl-certificate=ingress-nginx/default-tls"}
   ]'
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

6. Verify the fallback changed:

   ```bash
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername unknown.cks.lab </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -issuer
   ```

### Comprehension check — Block 4

- **Q4.1** Two hosts, one IP, two different certificates. Which TLS extension makes this possible, and at which point of the handshake is the hostname visible on the wire?
- **Q4.2** Why does the wildcard `*.api.cks.lab` cover `v1.api.cks.lab` but not `api.cks.lab` or `a.b.api.cks.lab`?
- **Q4.3** Wildcard certificates are convenient. Name two security drawbacks compared with per-host certificates.
- **Q4.4** What is the blast radius of a compromised `--default-ssl-certificate` Secret versus a per-Ingress Secret?
- **Q4.5** Two Ingress objects in different namespaces both declare `host: shop.cks.lab`. What does the controller do, and why is this a tenant-isolation problem?

---

## Exercise 5 — Harden the TLS parameters

1. Baseline the current negotiation. Check which protocol versions the controller accepts:

   ```bash
   for P in tls1 tls1_1 tls1_2 tls1_3; do
     printf "%-8s " "$P"
     openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername shop.cks.lab \
       "-$P" </dev/null >/dev/null 2>&1 && echo ACCEPTED || echo refused
   done
   ```

2. Restrict protocols and ciphers globally in the controller ConfigMap:

   ```bash
   kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{
     "data": {
       "ssl-protocols": "TLSv1.3",
       "ssl-ciphers": "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305",
       "ssl-prefer-server-ciphers": "true",
       "ssl-session-tickets": "false"
     }
   }'
   ```

3. Confirm the configuration reached nginx itself, not just the API server:

   ```bash
   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -E "ssl_protocols|ssl_ciphers|ssl_session_tickets" /etc/nginx/nginx.conf
   ```

4. Re-run the protocol sweep from step 1 and confirm that TLS 1.2 and below are refused.

5. Try to override the protocol on a single Ingress and observe what happens:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/ssl-ciphers="ECDHE-RSA-AES128-GCM-SHA256" --overwrite

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "ssl_ciphers" /etc/nginx/nginx.conf | head -20
   ```

6. Reduce the annotation attack surface of the controller:

   ```bash
   kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{
     "data": {
       "allow-snippet-annotations": "false",
       "annotations-risk-level": "High"
     }
   }'
   kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

7. Prove the restriction works by attempting to inject raw nginx configuration from a namespaced Ingress:

   ```bash
   kubectl -n shop annotate ingress shop \
     'nginx.ingress.kubernetes.io/configuration-snippet=more_set_headers "X-Injected: yes";' --overwrite

   kubectl -n shop describe ingress shop | tail -20
   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=30 | grep -i -E "snippet|annotation"
   ```

   Clean up the annotation afterwards:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/configuration-snippet- \
     nginx.ingress.kubernetes.io/ssl-ciphers- --overwrite
   ```

### Comprehension check — Block 5

- **Q5.1** `ssl-protocols` is only settable in the ConfigMap, while `ssl-ciphers` also exists as a per-Ingress annotation. What does that asymmetry imply about which team owns protocol policy?
- **Q5.2** Why does `ssl-prefer-server-ciphers` matter, and why is it largely irrelevant once you pin `ssl-protocols: TLSv1.3`?
- **Q5.3** You disabled TLS session tickets. What property does that improve, and what is the performance cost?
- **Q5.4** Explain concretely how `configuration-snippet` on a namespaced Ingress can become a cluster-wide compromise. Why is `allow-snippet-annotations: "false"` a CKS-relevant hardening step and not just tidiness?
- **Q5.5** In step 3 you exec'd into the pod to read `nginx.conf`. Why is verifying the rendered config more trustworthy than verifying the ConfigMap?

---

## Exercise 6 — Client certificate authentication (mTLS) at the Ingress

1. Publish the CA certificate that the Ingress will use to validate clients. The Secret must live in the Ingress's namespace and carry the key `ca.crt`:

   ```bash
   cd ~/cks13
   kubectl -n shop create secret generic shop-client-ca --from-file=ca.crt=ca.crt
   kubectl -n shop get secret shop-client-ca -o jsonpath='{.data}' | tr ',' '\n'
   ```

2. Enable mTLS on the Ingress:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/auth-tls-secret="shop/shop-client-ca" \
     nginx.ingress.kubernetes.io/auth-tls-verify-client="on" \
     nginx.ingress.kubernetes.io/auth-tls-verify-depth="1" \
     nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream="true" \
     --overwrite
   ```

3. Confirm the request is now rejected without a client certificate:

   ```bash
   curl -s --cacert ca.crt --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "https://shop.cks.lab:$HTTPS_PORT/"
   ```

4. Issue a client certificate from the same CA:

   ```bash
   openssl req -nodes -newkey rsa:2048 -keyout client.key -out client.csr \
     -subj "/CN=alice/O=shop-clients"

   openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out client.crt -days 30 \
     -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n")

   openssl x509 -in client.crt -noout -subject -ext extendedKeyUsage
   ```

5. Retry with the client certificate attached:

   ```bash
   curl -s --cacert ca.crt --cert client.crt --key client.key \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "https://shop.cks.lab:$HTTPS_PORT/"
   ```

6. Observe what the backend receives, since you enabled certificate pass-through:

   ```bash
   kubectl -n shop exec deploy/shop -- sh -c \
     'sed -i "s|location / {|location / { add_header X-Seen-Client \$http_ssl_client_subject_dn always;|" /etc/nginx/conf.d/default.conf && nginx -s reload' 2>/dev/null

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "ssl-client-verify\|ssl_client_s_dn\|proxy_set_header ssl-client" /etc/nginx/nginx.conf | head
   ```

7. Switch to `optional` mode and see the difference in who decides:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/auth-tls-verify-client="optional" --overwrite

   curl -s --cacert ca.crt --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "https://shop.cks.lab:$HTTPS_PORT/"
   ```

8. Restore `on` before continuing:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/auth-tls-verify-client="on" --overwrite
   ```

### Comprehension check — Block 6

- **Q6.1** Why must the client-CA Secret use the key name `ca.crt` and be a plain `Opaque`/generic Secret rather than `kubernetes.io/tls`?
- **Q6.2** What does `auth-tls-verify-depth: "1"` limit, and what attack does a large depth enable if an intermediate CA is compromised?
- **Q6.3** With `auth-tls-verify-client: optional`, an unauthenticated request reaches the backend. Which header must the backend then check, and what happens if the application ignores it?
- **Q6.4** `auth-tls-pass-certificate-to-upstream: "true"` forwards the client certificate as a request header. Why is this dangerous if the backend Service can also be reached directly from inside the cluster (bypassing the Ingress)?
- **Q6.5** mTLS at the Ingress authenticates the *client to the edge*. Name the segment of the path it does **not** protect, and which exercise addresses it.

---

## Exercise 7 — Protect the traffic behind the Ingress

TLS termination at the edge means controller-to-pod traffic is plaintext by default. Fix that two different ways.

1. Give the backend its own certificate and make it serve HTTPS:

   ```bash
   cd ~/cks13
   openssl req -nodes -newkey rsa:2048 -keyout backend.key -out backend.csr \
     -subj "/CN=shop.shop.svc.cluster.local/O=cks-lab"

   openssl x509 -req -in backend.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out backend.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:shop.shop.svc.cluster.local,DNS:shop.shop.svc\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

   kubectl -n shop create secret tls backend-tls --cert=backend.crt --key=backend.key
   ```

2. Reconfigure the backend nginx to listen on 8443 with TLS:

   ```bash
   kubectl -n shop create configmap backend-nginx --from-literal=default.conf='
   server {
     listen 8443 ssl;
     ssl_certificate     /etc/tls/tls.crt;
     ssl_certificate_key /etc/tls/tls.key;
     ssl_protocols       TLSv1.3;
     location / { return 200 "backend over TLS\n"; }
   }
   '

   kubectl -n shop patch deploy shop --type=strategic -p '{
     "spec":{"template":{"spec":{
       "volumes":[
         {"name":"tls","secret":{"secretName":"backend-tls","defaultMode":256}},
         {"name":"conf","configMap":{"name":"backend-nginx"}}
       ],
       "containers":[{"name":"nginx","volumeMounts":[
         {"name":"tls","mountPath":"/etc/tls","readOnly":true},
         {"name":"conf","mountPath":"/etc/nginx/conf.d","readOnly":true}
       ]}]
     }}}
   }'
   kubectl -n shop rollout status deploy/shop
   ```

3. Repoint the Service and tell the controller to speak HTTPS upstream:

   ```bash
   kubectl -n shop patch svc shop --type=merge \
     -p '{"spec":{"ports":[{"name":"https","port":443,"targetPort":8443,"protocol":"TCP"}]}}'

   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/backend-protocol="HTTPS" --overwrite

   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":443}]'
   ```

4. Test end to end and confirm the controller reaches the pod over TLS:

   ```bash
   curl -s --cacert ca.crt --cert client.crt --key client.key \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/"

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "proxy_pass https" /etc/nginx/nginx.conf | head
   ```

5. Add upstream verification, which `backend-protocol: HTTPS` alone does **not** do:

   ```bash
   kubectl -n shop create secret generic upstream-ca --from-file=ca.crt=ca.crt

   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/proxy-ssl-secret="shop/upstream-ca" \
     nginx.ingress.kubernetes.io/proxy-ssl-verify="on" \
     nginx.ingress.kubernetes.io/proxy-ssl-verify-depth="1" \
     nginx.ingress.kubernetes.io/proxy-ssl-name="shop.shop.svc.cluster.local" \
     --overwrite

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "proxy_ssl_verify\|proxy_ssl_name\|proxy_ssl_trusted" /etc/nginx/nginx.conf | head
   ```

6. Contrast with SSL passthrough, where the controller does not terminate at all. Enable the flag and read the caveat:

   ```bash
   kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type=json -p='[
     {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}
   ]'
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

   ```yaml
   # passthrough example — do NOT combine with the mTLS annotations above
   metadata:
     annotations:
       nginx.ingress.kubernetes.io/ssl-passthrough: "true"
       nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
   ```

### Comprehension check — Block 7

- **Q7.1** `backend-protocol: "HTTPS"` makes the controller use `proxy_pass https://…`. Does it validate the backend certificate by default? What did step 5 add, and which annotation supplies the trusted CA?
- **Q7.2** Why does the backend certificate's SAN use `shop.shop.svc.cluster.local` rather than `shop.cks.lab`?
- **Q7.3** With `ssl-passthrough` enabled, why do path-based rules, HTTP headers, WAF rules, and the mTLS annotations stop working for that host?
- **Q7.4** `ssl-passthrough` routes by SNI at layer 4 for the whole controller. Why is enabling it a global decision with a performance and observability cost?
- **Q7.5** You mounted the backend TLS Secret with `defaultMode: 256`. What is that in octal, and why does it matter for a private key?

---

## Exercise 8 — Secure the Ingress control plane itself

The Ingress controller is a high-value target: it holds every TLS private key it serves and it terminates all external traffic.

1. Inspect what the controller is actually allowed to read:

   ```bash
   kubectl -n ingress-nginx get sa
   kubectl get clusterrole ingress-nginx -o yaml | grep -A8 "secrets"
   kubectl auth can-i get secrets --all-namespaces \
     --as=system:serviceaccount:ingress-nginx:ingress-nginx
   ```

2. Enumerate every TLS Secret the controller could reach — this is the blast radius of one compromised pod:

   ```bash
   kubectl get secrets --all-namespaces --field-selector type=kubernetes.io/tls
   ```

3. Reduce the scope with `--watch-namespace` (single-tenant controllers) or verify whether your deployment already limits it:

   ```bash
   kubectl -n ingress-nginx get deploy ingress-nginx-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
   ```

4. Review the admission webhook. It is the component behind CVE-2025-1974 ("IngressNightmare"), where crafted Ingress objects could lead to remote code execution in the controller:

   ```bash
   kubectl get validatingwebhookconfiguration ingress-nginx-admission -o yaml \
     | grep -E "name:|clientConfig:|service:|port:|failurePolicy:"

   kubectl -n ingress-nginx get svc ingress-nginx-controller-admission
   ```

   Mitigations to be able to name: run a patched controller version; ensure the admission Service is not reachable from arbitrary pods; and if you do not use the webhook, remove the `ValidatingWebhookConfiguration` and the `--validating-webhook` args.

5. Restrict who can reach the admission endpoint with a NetworkPolicy:

   ```yaml
   # ingress-admission-netpol.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: admission-webhook-lockdown
     namespace: ingress-nginx
   spec:
     podSelector:
       matchLabels:
         app.kubernetes.io/component: controller
     policyTypes: ["Ingress"]
     ingress:
     - ports:
       - protocol: TCP
         port: 80
       - protocol: TCP
         port: 443
   ```

   ```bash
   kubectl apply -f ingress-admission-netpol.yaml
   ```

   Note that port 8443 (admission) is deliberately absent, so only the API server path you explicitly allow — or none, if you removed the webhook — can reach it.

6. Check the controller's own runtime posture:

   ```bash
   kubectl -n ingress-nginx get deploy ingress-nginx-controller \
     -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | python3 -m json.tool
   ```

7. Confirm which users can create Ingress objects at all, since an Ingress is a routing-authority grant:

   ```bash
   kubectl auth can-i create ingresses -n shop --as=system:serviceaccount:shop:default
   kubectl get clusterrolebindings -o json \
     | grep -B5 -A5 "edit" | head -40
   ```

### Comprehension check — Block 8

- **Q8.1** The default ingress-nginx ClusterRole can read Secrets across the cluster. Explain the exact escalation path from "attacker gets RCE in the controller pod" to "attacker impersonates every HTTPS site behind this controller."
- **Q8.2** Which two configuration changes most directly shrink that blast radius, and what functionality do you give up with each?
- **Q8.3** Why is `NET_BIND_SERVICE` in the controller's capability list, and why is it acceptable while `allowPrivilegeEscalation: true` would not be?
- **Q8.4** A developer with `edit` in namespace `shop` creates an Ingress claiming `host: payments.cks.lab`, a hostname owned by another team. What has effectively happened, and which admission-time control (name one) prevents it?
- **Q8.5** Why does removing an unused `ValidatingWebhookConfiguration` count as attack-surface reduction rather than a patch?

---

## Exercise 9 — Troubleshooting drill

Work these three broken scenarios end to end. Break, diagnose from evidence, then fix.

1. **Scenario A — wrong key pair.** Swap in a mismatched key and observe:

   ```bash
   cd ~/cks13
   openssl genrsa -out wrong.key 2048
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=wrong.key \
     --dry-run=client -o yaml | kubectl apply -f -

   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=40 | grep -i -E "error|certificate|key"
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername shop.cks.lab </dev/null 2>/dev/null \
     | openssl x509 -noout -subject
   ```

   Fix:

   ```bash
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=shop.key \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

2. **Scenario B — expired certificate.** Issue a certificate that is already expired and see how the failure differs from Scenario A:

   ```bash
   openssl x509 -req -in shop.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out expired.crt -days -1 \
     -extfile <(printf "subjectAltName=DNS:shop.cks.lab\nbasicConstraints=CA:FALSE\n")

   kubectl -n shop create secret tls shop-tls --cert=expired.crt --key=shop.key \
     --dry-run=client -o yaml | kubectl apply -f -

   curl -sv --cacert ca.crt --cert client.crt --key client.key \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/" 2>&1 | grep -iE "expire|certificate|SSL"

   # audit every TLS secret's expiry
   kubectl get secrets -A --field-selector type=kubernetes.io/tls \
     -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.data.tls\.crt}{"\n"}{end}' \
   | while IFS=$'\t' read -r NAME CRT; do
       END=$(echo "$CRT" | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
       printf "%-40s %s\n" "$NAME" "$END"
     done
   ```

   Fix by restoring the valid certificate.

3. **Scenario C — wrong or missing IngressClass.** Remove the class and diagnose the silent failure:

   ```bash
   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"remove","path":"/spec/ingressClassName"}]'

   kubectl -n shop get ingress shop
   kubectl -n shop describe ingress shop | grep -A5 Events
   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=20
   ```

   Fix:

   ```bash
   kubectl -n shop patch ingress shop --type=merge \
     -p '{"spec":{"ingressClassName":"nginx"}}'
   kubectl -n shop get ingress shop -o wide
   ```

4. **Rotation without downtime.** Confirm the controller picks up a new certificate on Secret update alone:

   ```bash
   openssl req -nodes -newkey rsa:2048 -keyout shop2.key -out shop2.csr \
     -subj "/CN=shop.cks.lab/O=cks-lab-rotated"
   openssl x509 -req -in shop2.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out shop2.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:shop.cks.lab\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n")

   kubectl -n shop create secret tls shop-tls --cert=shop2.crt --key=shop2.key \
     --dry-run=client -o yaml | kubectl apply -f -

   sleep 5
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername shop.cks.lab </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -serial
   ```

### Comprehension check — Block 9

- **Q9.1** In Scenario A the endpoint kept answering TLS. Which certificate was served, and why is "the site still works over HTTPS" a misleading health signal?
- **Q9.2** Scenario B fails on the client, not the controller. Why does the controller happily load an expired certificate, and what does that tell you about where expiry monitoring must live?
- **Q9.3** In Scenario C the Ingress object existed and was accepted by the API server, yet nothing routed. What does an empty `ADDRESS` column mean, and why is there usually no error event?
- **Q9.4** Step 4 rotated the certificate with no pod restart. Which controller behaviour makes that possible, and what implication does it have for a controller running with `--watch-namespace`?
- **Q9.5** Write the one-liner you would run in the exam to list every `kubernetes.io/tls` Secret in the cluster together with its subject and expiry.

---

## Cleanup

```bash
kubectl delete namespace shop shop-certs --ignore-not-found
kubectl -n ingress-nginx delete secret default-tls --ignore-not-found
kubectl delete -f ingress-admission-netpol.yaml --ignore-not-found
rm -rf ~/cks13
```

---

<details>
<summary><strong>Answers</strong></summary>

### Block 0

**A0.1** It served ingress-nginx's built-in self-signed *fake* certificate (issuer/subject typically `Kubernetes Ingress Controller Fake Certificate`). nginx must complete the TLS handshake before it can read the HTTP `Host` header, so it always needs *some* certificate. When SNI matches no configured server block, it falls back to the default certificate and then usually returns `404`. The lesson: a successful handshake proves nothing about whether your Ingress is wired correctly.

**A0.2** `IngressClass` is a real cluster-scoped API object referenced by `spec.ingressClassName`; it names a controller (`spec.controller: k8s.io/ingress-nginx`) and can carry parameters. The `kubernetes.io/ingress.class` annotation is the pre-1.18 mechanism, deprecated and only honoured by some controllers for backwards compatibility. On `networking.k8s.io/v1` always use `spec.ingressClassName`. An `IngressClass` annotated `ingressclass.kubernetes.io/is-default-class: "true"` is applied to Ingresses that omit the field — convenient, but it also means a typo'd class name behaves very differently from an absent one.

**A0.3** Clients cannot distinguish the controller's fake certificate from an attacker's self-signed certificate, so users are trained to click through warnings, and any tooling that sets `--insecure`/`InsecureSkipVerify` to cope with it loses MITM protection permanently. It also leaks that the endpoint is an unconfigured ingress-nginx, which is useful reconnaissance.

### Block 1

**A1.1** Since roughly 2017 all mainstream TLS clients (and Go's crypto/tls, which most Kubernetes tooling uses) ignore `CN` for hostname verification entirely and require a matching `subjectAltName` DNS entry (RFC 6125 / CA-Browser Forum). A certificate with only a CN is treated as having no valid names.

**A1.2** `extendedKeyUsage=serverAuth` marks the certificate as valid for authenticating a *server* during TLS. A verifier that enforces EKU will reject it if presented as a client credential. For a client certificate you set `extendedKeyUsage=clientAuth` (as done in Exercise 6, step 4). Constraining EKU prevents a single leaked keypair from being usable in both directions.

**A1.3** nginx would fail to load the keypair. Depending on version and timing you either see the controller log an error and keep the previous/fallback certificate, or the server block never materialises — externally it looks like "the wrong certificate is being served" or a handshake failure, not an obvious configuration error. That is exactly Scenario A in Exercise 9.

**A1.4** `-nodes` writes the private key unencrypted. Outside a lab you would normally protect a key at rest with a passphrase or an HSM/KMS. Kubernetes forces your hand: the kubelet must be able to mount the key and nginx must read it non-interactively, so a `kubernetes.io/tls` Secret **must** contain an unencrypted PEM key. The protection therefore has to come from elsewhere — etcd encryption at rest, RBAC on the Secret, and a short certificate lifetime.

### Block 2

**A2.1** `kubectl create secret tls` creates a Secret of type `kubernetes.io/tls` and enforces the presence of exactly the keys `tls.crt` and `tls.key`; the API server validates that both are present for that type. A generic Secret has type `Opaque` and no key constraints, so an Ingress referencing it will fail to find the expected data.

**A2.2** The controller's default certificate (the fake one, or `default-tls` after Exercise 4). Because *every* unmatched SNI gets the same fallback, a scanner can walk a hostname list against one IP and tell configured hosts from unconfigured ones purely by which certificate comes back — a free enumeration oracle for your internal hostnames.

**A2.3** `spec.tls[].secretName` is resolved **in the Ingress's own namespace**. A `namespace/name` string is not valid there (unlike some annotations such as `auth-tls-secret`, which *do* take `namespace/name`). The Secret must be copied into, or created in, the same namespace as the Ingress. This is deliberate isolation: it stops namespace A from mounting namespace B's private key by reference.

**A2.4** Routing still works, but that host gets no certificate of its own — nginx serves the default/fallback certificate for it, so clients see a name-mismatch error. `rules` controls *routing*; `tls` controls *which certificate is presented for which SNI*. They are independent and both are required.

**A2.5** Base64 is encoding, not encryption — it is trivially reversible and offers zero confidentiality. At rest, protection comes from **etcd encryption providers** (`EncryptionConfiguration` with e.g. `aescbc`/`kms`, referenced by `--encryption-provider-config` on the API server); without it the key sits in plaintext in etcd. Against other users, protection comes from **RBAC**: anyone with `get` on Secrets in that namespace — including any ServiceAccount with `edit`/`admin`, and any pod that can mount the Secret — reads the private key.

### Block 3

**A3.1** `ssl-redirect` (default `true`) redirects HTTP→HTTPS **only when the host has a TLS certificate configured** for it. If `spec.tls` is missing or the Secret failed to load, it quietly does nothing and plaintext is served. `force-ssl-redirect` redirects unconditionally, regardless of whether TLS is configured for that host — which is why it is the safer choice when you want a hard guarantee.

**A3.2** The first request exposes the full URL, the `Host` header, cookies sent on plain HTTP, and the client's intent — and an active MITM can simply answer it instead of redirecting (SSL stripping), never letting the client reach HTTPS at all. **HSTS** closes the window for *subsequent* visits by instructing the browser to convert `http://` to `https://` locally before any packet leaves. HSTS preloading closes even the very first visit.

**A3.3** The directive applies to the entire registrable domain and everything under it, cached by browsers for the stated duration and not easily revocable — clearing it requires visiting each affected host and shipping a `max-age=0` policy, which is impossible if a subdomain has no working HTTPS at all. On a shared domain you can take down a sibling team's plain-HTTP service and have no fast rollback.

**A3.4** The ConfigMap (`ingress-nginx-controller` in the controller's namespace) applies to **every** Ingress served by that controller; annotations apply to a **single** Ingress. ConfigMap changes are picked up by the controller and trigger a config reload — but a malformed value can make the reload fail, leaving the old config running, so you must confirm the change actually landed (`rollout status`, controller logs, or grepping the rendered `nginx.conf`) rather than assuming.

### Block 4

**A4.1** **SNI** (Server Name Indication, RFC 6066). The client sends the target hostname in the **ClientHello**, i.e. in *cleartext*, before any encryption is negotiated. That is what lets nginx pick the right certificate — and also what lets a network observer see which site you are visiting even over TLS (the problem Encrypted Client Hello aims to solve).

**A4.2** A wildcard matches exactly **one** label, in the leftmost position only. `v1` is one label under `api.cks.lab` → match. `api.cks.lab` is the bare domain with no leftmost label to substitute → no match (which is why the SAN list also includes it explicitly). `a.b.api.cks.lab` needs two labels → no match.

**A4.3** (1) **Blast radius**: one leaked key compromises every current and future host under that domain, and revocation takes them all down at once. (2) **Weakest-link exposure**: the key must be distributed to every host/controller that serves any subdomain, so the least-hardened consumer sets the security level for all of them — and any subdomain takeover instantly gets a valid certificate. (Also: wildcards cannot be issued at Extended Validation level and offer no per-host revocation granularity.)

**A4.4** The default certificate is used for every unmatched SNI across the whole controller and typically lives in the controller's namespace, so compromising it affects every host that falls through — plus it signals that the attacker already has read access in the ingress-controller namespace, which is where all the other keys are too. A per-Ingress Secret compromises exactly one hostname and requires access to that one namespace.

**A4.5** ingress-nginx merges the configurations and, by default, the **oldest** Ingress (by creation timestamp) wins the conflicting server block; the other's rules may be partially or wholly ignored, and the certificate served can come from the winner's Secret. This is a tenant-isolation problem because nothing in vanilla Kubernetes stops namespace B from claiming namespace A's hostname — hostname ownership is not an RBAC-enforced resource. Mitigations: separate controllers per tenant, `--watch-namespace`, or an admission policy (ValidatingAdmissionPolicy / Kyverno / Gatekeeper) that binds hostname suffixes to namespaces.

### Block 5

**A5.1** Protocol version is a **global, non-delegable** policy: it is compiled into the shared `http {}` block of `nginx.conf`, so a single namespace tenant cannot weaken it. Ciphers are settable per-Ingress, which means a tenant *can* weaken the cipher suite for their own host. The implication: the platform/security team owns the protocol floor via the ConfigMap, and if cipher policy matters to you, you must additionally block or constrain the `ssl-ciphers` annotation (via `annotations-risk-level` or an admission policy) rather than trusting tenants.

**A5.2** In TLS 1.2 and earlier, `ssl_prefer_server_ciphers on` makes the *server's* cipher ordering authoritative instead of the client's, preventing a client (or a downgrade-forcing attacker) from steering the connection toward a weak suite. TLS 1.3 removed the negotiable-weak-cipher problem — its five AEAD suites are all strong and the handshake is redesigned — so the directive has no meaningful effect once you pin `TLSv1.3`.

**A5.3** It improves **forward secrecy**. Session tickets encrypt the resumption state with a server-held key; if that key is not rotated frequently (nginx by default does not rotate it across the process lifetime) an attacker who later obtains it can decrypt recorded sessions, undoing the forward secrecy that ECDHE provides. The cost is that resumption falls back to server-side session cache or is lost entirely, so more connections pay a full handshake — extra CPU and one extra round trip.

**A5.4** `configuration-snippet` injects raw nginx directives into the rendered `nginx.conf` of the **shared** controller. Anyone who can create or edit an Ingress in *any* watched namespace can therefore inject directives that affect other tenants: read arbitrary files from the controller's filesystem (including the mounted ServiceAccount token at `/var/run/secrets/kubernetes.io/serviceaccount/token`), proxy to internal endpoints, log other hosts' traffic, or with `lua` blocks execute code. Since the controller's ServiceAccount can typically read Secrets cluster-wide, that is a straight path from namespace-level `edit` to cluster-wide secret disclosure. `allow-snippet-annotations: "false"` (the default since ingress-nginx v1.12) removes the primitive entirely; `annotations-risk-level` additionally rejects annotations above the configured risk tier.

**A5.5** The ConfigMap records your *intent*; `nginx.conf` records what nginx is actually enforcing. Between the two sits template rendering, value validation, and a reload that can fail — a typo'd key is silently ignored, an invalid value can abort the reload and leave the previous configuration serving traffic. Only the rendered file (or an external handshake probe) is evidence.

### Block 6

**A6.1** ingress-nginx looks up the fixed key `ca.crt` in the referenced Secret and writes it out as the `ssl_client_certificate` trust store; any other key name yields "secret does not contain 'ca.crt'" in the controller log. It cannot be `kubernetes.io/tls`, because that type requires `tls.crt`/`tls.key` — and you deliberately do not want the CA's *private key* anywhere near the cluster. (The same Secret may optionally carry `ca.crl` for revocation.)

**A6.2** It caps the length of the certificate chain nginx will follow when validating a client certificate. Depth `1` means the client certificate must be signed directly by a CA in your trust store. A large depth means any intermediate anywhere in the chain — including one you did not intend to trust — can mint client certificates that validate, so a single compromised or overly permissive intermediate silently becomes an authentication bypass for your whole Ingress.

**A6.3** `ssl-client-verify` (forwarded by ingress-nginx as a request header, along with `ssl-client-subject-dn`, `ssl-client-issuer-dn`, and the certificate itself when pass-through is on). Its value is `SUCCESS`, `FAILED:<reason>`, or `NONE`. If the application ignores it, `optional` is functionally equivalent to no authentication at all: unauthenticated requests reach the backend and are served. `optional` moves the authorization decision from the edge to the app — which is only safe if the app actually makes it.

**A6.4** Because the certificate arrives as an ordinary HTTP header, any client that can reach the backend Service or Pod IP directly can **forge that header** and impersonate an authenticated user — the backend has no way to distinguish a header set by the trusted Ingress from one set by an attacker pod. Passing certificates upstream is only safe when a NetworkPolicy restricts the backend to accept traffic exclusively from the ingress-controller pods (or a mesh/mTLS layer authenticates the hop).

**A6.5** It does not protect the **controller → backend Pod** hop, which is plaintext HTTP by default even when the external connection is TLS 1.3 with mutual authentication. Exercise 7 addresses it, with `backend-protocol: HTTPS` plus `proxy-ssl-verify`, or with `ssl-passthrough`, or by placing a service mesh sidecar on that hop.

### Block 7

**A7.1** **No.** `backend-protocol: "HTTPS"` only changes the scheme on `proxy_pass`; nginx's `proxy_ssl_verify` defaults to `off`, so the controller accepts *any* certificate from the upstream — including an attacker's, which means the hop is encrypted but not authenticated and remains MITM-able inside the cluster. Step 5 added `proxy-ssl-verify: "on"` with `proxy-ssl-verify-depth` and `proxy-ssl-name`; the trusted CA comes from `nginx.ingress.kubernetes.io/proxy-ssl-secret` (a `namespace/name` reference to a Secret containing `ca.crt`).

**A7.2** Certificate validation matches the name the *client of that connection* used to dial. On the controller→backend hop the client is nginx and the target is the in-cluster Service DNS name (or the value pinned via `proxy-ssl-name`), not the public hostname the browser used. `shop.cks.lab` is only relevant to the external hop, which the Ingress already terminated.

**A7.3** With passthrough the controller never decrypts the connection — it inspects only the SNI in the ClientHello and then pipes raw TCP bytes to the backend. Everything downstream of decryption is therefore unavailable: paths, methods, headers, cookies, header injection, WAF/ModSecurity inspection, and edge mTLS (there is nothing to terminate, so client-certificate verification must move to the backend). The backend becomes solely responsible for TLS and for authentication.

**A7.4** `--enable-ssl-passthrough` is a controller-level flag: enabling it inserts an SNI-reading TCP proxy listener in front of the normal HTTP listeners, so **all** traffic through that controller takes an extra hop, even hosts that do not use passthrough. Costs: added latency and CPU for every connection, loss of L7 access logs and metrics for passthrough hosts (you cannot log what you cannot read), and the loss of edge WAF/rate-limiting for them. Prefer a separate controller instance for passthrough workloads.

**A7.5** `256` decimal is `0400` octal — read-only for the owner, no access for group or others. Kubernetes `defaultMode` takes a decimal integer in JSON (YAML `0400` is octal only if unquoted and interpreted as such, a classic footgun). It matters because a private key readable by group/other is readable by any process or sidecar in the pod, and many TLS libraries and tools warn or refuse on world-readable keys.

### Block 8

**A8.1** The default `ingress-nginx` ClusterRole grants `get`/`list`/`watch` on `secrets` cluster-wide (it must, to load TLS Secrets from arbitrary namespaces). An attacker with code execution in the controller pod reads the mounted ServiceAccount token at `/var/run/secrets/kubernetes.io/serviceaccount/token`, uses it against the API server, and lists every `kubernetes.io/tls` Secret in the cluster — obtaining the **private keys** for every host the controller fronts. With those keys they can decrypt captured traffic where forward secrecy is absent, and impersonate any of those sites with a certificate that validates against the real public CA. The same token typically also grants read on ConfigMaps and Endpoints, extending reconnaissance.

**A8.2** (1) **`--watch-namespace=<ns>`** plus a namespaced Role instead of a ClusterRole: the controller can only read Secrets in one namespace. You give up serving multiple namespaces from one controller, so you must run one controller per tenant (more IPs, more resource cost). (2) **Removing/locking down the admission webhook** and setting `allow-snippet-annotations: "false"` with a restrictive `annotations-risk-level`: you lose pre-admission validation of Ingress objects (bad configs fail at reload instead of at `kubectl apply`) and lose snippet-based customisation. Both meaningfully shrink the path from "tenant can create an Ingress" to "tenant reads all keys."

**A8.3** `NET_BIND_SERVICE` allows binding to privileged ports (<1024) so nginx can listen on 80/443 while running as a non-root UID. It is a narrow, single-purpose capability that grants no ability to read other processes' memory, load modules, or escape the container. `allowPrivilegeEscalation: true` is categorically different: it permits a process to gain capabilities its parent did not have (via setuid binaries or file capabilities), which turns any in-container code execution into a much broader compromise and undermines the whole non-root posture.

**A8.4** They have hijacked routing for a hostname they do not own — every request to `payments.cks.lab` that arrives at this controller can now be sent to their backend, letting them phish credentials or capture session cookies with a certificate the controller happily serves from *their* namespace's Secret. Kubernetes RBAC has no concept of hostname ownership. Prevention requires admission-time policy: a **ValidatingAdmissionPolicy** (CEL, built-in since 1.30) or Kyverno/Gatekeeper rule that asserts `spec.rules[*].host` matches a suffix allow-listed for the object's namespace — or physically separating tenants onto their own `--watch-namespace` controllers.

**A8.5** A patch fixes the *known* bug in a component you keep running; removing the webhook deletes the component's exposure entirely, so it is immune to the next unknown bug in the same code path as well. CVE-2025-1974 was reachable because the admission endpoint accepted connections and processed attacker-influenced Ingress content; a cluster with no `ValidatingWebhookConfiguration` and no admission listener had nothing to reach. Defence in depth ranks "the code isn't running" above "the code is running, patched."

### Block 9

**A9.1** The controller failed to load the mismatched pair and fell back to the default certificate (fake or `default-tls`) for that server block, so the handshake still succeeded — with the *wrong* identity. "HTTPS responds" only proves a certificate was presented, not that it was *your* certificate for *that* host. Monitoring must assert the served certificate's subject/SAN and issuer, not just that port 443 answers.

**A9.2** nginx validates the *structure* of a certificate (parseable PEM, key match) at load time, not its validity window — expiry is a **relying-party** decision made by the client at handshake time (`certificate has expired`, curl exit 60). So the controller reports healthy and the config reload succeeds. Expiry monitoring therefore cannot live in the controller: it belongs in an external check that decodes each `kubernetes.io/tls` Secret and alerts on `notAfter`, or in automated issuance (cert-manager) that renews well before expiry.

**A9.3** An empty `ADDRESS` means **no controller has claimed the object** — nothing has written `status.loadBalancer.ingress`. There is no error event because from the API server's perspective the object is perfectly valid; the Ingress spec simply does not require that any controller exist. Controllers only emit events for Ingresses they own, and this one owns nothing, so both the object's events and the controller log are silent. Absence of an address is the diagnostic signal. (The same silent failure occurs with a class name that no `IngressClass` matches.)

**A9.4** The controller **watches** Secret objects through the API server and re-renders/reloads nginx on change — TLS material is not baked into the pod, so rotation is a data-plane update with no restart and no dropped connections. For a controller running `--watch-namespace`, the watch is scoped to that namespace: a Secret updated outside it is never observed, so certificate rotation for a host must happen in a namespace the controller actually watches, and cross-namespace certificate distribution (e.g. cert-manager issuing into each tenant namespace) becomes mandatory rather than optional.

**A9.5**

```bash
kubectl get secrets -A --field-selector type=kubernetes.io/tls \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.data.tls\.crt}{"\n"}{end}' \
| while IFS=$'\t' read -r N C; do
    echo "$N  $(echo "$C" | base64 -d | openssl x509 -noout -subject -enddate | tr '\n' ' ')"
  done
```

</details>

---

## Reference sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes documentation, *Ingress* — https://kubernetes.io/docs/concepts/services-networking/ingress/
- Kubernetes documentation, *Ingress Controllers* — https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Kubernetes documentation, *Secrets — TLS Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
- Kubernetes documentation, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes documentation, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- ingress-nginx, *TLS/HTTPS user guide* — https://kubernetes.github.io/ingress-nginx/user-guide/tls/
- ingress-nginx, *Annotations reference* — https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- ingress-nginx, *ConfigMap reference* — https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
- ingress-nginx, *Command line arguments* — https://kubernetes.github.io/ingress-nginx/user-guide/cli-arguments/
- ingress-nginx, *Hardening guide* — https://kubernetes.github.io/ingress-nginx/deploy/hardening-guide/
- Kubernetes security advisory, *CVE-2025-1974 (ingress-nginx)* — https://github.com/kubernetes/kubernetes/issues/131009
- IETF RFC 8446, *The Transport Layer Security (TLS) Protocol Version 1.3* — https://www.rfc-editor.org/rfc/rfc8446
- IETF RFC 6066, *TLS Extensions: Server Name Indication* — https://www.rfc-editor.org/rfc/rfc6066
- IETF RFC 6125, *Representation and Verification of Domain-Based Application Service Identity* — https://www.rfc-editor.org/rfc/rfc6125
- IETF RFC 6797, *HTTP Strict Transport Security (HSTS)* — https://www.rfc-editor.org/rfc/rfc6797
- cert-manager documentation, *Securing Ingress Resources* — https://cert-manager.io/docs/usage/ingress/