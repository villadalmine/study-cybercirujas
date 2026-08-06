# Examen LPIC-2 202-450: Tema 2.4 / 210 - Network Client Management

**Examen:** LPIC-2 (Examen 201-450 y 202-450, Versión 4.5)  
**Tema 2.4 / 210:** Network Client Management  
**Peso del examen:** 8  
**Nivel objetivo:** Senior SRE / Principal Platform Architect  
**Referencia oficial:** [Linux Professional Institute - LPIC-2 Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)

---

## Visión general técnica y arquitectura

Network Client Management en entornos Linux empresariales establece la base para el bootstrap de red automatizado, la gestión centralizada de identidades y la aplicación de acceso seguro. Una arquitectura SRE en producción integra cuatro capas críticas:

1. **Dynamic Addressing & Network Bootstrap (DHCP/DHCPv6 & Relay):** Automatiza la asignación de direcciones IPv4/IPv6, el enrutamiento y los parámetros de PXE boot utilizando ISC DHCP (`dhcpd`) y agentes DHCP Relay (`dhcrelay`).
2. **Pluggable Authentication Modules (PAM):** Proporciona una capa de abstracción modular (`/etc/pam.d/`) para aplicar pipelines de autenticación empresariales, mitigación de fuerza bruta (`pam_faillock`), restricciones de recursos (`pam_limits`) y políticas de autorización (`pam_wheel`).
3. **Directory Services (OpenLDAP & OLC):** Implementa On-Line Configuration (`cn=config` / OLC) con backends Lightning Memory-Mapped Database (`mdb`), Access Control Lists granulares (`olcAccess`) y cifrado TLS/SSL obligatorio.
4. **Client Identity Orchestration (SSSD & NSSwitch):** Integra clientes Linux en la infraestructura de directorio mediante System Security Services Daemon (`sssd`) y Name Service Switch (`/etc/nsswitch.conf`) con almacenamiento en caché de credenciales offline y resolución de identidades de alto rendimiento.

---

## Bloque de ejercicios 1: ISC DHCP Server, aislamiento de subredes, PXE Boot y DHCP Relay

### Mecánica arquitectónica y análisis profundo

El protocolo DHCP opera sobre un handshake de cuatro vías (**DORA**: **D**iscover, **O**ffer, **R**equest, **A**cknowledge) a través de los puertos UDP `67` (servidor) y `68` (cliente).

```
Client (Port 68)                             DHCP Relay / Server (Port 67)
       |                                                    |
       |--- DHCPDISCOVER (Broadcast 255.255.255.255) ------>|
       |<-- DHCPOFFER (Unicast/Broadcast + Offered IP) -----|
       |--- DHCPREQUEST (Broadcast + Selected IP) -------->|
       |<-- DHCPACK (Unicast/Broadcast + Lease Terms) ------|
```

Cuando los clientes residen en subredes remotas donde los broadcasts UDP no pueden atravesar los límites de los routers, un **DHCP Relay Agent** (`dhcrelay`) inspecciona los paquetes `DHCPDISCOVER` entrantes, los intercepta en la Capa 2/3, inyecta la dirección de su propia interfaz en el campo `giaddr` (**G**ateway **I**P **A**ddress) y reenvía el paquete como un payload unicast al servidor DHCP central.

En entornos IPv6, la configuración de direcciones se divide en:
* **Stateless Address Autoconfiguration (SLAAC):** Impulsado por ICMPv6 Router Advertisements (RA).
* **Stateless DHCPv6:** Los Router Advertisements establecen el flag **O** (Other configuration) en `1`, solicitando a los clientes que obtengan la configuración de DNS y dominio a través de DHCPv6.
* **Stateful DHCPv6:** Los Router Advertisements establecen el flag **M** (Managed address configuration) en `1`, indicando a los clientes que obtengan su dirección IPv6 directamente del demonio DHCPv6 (`dhcpd -6`).

---

### Implementación guiada paso a paso

#### Paso 1.1: Desplegar una configuración ISC DHCP empresarial con subredes y opciones de PXE Boot

Edite `/etc/dhcp/dhcpd.conf` para configurar un servidor DHCP autoritativo que gestione el aislamiento de subredes, reservas fijas de MAC y parámetros de PXE boot.

```dhcpd
# /etc/dhcp/dhcpd.conf
default-lease-time 86400;
max-lease-time 604800;
authoritative;

log-facility local7;

# Global Option Definitions
option domain-name "infra.production.local";
option domain-name-servers 10.100.0.10, 10.100.0.11;
option ntp-servers 10.100.0.1;

# Production Application Subnet
subnet 10.100.10.0 netmask 255.255.255.0 {
  range 10.100.10.100 10.100.10.200;
  option routers 10.100.10.1;
  option broadcast-address 10.100.10.255;

  # PXE Boot Options for Automated Deployment
  filename "pxelinux.0";
  next-server 10.100.0.50;

  # Static Host Reservation based on Hardware MAC
  host baremetal-node-01 {
    hardware ethernet 52:54:00:ab:cd:ef;
    fixed-address 10.100.10.50;
    option host-name "node01.infra.production.local";
  }
}
```

