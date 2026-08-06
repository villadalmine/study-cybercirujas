# LPIC-2 (Exámenes 201-450 y 202-450, v4.5) — Tema 2.6 / 209: Seguridad del Sistema
**Ponderación:** 9  
**Nivel Objetivo:** Senior SRE / Principal Platform Architect  
**Referencia Oficial:** [Linux Professional Institute LPIC-2 Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)

---

## Descripción Técnica General y Arquitectura Central

La Seguridad del Sistema dentro del Tema 209 de LPIC-2 (Ponderación 9) abarca tres subtemas fundamentales:
1. **209.1 Configuración de Routers y Filtrado de Paquetes (Ponderación 3):** Arquitectura de IP forwarding del kernel (`net.ipv4.ip_forward`), arquitectura de Linux netfilter, filtrado de paquetes con estado (`iptables` y `nftables`), Traducción de Direcciones de Red (NAT/SNAT/DNAT), enmascaramiento (masquerading) y manipulación de la tabla de enrutamiento.
2. **209.2 Aseguramiento de Servidores FTP (Ponderación 2):** Hardening criptográfico de daemons FTP (`vsftpd`, `Pure-FTPd`), cifrado explícito TLS/SSL, restricción de rango de puertos en modo pasivo en entornos con firewall, mecanismos de autenticación de usuarios y aislamiento estricto del sistema de archivos mediante jails `chroot`.
3. **209.3 Shell Seguro - SSH (Ponderación 4):** Arquitectura del daemon OpenSSH (`sshd`), configuración de claves de host y de usuario criptográficamente seguras, Autoridades de Certificación (CA) de OpenSSH, reenvío de puertos/tunelización restringido (`AllowTcpForwarding`, `PermitOpen`), riesgos de seguridad del reenvío de agentes SSH (agent forwarding), bloqueo del subsistema SFTP e integración dinámica de prevención de intrusiones.

---

## Ejercicios Prácticos Guiados

---

### Ejercicio 1: Hardening de Router Stateful Avanzado y NAT con `nftables`

#### Contexto y Mecánica de la Arquitectura
El framework netfilter de Linux procesa los paquetes de red que atraviesan la pila de red a través de puntos de enganche (hook points: `prerouting`, `input`, `forward`, `output`, `postrouting`). Mientras que el legado `iptables` utiliza módulos de kernel distintos para IPv4 (`ip_tables`) e IPv6 (`ip6_tables`), `nftables` consolida ambos a través de una máquina virtual de bytecode unificada dentro del kernel (`nft_compat` / `nf_tables`), ejecutando instrucciones generadas por la utilidad de espacio de usuario `nft`.

Cuando el IP forwarding (`net.ipv4.ip_forward = 1`) está habilitado, el tráfico de tránsito entrante ingresa a `prerouting`, pasa a través de la cadena `forward` y sale a través de `postrouting`. Las operaciones de NAT reescriben los encabezados:
- **DNAT (Destination NAT):** Modifica la IP/puerto de destino en `prerouting` antes de que ocurran las decisiones de enrutamiento.
- **SNAT / Masquerade (Source NAT):** Modifica la IP/puerto de origen en `postrouting` después de que las decisiones de enrutamiento seleccionan la interfaz de salida (egress).

```
       +---------------------------------------------------------------------------------+
       |                              Linux Kernel Netfilter                             |
       |                                                                                 |
[In] ---> Prerouting ---> Routing Decision ---> Forward ------------> Postrouting ---> [Out]
           (DNAT)               |                 (Filter)            (SNAT/Masq)
                                v
                              Input ------------> Local Process ---> Output
                             (Filter)                               (Filter)
       +---------------------------------------------------------------------------------+
```

#### Ejecución Paso a Paso

1. **Habilitar Kernel Packet Forwarding y Aplicar Parámetros de Sysctl:**
   Configurar los parámetros del kernel para permitir el IP forwarding, habilitar el filtrado de ruta inversa (RPF) contra el IP spoofing y deshabilitar los redireccionamientos ICMP.

   ```bash
   sudo sysctl -w net.ipv4.ip_forward=1
   sudo sysctl -w net.ipv4.conf.all.rp_filter=1
   sudo sysctl -w net.ipv4.conf.default.rp_filter=1
   sudo sysctl -w net.ipv4.conf.all.accept_redirects=0
   sudo sysctl -w net.ipv4.conf.all.send_redirects=0
   ```

   *Expected Output:*
   ```text
   net.ipv4.ip_forward = 1
   net.ipv4.conf.all.rp_filter = 1
   net.ipv4.conf.default.rp_filter = 1
   net.ipv4.conf.all.accept_redirects = 0
   net.ipv4.conf.all.send_redirects = 0
   ```

