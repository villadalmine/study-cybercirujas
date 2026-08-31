# 110.3 — Asegurar datos con cifrado

**LPIC-1 (101-500 / 102-500), versión 5.0 — Tema 110: Seguridad**

Cobertura del objetivo: configuración y uso del cliente OpenSSH 2; el rol de las claves de host; configuración, uso y revocación de GnuPG; túneles de puertos SSH, incluidos los túneles X11.
Archivos y comandos incluidos: `ssh`, `ssh-keygen`, `ssh-agent`, `ssh-add`, `~/.ssh/id_rsa{,.pub}`, `~/.ssh/id_dsa{,.pub}`, `~/.ssh/id_ecdsa{,.pub}`, `~/.ssh/id_ed25519{,.pub}`, `/etc/ssh/ssh_host_{rsa,dsa,ecdsa,ed25519}_key{,.pub}`, `~/.ssh/authorized_keys`, `ssh_known_hosts`, `gpg`, `gpg-agent`, `~/.gnupg/`.

---

## 1. Motivación y el problema arquitectónico en producción

### 1.1 Qué te compra realmente "asegurar datos con cifrado"

El cifrado no es una funcionalidad que se enciende. Es un conjunto de garantías que elegís comprar, cada una con un costo de ejecución distinto y un modo de falla distinto. En una plataforma Linux hay exactamente tres planos donde se compran esas garantías:

| Plano | Garantía | Modelo de adversario | Herramientas de este objetivo |
|---|---|---|---|
| **Datos en tránsito** | Confidencialidad + integridad + **autenticación del par** sobre el cable | Atacante en el camino (switch malicioso, NAT hostil, secuestro BGP, jump host comprometido) | Transporte OpenSSH |
| **Datos en reposo** | Confidencialidad de un blob independientemente del sistema de archivos donde viva | Cualquiera que pueda leer el archivo después: cinta de backup, historia de git, bucket S3, volcado de `etcd`, una laptop robada | GnuPG (OpenPGP) |
| **Procedencia de los datos** | Prueba no repudiable de *quién produjo este artefacto* | Atacante de cadena de suministro con escritura sobre tu registry, mirror o remoto de git | Firmas GnuPG, firmas `ssh-keygen -Y` |

El plano que la mayoría de los ingenieros entiende mal es la segunda mitad de la primera fila: la **autenticación del par**. Una sesión SSH contra el host equivocado está perfectamente cifrada y completamente comprometida. Todo incidente real de SSH en producción es una falla de autenticación, nunca una falla del cifrador.

### 1.2 El problema arquitectónico: identidad a escala de flota

Considerá la forma realista de una plataforma: 400 nodos en 3 regiones, reemplazados continuamente por un autoscaler, más 40 ingenieros, más 12 runners de CI que necesitan publicar artefactos y descargar módulos privados.

SSH ingenuo te da un **problema de confianza cuadrático**:

- Cada uno de los 440 clientes debe aprender la clave de host de cada uno de los 400 servidores → hasta 176.000 decisiones de confianza.
- Cada nodo nuevo que acuña el autoscaler genera claves de host *frescas* en el primer arranque, así que `known_hosts` está permanentemente mal.
- La respuesta humana a "permanentemente mal" es `StrictHostKeyChecking no`, que elimina por completo la garantía de autenticación del transporte. Esta es la vulnerabilidad SSH autoinfligida más común de la industria.

Y un problema simétrico del lado del usuario:

- 40 ingenieros × 400 nodos de entradas en `authorized_keys`, distribuidas por gestión de configuración, significa que un ingeniero dado de baja recién queda revocado cuando la siguiente corrida de gestión de configuración aterriza en cada nodo — incluidos los nodos que están acordonados, inalcanzables o en un rollout atascado.

Las tres respuestas de producción, en orden de madurez:

1. **Clave pública fijada fuera de banda** — cocinar `/etc/ssh/ssh_known_hosts` desde un inventario confiable al construir la imagen, o publicar registros `SSHFP` en DNS firmado con DNSSEC. Elimina el TOFU, mantiene la contabilidad cuadrática.
2. **Certificados SSH** — una CA de host firma las claves de host, una CA de usuario firma las claves de usuario. La confianza pasa a ser **2 claves en lugar de 176.000 emparejamientos**, y los certificados de usuario llevan una ventana de `validity`, así que la revocación se vuelve *vencimiento* en lugar de una carrera contra la gestión de configuración. Esto es a lo que converge toda implementación SSH a gran escala.
3. **Claves atadas a hardware** — `ed25519-sk`/`ecdsa-sk` (FIDO2) o una smartcard OpenPGP, de modo que la clave privada *no sea exfiltrable* ni siquiera desde una estación de trabajo totalmente comprometida. Este es el único control que sobrevive a una laptop robada con un agente vivo.

Para los datos en reposo, el problema arquitectónico equivalente es el **problema del secreto en git**: un `Secret` de Kubernetes es base64, no cifrado; un archivo de estado de Terraform contiene credenciales en texto plano; un `values.yaml` de Helm en un repo privado está a un fork de ser público. GnuPG (o age, mediante el mismo patrón de sobre) resuelve esto haciendo que el repositorio sea el transporte y el material de claves sea la frontera — el archivo se cifra *hacia un conjunto de destinatarios*, y el runner de CI es uno de ellos.

### 1.3 Los no-objetivos — decíselos explícitamente a tus estudiantes

- SSH **no** protege los datos en reposo en ninguno de los dos extremos. Hacé `scp` de un volcado de base de datos y aterriza en texto plano.
- GnuPG **no** da forward secrecy. Un mensaje cifrado hacia tu clave hoy es legible mañana si esa clave se filtra. SSH *sí* la da (ECDH efímero por sesión).
- Ninguno protege contra un extremo comprometido. Reenviar el agente hacia un host hostil equivale a entregar la clave por la duración de la sesión.

---

## 2. Comparativas técnicas y compromisos

### 2.1 Algoritmos de claves SSH

```
$ ssh -Q key
ssh-ed25519
ssh-ed25519-cert-v01@openssh.com
sk-ssh-ed25519@openssh.com
sk-ssh-ed25519-cert-v01@openssh.com
ecdsa-sha2-nistp256
ecdsa-sha2-nistp384
ecdsa-sha2-nistp521
sk-ecdsa-sha2-nistp256@openssh.com
ssh-rsa
rsa-sha2-256
rsa-sha2-512
```

| Algoritmo | Tamaño de clave en disco | Nivel de seguridad | Velocidad de firma | Notas para producción |
|---|---|---|---|---|
| `ssh-ed25519` | 68 B de clave pública, 399 B privada | ~128 bits | La más rápida | **Elección por defecto.** Tiempo constante, sin parámetros que elegir mal, sin dependencia de la calidad del RNG al momento de firmar. Soportada desde OpenSSH 6.5 (2014). |
| `sk-ssh-ed25519@openssh.com` | Solo el handle; el secreto está en el token | ~128 bits + hardware | Rápida + latencia del toque | Ed25519 con un autenticador FIDO2. La clave privada **no puede** copiarse fuera del dispositivo. Requiere OpenSSH ≥ 8.2 en el cliente **y** en el servidor. |
| `rsa-sha2-512` (RSA-4096) | ~3,2 KB privada | ~128–140 bits | Generación lenta, verificación lenta | Solo para interoperar con servidores heredados o hardware anterior a EdDSA. RSA-2048 es el piso práctico; RSA-1024 está muerta. |
| `ecdsa-sha2-nistp256` | 178 B de clave pública | ~128 bits | Rápida | Funciona, pero ECDSA falla catastróficamente ante la reutilización de nonce y depende del RNG al momento de firmar. Preferí Ed25519. |
| `ssh-dss` (DSA) | 1024 bits fijos | ~80 bits — rota | — | **No la uses.** Deshabilitada por defecto desde OpenSSH 7.0, deshabilitada por defecto en tiempo de compilación en 9.8, eliminada en OpenSSH 10.0. El objetivo LPIC-1 todavía lista `~/.ssh/id_dsa` — conocé el nombre del archivo, nunca crees uno. |

> **Trampa de examen y trampa de producción en una sola:** OpenSSH 8.8 (2021) deshabilitó por defecto el algoritmo de firma `ssh-rsa` (RSA con SHA-1). Una *clave* RSA sigue estando bien; el *esquema de firma* SHA-1 no. El síntoma es `no mutual signature algorithm` contra servidores viejos, y se arregla en el cliente con `PubkeyAcceptedAlgorithms +ssh-rsa` — en un bloque `Host` acotado, nunca uno global.

### 2.2 Modelos de confianza para claves de host

| Modelo | Costo de arranque | Revocación | Amigable con autoscaling | Modo de falla |
|---|---|---|---|---|
| **TOFU** (`StrictHostKeyChecking ask`, el valor por defecto) | Cero | `ssh-keygen -R` manual | ✗ — cada nodo nuevo pregunta | Habituación del usuario: los ingenieros escriben `yes` por reflejo |
| **`StrictHostKeyChecking no`** | Cero | N/D | ✓ | **Ninguna autenticación en absoluto.** Nunca en producción. |
| **`accept-new`** (OpenSSH ≥ 7.6) | Cero | `ssh-keygen -R` | Parcial | Acepta hosts desconocidos en silencio, pero *rechaza claves cambiadas*. Un punto medio pragmático para CI efímero. |
| **`/etc/ssh/ssh_known_hosts` presembrado** | Construir un inventario confiable | Reconstruir + redistribuir el archivo | ✗ | Archivo obsoleto → fallas duras en reconstrucciones legítimas |
| **SSHFP en DNSSEC** (`VerifyHostKeyDNS yes`) | Zona DNSSEC + automatización | Actualización de la zona, respeta el TTL | ✓ | Degrada silenciosamente a TOFU si la validación DNSSEC no está disponible |
| **Certificados de host (`@cert-authority`)** | Un par de claves de CA | Rotación de la CA o `RevokedHostKeys` | ✓✓ | El compromiso de la clave privada de la CA es total; mantenela offline/en HSM |

### 2.3 Selección de intercambio de claves y cifradores

```
$ ssh -Q kex | head -12
diffie-hellman-group1-sha1
diffie-hellman-group14-sha1
diffie-hellman-group14-sha256
diffie-hellman-group16-sha512
diffie-hellman-group18-sha512
diffie-hellman-group-exchange-sha1
diffie-hellman-group-exchange-sha256
ecdh-sha2-nistp256
ecdh-sha2-nistp384
ecdh-sha2-nistp521
curve25519-sha256
curve25519-sha256@libssh.org

$ ssh -Q cipher
3des-cbc
aes128-cbc
aes192-cbc
aes256-cbc
aes128-ctr
aes192-ctr
aes256-ctr
aes128-gcm@openssh.com
aes256-gcm@openssh.com
chacha20-poly1305@openssh.com
```