Verifique la sintaxis e inicie el demonio:

```bash
dhcpd -t -cf /etc/dhcp/dhcpd.conf
systemctl restart isc-dhcp-server
```

**Salida esperada:**
```text
Internet Systems Consortium DHCP Server 4.4.1
Config file: /etc/dhcp/dhcpd.conf
Source file: /etc/dhcp/dhcpd.conf
Line 1: semicolon expected. (Only if syntax error exists; clean output exits with status 0)
Server starts without syntax errors.
```

#### Paso 1.2: Inspeccionar el estado en la base de datos de leases de DHCP

Inspeccione los leases activos registrados dinámicamente en `/var/lib/dhcp/dhcpd.leases`:

```bash
cat /var/lib/dhcp/dhcpd.leases
```

**Salida esperada:**
```text
lease 10.100.10.105 {
  starts 4 2026/08/06 10:00:00;
  ends 5 2026/08/07 10:00:00;
  cltt 4 2026/08/06 10:00:00;
  binding state active;
  next binding state free;
  rewind binding state free;
  hardware ethernet 52:54:00:12:34:56;
  client-hostname "worker-node-12";
}
```

#### Paso 1.3: Configurar un DHCP Relay Agent de múltiples interfaces (`dhcrelay`)

En un nodo gateway que enruta el tráfico entre `10.100.20.0/24` (`eth1`) y el servidor DHCP central en `10.100.0.5` (`eth0`), ejecute `dhcrelay`:

```bash
dhcrelay -i eth1 -i eth0 10.100.0.5
```

Verifique el estado de ejecución del proceso:

```bash
ps aux | grep dhcrelay
```

**Salida esperada:**
```text
dhcpd     14201  0.0  0.1  12456  3120 ?        Ss   10:05   0:00 dhcrelay -i eth1 -i eth0 10.100.0.5
```

#### Paso 1.4: Capturar y analizar el tráfico del protocolo DHCP

Capture tramas del handshake de DHCP usando `tcpdump` para verificar la inyección de opciones del Relay Agent (`giaddr`):

```bash
tcpdump -i eth0 -nn -vvv port 67 or port 68
```

**Salida esperada:**
```text
10:10:01.102938 IP (tos 0x0, ttl 64, id 1202, offset 0, flags [none], proto UDP (17), length 328)
    10.100.20.1.67 > 10.100.0.5.67: [udp sum ok] BOOTP/DHCP, Request from 52:54:00:fe:dc:ba, length 300, xid 0x9a3c1f, Flags [none]
	  Gateway-IP 10.100.20.1
	  Client-Ethernet-Address 52:54:00:fe:dc:ba
	  Vendor-rfc1048 Extensions
	    Magic Cookie 0x63825363
	    DHCP-Message Option 53, length 1: Discover
	    Parameter-Request Option 55, length 4: Subnet-Mask, BR, Time-Zone, Router
```

---

### Preguntas de verificación - Bloque 1

#### Pregunta 1.1
Un SRE despliega un DHCP relay agent en un router que conecta la Subnet A (`10.200.1.0/24`) con un servidor DHCP centralizado en la Subnet B (`10.200.2.10`). Los clientes de la Subnet A no logran obtener direcciones IP. La inspección de los logs del servidor muestra `DHCPDISCOVER from 52:54:00:11:22:33 via eth0: network 10.200.2.0/24: no free leases`. ¿Cuál es la causa principal de este fallo?

- A) El servidor DHCP requiere una entrada en `/etc/hosts` que coincida con la dirección MAC del DHCP relay agent.
- B) El servidor DHCP carece de una declaración `subnet 10.200.1.0 netmask 255.255.255.0` que coincida con el campo `giaddr` del relay agent.
- C) El DHCP relay agent no inyectó la metadata de Option 82 en el encabezado de la trama Ethernet.
- D) El cliente solicitó un lease estático mediante BOOTP, lo que anula el procesamiento de rango dinámico.

#### Pregunta 1.2
En un diseño de autoconfiguración de IPv6, un SRE necesita que los clientes generen sus propios identificadores de interfaz mediante SLAAC, pero exige que consulten a un servidor DHCPv6 local para obtener los servidores de nombres DNS y las listas de búsqueda de dominios. ¿Qué combinación de configuración se debe establecer en los flags de Router Advertisement (RA) ICMPv6 del router?

- A) Flag Managed Address Configuration ($M$) = 1, Flag Other Configuration ($O$) = 0
- B) Flag Managed Address Configuration ($M$) = 0, Flag Other Configuration ($O$) = 1
- C) Flag Managed Address Configuration ($M$) = 1, Flag Other Configuration ($O$) = 1
- D) Flag Managed Address Configuration ($M$) = 0, Flag Other Configuration ($O$) = 0

---

## Bloque de ejercicios 2: Arquitectura y aplicación de seguridad de Pluggable Authentication Modules (PAM)