2. **Desplegar el Manifiesto Completo de Producción para `nftables` (`/etc/nftables.conf`):**
   Crear una estructura de reglas atómicas de `nftables` que soporte inspección con estado, mitigación de TCP SYN flood utilizando estados dinámicos de connection tracking, SNAT para subredes internas y reenvío selectivo de puertos mediante DNAT.

   ```bash
   sudo cat << 'EOF' | sudo tee /etc/nftables.conf
   #!/usr/sbin/nft -f

   flush ruleset

   table inet firewall {
       chain input {
           type filter hook input priority filter; policy drop;

           # Loopback traffic
           iifname "lo" accept

           # State tracking: Accept established and related traffic
           ct state established,related accept
           ct state invalid drop

           # Rate-limit ICMP echo requests (Ping Flood Protection)
           ip protocol icmp icmp type echo-request limit rate 5/second burst 10 packets accept
           ip protocol icmp icmp type echo-request drop

           # Rate-limit SSH SYN connections to mitigate brute-force scans
           tcp flags syn ct state new tcp dport 22 meter ssh_meter { ip saddr limit rate 3/minute over burst 5 packets } drop
           tcp flags syn ct state new tcp dport 22 accept

           # Reject unhandled traffic explicitly with ICMP port-unreachable
           reject with icmpx type port-unreachable
       }

       chain forward {
           type filter hook forward priority filter; policy drop;

           # Allow established/related transit connections
           ct state established,related accept
           ct state invalid drop

           # Allow LAN (eth1) traffic to reach WAN (eth0)
           iifname "eth1" oifname "eth0" ct state new accept

           # Allow DNAT forwarded traffic to internal DMZ Web Server (192.168.10.50:80)
           ip daddr 192.168.10.50 tcp dport 80 ct state new accept
       }

       chain postrouting {
           type nat hook postrouting priority srcnat; policy accept;

           # Masquerade traffic exiting WAN interface eth0 from internal LAN
           oifname "eth0" ip saddr 192.168.10.0/24 masquerade
       }

       chain prerouting {
           type nat hook prerouting priority dstnat; policy accept;

           # Port Forwarding: WAN (eth0) port 8080 -> DMZ HTTP Server port 80
           iifname "eth0" tcp dport 8080 dnat to 192.168.10.50:80
       }
   }
   EOF
   ```

3. **Cargar y Verificar el Ruleset de `nftables`:**
   Cargar el manifiesto de configuración atómico y verificar el estado de ejecución.

   ```bash
   sudo nft -f /etc/nftables.conf
   sudo nft list ruleset
   ```

   *Expected Output:*
   ```text
   table inet firewall {
   	meter ssh_meter {
   		type ipv4_addr
   		flags dynamic
   	}

   	chain input {
   		type filter hook input priority filter; policy drop;
   		iifname "lo" accept
   		ct state established,related accept
   		ct state invalid drop
   		ip protocol icmp icmp type echo-request limit rate 5/second burst 10 packets accept
   		ip protocol icmp icmp type echo-request drop
   		tcp flags syn ct state new tcp dport 22 meter ssh_meter { ip saddr limit rate 3/minute over burst 5 packets } drop
   		tcp flags syn ct state new tcp dport 22 accept
   		reject with icmpx type port-unreachable
   	}

   	chain forward {
   		type filter hook forward priority filter; policy drop;
   		ct state established,related accept
   		ct state invalid drop
   		iifname "eth1" oifname "eth0" ct state new accept
   		ip daddr 192.168.10.50 tcp dport 80 ct state new accept
   	}

   	chain postrouting {
   		type nat hook postrouting priority srcnat; policy accept;
   		oifname "eth0" ip saddr 192.168.10.0/24 masquerade
   	}

   	chain prerouting {
   		type nat hook prerouting priority dstnat; policy accept;
   		iifname "eth0" tcp dport 8080 dnat to 192.168.10.50:80
   	}
   }
   ```

4. **Verificar las Entradas Activas de Connection Tracking:**
   Inspeccionar la tabla de connection tracking del kernel (`conntrack`).

   ```bash
   sudo conntrack -L -p tcp
   ```

   *Expected Output:*
   ```text
   tcp      6 432000 ESTABLISHED src=192.168.10.50 dst=1.1.1.1 sport=45210 dport=443 src=1.1.1.1 dst=192.168.1.100 sport=443 dport=45210 [ASSURED] mark=0 use=1
   conntrack v1.4.6 flow entries have been shown.
   ```

---

#### Preguntas de Verificación — Ejercicio 1
1. **¿Por qué las reglas de Destination NAT (DNAT) deben procesarse en el hook `prerouting`, mientras que las reglas de Source NAT (SNAT/Masquerade) deben aplicarse en el hook `postrouting`?**
2. **¿Qué ventaja estructural a nivel de kernel posee `nftables` sobre el legado `iptables` al evaluar rulesets de paquetes que contienen cientos de filtros IP?**

---

### Ejercicio 2: Hardening de OpenSSH en Producción, Autenticación con Certificados de CA y Jails Chroot