| Elección | Cuándo gana | Costo |
|---|---|---|
| `chacha20-poly1305@openssh.com` | CPUs sin AES-NI (SBCs ARM, embebidos viejos, algunas instancias burstable de nube) | ~10–20 % más lento que AES-GCM donde existe AES-NI |
| `aes256-gcm@openssh.com` | Cualquier cosa con AES-NI — transferencia masiva, backups sobre SSH | Necesita aceleración por hardware para superar a ChaCha20 |
| `curve25519-sha256` | KEX por defecto; rápido, sin preocupaciones por curvas NIST | — |
| KEX híbrido poscuántico (`sntrup761x25519-sha512@openssh.com`, `mlkem768x25519-sha256`) | Amenaza **harvest-now-decrypt-later**: contenido de sesión de larga vida grabado hoy | Handshake más grande, CPU despreciable; ambos pares deben tener OpenSSH reciente. OpenSSH moderno negocia un KEX híbrido PQ por defecto. |
| Modos CBC, `3des-cbc`, MACs `*-sha1` | Nunca | Solo legado; deshabilitalos explícitamente |

Verificá lo que un par realmente negoció, no lo que vos configuraste:

```
$ ssh -v node-a.prod.example.net true 2>&1 | grep -E 'kex:|cipher|compat'
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
```

### 2.4 Tipos de túnel

| Flag | Dirección | El listener corre en | Uso canónico | Riesgo principal |
|---|---|---|---|---|
| `-L [bind:]lport:dhost:dport` | Local → remoto | **Cliente** | Alcanzar una BD ligada a `127.0.0.1` en un nodo remoto | Exponer el listener en `0.0.0.0` |
| `-R [bind:]rport:dhost:dport` | Remoto → local | **Servidor** | Exponer un servicio desde una red con NAT hacia un bastión | Requiere `GatewayPorts` en el servidor para ligar fuera de loopback; si no, liga loopback en silencio |
| `-D [bind:]port` | Cliente → a cualquier lado | **Cliente** | Proxy SOCKS5, navegar a través de una frontera de red | Todo lo que hay en la máquina puede usarlo; ligalo solo a loopback |
| `-W host:port` | stdio → remoto | ninguno | Bloque de construcción de `ProxyCommand` | Superado por `ProxyJump` |
| `-J user@jump` | n/d | ninguno | Múltiples saltos **sin** reenvío de agente | Ninguno — esta es la respuesta correcta |
| `-X` / `-Y` | Canal X11 | El servidor fija `DISPLAY` | Correr una herramienta gráfica remotamente | `-Y` (confiable) deshabilita la extensión de seguridad de X: la aplicación remota puede registrar cada tecla de toda tu sesión X |
| `-A` (reenvío de agente) | Socket del agente | Servidor | Logins encadenados | **Un usuario root en el host remoto puede usar tu agente todo el tiempo que estés conectado.** Preferí `-J`. |

| Alternativa a los túneles SSH | Fortaleza | Debilidad |
|---|---|---|
| `ssh -L/-R` | Sin infraestructura extra, autenticación por usuario, rastro de auditoría en el bastión | Por sesión, solo TCP, muere con la sesión, colapso de TCP-sobre-TCP con pérdida de paquetes |
| WireGuard | En espacio de kernel, UDP, roaming, sobrevive cambios de enlace | Necesita un registro de pares y planificación de IPs; por sí solo no da identidad por usuario |
| `kubectl port-forward` | No hace falta acceso al nodo, acotado por RBAC | Una sola conexión, sin HA, muere al reiniciarse el pod |
| mTLS de service mesh | Transparente para las aplicaciones, identidad por carga de trabajo | Plano de control pesado; irrelevante para el acceso del operador |

### 2.5 Elecciones de algoritmo y topología en GnuPG

| Elección | Recomendación | Fundamento |
|---|---|---|
| Algoritmo de la clave primaria | `ed25519` (`future-default`) | Pequeña, rápida, sin selección de parámetros. RSA-4096 solo cuando el herramental de la contraparte es antiquísimo. |
| Subclave de cifrado | `cv25519` | ECDH X25519; se empareja automáticamente con `future-default`. |
| División de capacidades | Primaria solo `[C]`; subclaves `[S]`, `[E]`, `[A]` | El compromiso de una laptop pierde una *subclave*, que revocás y reemplazás. El compromiso de la primaria pierde tu identidad. |
| Almacenamiento de la clave primaria | Offline (USB cifrado / air-gapped) o smartcard | `gpg --export-secret-subkeys` deja solo las subclaves en la máquina de uso diario. |
| Vencimiento | Subclaves 1 año, primaria 2–3 años o nunca-con-almacenamiento-offline | El vencimiento es un interruptor de hombre muerto para las claves a las que perdés acceso. |
| Certificado de revocación | Generalo **al crear la clave**, guardalo aparte de la clave | GnuPG ≥ 2.1 escribe uno automáticamente en `~/.gnupg/openpgp-revocs.d/<FPR>.rev`. Si perdés tanto la clave como el certificado de revocación, tu clave publicada es inmortal e inutilizable. |

| Simétrico vs asimétrico en reposo | `gpg --symmetric` | `gpg --encrypt -r` |
|---|---|---|
| Distribución de claves | Frase de paso compartida fuera de banda | Claves públicas de los destinatarios, distribuibles en claro |
| Agregar un consumidor | Recompartir la frase de paso a todos | Recifrar hacia un destinatario más |
| Revocar un consumidor | Rotar la frase de paso en todas partes | Recifrar sin él (las copias pasadas siguen siendo legibles — rotá el secreto en texto plano) |
| Amigable con CI | Frase de paso en una variable de entorno — incómodo pero simple | Clave privada en el runner, `--pinentry-mode loopback` |
| Uso correcto | Archivo puntual, blob de backup | Secretos de repositorio, artefactos multiconsumidor |

---

## 3. Manifiestos completos de infraestructura

### 3.1 `~/.ssh/config` — una configuración de cliente para producción

```sshconfig
# ~/.ssh/config — mode 0600
# Order matters: OpenSSH applies the FIRST value obtained for each keyword.
# Put specific Host blocks above general ones.

Host bastion-eu
    HostName          bastion.eu-west-1.example.net
    User              sre
    Port              22
    IdentityFile      ~/.ssh/id_ed25519_sk_prod
    IdentitiesOnly    yes
    # Certificate issued by the user CA; short-lived, refreshed by `step ssh login`
    CertificateFile   ~/.ssh/id_ed25519_sk_prod-cert.pub
    ForwardAgent      no
    ControlMaster     auto
    ControlPath       ~/.ssh/cm/%C
    ControlPersist    10m

# Every production node is reached through the bastion. No direct exposure.
Host *.prod.example.net 10.42.*
    User              sre
    ProxyJump         bastion-eu
    IdentityFile      ~/.ssh/id_ed25519_sk_prod
    IdentitiesOnly    yes
    ForwardAgent      no
    ForwardX11        no
    StrictHostKeyChecking yes
    UserKnownHostsFile /etc/ssh/ssh_known_hosts ~/.ssh/known_hosts

# Ephemeral CI workers: keys change on every rebuild, so accept-new is the
# strongest setting that still works. It refuses CHANGED keys, unlike `no`.
Host ci-runner-*
    User              runner
    IdentityFile      ~/.ssh/id_ed25519_ci
    IdentitiesOnly    yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts.ci

Host github.com
    User              git
    IdentityFile      ~/.ssh/id_ed25519_git
    IdentitiesOnly    yes
    # GitHub publishes host keys over HTTPS; pin them, do not TOFU them.
    UserKnownHostsFile ~/.ssh/known_hosts.github

Host *
    # Defaults applied to everything not matched above.
    AddKeysToAgent        yes
    HashKnownHosts        yes
    UpdateHostKeys        yes
    VerifyHostKeyDNS      ask
    ServerAliveInterval   30
    ServerAliveCountMax   3
    TCPKeepAlive          no
    Compression           no
    ExitOnForwardFailure  yes
    PubkeyAcceptedAlgorithms sk-ssh-ed25519@openssh.com,ssh-ed25519,rsa-sha2-512,rsa-sha2-256
    HostKeyAlgorithms     ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,rsa-sha2-512
    Ciphers               chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
    MACs                  hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    KexAlgorithms         mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256
```

> `ExitOnForwardFailure yes` es la diferencia entre "mi túnel está arriba" y "mi túnel falló en silencio y estoy hablando con un servicio local por accidente". Ponelo globalmente.

### 3.2 `/etc/ssh/sshd_config` — los roles de las claves de host, explícitos

```sshconfig
# /etc/ssh/sshd_config — the server half of the trust relationship.
# The HOST key proves the SERVER's identity to the client. It is never used
# to authenticate users.

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
# ECDSA and DSA host keys deliberately absent.

# Host certificate signed by the host CA: clients that trust the CA need no
# per-host known_hosts entry at all.
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub

# Users authenticate with certificates issued by the user CA...
TrustedUserCAKeys /etc/ssh/user_ca.pub
RevokedKeys       /etc/ssh/revoked_user_keys
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
# ...and, as a break-glass fallback, with raw keys from a root-owned path.
AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u .ssh/authorized_keys

PermitRootLogin           no
PasswordAuthentication    no
KbdInteractiveAuthentication no
PubkeyAuthentication      yes
AuthenticationMethods     publickey
UsePAM                    yes

# Forwarding policy: deny by default, allow per-group.
AllowAgentForwarding      no
AllowTcpForwarding        no
GatewayPorts              no
X11Forwarding             no
PermitTunnel              no

Match Group bastion-users
    AllowTcpForwarding    yes
    PermitOpen            10.42.0.0/16:5432 10.42.0.0/16:6443
    ForceCommand          /usr/local/sbin/bastion-shell

Match Group desktop-admins
    X11Forwarding         yes
    X11UseLocalhost       yes
    AllowAgentForwarding  no

LogLevel VERBOSE
Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO

KexAlgorithms  mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256
Ciphers        chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs           hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

### 3.3 `~/.ssh/authorized_keys` — entradas restringidas

```
# One line per key. Options come BEFORE the key type. Line order is irrelevant.

# Full interactive access, restricted to the bastion's source addresses.
from="10.42.0.10,10.42.0.11" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP sre@laptop