### Mecánica arquitectónica y análisis profundo

PAM proporciona autenticación de sistema modular al desacoplar las aplicaciones (por ejemplo, `sshd`, `sudo`, `login`) de las tecnologías de autenticación del back-end (por ejemplo, contraseñas shadow locales, LDAP, Kerberos). La configuración de PAM reside en `/etc/pam.d/<service>` o `/etc/pam.conf`.

Cada línea de PAM sigue la sintaxis:
```text
type    control_flag    module_path    module_arguments
```

```
               +----------------------------------+
               |      Application (e.g., SSHD)    |
               +----------------------------------+
                                |
                                v
               +----------------------------------+
               |        PAM Stack Engine          |
               +----------------------------------+
                                |
        +-----------------------+-----------------------+
        |                       |                       |
        v                       v                       v
  [auth module]          [account module]       [session module]
  Verify identity        Verify permissions,    Setup environment,
  (Password, Token)      expiration, hours      mounts, logging
```

#### Grupos de gestión (`type`)
1. `auth`: Valida la autenticidad del usuario (por ejemplo, solicitud de contraseña) y establece credenciales.
2. `account`: Verifica la disponibilidad de la cuenta no relacionada con la autenticación (por ejemplo, expiración de contraseña, horas de acceso, restricciones de root).
3. `session`: Configura tareas del entorno antes de la ejecución de la shell y la limpieza al finalizar (por ejemplo, montaje de homes, registros, límites de recursos).
4. `password`: Gestiona actualizaciones de contraseñas y actualiza los almacenes de credenciales vinculados.

#### Flags de control y matriz de evaluación
* `required`: El fallo del módulo garantiza el fallo final del stack. Sin embargo, la ejecución **continúa** hacia abajo en el stack para ocultar las razones del fallo del módulo a posibles atacantes.
* `requisite`: El fallo del módulo causa un **fallo inmediato** de todo el stack; los módulos subsecuentes en el grupo son omitidos.
* `sufficient`: El éxito del módulo retorna inmediatamente **éxito** a la aplicación, omitiendo los módulos restantes *si ningún módulo `required` previo ha fallado*.
* `optional`: El fallo o éxito del módulo es ignorado a menos que sea el único módulo en el stack.
* `include` / `substack`: Incrusta stacks de configuración externos.

---

### Implementación guiada paso a paso

#### Paso 2.1: Construir un stack de seguridad de producción con `pam_faillock`, `pam_limits` y `pam_wheel`

Modifique `/etc/pam.d/system-auth` para bloquear cuentas después de 3 intentos fallidos de contraseña dentro de los 15 minutos (900s), aplicar el aislamiento del grupo `wheel` para escalaciones administrativas y establecer límites de recursos estrictos.

```pam
# /etc/pam.d/system-auth
# Priority Auth Stack with Brute-Force Lockout
auth        required      pam_env.so
auth        required      pam_faillock.so preauth silent audit deny=3 unlock_time=900 even_deny_root
auth        sufficient    pam_unix.so nullok try_first_pass
auth        required      pam_faillock.so authfail audit deny=3 unlock_time=900 even_deny_root
auth        required      pam_deny.so

# Account Expiration and Access Control
account     required      pam_faillock.so
account     required      pam_unix.so

# Password Hardening Policy
password    requisite     pam_pwquality.so retry=3 minlen=14 retry=3 enforce_for_root
password    sufficient    pam_unix.so sha512 shadow try_first_pass use_authtok
password    required      pam_deny.so

# Session Setup and Resource Isolation
session     optional      pam_keyinit.so revoke
session     required      pam_limits.so
session     required      pam_unix.so
```

Modifique `/etc/pam.d/su` para restringir el acceso a `su` exclusivamente a miembros del grupo del sistema `wheel`:

```pam
# /etc/pam.d/su
auth        required      pam_env.so
auth        sufficient    pam_rootok.so
auth        required      pam_wheel.so use_uid group=wheel
auth        include       system-auth
account     include       system-auth
session     include       system-auth
```

#### Paso 2.2: Auditar y limpiar bloqueos de cuentas a través de la CLI `faillock`

Simule fallos de autenticación y gestione cuentas bloqueadas usando `faillock`:

Verifique el estado de bloqueo de la cuenta:

```bash
faillock --user secadmin
```

**Salida esperada:**
```text
secadmin:
When                Type  Source                          Valid
2026-08-06 10:15:22 V     192.168.1.50                    V
2026-08-06 10:15:28 V     192.168.1.50                    V
2026-08-06 10:15:34 V     192.168.1.50                    V
```

Limpie el estado de bloqueo de la cuenta inmediatamente:

```bash
faillock --user secadmin --reset
```

**Salida esperada:**
```text
(No output returned; exit status 0 indicates successfully cleared database record).
```

#### Paso 2.3: Configurar aislamiento estricto de recursos del sistema en `/etc/security/limits.conf`

Aplique restricciones de recursos procesadas por `pam_limits.so`:

```text
# /etc/security/limits.conf
# <domain>      <type>  <item>         <value>
*               hard    core           0
*               hard    nproc          2048
*               soft    nofile         65536
*               hard    nofile         524288
@developers     hard    maxlogins      2
```

Valide la ejecución de límites de usuario:

```bash
su - secadmin -c "ulimit -a"
```

**Salida esperada:**
```text
core file size          (blocks, -c) 0
data seg size           (kbytes, -d) unlimited
scheduling priority             (-e) 0
file size               (blocks, -f) unlimited
pending signals                 (-i) 62832
max locked memory       (kbytes, -l) 64
max memory size         (kbytes, -m) unlimited
open files                      (-n) 65536
pipe size            (512 bytes, -p) 8
POSIX message queues     (bytes, -q) 819200
real-time priority              (-r) 0
stack size              (kbytes, -s) 8192
cpu time               (seconds, -t) unlimited
max user processes              (-u) 2048
virtual memory          (kbytes, -v) unlimited
file locks                      (-x) unlimited
```

---

### Preguntas de verificación - Bloque 2

#### Pregunta 2.1
Un arquitecto analiza el siguiente fragmento de configuración personalizado de `/etc/pam.d/sshd`:

```pam
auth    requisite     pam_ipmatch.so ip=10.0.0.0/8
auth    required      pam_faillock.so preauth silent deny=3
auth    sufficient    pam_unix.so
auth    required      pam_deny.so
```

Si un intento de autenticación se origina desde la dirección IP `192.168.1.100`, ¿cómo evalúa el PAM engine el stack?

- A) `pam_ipmatch.so` falla, pero debido a que le sigue `pam_faillock.so` (required), se le solicita una contraseña al usuario.
- B) `pam_ipmatch.so` falla, activando una terminación inmediata del grupo `auth` con un estado de denegación, omitiendo `pam_faillock.so` y `pam_unix.so`.
- C) `pam_ipmatch.so` retorna `PAM_IGNORE`, permitiendo que la ejecución pase directamente a `pam_unix.so`.
- D) `pam_ipmatch.so` falla, pero `pam_unix.so` (sufficient) anula el fallo si el usuario ingresa una contraseña válida.

#### Pregunta 2.2
Un sysadmin necesita forzar que la autenticación de `su` falle inmediatamente si el usuario invocador no es miembro del grupo `sysadmin`, garantizando al mismo tiempo que no se muestren solicitudes de contraseña a los solicitantes no autorizados. ¿Qué línea de configuración de PAM logra esto en `/etc/pam.d/su`?

- A) `auth optional pam_wheel.so group=sysadmin deny`
- B) `auth requisite pam_wheel.so group=sysadmin use_uid`
- C) `auth sufficient pam_wheel.so group=sysadmin trust`
- D) `auth required pam_group.so allow=sysadmin`

---

## Bloque de ejercicios 3: Arquitectura del servidor de directorio OpenLDAP y gestión de OLC (`cn=config`)

### Mecánica arquitectónica y análisis profundo

Los despliegues modernos de OpenLDAP (`slapd`) descartan los archivos planos estáticos `slapd.conf` en favor de **On-Line Configuration** (OLC), representada internamente como una base de datos de directorio LDAP activa bajo `cn=config`. Los cambios se aplican dinámicamente en tiempo de ejecución utilizando `ldapmodify` y archivos LDIF sin reiniciar el demonio `slapd`.

```
                         OpenLDAP Slapd Daemon
                                   |
         +-------------------------+-------------------------+
         |                                                   |
         v                                                   v
   cn=config (OLC)                                 dc=production,dc=local
 (Runtime Settings)                                (Directory User Data)
   |- olcDatabase={0}config                          |- olcDatabase={1}mdb
   |- olcDatabase={1}mdb                             |- User entries (posixAccount)
   |- Access Controls (olcAccess)                   |- Group entries (posixGroup)
   |- TLS Configuration                              |- Indexing (olcDbIndex)
```