#### Contexto y Mecánica de la Arquitectura
La autenticación por clave pública utilizando `authorized_keys` estándar presenta límites escalares operativos (costo de gestión de claves O(N*M)). El soporte de OpenSSH para Autoridades de Certificación (CA) permite la validación de hosts y usuarios mediante certificados de corta duración firmados por una clave raíz offline RSA/ED25519 de confianza.

Flujo de Autenticación con CA de OpenSSH:
1. El cliente genera un par de claves SSH efímero.
2. La CA de usuario firma la clave pública, produciendo `id_ed25519-cert.pub` que contiene la identidad de la clave, los principals (nombres de usuario), el indicador de tiempo de validez (timestamp) y los permisos (extensiones/opciones críticas).
3. El cliente presenta el certificado durante el SSH handshake.
4. El daemon verifica la firma utilizando `TrustedUserCAKeys` sin necesidad de una entrada de usuario local en `authorized_keys`.

```
+-------------+     1. Sign Public Key      +-------------------+
|  User CA    | --------------------------> | Client Key Pair   |
+-------------+                             +-------------------+
       |                                              |
       | 3. Deploy Trusted CA Public Key              | 2. Connect with Cert
       v                                              v
+---------------------------------------------------------------+
|                      OpenSSH Daemon (sshd)                    |
| Evaluates TrustedUserCAKeys -> Principal Match -> Access Grant|
+---------------------------------------------------------------+
```

#### Ejecución Paso a Paso

1. **Establecer la Autoridad de Certificación de Usuarios (CA):**
   Generar un par de claves Ed25519 aislado para la CA y firmar un certificado de clave de usuario con capacidades restringidas.

   ```bash
   sudo mkdir -p /etc/ssh/ca
   sudo chmod 700 /etc/ssh/ca
   sudo ssh-keygen -t ed25519 -f /etc/ssh/ca/users_ca -C "Production SRE User CA" -N ""

   # Generate a client key pair for user 'sre-admin'
   ssh-keygen -t ed25519 -f ~/.ssh/id_sre -N ""

   # CA signs client public key: Valid for 52 weeks, principal 'sre-admin'
   sudo ssh-keygen -s /etc/ssh/ca/users_ca -I "sre-admin-cert-01" -n sre-admin -V +52w ~/.ssh/id_sre.pub
   ```

   *Expected Output:*
   ```text
   Signed user key /home/user/.ssh/id_sre-cert.pub: id "sre-admin-cert-01" serial 0 valid from 2026-08-06T10:45:00 to 2027-08-05T10:45:00
   ```

2. **Inspeccionar el Contenido del Certificado y las Restricciones de Clave:**
   Verificar principals, período de validez, firmas criptográficas y flags de clave utilizando `ssh-keygen`.

   ```bash
   ssh-keygen -Lf ~/.ssh/id_sre-cert.pub
   ```

   *Expected Output:*
   ```text
   /home/user/.ssh/id_sre-cert.pub:
           Type: ssh-ed25519-cert-v01@openssh.com user certificate
           Public key: ED25519-CERT SHA2556:AbC...
           Signing CA: ED25519 SHA2556:Xyz... (comment "Production SRE User CA")
           Key ID: "sre-admin-cert-01"
           Serial: 0
           Valid: from 2026-08-06T10:45:00 to 2027-08-05T10:45:00
           Principals: 
                   sre-admin
           Critical Options: (none)
           Extensions: 
                   permit-X11-forwarding
                   permit-agent-forwarding
                   permit-port-forwarding
                   permit-pty
                   permit-user-rc
   ```

3. **Desplegar el Manifiesto de Configuración Endurecido `/etc/ssh/sshd_config`:**
   Configurar suites criptográficas explícitas, deshabilitar ciphers/macs legados inseguros, habilitar autenticación por CA, restringir el reenvío de puertos y definir una zona restringida de SFTP en chroot.

   ```bash
   sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
   sudo cat << 'EOF' | sudo tee /etc/ssh/sshd_config
   # OpenSSH Daemon Production Hardening - LPIC-2 209.3 compliant

   Port 22
   Protocol 2
   HostKey /etc/ssh/ssh_host_ed25519_key
   HostKey /etc/ssh/ssh_host_rsa_key

   # Cryptographic Binding
   KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
   Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
   MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

   # Authentication Settings
   PermitRootLogin no
   MaxAuthTries 3
   MaxSessions 5
   PubkeyAuthentication yes
   PasswordAuthentication no
   PermitEmptyPasswords no
   AuthenticationMethods publickey

   # User Certificate Authority Integration
   TrustedUserCAKeys /etc/ssh/ca/users_ca.pub

   # Session Hardening
   X11Forwarding no
   AllowTcpForwarding remote
   AllowAgentForwarding no
   ClientAliveInterval 300
   ClientAliveCountMax 2
   UsePAM yes

   # Subsystem SFTP Configuration
   Subsystem sftp internal-sftp

   # Conditional Match Block for Secure Restricted SFTP Users
   Match Group sftpusers
       ChrootDirectory /var/sftp/%u
       ForceCommand internal-sftp
       AllowTcpForwarding no
       X11Forwarding no
       PasswordAuthentication no
   EOF
   ```