# Backup robot: may run exactly one command, no PTY, no forwarding of any kind.
# `restrict` (OpenSSH >= 7.2) denies everything, then we re-enable nothing.
restrict,command="/usr/local/sbin/rrsync -ro /srv/backup",from="10.42.9.5" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKp5rV2sQ9cM8xL0wYnT4jB7hF3dZ1uR6gE2vX9kOaTs backup@controller

# Tunnel-only account: no shell at all, only a forward to the Postgres primary.
restrict,port-forwarding,permitopen="db-primary.prod:5432",command="/bin/false" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4tN9wQ2xR7vK1mZ0cJ8fL5hY3dP6sU9gT2bX7nWaEq analytics@grafana

# Hardware-backed key: server enforces user presence (touch) on every auth.
verify-required,restrict,pty ecdsa-sk-... AAAAInNr...  oncall@yubikey
```

### 3.4 `cloud-init` — un nodo que arranca con un certificado de host firmado

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Boots a node whose host key is signed by the host CA, so no client ever
# performs a TOFU decision against it.

users:
  - name: sre
    groups: [sudo, bastion-users]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: []          # deliberately empty: certificates only

write_files:
  - path: /etc/ssh/user_ca.pub
    permissions: "0644"
    owner: root:root
    content: |
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDq7hW2mX9pR4vT1cL8sJ0nY6bK3fZ5uQ7gE2dV9wXaM user-ca@example.net

  - path: /etc/ssh/auth_principals/sre
    permissions: "0644"
    owner: root:root
    content: |
      sre
      oncall

  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0600"
    owner: root:root
    content: |
      HostKey /etc/ssh/ssh_host_ed25519_key
      HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
      TrustedUserCAKeys /etc/ssh/user_ca.pub
      AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
      RevokedKeys /etc/ssh/revoked_user_keys
      PermitRootLogin no
      PasswordAuthentication no
      AuthenticationMethods publickey
      AllowTcpForwarding no
      X11Forwarding no
      LogLevel VERBOSE

  - path: /etc/ssh/revoked_user_keys
    permissions: "0644"
    owner: root:root
    content: ""

  - path: /usr/local/sbin/request-host-cert.sh
    permissions: "0750"
    owner: root:root
    content: |
      #!/bin/bash
      # Submit the freshly generated host public key to the CA service and
      # install the returned certificate. Idempotent: exits early if valid.
      set -euo pipefail
      PUB=/etc/ssh/ssh_host_ed25519_key.pub
      CERT=/etc/ssh/ssh_host_ed25519_key-cert.pub
      CA_URL="https://ca.internal.example.net/v1/ssh/sign-host"

      if [[ -s "$CERT" ]] && ssh-keygen -L -f "$CERT" | grep -q 'Valid: from'; then
          exit 0
      fi

      FQDN="$(hostname -f)"
      IP="$(ip -4 -o route get 1.1.1.1 | awk '{print $7; exit}')"

      curl --fail --silent --show-error \
           --cacert /etc/ssl/certs/internal-root.pem \
           --header "Content-Type: application/json" \
           --data "$(jq -nc --arg k "$(cat "$PUB")" --arg p "$FQDN,$IP" \
                     '{public_key:$k, principals:$p, ttl:"720h"}')" \
           "$CA_URL" -o "$CERT.tmp"

      install -m 0644 -o root -g root "$CERT.tmp" "$CERT"
      rm -f "$CERT.tmp"
      ssh-keygen -L -f "$CERT"

bootcmd:
  # Destroy any host keys baked into the golden image. A shared host key across
  # an autoscaling group means one stolen node impersonates the whole fleet.
  - [ sh, -c, "rm -f /etc/ssh/ssh_host_*" ]

runcmd:
  - [ ssh-keygen, -A ]
  - [ rm, -f, /etc/ssh/ssh_host_dsa_key,   /etc/ssh/ssh_host_dsa_key.pub ]
  - [ rm, -f, /etc/ssh/ssh_host_ecdsa_key, /etc/ssh/ssh_host_ecdsa_key.pub ]
  - [ /usr/local/sbin/request-host-cert.sh ]
  - [ systemctl, restart, ssh ]

ssh_deletekeys: true
ssh_genkeytypes: [ed25519, rsa]
ssh_pwauth: false
disable_root: true
```

### 3.5 Ansible — distribuir confianza, no claves

```yaml
---
# playbooks/ssh-trust.yml
# Distributes CA trust anchors and the revocation list. Individual user keys
# are NOT distributed: authorisation comes from short-lived certificates.
- name: Establish SSH trust anchors across the fleet
  hosts: all
  become: true
  vars:
    ssh_user_ca_pub: >-
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDq7hW2mX9pR4vT1cL8sJ0nY6bK3fZ5uQ7gE2dV9wXaM
      user-ca@example.net
    ssh_revoked_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF9kW3xR8mT2vQ6cY1pL5nJ0bH7dZ4uS3gE8wX2aVoRt former-employee@laptop"
    ssh_principals:
      sre:     [sre, oncall]
      deployer: [deployer]

  handlers:
    - name: validate and reload sshd
      ansible.builtin.shell: |
        set -euo pipefail
        /usr/sbin/sshd -t
        systemctl reload ssh
      args:
        executable: /bin/bash

  tasks:
    - name: Install the user CA trust anchor
      ansible.builtin.copy:
        content: "{{ ssh_user_ca_pub }}\n"
        dest: /etc/ssh/user_ca.pub
        owner: root
        group: root
        mode: "0644"
      notify: validate and reload sshd

    - name: Publish the revocation list
      ansible.builtin.copy:
        content: "{{ ssh_revoked_keys | join('\n') }}\n"
        dest: /etc/ssh/revoked_user_keys
        owner: root
        group: root
        mode: "0644"
      notify: validate and reload sshd

    - name: Create the principals directory
      ansible.builtin.file:
        path: /etc/ssh/auth_principals
        state: directory
        owner: root
        group: root
        mode: "0755"

    - name: Map local accounts to allowed certificate principals
      ansible.builtin.copy:
        content: "{{ item.value | join('\n') }}\n"
        dest: "/etc/ssh/auth_principals/{{ item.key }}"
        owner: root
        group: root
        mode: "0644"
      loop: "{{ ssh_principals | dict2items }}"
      loop_control:
        label: "{{ item.key }}"
      notify: validate and reload sshd

    - name: Remove weak host keys if a golden image reintroduced them
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - /etc/ssh/ssh_host_dsa_key
        - /etc/ssh/ssh_host_dsa_key.pub
        - /etc/ssh/ssh_host_ecdsa_key
        - /etc/ssh/ssh_host_ecdsa_key.pub
      notify: validate and reload sshd

    - name: Collect host key fingerprints for the inventory of record
      ansible.builtin.command:
        cmd: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
      changed_when: false
      register: hostkey_fpr

    - name: Report fingerprints
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} => {{ hostkey_fpr.stdout }}"
```

### 3.6 `sops` + GnuPG — secretos cifrados que viven en git

```yaml
---
# .sops.yaml — creation rules. Matched top-down against the file path.
creation_rules:
  # Production secrets: encrypted to the platform team AND to the CI key,
  # so the pipeline can decrypt without a human in the loop.
  - path_regex: ^deploy/prod/.*\.enc\.ya?ml$
    encrypted_regex: '^(data|stringData|password|token|.*_KEY)$'
    pgp: >-
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6,
      A7C3E91B22D4F6580A19B3CC5E7D2F41B8069AE2,
      D18F45A6C0B37E92FA5C1D8834B60E7791A2C5F3

  - path_regex: ^deploy/staging/.*\.enc\.ya?ml$
    encrypted_regex: '^(data|stringData)$'
    pgp: >-
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6,
      A7C3E91B22D4F6580A19B3CC5E7D2F41B8069AE2

  # Everything else in the repository must be encrypted to the platform key
  # at minimum, so an accidental `sops -e` never produces an orphan file.
  - path_regex: \.enc\.ya?ml$
    pgp: 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
```

```yaml
---
# deploy/prod/postgres-credentials.enc.yaml — the on-disk, committable form.
# Structure and keys are readable; values are per-value AES-256-GCM ciphertext
# whose data key is wrapped to each PGP recipient.
apiVersion: v1
kind: Secret
metadata:
    name: postgres-credentials
    namespace: platform
type: Opaque
stringData:
    POSTGRES_USER: ENC[AES256_GCM,data:8fJq2w==,iv:kR3v9pQ1sT7nX4mL0bY6cZ8dW2hF5uJ9gE1aV7oS3xI=,tag:pN4mQ8sT2vX6cL0bY9dZ1w==,type:str]
    POSTGRES_PASSWORD: ENC[AES256_GCM,data:Kd8xQ2mV7pR1sT9nY4bL0cZ6h,iv:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI=,tag:R2sT8vX4cL6bY1dZ0w9pQ==,type:str]
    PGSSLMODE: ENC[AES256_GCM,data:9pQ2sT==,iv:Y4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0=,tag:L0cZ6hK1pR8gJ5uH2aE7fV==,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
    age: []
    lastmodified: "2026-08-31T09:14:22Z"
    mac: ENC[AES256_GCM,data:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK==,iv:mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3=,tag:H2aE7fV1oS9xIT7vX2cL9==,type:str]
    pgp:
        - created_at: "2026-08-31T09:14:21Z"
          enc: |
            -----BEGIN PGP MESSAGE-----

            hF4DA9kQ7pR2sT8SAQdAxQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xI
            T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3
            0kABmK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7f
            V1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ
            =Kq7T
            -----END PGP MESSAGE-----
          fp: 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
        - created_at: "2026-08-31T09:14:21Z"
          enc: |
            -----BEGIN PGP MESSAGE-----

            hF4DL0cZ6hK1pR8SAQdAsT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9b
            Y0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5u
            0kABH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX
            2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3mK1pR
            =9dZ4
            -----END PGP MESSAGE-----
          fp: A7C3E91B22D4F6580A19B3CC5E7D2F41B8069AE2
    version: 3.9.0
```

### 3.7 `~/.gnupg/gpg.conf` y `~/.gnupg/gpg-agent.conf`

```conf
# ~/.gnupg/gpg.conf — mode 0600, directory ~/.gnupg mode 0700
# Display long key IDs and full fingerprints; short IDs are forgeable by
# collision and must never be used to identify a key.
keyid-format 0xlong
with-fingerprint
with-subkey-fingerprint

# Never trust the preferences embedded in someone else's key over ours.
personal-cipher-preferences AES256 AES192 AES
personal-digest-preferences SHA512 SHA384 SHA256
personal-compress-preferences ZLIB BZIP2 ZIP Uncompressed
default-preference-list SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed
cert-digest-algo SHA512
s2k-digest-algo SHA512
s2k-cipher-algo AES256
s2k-mode 3
s2k-count 65011712

# Operational hygiene
no-emit-version
no-comments
require-cross-certification
armor
charset utf-8
throw-keyids                    # do not leak the recipient list in the packet

# Key discovery: WKD first, keyserver as a fallback.
auto-key-locate wkd,keyserver
keyserver hkps://keys.openpgp.org
```