Referencia oficial: [OpenLDAP Software 2.4 Administrator's Guide](https://www.openldap.org/doc/admin24/)

#### Utilidades clave de OpenLDAP
* `slapadd`: Herramienta de inserción directa en la base de datos (omite el demonio; debe ejecutarse offline o contra almacenes no montados).
* `slapcat`: Exporta el contenido de la base de datos directamente a una salida LDIF.
* `slapindex`: Reconstruye los índices de búsqueda de la base de datos basados en los atributos `olcDbIndex`.
* `ldapsearch` / `ldapmodify`: Herramientas operativas del cliente que utilizan llamadas de protocolo de red estándar (sobre TLS/LDAPS).

---

### Implementación guiada paso a paso

#### Paso 3.1: Realizar el bootstrap de una base de datos OpenLDAP MDB a través de OLC (`cn=config`)

Cree un esquema de despliegue `bootstrap_domain.ldif` para configurar la estructura base de la organización y las opciones de la base de datos:

```ldif
# bootstrap_domain.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: dc=production,dc=local
-
replace: olcRootDN
olcRootDN: cn=admin,dc=production,dc=local
-
replace: olcRootPW
# Secret generated via: slappasswd -h {SSHA} -s "SuperSecurePassword123!"
olcRootPW: {SSHA}vR3Zk9w8N8XQ5J3e2Y1U4P6O7I8U9Y0T
```

Aplique modificaciones en tiempo de ejecución usando `ldapmodify` contra `cn=config`:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f bootstrap_domain.ldif
```

**Salida esperada:**
```text
SASL/EXTERNAL authentication started
SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
SASL SSF: 0
modifying entry "olcDatabase={1}mdb,cn=config"
```

#### Paso 3.2: Configurar Access Control Lists granulares (`olcAccess`)

Proteger los hashes de contraseñas de usuarios y atributos de directorio requiere un orden estricto en `olcAccess`. ¡La primera coincidencia gana!

Cree `configure_acls.ldif`:

```ldif
# configure_acls.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword
  by self write
  by anonymous auth
  by dn.exact="cn=admin,dc=production,dc=local" write
  by * none
olcAccess: {1}to attrs=shadowLastChange
  by self write
  by dn.exact="cn=admin,dc=production,dc=local" write
  by * none
olcAccess: {2}to *
  by dn.exact="cn=admin,dc=production,dc=local" write
  by users read
  by * read
```

Aplique modificaciones de ACL:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f configure_acls.ldif
```

#### Paso 3.3: Aplicar el cifrado de infraestructura TLS (StartTLS)

Importe certificados TLS en `cn=config` para aplicar la seguridad del canal:

```ldif
# enable_tls.ldif
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ssl/certs/ca-production.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ssl/certs/ldap-server.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ssl/private/ldap-server.key
-
replace: olcSecurity
olcSecurity: tls=1
```

Aplique la configuración de política TLS:

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f enable_tls.ldif
```

Pruebe la conectividad TLS sobre el puerto LDAP estándar (`389`) utilizando StartTLS (`-ZZ`):

```bash
ldapsearch -x -H ldap://ldap.production.local -ZZ -b "dc=production,dc=local" "(objectClass=*)"
```

**Salida esperada:**
```text
# extended LDIF
#
# LDAPv3
# base <dc=production,dc=local> with scope subtree
# filter: (objectClass=*)
# requesting: ALL
#

# production.local
dn: dc=production,dc=local
objectClass: top
objectClass: dcObject
objectClass: organization
o: Production Enterprise
dc: production

# search result
search: 3
result: 0 Success
```

#### Paso 3.4: Reconstruir índices de búsqueda mediante `slapindex`

Defina parámetros de indexación en `cn=config` para optimizar el rendimiento:

```ldif
# indexing.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: uid eq,pres,sub
olcDbIndex: cn,sn eq,sub
olcDbIndex: objectClass eq
```

Aplique la configuración de índices y fuerce el re-indexado de la base de datos fuera de línea (offline):

```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f indexing.ldif
systemctl stop slapd
slapindex -b "dc=production,dc=local"
chown -R openldap:openldap /var/lib/ldap/
systemctl start slapd
```

---

### Preguntas de verificación - Bloque 3

#### Pregunta 3.1
Un servidor OpenLDAP está configurado con las siguientes reglas `olcAccess`:

```text
olcAccess: {0}to * by users read by * none
olcAccess: {1}to attrs=userPassword by self write by anonymous auth by * none
```

Un usuario autenticado no administrativo (`uid=jdoe,ou=users,dc=production,dc=local`) intenta actualizar su atributo de contraseña (`userPassword`). ¿Cuál es el resultado?

- A) El cambio de contraseña tiene éxito porque la Regla `{1}` permite `self write`.
- B) La operación falla con permiso denegado porque la Regla `{0}` coincide primero, la evaluación se detiene y la Regla `{0}` no otorga permiso de escritura a `userPassword`.
- C) La operación tiene éxito porque las modificaciones de contraseña omiten la coincidencia estándar de `olcAccess` cuando se ejecutan sobre StartTLS.
- D) El servidor OpenLDAP se cae (crash) debido a declaraciones de reglas de acceso en conflicto.

#### Pregunta 3.2
Un SRE necesita reconstruir índices corruptos en una base de datos OpenLDAP activa (motor `mdb`). ¿Cuál es el procedimiento obligatorio para prevenir la corrupción de la base de datos durante la ejecución de `slapindex`?

- A) Ejecutar `slapindex -F /etc/openldap/slapd.d` mientras `slapd` está procesando escrituras activamente.
- B) Detener el demonio `slapd`, ejecutar `slapindex` con el alcance y privilegios apropiados de la base de datos, corregir permisos de archivos e iniciar `slapd`.
- C) Emitir `ldapmodify` con `olcDbIndex: rebuild` mientras `slapd` se ejecuta en modo monousuario.
- D) Exportar la base de datos a través de `ldapsearch`, eliminar `/var/lib/ldap/*` y reiniciar `slapd`.

---

## Bloque de ejercicios 4: Integración del directorio de cliente con SSSD, NSSwitch y herramientas de diagnóstico de LDAP

### Mecánica arquitectónica y análisis profundo

Integrar clientes Linux con directorios centralizados involucra dos subsistemas principales:

```
Applications (e.g., ls, id, sshd)
       |
       v
/etc/nsswitch.conf  -------------------------> PAM (/etc/pam.d/)
       | (Identity Lookups)                          | (Authentication)
       v                                             v
  nss_sss.so                                    pam_sss.so
       |                                             |
       +----------------------+----------------------+
                              |
                              v
                  SSSD Daemon (sssd)
                     |- Data Provider (LDAP / AD)
                     |- Fast In-Memory Cache (LDB: /var/lib/sss/db/)
```

1. **Name Service Switch (`/etc/nsswitch.conf`):** Configura búsquedas en bases de datos (por ejemplo, `passwd`, `group`, `hosts`, `shadow`). Librerías como `libnss_files.so` y `libnss_sss.so` resuelven identidades secuencialmente según las reglas definidas en `nsswitch.conf`.
2. **System Security Services Daemon (SSSD):** Gestiona búsquedas de identidad y solicitudes de autenticación. SSSD recupera entradas de servidores de directorio, las almacena en caché localmente en archivos LDB (`/var/lib/sss/db/`) y permite a los usuarios iniciar sesión incluso cuando están offline o desconectados de la red.

---

### Implementación guiada paso a paso

#### Paso 4.1: Configurar `/etc/nsswitch.conf` para la integración de SSSD

Edite `/etc/nsswitch.conf` para dirigir las llamadas de identidad primero a los archivos locales del sistema, recurriendo a SSSD en caso necesario:

```text
# /etc/nsswitch.conf
passwd:         files sss
group:          files sss
shadow:         files sss
gshadow:        files sss

hosts:          files dns
networks:       files

protocols:      db files
services:       db files sss
ethers:         db files
rpc:            db files
```

#### Paso 4.2: Desplegar `/etc/sssd/sssd.conf` de producción con enlace LDAP seguro

Cree `/etc/sssd/sssd.conf` para gestionar la búsqueda de identidades y la autenticación sobre LDAPS:

```ini
# /etc/sssd/sssd.conf
[sssd]
config_file_version = 2
services = nss, pam
domains = PRODUCTION

[domain/PRODUCTION]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

# LDAP Infrastructure Endpoints
ldap_uri = ldaps://ldap01.infra.production.local:636, ldaps://ldap02.infra.production.local:636
ldap_search_base = dc=production,dc=local
ldap_schema = rfc2307bis

# TLS Security Requirements
ldap_tls_cacert = /etc/ssl/certs/ca-production.crt
ldap_tls_reqcert = hard

# Credentials Binding for Client Queries
ldap_default_bind_dn = cn=sssd-bind,ou=services,dc=production,dc=local
ldap_default_authtok = DirectClientBindSecret987!

# Offline Caching Policies
cache_credentials = true
account_cache_expiration = 1
entry_cache_timeout = 5400
```

Establezca los permisos de seguridad requeridos (SSSD se negará a iniciar si los permisos son demasiado permisivos):

```bash
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
systemctl restart sssd
```

#### Paso 4.3: Realizar resolución de identidad y consultas al directorio LDAP

Verifique la resolución de NSS utilizando primitivas del sistema:

```bash
getent passwd sysop_user
```

**Salida esperada:**
```text
sysop_user:*:10052:10001:System Operations User:/home/sysop_user:/bin/bash
```

Consulte directamente los atributos LDAP a través de `ldapsearch` utilizando las credenciales del enlace de servicio del cliente:

```bash
ldapsearch -x -H ldaps://ldap01.infra.production.local \
  -D "cn=sssd-bind,ou=services,dc=production,dc=local" \
  -w "DirectClientBindSecret987!" \
  -b "ou=users,dc=production,dc=local" \
  "(uid=sysop_user)" uidNumber gidNumber homeDirectory loginShell
```

**Salida esperada:**
```text
# extended LDIF
#
# LDAPv3
# base <ou=users,dc=production,dc=local> with scope subtree
# filter: (uid=sysop_user)
# requesting: uidNumber gidNumber homeDirectory loginShell
#

# sysop_user, users, production.local
dn: uid=sysop_user,ou=users,dc=production,dc=local
uidNumber: 10052
gidNumber: 10001
homeDirectory: /home/sysop_user
loginShell: /bin/bash

# search result
search: 2
result: 0 Success
```

Valide el estado actual de la autenticación del enlace mediante `ldapwhoami`:

```bash
ldapwhoami -x -H ldaps://ldap01.infra.production.local \
  -D "cn=sssd-bind,ou=services,dc=production,dc=local" \
  -w "DirectClientBindSecret987!"
```

**Salida esperada:**
```text
dn:cn=sssd-bind,ou=services,dc=production,dc=local
```

#### Paso 4.4: Vaciar caché y depurar problemas de SSSD

Cuando los atributos del directorio se actualizan en el servidor pero no se reflejan en el cliente, limpie la caché de SSSD usando `sss_cache`:

```bash
sss_cache -E
```

Inspeccione los registros del dominio SSSD en busca de fallos de conexión o problemas de discrepancia de esquemas:

```bash
tail -n 25 /var/log/sssd/sssd_PRODUCTION.log
```

---

### Preguntas de verificación - Bloque 4

#### Pregunta 4.1
Un servidor Linux configurado con SSSD experimenta un evento inesperado de aislamiento de red que lo separa de todos los controladores de dominio OpenLDAP. Los usuarios reportan que las cuentas almacenadas en caché existentes pueden iniciar sesión, pero al ejecutar `getent passwd` solo se muestran las cuentas locales de `/etc/passwd`. ¿Qué explica este comportamiento?

- A) SSSD deshabilita la verificación de credenciales almacenadas en caché local cuando caen las interfaces de red.
- B) `getent passwd` enumera todas las entradas. SSSD deshabilita la enumeración completa de manera predeterminada (`enumeration = false`) para evitar la saturación de red y el consumo de memoria, mientras sigue permitiendo la autenticación directa en caché.
- C) NSSwitch elimina automáticamente `sss` de `/etc/nsswitch.conf` al detectar la pérdida del enlace de red.
- D) Las bases de datos de identidad en caché bajo `/var/lib/sss/db/` se limpian inmediatamente cuando los servidores LDAP quedan inalcanzables.

#### Pregunta 4.2
SSSD no logra iniciar tras un reinicio del host. Al ejecutar `systemctl status sssd` se muestra `FATAL: Unsafe permissions on configuration file /etc/sssd/sssd.conf`. ¿Qué combinación exacta de bits de modo de archivo se requiere para solucionar esto?

- A) `0755` (`rwxr-xr-x`) propiedad de `root:root`
- B) `0644` (`rw-r--r--`) propiedad de `root:sssd`
- C) `0600` (`rw-------`) propiedad de `root:root`
- D) `0400` (`r--------`) propiedad de `sssd:sssd`

---

<details>
<summary><strong>Haz clic para expandir: Soluciones completas y clave de respuestas</strong></summary>

### Respuestas del Bloque 1

* **Pregunta 1.1: Respuesta correcta B**  
  * **Razonamiento:** Cuando un DHCP Relay Agent reenvía un paquete `DHCPDISCOVER`, completa el campo `giaddr` con la dirección IP de su propia interfaz en la subred del cliente (`10.200.1.1`). El servidor DHCP usa `giaddr` para hacer coincidir las solicitudes entrantes con una declaración `subnet` adecuada en `dhcpd.conf`. Si no existe un bloque `subnet 10.200.1.0 netmask 255.255.255.0` en el servidor DHCP, este no puede asignar una dirección IP de ese pool, lo que genera un registro indicando que no hay leases libres para el segmento de red local del servidor.
  * **Opciones incorrectas:** A es incorrecta porque DHCP no mapea agentes de retransmisión en `/etc/hosts`. C es incorrecta porque la falta de metadata de Option 82 no impide la asignación básica de subred vía `giaddr`. D es incorrecta porque los clientes dinámicos normales emiten `DHCPDISCOVER` a través del estándar DORA, no de BOOTP.

* **Pregunta 1.2: Respuesta correcta B**  
  * **Razonamiento:** En la autoconfiguración de IPv6:
    * El flag **$M$ (Managed address configuration)** determina si las direcciones se obtienen a través de Stateful DHCPv6 ($M=1$). Establecer $M=0$ indica a los clientes que utilicen **SLAAC** para generar sus propias direcciones IP.
    * El flag **$O$ (Other configuration)** determina si los parámetros que no son direcciones (como servidores DNS y listas de búsqueda de dominios) se obtienen a través de DHCPv6 ($O=1$).
    * Por lo tanto, SLAAC + Stateless DHCPv6 para opciones requiere **$M=0, O=1$**.
  * **Opciones incorrectas:** A ($M=1, O=0$) fuerza Stateful DHCPv6 para la asignación de IP sin opciones adicionales. C ($M=1, O=1$) exige DHCPv6 completamente stateful tanto para asignación de IP como para opciones. D ($M=0, O=0$) representa SLAAC puro sin interacción con un servidor DHCPv6.

---

### Respuestas del Bloque 2

* **Pregunta 2.1: Respuesta correcta B**  
  * **Razonamiento:** El flag de control `requisite` especifica que si el módulo falla, el PAM engine **termina inmediatamente la ejecución de ese grupo de gestión (`auth`)** y devuelve un estado de fallo directamente a la aplicación. Debido a que `192.168.1.100` no coincide con `10.0.0.0/8`, `pam_ipmatch.so` devuelve un fallo, deteniendo el stack al instante y omitiendo `pam_faillock.so` y `pam_unix.so`.
  * **Opciones incorrectas:** A describe el comportamiento de `required`, no de `requisite`. C es incorrecta porque una IP no coincidente causa un fallo en el módulo, no `PAM_IGNORE`. D es incorrecta porque los fallos de `requisite` interrumpen el stack antes de alcanzar los módulos `sufficient` subsecuentes.

* **Pregunta 2.2: Respuesta correcta B**  
  * **Razonamiento:** La línea `auth requisite pam_wheel.so group=sysadmin use_uid` impone que el usuario invocador (determinado mediante `use_uid`) debe pertenecer al grupo `sysadmin`. El uso del flag de control `requisite` garantiza que si el usuario no está en `sysadmin`, la evaluación del módulo falle y detenga la ejecución inmediatamente antes de que se ejecuten los módulos que generan solicitudes de contraseña (como `pam_unix.so`).
  * **Opciones incorrectas:** A usa `optional`, el cual no bloquea a los no miembros. C usa `sufficient`, el cual omite la verificación de contraseña para los miembros del grupo en lugar de denegar a los no miembros antes de la ejecución de la solicitud. D hace referencia a una sintaxis y módulo no estándar para la restricción de `su` basada en grupos.

---

### Respuestas del Bloque 3

* **Pregunta 3.1: Respuesta correcta B**  
  * **Razonamiento:** OpenLDAP evalúa las reglas `olcAccess` secuencialmente en orden numérico (`{0}`, `{1}`, `{2}`, ...). **La primera regla que coincide con la entrada y atributo de destino procesa la solicitud y la evaluación se detiene.** Debido a que la Regla `{0}` apunta a `to *` (todos los atributos, incluyendo `userPassword`), coincide con la solicitud primero. La Regla `{0}` permite a `users` leer (`read`), pero no otorga acceso de escritura (`write`). En consecuencia, la evaluación se detiene en la Regla `{0}` y el acceso es denegado. La Regla `{1}` nunca se evalúa.
  * **Opciones incorrectas:** A es incorrecta porque la Regla `{0}` interrumpe la evaluación antes de alcanzar la Regla `{1}`. C es incorrecta porque TLS cifra el canal de transporte pero no anula las ACL del directorio. D es incorrecta porque el orden de ACL no válido causa fallos operativos de autorización, no caídas del demonio.

* **Pregunta 3.2: Respuesta correcta B**  
  * **Razonamiento:** `slapindex` modifica directamente el motor de almacenamiento de base de datos subyacente (`mdb` o los legados `hdb`/`bdb`) en disco, omitiendo el proceso del demonio `slapd`. Ejecutar `slapindex` mientras `slapd` se ejecuta activamente provoca escrituras de archivos concurrentes, corrupción de índices y fallos de bloqueo de base de datos. El servicio debe detenerse antes de ejecutar `slapindex`.
  * **Opciones incorrectas:** A causa una severa corrupción en la base de datos. C no es válida porque `olcDbIndex` modifica parámetros de configuración en `cn=config`, pero no admite una palabra clave `rebuild`. D es una solución ineficiente que requiere exportar/importar datos en lugar de ejecutar una reindexación fuera de línea.

---

### Respuestas del Bloque 4

* **Pregunta 4.1: Respuesta correcta B**  
  * **Razonamiento:** SSSD deshabilita la enumeración de bases de datos (`enumeration = false`) de forma predeterminada. Enumerar directorios completos (`getent passwd`) sobre bases de datos empresariales grandes genera una inmensa sobrecarga de red y CPU. Cuando está fuera de línea, `getent passwd` consulta NSS, que llama a `sss`; debido a que la enumeración está deshabilitada, `sss` devuelve solo archivos del sistema local o coincidencias activas. Sin embargo, la autenticación directa de usuario (`pam_sss`) y las consultas explícitas de un solo usuario (`id <username>`) tienen éxito porque las credenciales y los mapeos de usuario individuales se almacenan en caché localmente en `/var/lib/sss/db/`.
  * **Opciones incorrectas:** A es incorrecta porque SSSD admite explícitamente la autenticación fuera de línea mediante credenciales en caché. C es incorrecta porque NSSwitch no reescribe dinámicamente `/etc/nsswitch.conf`. D es incorrecta porque SSSD conserva los archivos de caché durante las interrupciones de red para admitir la autenticación fuera de línea.

* **Pregunta 4.2: Respuesta correcta C**  
  * **Razonamiento:** `/etc/sssd/sssd.conf` almacena secretos operativos sensibles, incluidas contraseñas de enlace de cuentas de servicio en texto plano (`ldap_default_authtok`). Para proteger estas credenciales, SSSD aplica permisos estrictos de seguridad de archivos. El archivo de configuración debe ser propiedad de `root:root` con permisos establecidos estrictamente en `0600` (`rw-------`) o `0400` (`r--------`). Cualquier legibilidad por parte del grupo o del resto del mundo hace que SSSD aborte el inicio del demonio.
  * **Opciones incorrectas:** A (`0755`), B (`0644`) y D (propiedad incorrecta `sssd:sssd`) violan los controles de aplicación de seguridad de SSSD, causando fallos al iniciar.

</details>