4. **Validar la Sintaxis de la Configuración y Recargar `sshd`:**
   Ejecutar el flag de prueba del daemon (`-t`) para garantizar cero errores sintácticos antes de reejecutar el servicio.

   ```bash
   sudo sshd -t
   echo $?
   sudo systemctl restart sshd
   ```

   *Expected Output:*
   ```text
   0
   ```

5. **Configurar los Permisos del Directorio Chroot:**
   La directiva `ChrootDirectory` requiere que el usuario `root` sea propietario de todos los componentes de la ruta padre hasta el jail, con permisos máximos de `755` (no se permiten permisos de escritura para grupo ni otros por exigencia de seguridad de OpenSSH).

   ```bash
   sudo groupadd sftpusers
   sudo useradd -g sftpusers -s /bin/false -d /upload sre-transfer
   sudo mkdir -p /var/sftp/sre-transfer/upload
   sudo chown root:root /var/sftp/sre-transfer
   sudo chmod 755 /var/sftp/sre-transfer
   sudo chown sre-transfer:sftpusers /var/sftp/sre-transfer/upload
   sudo chmod 750 /var/sftp/sre-transfer/upload
   ```

6. **Probar la Autenticación por Certificado y el Output de Log de Depuración:**
   Ejecutar la conexión del cliente en modo verbose de depuración (`-vvv`).

   ```bash
   ssh -i ~/.ssh/id_sre -vvv sre-admin@localhost "id"
   ```

   *Expected Output (Truncated Debug Trace):*
   ```text
   debug1: Server host key type: ssh-ed25519
   debug3: send packet: type 50 [SSH2_MSG_USERAUTH_REQUEST]
   debug1: Offering public key: /home/user/.ssh/id_sre-cert.pub ED25519-CERT SHA256:...
   debug3: receive packet: type 60 [SSH2_MSG_USERAUTH_PK_OK]
   debug1: Server accepts key: /home/user/.ssh/id_sre-cert.pub ED25519-CERT SHA256:...
   debug1: Authentication succeeded (publickey).
   uid=1001(sre-admin) gid=1001(sre-admin) groups=1001(sre-admin)
   ```

---

#### Preguntas de Verificación — Ejercicio 2
1. **¿Qué permisos de archivo y jerarquía de propiedad específicos exige `sshd` en las rutas de `ChrootDirectory`, y qué falla si `/var/sftp/sre-transfer` pertenece a `sre-transfer:sftpusers` con modo `775`?**
2. **¿En qué se diferencia operativamente `AllowTcpForwarding remote` de `AllowTcpForwarding yes` o `AllowTcpForwarding local` en `sshd_config`?**

---

### Ejercicio 3: Aseguramiento de Daemons FTP (`vsftpd`) con TLS Explícito e Aislamiento Chroot

#### Contexto y Mecánica de la Arquitectura
FTP (File Transfer Protocol) transmite credenciales de autenticación y datos de carga útil en texto plano sobre el puerto TCP 21 (Control) y puertos negociados dinámicamente (Datos). En el **Modo Pasivo (PASV)**, el cliente FTP inicia tanto la conexión de control como la de datos hacia el servidor, resolviendo problemas de traversal de NAT/firewall en el lado del cliente.

```
Plaintext Control (Port 21) -----> RFC 4217 Explicit TLS (AUTH TLS)
                                          |
                                          v
                              Upgrade Session to TLS
                                          |
                                          v
                              Encrypted Data (PASV Ports: 40000-40100)
```

Asegurar `vsftpd` requiere:
- **TLS Explícito (FTPS):** El canal de control establece primero TCP plano y luego se actualiza a través del comando `AUTH TLS` (RFC 4217).
- **Jails Chroot:** Prevenir ataques de directory traversal (exposición de `/etc/passwd`) mediante `chroot_local_user=YES`.
- **Mitigación de `allow_writeable_chroot`:** Las versiones modernas de `vsftpd` se niegan a ejecutarse si el directorio raíz del chroot es escribible por el usuario encarcelado.

#### Ejecución Paso a Paso

1. **Generar un Certificado Autofirmado TLS para `vsftpd`:**
   Crear un certificado X.509 RSA de 4096 bits y un par de claves dedicado al cifrado de FTP.

   ```bash
   sudo mkdir -p /etc/ssl/private
   sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
     -keyout /etc/ssl/private/vsftpd.pem \
     -out /etc/ssl/certs/vsftpd.pem \
     -subj "/C=US/ST=State/L=City/O=SRE Lab/OU=Infrastructure/CN=ftp.srelab.internal"
   
   sudo chmod 600 /etc/ssl/private/vsftpd.pem
   ```