```conf
# ~/.gnupg/gpg-agent.conf — mode 0600
default-cache-ttl 600            # 10 min idle timeout for a cached passphrase
max-cache-ttl 7200               # 2 h absolute ceiling regardless of use
default-cache-ttl-ssh 600
max-cache-ttl-ssh 7200

pinentry-program /usr/bin/pinentry-gnome3
# Headless / TTY-only hosts:
# pinentry-program /usr/bin/pinentry-curses

# Let gpg-agent act as the ssh-agent as well. Keygrips listed in
# ~/.gnupg/sshcontrol become available to ssh(1).
enable-ssh-support

# Refuse to keep secrets after an explicit lock.
no-allow-external-cache
```

### 3.8 Systemd — un túnel inverso supervisado

```ini
# /etc/systemd/system/tunnel-metrics.service
# Exposes the node's local Prometheus exporter (127.0.0.1:9100) on the
# bastion's loopback:19100 so the scraper can reach a NAT'd network.
[Unit]
Description=Reverse SSH tunnel: node-exporter -> bastion:19100
Documentation=man:ssh(1)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=exec
User=tunnel
Group=tunnel
ExecStart=/usr/bin/ssh -NT \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts \
    -o IdentitiesOnly=yes \
    -i /etc/tunnel/id_ed25519 \
    -R 127.0.0.1:19100:127.0.0.1:9100 \
    tunnel@bastion.eu-west-1.example.net
Restart=always
RestartSec=5

# The tunnel process needs nothing but a socket.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/etc/tunnel
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/user/ssh-agent.service
# A per-user agent with a stable socket path, so every login shell finds it.
[Unit]
Description=OpenSSH key agent
Documentation=man:ssh-agent(1)

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK
# Keys expire from the agent after 8 hours regardless of activity.
ExecStartPost=/bin/sh -c 'sleep 1; /usr/bin/ssh-add -t 8h /home/%u/.ssh/id_ed25519 </dev/null || true'
Restart=on-failure

[Install]
WantedBy=default.target
```

```sh
# /etc/profile.d/ssh-agent.sh
# Point every shell at the systemd-managed socket. XDG_RUNTIME_DIR is per-user
# and mode 0700, which is exactly the protection an agent socket needs.
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket" ]; then
    export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
fi
```

### 3.9 CI: un pipeline de GitLab que descifra con GnuPG

```yaml
---
# .gitlab-ci.yml
stages: [verify, deploy]

variables:
  GNUPGHOME: "$CI_PROJECT_DIR/.gnupg-ci"

.gpg_bootstrap: &gpg_bootstrap
  before_script:
    # A private key in a masked CI variable, base64-armoured.
    - install -d -m 0700 "$GNUPGHOME"
    - echo "$CI_GPG_PRIVATE_KEY_B64" | base64 -d | gpg --batch --quiet --import
    - |
      cat > "$GNUPGHOME/gpg-agent.conf" <<'EOF'
      allow-loopback-pinentry
      default-cache-ttl 0
      max-cache-ttl 0
      EOF
    - gpgconf --kill gpg-agent
    - gpg --batch --list-secret-keys --keyid-format 0xlong
  after_script:
    # Kill the agent and shred the ephemeral homedir; runners are reused.
    - gpgconf --kill all || true
    - rm -rf "$GNUPGHOME"

verify:signatures:
  stage: verify
  <<: *gpg_bootstrap
  script:
    - gpg --batch --import keys/release-signing.pub.asc
    - gpg --batch --verify dist/artifact.tar.gz.asc dist/artifact.tar.gz

deploy:prod:
  stage: deploy
  environment: production
  <<: *gpg_bootstrap
  script:
    - export SOPS_GPG_EXEC=gpg
    - |
      sops --decrypt deploy/prod/postgres-credentials.enc.yaml \
        | kubectl apply --namespace platform -f -
    - kubectl rollout status deployment/api --namespace platform --timeout=180s
  rules:
    - if: $CI_COMMIT_TAG
```

---

## 4. CLI: comandos y salida real de terminal

### 4.1 Generar claves

```
$ ssh-keygen -t ed25519 -a 100 -C "sre@laptop-2026-08" -f ~/.ssh/id_ed25519_prod
Generating public/private ed25519 key pair.
Enter passphrase for "/home/sre/.ssh/id_ed25519_prod" (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /home/sre/.ssh/id_ed25519_prod
Your public key has been saved in /home/sre/.ssh/id_ed25519_prod.pub
The key fingerprint is:
SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI sre@laptop-2026-08
The key's randomart image is:
+--[ED25519 256]--+
|      .o+=B*o    |
|       o.=+*.    |
|      . = *.o    |
|     . + O =     |
|      o S B .    |
|     . o + o     |
|    . o . E      |
|   . o .         |
|    o .          |
+----[SHA256]-----+
```

`-a 100` fija la cantidad de rondas de KDF que protegen la clave privada en disco; el valor por defecto es 16. Subirlo hace que un ataque offline sobre un archivo de clave robado sea ~6× más caro, al costo de unos cientos de milisegundos por desbloqueo.

Clave respaldada por hardware (token FIDO2):

```
$ ssh-keygen -t ed25519-sk -O resident -O verify-required -O application=ssh:prod \
             -C "oncall@yubikey" -f ~/.ssh/id_ed25519_sk_prod
Generating public/private ed25519-sk key pair.
You may need to touch your authenticator to authorize key generation.
Enter PIN for authenticator:
You may need to touch your authenticator again to authorize key generation.
Enter file in which to save the key (/home/sre/.ssh/id_ed25519_sk_prod):
Enter passphrase for "/home/sre/.ssh/id_ed25519_sk_prod" (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /home/sre/.ssh/id_ed25519_sk_prod
Your public key has been saved in /home/sre/.ssh/id_ed25519_sk_prod.pub
The key fingerprint is:
SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI oncall@yubikey
```

Inspeccionar, y cambiar la frase de paso sin cambiar la clave:

```
$ ssh-keygen -lf ~/.ssh/id_ed25519_prod.pub
256 SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI sre@laptop-2026-08 (ED25519)

$ ssh-keygen -y -f ~/.ssh/id_ed25519_prod          # derive the public key from the private one
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP

$ ssh-keygen -p -a 200 -f ~/.ssh/id_ed25519_prod   # rotate the passphrase / raise KDF rounds
Enter old passphrase:
Key has comment 'sre@laptop-2026-08'
Enter new passphrase (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved with the new passphrase.

$ ssh-keygen -c -C "sre@laptop-rotated-2026-08-31" -f ~/.ssh/id_ed25519_prod
Enter passphrase for "/home/sre/.ssh/id_ed25519_prod":
Comment 'sre@laptop-2026-08' -> 'sre@laptop-rotated-2026-08-31'
```

Claves de host del servidor — notá que `-A` solo crea lo que falta, lo que lo vuelve idempotente:

```
$ sudo ssh-keygen -A
ssh-keygen: generating new host keys: RSA ECDSA ED25519

$ ls -l /etc/ssh/ssh_host_*
-rw------- 1 root root  505 Aug 31 09:02 /etc/ssh/ssh_host_ecdsa_key
-rw-r--r-- 1 root root  176 Aug 31 09:02 /etc/ssh/ssh_host_ecdsa_key.pub
-rw------- 1 root root  411 Aug 31 09:02 /etc/ssh/ssh_host_ed25519_key
-rw-r--r-- 1 root root   96 Aug 31 09:02 /etc/ssh/ssh_host_ed25519_key.pub
-rw------- 1 root root 2602 Aug 31 09:02 /etc/ssh/ssh_host_rsa_key
-rw-r--r-- 1 root root  568 Aug 31 09:02 /etc/ssh/ssh_host_rsa_key.pub
```

> **El rol de la clave de host, dicho con precisión:** durante el intercambio de claves el servidor firma el hash del intercambio con su clave privada de host. El cliente verifica esa firma contra la clave *pública* de host que ya tiene (de `known_hosts`, `ssh_known_hosts`, un `SSHFP` de DNS, o una firma de CA). Esto liga la clave de sesión recién negociada a una identidad de servidor específica, y es lo *único* que se interpone entre vos y un hombre en el medio. `/etc/ssh/ssh_host_*_key` debe tener modo `0600` y pertenecer a `root`.

### 4.2 Gestión de `known_hosts`

```
$ ssh-keyscan -t ed25519 node-a.prod.example.net
# node-a.prod.example.net:22 SSH-2.0-OpenSSH_9.9p1 Debian-3
node-a.prod.example.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS

$ ssh-keyscan -t ed25519 node-a.prod.example.net 2>/dev/null | ssh-keygen -lf -
256 SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI node-a.prod.example.net (ED25519)
```

`ssh-keyscan` **no** es un paso de verificación. Transporta lo que sea que la red te dé. Compará su huella contra un canal que el atacante no controle — la salida serial de la consola de la nube, el hecho de Ansible recolectado por un camino ya confiable, o el certificado firmado por la CA.

```
$ ssh-keygen -F node-a.prod.example.net                 # is it already known?
# Host node-a.prod.example.net found: line 42
|1|8sJ2qL0cZ6hK1pR8gJ5uH2aE7fV=|9dZ4wQ8sN3mK1pR6gJ5uH2aE7fV= ssh-ed25519 AAAAC3Nza...

$ ssh-keygen -R node-a.prod.example.net                 # remove it (works on hashed files)
# Host node-a.prod.example.net found: line 42
/home/sre/.ssh/known_hosts updated.
Original contents retained as /home/sre/.ssh/known_hosts.old

$ ssh-keygen -H -f ~/.ssh/known_hosts                   # hash an existing plaintext file
/home/sre/.ssh/known_hosts updated.
Original contents retained as /home/sre/.ssh/known_hosts.old
WARNING: /home/sre/.ssh/known_hosts.old contains unhashed entries
Delete this file to ensure privacy of hostnames
```

El hashing importa: un `known_hosts` sin hashear en una laptop comprometida es un mapa de movimiento lateral listo para usar.

### 4.3 El agente