2. **Desplegar el Manifiesto Completo de Producción `/etc/vsftpd/vsftpd.conf`:**
   Configurar los requerimientos explícitos de SSL/TLS, bloquear usuarios en jails chroot, restringir el acceso anónimo y ajustar los límites de puertos pasivos para el cumplimiento con el firewall.

   ```bash
   sudo cat << 'EOF' | sudo tee /etc/vsftpd/vsftpd.conf
   # vsftpd Production Security Configuration - LPIC-2 209.2 compliant

   # General Daemon Behavior
   listen=YES
   listen_ipv6=NO
   anonymous_enable=NO
   local_enable=YES
   write_enable=YES
   local_umask=022
   dirmessage_enable=YES
   use_localtime=YES
   xferlog_enable=YES
   connect_from_port_20=YES
   xferlog_std_format=YES

   # Filesystem Isolation (Chroot Jail Security)
   chroot_local_user=YES
   chroot_list_enable=NO
   allow_writeable_chroot=NO

   # Passive Mode Firewall Port Ranges
   pasv_enable=YES
   pasv_min_port=40000
   pasv_max_port=40100
   pasv_promiscuous=NO

   # Explicit SSL/TLS Configuration
   ssl_enable=YES
   allow_anon_ssl=NO
   force_local_data_ssl=YES
   force_local_logins_ssl=YES
   ssl_tlsv1_2=YES
   ssl_tlsv1_3=YES
   ssl_sslv2=NO
   ssl_sslv3=NO
   rsa_cert_file=/etc/ssl/certs/vsftpd.pem
   rsa_private_key_file=/etc/ssl/private/vsftpd.pem
   ssl_ciphers=HIGH:!aNULL:!MD5

   # Security Controls & User Validation
   pam_service_name=vsftpd
   userlist_enable=YES
   userlist_file=/etc/vsftpd/user_list
   userlist_deny=NO
   
   # Logging & Security Fine-Tuning
   dual_log_enable=YES
   vsftpd_log_file=/var/log/vsftpd.log
   EOF
   ```

3. **Configurar la Whitelist de Usuarios y Cuentas del Sistema:**
   Poblar `/etc/vsftpd/user_list` (dado que `userlist_deny=NO`, solo a los usuarios declarados explícitamente dentro de este archivo se les permite el acceso).

   ```bash
   sudo mkdir -p /etc/vsftpd
   echo "ftpuser" | sudo tee /etc/vsftpd/user_list
   
   # Create isolated FTP user account with no system shell access
   sudo useradd -m -s /sbin/nologin ftpuser
   echo "ftpuser:ComplexPassword123!" | sudo chpasswd
   
   # Secure the root of user directory for vsftpd chroot enforcement
   sudo chown root:root /home/ftpuser
   sudo chmod 755 /home/ftpuser
   sudo mkdir -p /home/ftpuser/files
   sudo chown ftpuser:ftpuser /home/ftpuser/files
   ```

4. **Reiniciar el Servicio `vsftpd` y Verificar Bindings de Puertos:**

   ```bash
   sudo systemctl restart vsftpd
   sudo ss -tulpn | grep vsftpd
   ```

   *Expected Output:*
   ```text
   tcp   LISTEN 0      32           0.0.0.0:21        0.0.0.0:*    users:(("vsftpd",pid=14205,fd=3))
   ```

5. **Probar la Conexión TLS Explícita de FTPS a través del CLI de `lftp`:**
   Verificar que los inicios de sesión FTP planos sin cifrar sean rechazados, mientras que los inicios de sesión FTPS se completen con éxito.

   ```bash
   # Test raw unencrypted session rejection
   curl ftp://localhost --user "ftpuser:ComplexPassword123!"
   ```

   *Expected Output:*
   ```text
   curl: (67) Access denied: 530 Fast SSL/TLS required on control channel.
   ```

   ```bash
   # Connect using Explicit FTPS via lftp
   lftp -e "set ftp:ssl-force true; set ssl:verify-certificate false; login ftpuser ComplexPassword123!; ls; quit" ftp://localhost
   ```

   *Expected Output:*
   ```text
   drwxr-xr-x    2 1002     1002         4096 Aug 06 10:45 files
   ```

---

#### Preguntas de Verificación — Ejercicio 3
1. **¿Por qué establecer `allow_writeable_chroot=YES` presenta una vulnerabilidad de seguridad en entornos FTP de producción y cómo lo resuelve la partición estándar de permisos del sistema de archivos sin habilitar esta directiva?**
2. **Si un firewall empresarial se ubica delante del servidor `vsftpd`, ¿qué dos requerimientos deben cumplirse en `vsftpd.conf` y en el firewall para que las transferencias de FTP Pasivo (PASV) tengan éxito sobre FTPS?**

---

### Ejercicio 4: Controles Basados en Host, Hardening de PAM y Prevención de Intrusiones (`fail2ban`)

#### Contexto y Mecánica de la Arquitectura
La defensa en profundidad combina Pluggable Authentication Modules (PAM), listas de acceso a hosts (`/etc/hosts.allow` y `/etc/hosts.deny` compilados con `libwrap`) y filtros de paquetes basados en parsing dinámico de logs (`fail2ban`).

Cuando ocurre un intento de conexión SSH:
1. `libwrap` (si está compilado en el servicio o es gestionado por sockets de systemd) verifica las reglas de TCP wrappers.
2. `pam_exec` / `pam_faillock` incrementa el conteo de intentos fallidos dentro de `/var/run/faillock/`.
3. `fail2ban-server` monitorea `/var/log/auth.log` o el journal de systemd a través de la API `inotify` o `sd-journal`, haciendo coincidir filtros de expresiones regulares (`filter.d/sshd.conf`). Al alcanzar el umbral (`maxretry`), `fail2ban` inyecta dinámicamente reglas de drop en `nftables` o `iptables` durante `bantime` segundos.

```
Incoming Request -> TCP Wrappers (/etc/hosts.allow)
                         |
                         v
                    PAM Stack (/etc/pam.d/sshd) -> pam_faillock
                         |
                         v
                    Auth Log Output (/var/log/auth.log)
                         |
                         v (Inotify / Journal API)
                    Fail2ban Daemon -> Inject Rule into nftables ruleset
```

#### Ejecución Paso a Paso

1. **Configurar el Control de Acceso a Hosts (TCP Wrappers / Equivalente Moderno):**
   Restringir el acceso a daemons a nivel de host a través de `/etc/hosts.allow` y `/etc/hosts.deny`.

   ```bash
   sudo cat << 'EOF' | sudo tee /etc/hosts.deny
   ALL: ALL
   EOF

   sudo cat << 'EOF' | sudo tee /etc/hosts.allow
   sshd: 192.168.1.0/24, 10.0.0.0/8, 127.0.0.1
   vsftpd: 10.0.0.0/8
   EOF
   ```

2. **Configurar el Bloqueo de Cuentas en PAM con `pam_faillock`:**
   Forzar el bloqueo de cuentas tras 3 intentos fallidos consecutivos de autenticación dentro de 600 segundos. Editar `/etc/pam.d/system-auth` o `/etc/pam.d/sshd`.

   ```bash
   sudo cat << 'EOF' | sudo tee /etc/pam.d/sshd
   #%PAM-1.0
   auth        required      pam_sepermit.so
   auth        required      pam_faillock.so preauth silent audit deny=3 unlock_time=600 even_deny_root fail_interval=600
   auth        sufficient    pam_unix.so nullok try_first_pass
   auth        requisite     pam_deny.so
   auth        required      pam_faillock.so authfail audit deny=3 unlock_time=600 even_deny_root fail_interval=600

   account     required      pam_nologin.so
   account     required      pam_faillock.so
   account     required      pam_unix.so

   password    include       system-auth

   session     required      pam_loginuid.so
   session     include       system-auth
   EOF
   ```

3. **Desplegar la Configuración de Producción para `fail2ban` (`/etc/fail2ban/jail.local`):**
   Integrar `fail2ban` directamente con `nftables` para desestimar automáticamente direcciones IP maliciosas que intenten ataques de fuerza bruta contra SSH y FTP.

   ```bash
   sudo cat << 'EOF' | sudo tee /etc/fail2ban/jail.local
   [DEFAULT]
   bantime  = 1h
   findtime = 10m
   maxretry = 3
   banaction = nftables-multiport
   banaction_allports = nftables-allports
   backend = systemd

   [sshd]
   enabled = true
   port    = ssh
   logpath = %(sshd_log)s
   maxretry = 3
   bantime = 24h

   [vsftpd]
   enabled = true
   port    = ftp,ftp-data,ftps,ftps-data
   logpath = %(vsftpd_log)s
   maxretry = 3
   EOF
   ```

4. **Iniciar `fail2ban`, Desencadenar un Bloqueo de Prueba e Inspeccionar Banchs Activos:**
   Iniciar el servicio, verificar su estado e inspeccionar el estado en tiempo de ejecución de `fail2ban` a través de `fail2ban-client`.

   ```bash
   sudo systemctl restart fail2ban
   sudo fail2ban-client status sshd
   ```

   *Expected Output:*
   ```text
   Status for the jail: sshd
   |- Filter
   |  |- Currently failed: 0
   |  |- Total failed:     0
   |  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
   `- Actions
      |- Currently banned: 0
      |- Total banned:     0
      `- Banned IP list:   
   ```