```
$ eval "$(ssh-agent -s)"
Agent pid 48213

$ echo "$SSH_AUTH_SOCK"
/tmp/ssh-XXXXXm9K2pQ/agent.48212

$ ssh-add -t 4h ~/.ssh/id_ed25519_prod
Enter passphrase for /home/sre/.ssh/id_ed25519_prod:
Identity added: /home/sre/.ssh/id_ed25519_prod (sre@laptop-2026-08)
Lifetime set to 14400 seconds

$ ssh-add -l
256 SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI sre@laptop-2026-08 (ED25519)
256 SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI oncall@yubikey (ED25519-SK)

$ ssh-add -L | head -1
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP /home/sre/.ssh/id_ed25519_prod

$ ssh-add -x                                # lock the agent without dropping keys
Enter lock password:
Again:
Agent locked.

$ ssh-add -l
The agent has no identities.               # keys are still there, just unusable

$ ssh-add -X
Enter lock password:
Agent unlocked.

$ ssh-add -d ~/.ssh/id_ed25519_prod         # drop one key
Identity removed: /home/sre/.ssh/id_ed25519_prod ED25519 (sre@laptop-2026-08)

$ ssh-add -D                                # drop all
All identities removed.
```

Confirmación al usar — la mitigación que hace tolerable el reenvío de agente cuando de verdad no podés evitarlo:

```
$ ssh-add -c -t 1h ~/.ssh/id_ed25519_prod
Enter passphrase for /home/sre/.ssh/id_ed25519_prod:
Identity added: /home/sre/.ssh/id_ed25519_prod (sre@laptop-2026-08)
Lifetime set to 3600 seconds
The user must confirm each use of the key
```

### 4.4 Autenticarse y leer el handshake

```
$ ssh-copy-id -i ~/.ssh/id_ed25519_prod.pub sre@node-a.prod.example.net
/usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed: "/home/sre/.ssh/id_ed25519_prod.pub"
/usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed
/usr/bin/ssh-copy-id: INFO: 1 key(s) remain to be installed -- if you are prompted now it is to install the new keys
sre@node-a.prod.example.net's password:

Number of key(s) added: 1

Now try logging into the machine, with:   "ssh 'sre@node-a.prod.example.net'"
and check to make sure that only the key(s) you wanted were added.
```

```
$ ssh -v sre@node-a.prod.example.net true
OpenSSH_9.9p1 Debian-3, OpenSSL 3.4.0 22 Oct 2024
debug1: Reading configuration data /home/sre/.ssh/config
debug1: /home/sre/.ssh/config line 22: Applying options for *.prod.example.net
debug1: Reading configuration data /etc/ssh/ssh_config
debug1: Setting implicit ProxyCommand from ProxyJump: ssh -v -W '[%h]:%p' bastion-eu
debug1: Executing proxy command: exec ssh -v -W '[node-a.prod.example.net]:22' bastion-eu
debug1: Connecting to node-a.prod.example.net port 22.
debug1: Connection established.
debug1: identity file /home/sre/.ssh/id_ed25519_sk_prod type 3
debug1: Local version string SSH-2.0-OpenSSH_9.9p1 Debian-3
debug1: Remote protocol version 2.0, remote software version OpenSSH_9.9p1 Debian-3
debug1: SSH2_MSG_KEXINIT sent
debug1: SSH2_MSG_KEXINIT received
debug1: kex: algorithm: mlkem768x25519-sha256
debug1: kex: host key algorithm: ssh-ed25519-cert-v01@openssh.com
debug1: kex: server->client cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: kex: client->server cipher: chacha20-poly1305@openssh.com MAC: <implicit> compression: none
debug1: Server host certificate: ssh-ed25519-cert-v01@openssh.com SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI, serial 4471 ID "node-a.prod" CA ssh-ed25519 SHA256:L0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4w valid from 2026-08-01T00:00:00 to 2026-09-30T00:00:00
debug1: Host 'node-a.prod.example.net' is known and matches the ED25519-CERT host certificate.
debug1: Found CA key in /etc/ssh/ssh_known_hosts:1
debug1: Will attempt key: /home/sre/.ssh/id_ed25519_sk_prod ED25519-SK SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI agent
debug1: Authentications that can continue: publickey
debug1: Offering public key: /home/sre/.ssh/id_ed25519_sk_prod ED25519-SK SHA256:T7vX... agent
debug1: Server accepts key: /home/sre/.ssh/id_ed25519_sk_prod ED25519-SK SHA256:T7vX... agent
Confirm user presence for key ED25519-SK SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI
User presence confirmed
Authenticated to node-a.prod.example.net (via proxy) using "publickey".
debug1: Entering interactive session.
debug1: Exit status 0
```

Volcá la configuración efectiva del cliente — esto zanja toda discusión del tipo "pero si lo puse en `/etc/ssh/ssh_config`":

```
$ ssh -G node-a.prod.example.net | grep -E '^(user|port|identityfile|proxyjump|forwardagent|stricthostkeychecking|ciphers)'
user sre
port 22
identityfile ~/.ssh/id_ed25519_sk_prod
proxyjump bastion-eu
forwardagent no
stricthostkeychecking yes
ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
```

### 4.5 Túneles

**Reenvío local** — alcanzar un primario de Postgres que solo escucha en su propio loopback:

```
$ ssh -f -N -L 127.0.0.1:15432:127.0.0.1:5432 -o ExitOnForwardFailure=yes sre@db-primary.prod.example.net

$ ss -tlnp 'sport = :15432'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       128         127.0.0.1:15432        0.0.0.0:*      users:(("ssh",pid=51204,fd=5))

$ psql "host=127.0.0.1 port=15432 dbname=orders user=readonly sslmode=disable" -c 'select now(), inet_server_addr();'
              now              | inet_server_addr
-------------------------------+------------------
 2026-08-31 09:31:47.114882+00 | 10.42.3.17
(1 row)
```

`sslmode=disable` es correcto *acá*: el canal SSH ya provee confidencialidad e integridad, y el extremo TCP es el propio loopback del servidor. No lo generalices.

**Reenvío remoto** — publicar un servicio local en el bastión:

```
$ ssh -N -R 127.0.0.1:19100:127.0.0.1:9100 tunnel@bastion.eu-west-1.example.net &
[1] 51890

# On the bastion:
$ ss -tlnp 'sport = :19100'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       128         127.0.0.1:19100        0.0.0.0:*      users:(("sshd",pid=2211,fd=9))

$ curl -s http://127.0.0.1:19100/metrics | head -3
# HELP go_gc_duration_seconds A summary of the wall-time pause (GC) duration.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 4.1206e-05
```

Pedile al servidor que elija el puerto (`-R 0:...`) cuando muchos nodos comparten un bastión:

```
$ ssh -N -R 0:127.0.0.1:9100 tunnel@bastion.eu-west-1.example.net -v 2>&1 | grep 'Allocated port'
debug1: Remote connections from LOCALHOST:39241 forwarded to local address 127.0.0.1:9100
Allocated port 39241 for remote forward to 127.0.0.1:9100
```

**Reenvío dinámico** (SOCKS5):

```
$ ssh -f -N -D 127.0.0.1:1080 sre@bastion.eu-west-1.example.net

$ curl -s --socks5-hostname 127.0.0.1:1080 http://argocd.internal.example.net/api/version | jq -r .Version
v2.13.1+af54ef8
```

`--socks5-hostname` (en lugar de `--socks5`) resuelve el DNS **en el bastión**. Sin eso, tu resolvedor local filtra el nombre de host interno y, más en la práctica, ni siquiera logra resolverlo.

**Gestionar reenvíos sobre una conexión viva** vía el socket de control — sin reconectar, sin perder la sesión:

```
$ ssh -O check bastion-eu
Master running (pid=51204)

$ ssh -O forward -L 127.0.0.1:16443:10.42.0.5:6443 bastion-eu
$ ss -tlnp 'sport = :16443'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       128         127.0.0.1:16443        0.0.0.0:*      users:(("ssh",pid=51204,fd=7))

$ ssh -O cancel -L 127.0.0.1:16443:10.42.0.5:6443 bastion-eu
$ ssh -O exit bastion-eu
Exit request sent.
```

Lo mismo se alcanza interactivamente con la secuencia de escape `~C` (primero un salto de línea, después `~C`):

```
ssh> -L 127.0.0.1:18080:10.42.0.9:80
Forwarding port.
ssh> ?
Commands:
      -L[bind_address:]port:host:hostport    Request local forward
      -R[bind_address:]port:host:hostport    Request remote forward
      -D[bind_address:]port                  Request dynamic forward
      -KL[bind_address:]port                 Cancel local forward
```

**Reenvío X11:**

```
$ ssh -X sre@workstation.lab.example.net
sre@workstation:~$ echo $DISPLAY
localhost:10.0

sre@workstation:~$ xauth list
workstation.lab.example.net/unix:10  MIT-MAGIC-COOKIE-1  9f2c7b41d80e5a63c17f4b2e6a05d391

sre@workstation:~$ ss -tlnp | grep 601
LISTEN 0  128  127.0.0.1:6010  0.0.0.0:*  users:(("sshd",pid=8842,fd=10))

sre@workstation:~$ xdpyinfo | head -3
name of display:    localhost:10.0
version number:     11.0
vendor string:      The X.Org Foundation

sre@workstation:~$ xclock &
```

El display `localhost:10.0` mapea al puerto TCP `6000 + 10 = 6010`, ligado a loopback porque `X11UseLocalhost yes` es el valor por defecto. El `MIT-MAGIC-COOKIE-1` en `~/.Xauthority` es el secreto compartido que autoriza al cliente remoto ante tu servidor X local; SSH genera una cookie *proxy* para el reenvío no confiable (`-X`) y la sustituye de forma transparente.

`-X` aplica la extensión SECURITY de X y un tiempo de expiración de 20 minutos sobre la cookie no confiable; `-Y` se saltea ambas cosas. Bajo `-Y`, la aplicación remota puede leer tu portapapeles, sacar capturas de pantalla e inyectar pulsaciones de teclas en cada ventana de tu servidor X local. En Wayland, el reenvío X11 alcanza únicamente a los clientes de `Xwayland`.

### 4.6 GnuPG de punta a punta

**Crear una clave con una topología apta para uso offline:**

```
$ gpg --quick-generate-key "SRE Platform <sre@example.com>" future-default cert 2y
About to create a key for:
    "SRE Platform <sre@example.com>"

Continue? (Y/n) y
We need to generate a lot of random bytes. ...
gpg: /home/sre/.gnupg/trustdb.gpg: trustdb created
gpg: directory '/home/sre/.gnupg/openpgp-revocs.d' created
gpg: revocation certificate stored as '/home/sre/.gnupg/openpgp-revocs.d/4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6.rev'
public and secret key created and signed.

pub   ed25519 2026-08-31 [C] [expires: 2028-08-30]
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
uid                      SRE Platform <sre@example.com>
```

```
$ gpg --quick-add-key 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 ed25519 sign 1y
$ gpg --quick-add-key 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 cv25519 encr 1y
$ gpg --quick-add-key 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 ed25519 auth 1y

$ gpg --list-secret-keys --keyid-format 0xlong --with-keygrip
/home/sre/.gnupg/pubring.kbx
----------------------------
sec   ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 [C] [expires: 2028-08-30]
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
      Keygrip = 7B4C29E01FA6D3958C2B7E14D06A5F8931CE2740
uid                   [ultimate] SRE Platform <sre@example.com>
ssb   ed25519/0x3C7D91AB55E20F48 2026-08-31 [S] [expires: 2027-08-31]
      Keygrip = A15F7C930D6B24E8871F0A3C95D26E4470BA8135
ssb   cv25519/0xB2E80D14C93A6F57 2026-08-31 [E] [expires: 2027-08-31]
      Keygrip = C40E29B7158A6D3F92C1704E8BD53A6621F09C84
ssb   ed25519/0x6A1F03D8E27B54C9 2026-08-31 [A] [expires: 2027-08-31]
      Keygrip = E93D175CB0248FA61D7E9350C82B4F017AD6E259
```

`[C]` certificar, `[S]` firmar, `[E]` cifrar, `[A]` autenticar. El keygrip es el nombre de archivo bajo `~/.gnupg/private-keys-v1.d/` y el token que `gpg-agent` usa en `sshcontrol`.

**Mover la clave primaria fuera de línea** — la operación que hace que toda la topología valga la pena:

```
$ gpg --export-secret-subkeys --armor 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 > /mnt/airgap/subkeys.asc
$ gpg --export-secret-keys --armor 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6 > /mnt/airgap/primary-FULL.asc
$ gpg --delete-secret-keys 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
$ gpg --import /mnt/airgap/subkeys.asc

$ gpg --list-secret-keys --keyid-format 0xlong
sec#  ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 [C] [expires: 2028-08-30]
```

El `#` después de `sec` es exactamente el punto: el secreto primario **no está en esta máquina**. La laptop puede firmar, cifrar y autenticar; no puede certificar otras claves, agregar UIDs ni extender el vencimiento — y un ladrón no puede apoderarse de tu identidad.

**Operaciones cotidianas:**

```
$ gpg --armor --export sre@example.com > sre-public.asc
$ gpg --import colleague-public.asc
gpg: key 0xA7C3E91B22D4F658: public key "Platform CI <ci@example.com>" imported
gpg: Total number processed: 1
gpg:               imported: 1

$ gpg --edit-key ci@example.com
gpg> fpr
pub   ed25519/0xA7C3E91B22D4F658 2026-06-14 SRE Platform CI
 Primary key fingerprint: A7C3 E91B 22D4 F658 0A19  B3CC 5E7D 2F41 B806 9AE2
gpg> trust
  1 = I don't know or won't say
  2 = I do NOT trust
  3 = I trust marginally
  4 = I trust fully
  5 = I trust ultimately
Your decision? 4
gpg> sign
gpg> save
```

Verificá esa huella por voz, en persona, o contra un inventario firmado — nunca leyéndola del mismo correo que trajo la clave.

```
$ echo "s3cr3t-db-password" | gpg --encrypt --armor \
    --recipient sre@example.com --recipient ci@example.com --output db.pw.asc

$ gpg --list-packets db.pw.asc | grep -E 'pubkey enc|keyid'
:pubkey enc packet: version 3, algo 18, keyid B2E80D14C93A6F57
:pubkey enc packet: version 3, algo 18, keyid 0000000000000000     # throw-keyids in effect

$ gpg --decrypt db.pw.asc
gpg: encrypted with cv25519 key, ID 0xB2E80D14C93A6F57, created 2026-08-31
      "SRE Platform <sre@example.com>"
s3cr3t-db-password

$ gpg --symmetric --cipher-algo AES256 --armor --output backup.tar.gz.asc backup.tar.gz

$ gpg --detach-sign --armor --output dist/artifact.tar.gz.asc dist/artifact.tar.gz
$ gpg --verify dist/artifact.tar.gz.asc dist/artifact.tar.gz
gpg: Signature made Mon 31 Aug 2026 09:47:12 AM UTC
gpg:                using EDDSA key 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF
gpg:                issuer "sre@example.com"
gpg: Good signature from "SRE Platform <sre@example.com>" [ultimate]
```

`gpg --verify` sale con `0` ante una firma buena y con `1` en caso contrario — pero **una firma buena de una clave no confiable también sale con 0**, con un `WARNING: This key is not certified with a trusted signature!`. En automatización, verificá contra un llavero dedicado que contenga solo las claves que aceptás:

```
$ gpg --no-default-keyring --keyring /etc/apt/trusted-release.gpg \
      --status-fd 1 --verify dist/artifact.tar.gz.asc dist/artifact.tar.gz \
  | grep -E '^\[GNUPG:\] (GOODSIG|VALIDSIG|TRUST_)'
[GNUPG:] GOODSIG 3C7D91AB55E20F48 SRE Platform <sre@example.com>
[GNUPG:] VALIDSIG 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF 2026-08-31 1788507232 0 4 0 22 10 00 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF
[GNUPG:] TRUST_ULTIMATE 0 pgp
```

La salida legible por máquina de `--status-fd` es la única superficie de parseo correcta; la salida humana no es una API estable.

**Revocación:**

```
$ gpg --output revoke-sre.asc --gen-revoke sre@example.com
sec  ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 SRE Platform <sre@example.com>

Create a revocation certificate for this key? (y/N) y
Please select the reason for the revocation:
  0 = No reason specified
  1 = Key has been compromised
  2 = Key is no longer used
  3 = User ID is no longer valid
  Q = Cancel
Your decision? 1
Enter an optional description; end it with an empty line:
> Laptop stolen 2026-08-31, key material assumed exfiltrated
>
Reason for revocation: Key has been compromised
Laptop stolen 2026-08-31, key material assumed exfiltrated
Is this okay? (y/N) y
ASCII armored output forced.
Revocation certificate created.

$ gpg --import revoke-sre.asc
gpg: key 0x9E4A2C7F0B15D3A6: "SRE Platform <sre@example.com>" revocation certificate imported

$ gpg --keyserver hkps://keys.openpgp.org --send-keys 4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
gpg: sending key 0x9E4A2C7F0B15D3A6 to hkps://keys.openpgp.org

$ gpg --list-keys sre@example.com
pub   ed25519/0x9E4A2C7F0B15D3A6 2026-08-31 [C] [revoked: 2026-08-31]
      4F2B8C11D9A06E3D77B41C889E4A2C7F0B15D3A6
uid           [ revoked] SRE Platform <sre@example.com>
```

Revocar una única subclave comprometida en lugar de toda la identidad:

```
$ gpg --edit-key sre@example.com
gpg> key 2
gpg> revkey
Do you really want to revoke this subkey? (y/N) y
Please select the reason for the revocation:
  1 = Key has been compromised
Your decision? 1
gpg> save
```

La revocación es **publicación**, no borrado. Cualquiera que nunca refresque desde un keyserver, y todo texto cifrado ya producido, quedan sin efecto. Tratá la revocación como una señal hacia tus pares y **rotá los secretos subyacentes** — esa es la parte que realmente contiene el incidente.

**`gpg-agent` como `ssh-agent`:**

```
$ gpgconf --list-dirs agent-ssh-socket
/run/user/1000/gnupg/S.gpg-agent.ssh

$ echo E93D175CB0248FA61D7E9350C82B4F017AD6E259 >> ~/.gnupg/sshcontrol
$ gpgconf --kill gpg-agent
$ export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

$ ssh-add -l
256 SHA256:mK1pR6gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4wQ8sN3 (ED25519)
```

La subclave `[A]` (autenticación) ahora sirve como identidad SSH, que es el mecanismo detrás del login SSH con smartcard OpenPGP.

**Firmar commits de git — con ambos back ends:**

```
$ git config --global user.signingkey 0x3C7D91AB55E20F48
$ git config --global commit.gpgsign true
$ git config --global tag.gpgsign true
$ git commit -S -m "feat: rotate database credentials"
[main 7a3f912] feat: rotate database credentials

$ git log --show-signature -1
commit 7a3f912c8e04b5d1739f2a6c58e1d047b3925fa8
gpg: Signature made Mon 31 Aug 2026 09:52:01 AM UTC
gpg:                using EDDSA key 3C7D91AB55E20F48A0F2C815D74B93E60A5C21DF
gpg: Good signature from "SRE Platform <sre@example.com>" [ultimate]
```

```
$ git config --global gpg.format ssh
$ git config --global user.signingkey ~/.ssh/id_ed25519_prod.pub
$ git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
$ printf 'sre@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0f7c9pQ2m4hV1sT7nQ8xJd3bK9wRfZ1Yv6uLg0aXcP\n' \
    > ~/.config/git/allowed_signers

$ git log --show-signature -1
Good "git" signature for sre@example.com with ED25519 key SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI
```

Firmas independientes con `ssh-keygen` sobre archivos arbitrarios, útiles cuando ya operás una CA de SSH y no querés una segunda PKI:

```
$ ssh-keygen -Y sign -f ~/.ssh/id_ed25519_prod -n file dist/artifact.tar.gz
Signing file dist/artifact.tar.gz
Write signature to dist/artifact.tar.gz.sig

$ ssh-keygen -Y verify -f ~/.config/git/allowed_signers -I sre@example.com \
             -n file -s dist/artifact.tar.gz.sig < dist/artifact.tar.gz
Good "file" signature for sre@example.com with ED25519 key SHA256:qN4mV7pR2sT9xL0cY6bZ1wJ8dK3fH5uQ7gE2aX9oSvI
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La escalera de verificación

| Peldaño | Qué prueba | Comando | Costo |
|---|---|---|---|
| 1. Sintaxis | Que la configuración parsee | `sshd -t`; `ssh -G host` | gratis |
| 2. Configuración efectiva | Qué se aplica realmente, tras fusionar `Match`/`Host` | `sshd -T -C user=sre,host=10.42.0.5,addr=10.42.0.5`; `ssh -G host` | gratis |
| 3. Inventario de claves | Qué claves existen, su tipo y su huella | `ssh-keygen -lf`; `gpg -K --with-keygrip` | gratis |
| 4. Anclas de confianza | Que el cliente confíe en la identidad de host correcta | `ssh-keygen -F host`; `ssh-keygen -L -f *-cert.pub` | gratis |
| 5. Criptografía negociada | En qué acordaron realmente los pares, no lo que configuraste | `ssh -v … \| grep 'kex:'` | una conexión |
| 6. Autorización | Que esta clave realmente pueda alcanzar esta cuenta | `ssh -o BatchMode=yes -o PreferredAuthentications=publickey user@host true` | una conexión |
| 7. Camino de datos | Que el túnel lleve tráfico real al extremo previsto | `ss -tlnp`; una sonda a nivel de aplicación (`psql`, `curl`) | una petición |
| 8. Corrección del contenido | Que el texto plano descifrado sea el secreto que querías | Salud de la aplicación, no una herramienta criptográfica | — |

El peldaño 8 es donde está la brecha honesta: todos los chequeos anteriores pasan para una credencial perfectamente cifrada, perfectamente entregada y **equivocada**.

### 5.2 Chequeo de salud no interactivo

```bash
#!/usr/bin/env bash
# /usr/local/sbin/check-ssh-trust.sh — exits non-zero on the first violation.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'OK:   %s\n' "$1"; }