5. **Simular un Ban y Verificar la Aplicación en `nftables`:**
   Desencadenar manualmente un ban mediante `fail2ban-client` para verificar la inyección dinámica de reglas en el firewall.

   ```bash
   sudo fail2ban-client set sshd banip 198.51.100.44
   sudo fail2ban-client status sshd
   sudo nft list set inet fail2ban f2b-sshd
   ```

   *Expected Output:*
   ```text
   Status for the jail: sshd
   |- Filter
   |  |- Currently failed: 0
   |  |- Total failed:     0
   |  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
   `- Actions
      |- Currently banned: 1
      |- Total banned:     1
      `- Banned IP list:   198.51.100.44

   table inet fail2ban {
   	set f2b-sshd {
   		type ipv4_addr
   		elements = { 198.51.100.44 }
   	}
   }
   ```

6. **Inspeccionar el Estado del Bloqueo con la Utilidad `faillock`:**
   Verificar las cuentas de usuario del sistema bloqueadas y desbloquearlas cuando se verifique que están limpias.

   ```bash
   # Inspect current locks across accounts
   sudo faillock --user sre-admin
   
   # Reset failed authentication counters for account
   sudo faillock --user sre-admin --reset
   ```

---

#### Preguntas de Verificación — Ejercicio 4
1. **Si un sistema utiliza activación por socket de systemd para SSH o OpenSSH estándar enlazado sin `libwrap.so`, ¿cómo se evalúan `/etc/hosts.allow` y `/etc/hosts.deny` y qué cambio en la arquitectura de seguridad se requiere?**
2. **¿Qué problema operativo distinto ocurre cuando `pam_faillock` se configura con `even_deny_root` sin un rescue shell configurado o un mecanismo explícito de exclusión administrativa?**

---

## Respuestas y Explicaciones Detalladas

<details>
<summary>Hacé clic para desplegar las respuestas y explicaciones detalladas</summary>

### Respuestas del Ejercicio 1

1. **Ejecución en Hooks Prerouting vs. Postrouting:**
   - **DNAT en `prerouting`:** Destination NAT modifica la dirección IP de destino de los paquetes entrantes. Esta operación **debe** ejecutarse antes de que el kernel evalúe la tabla de enrutamiento IP (`Routing Decision`). Si la modificación del destino ocurriera después del enrutamiento, el kernel tomaría una decisión de enrutamiento basada en la IP de destino original (la IP WAN del router) en lugar de la verdadera IP de destino (el servidor DMZ interno), lo que provocaría un enrutamiento erróneo del paquete o su descarte local.
   - **SNAT/Masquerade en `postrouting`:** Source NAT modifica la dirección IP de origen de los paquetes salientes. El kernel debe completar primero la decisión de enrutamiento para seleccionar la interfaz de red de salida adecuada (por ejemplo, `eth0` WAN frente a `eth1` LAN). Una vez determinada la interfaz de salida, `postrouting` reescribe la dirección de origen para que coincida con la IP de esa interfaz (o la IP SNAT especificada), asegurando que los paquetes de respuesta regresen a la interfaz correcta del router.

2. **Ventaja de Rendimiento del Motor `nftables`:**
   `iptables` procesa las reglas secuencialmente utilizando comprobaciones lineales en tablas del kernel por protocolo (`ip_tables`, `ip6_tables`, `eb_tables`). Cada operación de coincidencia evalúa cada regla de forma lineal (complejidad $O(N)$). En contraste, `nftables` utiliza un modelo de ejecución basado en una máquina virtual interna que combina tablas de búsqueda nativas (diccionarios, sets y maps). Al realizar coincidencias contra grandes arreglos de IPs o puertos, `nftables` utiliza estructuras de datos de hashing y árboles rojo-negro (complejidad de búsqueda $O(1)$ u $O(\log N)$), lo que resulta en un rendimiento de paquetes muy superior y un consumo de CPU drásticamente reducido bajo altas cargas de red.

---

### Respuestas del Ejercicio 2

1. **Aplicación de Permisos de `ChrootDirectory` en OpenSSH:**
   - OpenSSH impone verificaciones estrictas de propiedad para prevenir la elevación de privilegios locales. Cada componente de la ruta especificada en `ChrootDirectory` debe pertenecer estrictamente a `root` y **no debe** ser escribible por ningún grupo u otro usuario (máscara de permisos máxima `755`).
   - Si `/var/sftp/sre-transfer` pertenece a `sre-transfer:sftpusers` con modo `775`, `sshd` rechazará el intento de conexión, generando el siguiente error en `/var/log/auth.log`:
     ```text
     fatal: bad ownership or permissions for chroot directory "/var/sftp/sre-transfer"
     ```
   - **Razonamiento:** Si el usuario encarcelado pudiera escribir en la raíz del chroot jail, podría manipular archivos o enlaces del sistema dentro de la ruta encarcelada (como configuraciones en `.etc` o archivos socket), lo que llevaría a un exploit de fuga de jail (jailbreak).

2. **Semántica Operativa de `AllowTcpForwarding remote`:**
   - `AllowTcpForwarding yes`: Habilita los túneles de reenvío de puertos TCP tanto locales (`ssh -L`, mapeo de puertos saliente) como remotos (`ssh -R`, mapeo de puertos inverso).
   - `AllowTcpForwarding remote`: Restringe las capacidades de tunelización de la conexión SSH exclusivamente al reenvío de puertos inverso remoto (`ssh -R`). El usuario tiene estrictamente bloqueada la creación de túneles salientes locales (`ssh -L`), impidiendo que utilice el servidor SSH como un proxy pivote arbitrario hacia la red interna detrás del servidor.

---

### Respuestas del Ejercicio 3

1. **Vulnerabilidad de `allow_writeable_chroot=YES` y Solución Adecuada:**
   - Habilitar `allow_writeable_chroot=YES` permite que el directorio raíz del `chroot` jail de FTP sea propiedad y tenga permisos de escritura del usuario de FTP. Esto introduce un vector de ataque de directory traversal donde un usuario puede modificar permisos de carpetas o abusar de condiciones de carrera para escapar del contexto del chroot.
   - **Solución de Partición Adecuada:** Mantener `allow_writeable_chroot=NO`. Configurar el directorio raíz de la ruta home del usuario (por ejemplo, `/home/ftpuser`) para que sea propiedad de `root:root` con permisos `755`. Dentro de esa carpeta, crear un subdirectorio escribible (por ejemplo, `/home/ftpuser/files`) propiedad de `ftpuser:ftpuser` con permisos `750` u `770`. El cliente FTP aterriza en un contexto raíz seguro y no escribible mientras conserva capacidades completas de escritura dentro de los subdirectorios designados.

2. **Requerimientos de Firewall para FTP Pasivo (PASV):**
   - **Parámetros de `vsftpd.conf`:** Definir explícitamente el rango de puertos pasivos (`pasv_min_port=40000`, `pasv_max_port=40100`) y declarar la IP pública del router si se ejecuta detrás de un NAT 1:1 (`pasv_address=X.X.X.X`).
   - **Requerimientos del Firewall:** El firewall empresarial debe abrir y reenviar el puerto TCP 21 (Control) **Y** todo el rango de puertos pasivos TCP definido (40000-40100). Los helpers de connection tracking dinámico del kernel estándar (`nf_conntrack_ftp`) no pueden inspeccionar ni abrir automáticamente puertos dinámicos cuando se utiliza FTPS porque los contenidos de la conexión de control están completamente cifrados a través de TLS.

---

### Respuestas del Ejercicio 4

1. **Depreciación de TCP Wrappers (`libwrap`) y Cambio Arquitectónico:**
   - Las distribuciones modernas de Linux han marcado como obsoleto o eliminado el soporte de `libwrap` en OpenSSH y otros daemons de red centrales. Si OpenSSH no está enlazado contra `libwrap.so`, `/etc/hosts.allow` y `/etc/hosts.deny` son completamente ignorados por `sshd`.
   - **Cambio Arquitectónico:** El control de acceso a la red debe migrar de las listas de hosts en espacio de usuario a nivel de aplicación hacia los filtros de paquetes a nivel de kernel (`nftables` / `iptables`) o al filtrado a nivel de socket de systemd (directivas `IPAddressAllow` / `IPAddressDeny` dentro de los archivos de unidad de systemd).

2. **Riesgos Operativos de `pam_faillock` con `even_deny_root`:**
   - Configurar `even_deny_root` fuerza a `pam_faillock` a bloquear la cuenta del sistema `root` tras alcanzar el umbral (`deny=3`). Si un actor malicioso externo ataca la cuenta `root` con intentos intencionados y repetidos de contraseñas incorrectas a través de SSH o inicios de sesión en la consola local, puede provocar una Denegación de Servicio (DoS), dejando a los administradores legítimos completamente fuera del servidor.
   - **Estrategia de Mitigación:** Mantener siempre rutas de administración fuera de banda (out-of-band) (como la autenticación por clave SSH con `PasswordAuthentication no`, la cual omite las comprobaciones de autenticación por contraseña de PAM, o la exclusión de root en consola mediante parámetros `root_unlock_time`).

</details>

---

## Documentación de Referencia Oficial y Especificaciones

- **Linux Professional Institute LPIC-2 Objectives:** [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **netfilter / nftables Project Documentation:** [https://netfilter.org/projects/nftables/documentation.html](https://netfilter.org/projects/nftables/documentation.html)
- **OpenSSH Official Manuals & Security Specs:** [https://www.openssh.com/manual.html](https://www.openssh.com/manual.html)
- **vsftpd Documentation & Security Manuals:** [https://security.appspot.com/vsftpd.html](https://security.appspot.com/vsftpd.html)
- **Linux PAM Documentation & `pam_faillock` Manpages:** [https://github.com/linux-pam/linux-pam](https://github.com/linux-pam/linux-pam)
- **Fail2ban Official Repository & Wiki:** [https://www.fail2ban.org/wiki/index.php/Main_Page](https://www.fail2ban.org/wiki/index.php/Main_Page)