# 1. sshd config is syntactically valid
/usr/sbin/sshd -t || fail "sshd_config does not parse"
ok "sshd_config parses"

# 2. Password authentication and root login are off in the effective config
eff=$(/usr/sbin/sshd -T 2>/dev/null)
grep -qx 'passwordauthentication no' <<<"$eff" || fail "PasswordAuthentication is enabled"
grep -qx 'permitrootlogin no'       <<<"$eff" || fail "PermitRootLogin is not 'no'"
ok "password auth and root login disabled"

# 3. No weak host keys present
for weak in dsa ecdsa; do
    [[ -e "/etc/ssh/ssh_host_${weak}_key" ]] && fail "weak host key present: ${weak}"
done
ok "no DSA/ECDSA host keys"

# 4. Host key permissions
while IFS= read -r -d '' k; do
    perm=$(stat -c '%a %U' "$k")
    [[ "$perm" == "600 root" ]] || fail "$k has wrong perms/owner: $perm"
done < <(find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key' -print0)
ok "host key permissions are 0600 root:root"

# 5. Host certificate, if configured, is still valid
cert=/etc/ssh/ssh_host_ed25519_key-cert.pub
if [[ -s "$cert" ]]; then
    until=$(ssh-keygen -L -f "$cert" | awk '/Valid:/ {print $NF}')
    left=$(( $(date -d "$until" +%s) - $(date +%s) ))
    (( left > 604800 )) || fail "host certificate expires in $((left/86400))d (< 7d)"
    ok "host certificate valid for $((left/86400)) more days"
fi

# 6. Every authorized_keys file is user-owned and not group/world writable
while IFS=: read -r user _ uid _ _ home _; do
    (( uid >= 1000 )) || continue
    ak="$home/.ssh/authorized_keys"
    [[ -f "$ak" ]] || continue
    perm=$(stat -c '%a %U' "$ak")
    [[ "${perm%% *}" =~ ^6[04]0$ ]] || fail "$ak has permissive mode: $perm"
    [[ "${perm##* }" == "$user" ]]  || fail "$ak not owned by $user"
done < /etc/passwd
ok "authorized_keys ownership and modes are sane"
```

### 5.3 Catálogo de fallas

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `Permissions 0644 for '/home/sre/.ssh/id_ed25519' are too open.` | Clave privada legible por otros; `ssh` se niega a usarla | `chmod 600 ~/.ssh/id_ed25519; chmod 700 ~/.ssh` |
| `Load key "...": error in libcrypto` | El archivo no es una clave, o es un `.ppk` de PuTTY, o está truncado | `ssh-keygen -y -f <key>`; convertir con `puttygen key.ppk -O private-openssh -o id_rsa` |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` | Reconstrucción legítima, O un MITM activo | **Verificá fuera de banda primero.** Después `ssh-keygen -R host`. Nunca borres `known_hosts` a ciegas. |
| `Host key verification failed.` | Host desconocido con `StrictHostKeyChecking yes`, o `UserKnownHostsFile` ilegible | Sembrá la entrada desde un inventario confiable; verificá la ruta del archivo con `ssh -G host \| grep knownhosts` |
| `no matching host key type found. Their offer: ssh-rsa` | El servidor solo ofrece RSA con SHA-1, deshabilitado desde OpenSSH 8.8 | Por host: `HostkeyAlgorithms +ssh-rsa`, `PubkeyAcceptedAlgorithms +ssh-rsa`. Arreglá el servidor. |
| `Unable to negotiate with 10.0.0.5 port 22: no matching key exchange method found.` | Par antiquísimo (electrodoméstico de red) | Por host `KexAlgorithms +diffie-hellman-group14-sha1` — acotado, temporal, registrado |
| `Permission denied (publickey).` con la clave correcta cargada | Modo/propiedad de `authorized_keys`, directorio home escribible por el grupo, etiqueta SELinux | `sudo journalctl -u ssh -n50`; buscá `Authentication refused: bad ownership or modes`; `restorecon -Rv ~/.ssh` |
| `sign_and_send_pubkey: signing failed for ED25519 ...: agent refused operation` | Agente bloqueado, clave vencida por `-t`, o el diálogo de confirmación de `-c` no tenía display | `ssh-add -l`; `ssh-add -X`; configurá `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` |
| `Could not open a connection to your authentication agent.` | `SSH_AUTH_SOCK` sin definir o apuntando a un socket muerto (clásico tras `sudo`, `screen`, reenganche de `tmux`) | `echo $SSH_AUTH_SOCK; ss -xl \| grep agent`; usá una ruta de socket estable (§3.8) |
| `Too many authentication failures` | El agente ofreció todas las claves cargadas; el servidor llegó a `MaxAuthTries` | `IdentitiesOnly yes` + `IdentityFile` explícito |
| `channel 2: open failed: administratively prohibited: open failed` | El servidor tiene `AllowTcpForwarding no` o el destino está fuera de `PermitOpen` | Revisá `sshd -T \| grep -E 'allowtcpforwarding\|permitopen'` |
| `bind [127.0.0.1]:8080: Address already in use` + `Could not request local forwarding.` | Un reenvío previo (a menudo un `ControlMaster` todavía vivo) retiene el puerto | `ssh -O check host`; `ssh -O exit host`; `ss -tlnp 'sport = :8080'` |
| El reenvío remoto liga solo loopback en silencio | `GatewayPorts no` (por defecto) | Configurá `GatewayPorts clientspecified` en el **servidor**; mejor todavía, quedate en loopback y agregá un proxy |
| El túnel "funciona" pero llegás al servicio equivocado | `ExitOnForwardFailure` sin definir: el reenvío falló y un servicio local respondió en su lugar | Siempre `ExitOnForwardFailure yes`; verificá el par con una sonda a nivel de aplicación |
| El túnel muere tras unos minutos de inactividad | El timeout de inactividad del NAT/firewall descarta el flujo | `ServerAliveInterval 30`, `ServerAliveCountMax 3`; supervisalo con systemd (§3.8) |
| Una transferencia masiva por un túnel colapsa ante pérdida de paquetes | TCP sobre TCP: dos temporizadores de retransmisión independientes pelean entre sí | Usá WireGuard/UDP, o `ssh -o Compression=no` + un único flujo; no lo resuelvas a fuerza de tuning |
| `X11 forwarding request failed on channel 0` | `X11Forwarding no`, o `xauth` no instalado en el servidor | `sshd -T \| grep x11`; `apt install xauth` |
| `Warning: untrusted X11 forwarding setup failed: xauth key data not generated` | `xauth` faltante o roto, o `~/.Xauthority` no escribible (disco lleno, home de solo lectura) | `which xauth`; `ls -l ~/.Xauthority`; espacio libre |
| `Error: Can't open display: localhost:10.0` | `$DISPLAY` heredado en una shell `sudo`/`su` que perdió `~/.Xauthority` | `xauth list` como el usuario original, `xauth add` como el usuario destino, o `sudo -E` |
| `gpg: decryption failed: No secret key` | Texto cifrado hacia una clave que no tenés, o `GNUPGHOME` equivocado | `gpg --list-packets file.asc \| grep keyid`; `gpg -K` |
| `gpg: signing failed: Inappropriate ioctl for device` | Pinentry sin TTY (cron, CI, contenedor) | `export GPG_TTY=$(tty)`; o `--pinentry-mode loopback --passphrase-fd 0` con `allow-loopback-pinentry` |
| `gpg: WARNING: unsafe permissions on homedir '/home/sre/.gnupg'` | El directorio no está en `0700` | `chmod 700 ~/.gnupg; chmod 600 ~/.gnupg/*` |
| `gpg: keyserver receive failed: No dirmngr` / `Server indicated a failure` | `dirmngr` no está corriendo o lo bloquea la política de egreso | `gpgconf --launch dirmngr`; `dirmngr --debug-level guru --server`; revisá el egreso hkps por 443 |
| `gpg: There is no assurance this key belongs to the named user` | Clave importada pero nunca certificada | `gpg --edit-key <id>` → verificar la huella fuera de banda → `trust` / `sign` |
| GnuPG se cuelga para siempre en CI | El agente espera un pinentry que nadie va a contestar | `--batch --no-tty --pinentry-mode loopback`; `gpgconf --kill gpg-agent` entre trabajos |
| `gpg: Note: signature key ... expired` | Pasó el vencimiento de la subclave | En la máquina offline: `gpg --quick-set-expire <fpr> 1y <subkey-fpr>`, reexportar, redistribuir |

### 5.4 Escalera de escalamiento diagnóstico

```
$ ssh -v  host        # config resolution, KEX, which keys were offered
$ ssh -vv host        # per-channel state, packet-level decisions
$ ssh -vvv host       # raw protocol; only when you suspect an implementation bug
```

Del lado del servidor, sin perturbar el demonio en ejecución — corré un segundo `sshd` en un puerto alternativo, en primer plano, una conexión por vez:

```
$ sudo /usr/sbin/sshd -d -p 2222
debug1: sshd version OpenSSH_9.9, OpenSSL 3.4.0 22 Oct 2024
debug1: private host key #0: ssh-ed25519 SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI
debug1: rexec_argv[2]='-p'
Server listening on 0.0.0.0 port 2222.
...
debug1: userauth-request for user sre service ssh-connection method publickey
debug1: trying public key file /home/sre/.ssh/authorized_keys
Authentication refused: bad ownership or modes for directory /home/sre
debug1: restore_uid: 0/0
Failed publickey for sre from 10.42.0.9 port 51422 ssh2: ED25519 SHA256:qN4mV7pR...
```

Esa única línea — `bad ownership or modes for directory /home/sre` — es la respuesta a la mayoría de los tickets de "mi clave dejó de funcionar", y nunca aparece en el cliente. Causa: el directorio home es escribible por el grupo o por todos (comúnmente `775` tras un `chmod -R` descuidado), así que alguien distinto del propietario podría reemplazar `~/.ssh`. `chmod 750 /home/sre` lo arregla.

Correlacioná en la capa de auditoría:

```
$ sudo journalctl -u ssh --since "1 hour ago" -o cat | grep -E 'Accepted|Failed|Disconnect'
Accepted publickey for sre from 10.42.0.9 port 51402 ssh2: ED25519-SK SHA256:T7vX2cL9bY0dZ4wQ8sN3mK1pR6gJ5uH2aE7fV1oS9xI, serial 4471 CA ED25519 SHA256:L0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4w
Failed publickey for deployer from 10.42.7.2 port 40118 ssh2: RSA SHA256:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9x
Disconnected from authenticating user deployer 10.42.7.2 port 40118 [preauth]
```

Con `LogLevel VERBOSE`, cada login aceptado registra la **huella de la clave** (y, con certificados, el número de serie y la CA emisora). Esa huella es lo que convierte "alguien inició sesión como `sre`" en "*esta* credencial en *esa* laptop inició sesión", que es la diferencia entre un rastro de auditoría y un archivo de log.

Verificá un certificado antes de culpar a la red:

```
$ ssh-keygen -L -f /etc/ssh/ssh_host_ed25519_key-cert.pub
/etc/ssh/ssh_host_ed25519_key-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com host certificate
        Public key: ED25519-CERT SHA256:9pQ2sT7vX4cL6bY1dZ0wJ8mK3nR5hF2uG7eV9aS1oXI
        Signing CA: ED25519 SHA256:L0cZ6hK1pR8gJ5uH2aE7fV1oS9xIT7vX2cL9bY0dZ4w (using ssh-ed25519)
        Key ID: "node-a.prod"
        Serial: 4471
        Valid: from 2026-08-01T00:00:00 to 2026-09-30T00:00:00
        Principals:
                node-a.prod.example.net
                10.42.3.17
        Critical Options: (none)
        Extensions: (none)
```

Un certificado vencido produce del lado del cliente un `Host key verification failed.` que se ve exactamente igual que un MITM. Alertá sobre `Valid: to` menos el ahora, no sobre las fallas de conexión — la alerta debería dispararse días antes de la caída.

Observá el camino de datos real de un túnel en lugar de confiar en que existe:

```
$ ss -tnp state established '( sport = :22 or dport = :22 )'
Recv-Q Send-Q     Local Address:Port      Peer Address:Port  Process
     0      0        10.42.0.9:51402     10.42.3.17:22       users:(("ssh",pid=51204,fd=3))

$ sudo lsof -nP -iTCP:15432 -sTCP:LISTEN
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
ssh     51204  sre    5u  IPv4 918233      0t0  TCP 127.0.0.1:15432 (LISTEN)

$ sudo ss -K dst 10.42.3.17 dport = 22     # forcibly kill a wedged session's socket
```

Inspección del estado de GnuPG:

```
$ gpgconf --list-components
gpg:OpenPGP:/usr/bin/gpg
gpgsm:S/MIME:/usr/bin/gpgsm
keyboxd:Public Keys:/usr/libexec/keyboxd
gpg-agent:Private Keys:/usr/bin/gpg-agent
scdaemon:Smartcards:/usr/libexec/scdaemon
dirmngr:Network:/usr/bin/dirmngr

$ gpg-connect-agent 'keyinfo --list' /bye
S KEYINFO A15F7C930D6B24E8871F0A3C95D26E4470BA8135 D - - - P - - -
S KEYINFO C40E29B7158A6D3F92C1704E8BD53A6621F09C84 D - - - P - - -
OK

$ gpg-connect-agent 'RELOADAGENT' /bye     # pick up gpg-agent.conf without a restart
OK

$ gpgconf --kill gpg-agent                 # hard reset: drops all cached passphrases
$ gpg --check-trustdb
gpg: marginals needed: 3  completes needed: 1  trust model: pgp
gpg: depth: 0  valid:   1  signed:   2  trust: 0-, 0q, 0n, 0m, 0f, 1u
gpg: depth: 1  valid:   2  signed:   0  trust: 2-, 0q, 0n, 0m, 0f, 0u
gpg: next trustdb check due at 2027-08-31
```

### 5.5 Runbook de incidente — "robaron la laptop de un ingeniero"

```
# 1. Revoke SSH authority. With a user CA this is one file, fleet-wide.
$ ssh-keygen -lf ~/inventory/keys/former.pub
256 SHA256:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9x former@laptop (ED25519)
$ ansible-playbook playbooks/ssh-trust.yml -e '@revoke-former.yml'

# 2. Confirm enforcement on a sample node, from the node itself.
$ ssh node-a.prod.example.net 'sudo sshd -T | grep -E "revokedkeys|trusteduserca"'
revokedkeys /etc/ssh/revoked_user_keys
trusteduserca /etc/ssh/user_ca.pub

# 3. Terminate live sessions belonging to that principal. Revocation does NOT
#    close an already-authenticated connection.
$ ansible all -b -m shell -a "pkill -u former -t 'pts/*' || true"

# 4. Revoke the OpenPGP subkeys from the offline primary, publish, redistribute.
$ gpg --edit-key former@example.com          # key N -> revkey -> save
$ gpg --keyserver hkps://keys.openpgp.org --send-keys <FPR>

# 5. Re-encrypt every secret that key could read, then ROTATE the plaintext.
#    Re-encryption alone is theatre: the attacker may already hold the old blob.
$ sops updatekeys deploy/prod/postgres-credentials.enc.yaml
$ ./scripts/rotate-db-credentials.sh --namespace platform

# 6. Audit what that fingerprint touched.
$ ansible all -b -m shell \
    -a "journalctl -u ssh --since '30 days ago' -o cat | grep 'SHA256:xQ2mV7pR1sT9nY4bL0cZ6hK1pR8gJ5uH2aE7fV1oS9x' || true"
```

Los pasos 3 y 5 son los que se saltean, y son los que importan. La revocación cambia las decisiones de autorización futuras; no hace nada respecto de una sesión ya abierta o de un texto cifrado ya copiado.

---

## 6. Referencias

**Objetivos de certificación LPI**
- Objetivos del examen 101-500 — https://www.lpi.org/our-certifications/exam-101-objectives/
- Objetivos del examen 102-500 (el tema 110.3 vive acá) — https://www.lpi.org/our-certifications/exam-102-objectives/
- Panorama de la certificación LPIC-1 — https://www.lpi.org/our-certifications/lpic-1-overview/

**OpenSSH — documentación del proyecto y páginas de manual**
- Proyecto OpenSSH — https://www.openssh.com/
- Notas de versión y cronograma de deprecación (`ssh-rsa`/SHA-1, eliminación de DSA) — https://www.openssh.com/releasenotes.html
- Política de seguridad de OpenSSH y guía sobre algoritmos heredados — https://www.openssh.com/security.html
- `ssh(1)` — https://man.openbsd.org/ssh.1
- `ssh_config(5)` — https://man.openbsd.org/ssh_config.5
- `sshd(8)`, incluidas las secciones `AUTHORIZED_KEYS FILE FORMAT` y `SSH_KNOWN_HOSTS FILE FORMAT` — https://man.openbsd.org/sshd.8
- `sshd_config(5)` — https://man.openbsd.org/sshd_config.5
- `ssh-keygen(1)`, incluidas `CERTIFICATES` y `ALLOWED SIGNERS` — https://man.openbsd.org/ssh-keygen.1
- `ssh-agent(1)` — https://man.openbsd.org/ssh-agent.1
- `ssh-add(1)` — https://man.openbsd.org/ssh-add.1
- `ssh-keyscan(1)` — https://man.openbsd.org/ssh-keyscan.1
- `ssh-copy-id(1)` — https://man.openbsd.org/ssh-copy-id.1
- Soporte FIDO/U2F en OpenSSH (claves `*-sk`) — https://www.openssh.com/agent-restrict.html

**GnuPG — documentación del proyecto**
- Proyecto GnuPG — https://gnupg.org/
- The GNU Privacy Handbook — https://gnupg.org/gph/en/manual.html
- Manual de `gpg`, Using the GNU Privacy Guard — https://gnupg.org/documentation/manuals/gnupg/
- Opciones y configuración de `gpg-agent` — https://gnupg.org/documentation/manuals/gnupg/Invoking-GPG_002dAGENT.html
- `gpgconf` — https://gnupg.org/documentation/manuals/gnupg/Invoking-gpgconf.html
- `dirmngr` (acceso a keyservers y WKD) — https://gnupg.org/documentation/manuals/gnupg/Invoking-DIRMNGR.html
- HOWTO de smartcard / tarjeta OpenPGP — https://gnupg.org/howtos/card-howto/en/smartcard-howto.html
- FAQ de GnuPG — https://gnupg.org/faq/gnupg-faq.html

**Estándares de protocolo**
- RFC 4251 — The Secure Shell (SSH) Protocol Architecture — https://www.rfc-editor.org/rfc/rfc4251
- RFC 4252 — SSH Authentication Protocol — https://www.rfc-editor.org/rfc/rfc4252
- RFC 4253 — SSH Transport Layer Protocol — https://www.rfc-editor.org/rfc/rfc4253
- RFC 4254 — SSH Connection Protocol (canales, reenvío de puertos, X11) — https://www.rfc-editor.org/rfc/rfc4254
- RFC 4255 — Using DNS to Securely Publish SSH Key Fingerprints (SSHFP) — https://www.rfc-editor.org/rfc/rfc4255
- RFC 4716 — The Secure Shell Public Key File Format — https://www.rfc-editor.org/rfc/rfc4716
- RFC 8332 — Use of RSA Keys with SHA-256 and SHA-512 in SSH — https://www.rfc-editor.org/rfc/rfc8332
- RFC 8709 — Ed25519 and Ed448 Public Key Algorithms for SSH — https://www.rfc-editor.org/rfc/rfc8709
- RFC 4880 — OpenPGP Message Format — https://www.rfc-editor.org/rfc/rfc4880
- RFC 9580 — OpenPGP (revisión actual) — https://www.rfc-editor.org/rfc/rfc9580

**Sistema X Window**
- `xauth(1)` — https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml
- `Xsecurity(7)` — mecanismos de control de acceso — https://www.x.org/releases/current/doc/man/man7/Xsecurity.7.xhtml

**Herramientas de apoyo referenciadas en los manifiestos**
- SOPS — https://github.com/getsops/sops
- Documentación de cloud-init — https://cloudinit.readthedocs.io/en/latest/
- Directivas de sandboxing de `systemd.exec(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- Git — firmar commits y etiquetas — https://git-scm.com/book/en/v2/Git-Tools-Signing-Your-Work