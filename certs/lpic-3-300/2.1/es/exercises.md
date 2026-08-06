# LPIC-3 Exam 300 (v3.0) — Tema 2.1: Samba y Dominios de Active Directory

**Peso del examen:** 20  
**Rol objetivo:** Senior SRE / Principal Platform Architect  
**Referencia oficial:** [LPI LPIC-3 300 Detailed Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/)  
**Documentación técnica de Samba:** [Samba AD DC HowTo & Architecture](https://wiki.samba.org/index.php/Samba_AD_DC_HOWTO)

---

## Visión General de la Arquitectura Técnica y Conceptos Clave

Samba como Active Directory Domain Controller (AD DC) integra varios protocolos y demonios de infraestructura distintos en un servicio de directorio empresarial unificado:

```
+-----------------------------------------------------------------------------------+
|                                 Samba AD DC Process                               |
|                                                                                   |
|  +------------------+  +-------------------+  +--------------------------------+  |
|  |   Heimdal/MIT    |  | Embedded LDB/LDAP |  | Internal DNS Server            |  |
|  |   Kerberos KDC   |  | Directory Service |  | (or BIND9 DLZ Plugin)          |  |
|  |   (Port 88 TCP/UDP)| | (Port 389 / 636) |  | (Port 53 TCP/UDP)              |  |
|  +--------+---------+  +---------+---------+  +---------------+----------------+  |
|           |                      |                            |                   |
|  +--------+----------------------+----------------------------+----------------+  |
|  |                 Directory Replication Service (DRS / DCE-RPC)               |  |
|  |                 NETLOGON & SYSVOL SMB File Sharing (Port 445)               |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Componentes Clave y Trade-offs Arquitectónicos

1. **Arquitectura de Demonios (`samba` vs `smbd`/`nmbd`/`winbindd`):**
   * Al actuar como un AD DC, Samba ejecuta el único binario `samba` que orquesta el KDC embebido, el servidor LDAP, el servidor DNS, el servidor NBT y los endpoints RPC.
   * Ejecutar los demonios heredados `smbd`, `nmbd` o `winbindd` por separado en un Samba AD DC causará conflictos de puertos y fallos de servicio.

2. **Motor de Almacenamiento (LDB vs OpenLDAP):**
   * Samba AD DC utiliza **LDB** (un formato de base de datos tipo LDAP ligero respaldado por TDB) en lugar de OpenLDAP independiente.
   * LDB admite filtros de búsqueda LDAP estándar, controles y aplicación de esquemas (schema enforcement), manteniendo un acceso rápido clave-valor local para las operaciones del dominio.

3. **Backends de DNS:**
   * **`SAMBA_INTERNAL`**: Servidor DNS embebido. Ligero, no requiere configuración de servicios externos, perfectamente adecuado para topologías simples. Trade-off: Carece de características avanzadas de BIND como split-horizon, firma en línea DNSSEC o vistas de zonas personalizadas.
   * **`BIND9_DLZ`**: Plugin de Zonas Cargadas Dinámicamente (`dlz_bind9.so`). BIND9 carga las zonas directamente desde la base de datos `sam.ldb` de Samba a través de DCE/RPC. Ideal para despliegues empresariales que requieren enrutamiento de DNS avanzado y cumplimiento de seguridad.

4. **Directory Replication Service (DRS):**
   * Utiliza Microsoft Directory Replication Service Remote Protocol (MS-DRSR) sobre DCE-RPC.
   * Opera a través de metadatos de replicación estándar de Active Directory (contadores USN, High-Water Marks y Up-To-Dateness Vectors).

---

## Ejercicios Prácticos de Laboratorio

---

### Módulo 1: Aprovisionamiento Greenfield de Samba 4 Active Directory DC

#### Objetivo
Aprovisionar un Active Directory Domain Controller principal de Samba 4 (`dc1.corp.example.com`) utilizando extensiones de esquema RFC 2307, configurar Kerberos del sistema y validar las operaciones internas de LDAP, DNS y KDC.

#### Paso 1.1: Preparación del Entorno y Chequeos Previos (Pre-Flight Checks)
Limpiar archivos de configuración heredados y asegurar que la resolución del hostname coincida con el Realm previsto.

```bash
# Set fully qualified domain name
hostnamectl set-hostname dc1.corp.example.com

# Verify /etc/hosts resolution
cat << 'EOF' > /etc/hosts
127.0.0.1   localhost
192.168.50.10 dc1.corp.example.com dc1
EOF

# Remove pre-existing Samba/Kerberos configurations
systemctl stop samba-ad-dc smbd nmbd winbind 2>/dev/null || true
rm -f /etc/samba/smb.conf /etc/krb5.conf
rm -rf /var/lib/samba/private/* /var/lib/samba/sysvol/*
```

#### Paso 1.2: Ejecutar el Aprovisionamiento del Dominio
Ejecutar `samba-tool domain provision` en modo no interactivo.

```bash
samba-tool domain provision \
  --realm=CORP.EXAMPLE.COM \
  --domain=CORP \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --adminpass="P@ssw0rd2026!" \
  --use-rfc2307
```

*Snippet de salida de CLI esperada:*
```text
Looking up IPv4 addresses
Looking up IPv6 addresses
Setting up share.ldb
Setting up secrets.ldb
Setting up the Registry
Setting up the SAM database
Setting up SamDB records
Setting up doming admin password
A-Cls and ACLs on SAM status...
Setting up self-join...
Setting up SAMDB security...
Setting up Netlogon and SYSVOL shares
Setting up WERR_OK
Provisioning complete!
A krb5.conf file appropriate for the Samba AD DC has been generated at /var/lib/samba/private/krb5.conf
```

#### Paso 1.3: Configurar Kerberos y Servicios del Sistema
Vincular el `krb5.conf` generado a las rutas del sistema e iniciar el servicio `samba-ad-dc`.

```bash
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl unmask samba-ad-dc
systemctl restart samba-ad-dc
systemctl enable samba-ad-dc
```

#### Paso 1.4: Validar Operaciones de LDAP, Kerberos y DNS
Ejecutar consultas de diagnóstico contra el nuevo Domain Controller.

```bash
# 1. Test Kerberos authentication for Administrator
kinit administrator@CORP.EXAMPLE.COM
```
*Salida esperada:*
```text
Password for administrator@CORP.EXAMPLE.COM: 
```

```bash
# 2. Inspect active Kerberos ticket-granting ticket (TGT)
klist
```
*Salida esperada:*
```text
Ticket cache: FILE:/tmp/krb5cc_0
Default principal: administrator@CORP.EXAMPLE.COM

Valid starting       Expires              Service principal
08/06/26 12:50:01  08/06/26 22:50:01  krbtgt/CORP.EXAMPLE.COM@CORP.EXAMPLE.COM
	renew until 08/07/26 12:50:01
```

```bash
# 3. Test DNS SRV record resolution
host -t SRV _kerberos._tcp.corp.example.com localhost
host -t SRV _ldap._tcp.corp.example.com localhost
```
*Salida esperada:*
```text
Using domain server:
Name: localhost
Address: 127.0.0.1#53

_kerberos._tcp.corp.example.com has SRV record 0 100 88 dc1.corp.example.com.
_ldap._tcp.corp.example.com has SRV record 0 100 389 dc1.corp.example.com.
```

---

#### Preguntas de Verificación — Módulo 1

1. **Pregunta 1.1:** ¿Por qué el aprovisionamiento de un AD DC requiere `--use-rfc2307` si clientes Linux/Unix se unirán al dominio?
2. **Pregunta 1.2:** ¿Qué ocurre si un administrador intenta iniciar unidades de systemd estándar de `smbd` y `winbindd` de forma concurrente con `samba-ad-dc`?

---

### Módulo 2: Arquitectura Multi-DC: Replicación DRS y Gestión de Roles FSMO

#### Objetivo
Unir un segundo nodo (`dc2.corp.example.com`) como un AD Domain Controller adicional para lograr redundancia de Directory Replication Service (DRS), inspeccionar la topología de replicación y transferir de forma segura los roles de Flexible Single Master Operation (FSMO).

```
                    +-----------------------+
                    |  FSMO Role Owner:     |
                    |  dc1.corp.example.com |
                    +-----------+-----------+
                                |
             MS-DRSR Replication| (DCE/RPC Port 135 / Dynamic)
                                v
                    +-----------------------+
                    |  Secondary DC:        |
                    |  dc2.corp.example.com |
                    +-----------------------+
```

#### Paso 2.1: Unir el Servidor Secundario al Dominio Existente
En `dc2.corp.example.com` (IP: `192.168.50.11`), establecer el DNS primario en `192.168.50.10` (`dc1`) y ejecutar el join del DC.

```bash
# Configure DNS pointing to primary DC
echo "nameserver 192.168.50.10" > /etc/resolv.conf

# Execute Domain Controller Join
samba-tool domain join corp.example.com DC \
  -U"CORP\Administrator" \
  --password="P@ssw0rd2026!" \
  --dns-backend=SAMBA_INTERNAL
```

*Snippet de salida de CLI esperada:*
```text
Finding a writeable DC for domain 'corp.example.com'
Found DC dc1.corp.example.com
Password for [CORP\Administrator]:
Partition[CN=Configuration,DC=corp,DC=example,DC=com] objects[1624] linked_values[28]
Partition[CN=Schema,CN=Configuration,DC=corp,DC=example,DC=com] objects[15670] linked_values[0]
Partition[DC=corp,DC=example,DC=com] objects[742] linked_values[61]
Replicating critical objects from the distant server
Joined domain CORP (SID S-1-5-21-382910482-120493821-93810294) as a DC
```

```bash
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl start samba-ad-dc
```

#### Paso 2.2: Verificar la Replicación DRS Entrante y Saliente
Inspeccionar el estado de la topología de replicación usando `samba-tool drs`.

```bash
samba-tool drs showrepl
```

*Snippet de salida de CLI esperada:*
```text
Default-First-Site-Name\DC2
DSA Options: IS_GC
DSA object GUID: 3b1a789c-4f81-42ab-9d10-81726a510101
DSA invocationId: e801aa45-9112-4211-89ab-010192837411

==== INBOUND NEIGHBORS ====

DC=corp,DC=example,DC=com
	Default-First-Site-Name\DC1 via RPC
		DSA object GUID: 1a89c7d6-3b21-4d1a-8e19-901827465192
		Last attempt @ Thu Aug  6 12:55:10 2026 EDT was successful
		0 failures since last success.
		Naming Context USN: 39482 (High Water), 39482 (Up To Date)
```

#### Paso 2.3: Consultar y Transferir Roles FSMO
Identificar los poseedores actuales de roles FSMO en todo el bosque y transferir los 7 roles de `dc1` a `dc2`.

```bash
# Query initial FSMO role placement
samba-tool fsmo show
```

*Salida de CLI esperada:*
```text
SchemaMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
InfrastructureMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
RidMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
PdcEmulation role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
NamingMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
DomainDnsZonesMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
ForestDnsZonesMaster role owner: CN=NTDS Settings,CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=corp,DC=example,DC=com
```

```bash
# Gracefully transfer all roles to dc2
samba-tool fsmo transfer --role=all -U"CORP\Administrator" --password="P@ssw0rd2026!"
```

*Snippet de salida esperada:*
```text
FSMO transfer of 'rid' role successful
FSMO transfer of 'pdc' role successful
FSMO transfer of 'naming' role successful
FSMO transfer of 'infrastructure' role successful
FSMO transfer of 'schema' role successful
FSMO transfer of 'domaindns' role successful
FSMO transfer of 'forestdns' role successful
Transferred 7 roles successfully
```

---

#### Preguntas de Verificación — Módulo 2

1. **Pregunta 2.1:** ¿Cuál es la diferencia técnica entre `samba-tool fsmo transfer` y `samba-tool fsmo seize`, y bajo qué condiciones operativas precisas debe utilizarse `seize`?
2. **Pregunta 2.2:** ¿Por qué hay 7 roles FSMO listados en Samba 4 AD DC en lugar de los 5 roles FSMO estándar definidos históricamente en la documentación tradicional de Active Directory?

---

### Módulo 3: Integración de DNS Empresarial: BIND9 DLZ y Actualizaciones Dinámicas de DNS Seguras (GSS-TSIG)

#### Objetivo
Reconfigurar Samba AD DC para usar BIND9 con el controlador Dynamically Loaded Zones (DLZ) (`dlz_bind9.so`) y configurar actualizaciones dinámicas de DNS seguras autenticadas por Kerberos (`gssapi_keytab`).

#### Paso 3.1: Generar la Configuración de Named y el Keytab
Ajustar `/etc/samba/smb.conf` para hacer referencia al backend BIND9 DLZ y verificar la ubicación del keytab.

```ini
# Append/verify in /etc/samba/smb.conf under [global]
[global]
    netbios name = DC1
    realm = CORP.EXAMPLE.COM
    workgroup = CORP
    server role = active directory domain controller
    dns forwarder = 1.1.1.1
    server services = -dns
```

#### Paso 3.2: Configurar el Manifiesto Named de BIND9
Crear un `/etc/bind/named.conf` sintácticamente válido integrando el módulo DLZ de Samba.

```bind
// /etc/bind/named.conf

options {
    directory "/var/cache/bind";
    forwarders {
        1.1.1.1;
        8.8.8.8;
    };
    dnssec-validation auto;
    listen-on port 53 { any; };
    listen-on-v6 { any; };
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
};

// Load Samba DLZ plugin dynamically (Path varies by distribution architecture)
dlz "AD_DNS" {
    statement "http://www.samba.org/samba/docs/man/samba-tool.8.html";
    database "dlopen /usr/lib/x86_64-linux-gnu/samba/bind9/dlz_bind9_18.so -H /var/lib/samba/private/sam.ldb";
};
```

#### Paso 3.3: Establecer Permisos y Reiniciar Servicios
Asegurar que BIND9 tenga acceso de lectura a los sockets de la base de datos LDB y al keytab de DNS de Samba.

```bash
# Grant bind user ownership to bind-dns path
chown -R root:bind /var/lib/samba/bind-dns
chmod 750 /var/lib/samba/bind-dns

# Stop samba-ad-dc, start bind9, then start samba-ad-dc
systemctl stop samba-ad-dc
systemctl restart bind9
systemctl start samba-ad-dc
```

#### Paso 3.4: Probar la Actualización Dinámica de DNS Segura mediante GSS-TSIG
Realizar una actualización de DNS autenticada utilizando `nsupdate` y credenciales de Kerberos.

```bash
# Obtain ticket for administrator
kinit administrator@CORP.EXAMPLE.COM

# Submit GSS-TSIG authenticated DNS registration
nsupdate -g << 'EOF'
server 127.0.0.1
realm CORP.EXAMPLE.COM
zone corp.example.com
update add app-server-01.corp.example.com 3600 A 192.168.50.50
send
EOF

# Verify record in DNS
host app-server-01.corp.example.com 127.0.0.1
```

*Salida esperada:*
```text
Using domain server:
Name: 127.0.0.1
Address: 127.0.0.1#53

app-server-01.corp.example.com has address 192.168.50.50
```

---

#### Preguntas de Verificación — Módulo 3

1. **Pregunta 3.1:** ¿Qué directiva en `named.conf` permite a BIND9 realizar actualizaciones GSS-TSIG autenticadas por Kerberos sin requerir claves TSIG estáticas precompartidas?
2. **Pregunta 3.2:** ¿Qué problema operativo ocurre si se omite `server services = -dns` en `smb.conf` al ejecutar BIND9 DLZ en el mismo host?

---

### Módulo 4: Administración de Objetos AD de Bajo Nivel y Políticas de Contraseñas Personalizadas (Fine-Grained Password Policies)

#### Objetivo
Gestionar objetos de Active Directory de forma programática, inspeccionar las bases de datos LDB subyacentes mediante `ldbsearch`/`ldbedit` y aplicar un Password Settings Object (PSO) para grupos específicos.

#### Paso 4.1: Inspeccionar el Esquema del Directorio vía `ldbsearch`
Consultar `sam.ldb` de Samba directamente omitiendo el stack de red LDAP estándar.

```bash
ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "DC=corp,DC=example,DC=com" \
  "(sAMAccountName=administrator)" \
  pwdLastSet userAccountControl objectSid
```

*Snippet de salida esperada:*
```ldif
dn: CN=Administrator,CN=Users,DC=corp,DC=example,DC=com
pwdLastSet: 133674829100000000
userAccountControl: 512
objectSid: S-1-5-21-382910482-120493821-93810294-500
```

#### Paso 4.2: Crear Unidad Organizativa, Usuarios y Grupos de Seguridad
Usar `samba-tool` para aprovisionar la jerarquía empresarial.

```bash
# Create Organizational Unit
samba-tool ou create "OU=Engineers,DC=corp,DC=example,DC=com"

# Create Security Group
samba-tool group add "Sec-DevOps" --groupou="OU=Engineers"

# Provision User Account with explicit POSIX attributes
samba-tool user create dev-user01 "P@ssw0rd2026Sec!" \
  --userou="OU=Engineers" \
  --given-name="Dev" \
  --surname="User" \
  --mail-address="dev-user01@corp.example.com"

# Add User to Group
samba-tool group addmembers "Sec-DevOps" dev-user01
```

#### Paso 4.3: Aplicar Política de Contraseñas Personalizada (PSO)
Crear un Password Settings Object (PSO) dirigido a grupos de ingeniería con altos privilegios.

```bash
samba-tool domain passwordsettings pso add "DevOps-PSO" 10 \
  --complexity=on \
  --history-length=24 \
  --min-pwd-age=1 \
  --max-pwd-age=60 \
  --min-pwd-length=16 \
  --account-lockout-threshold=5 \
  --account-lockout-duration=30 \
  --reset-account-lockout-after=30

# Apply PSO to Sec-DevOps group
samba-tool domain passwordsettings pso apply "DevOps-PSO" "Sec-DevOps"
```

#### Paso 4.4: Validar la Aplicación del PSO
Verificar la aplicación efectiva de la política en `dev-user01`.

```bash
samba-tool domain passwordsettings pso show-user dev-user01
```

*Snippet de salida esperada:*
```text
Password PSO info for user dev-user01:
  Applied PSO: DevOps-PSO
  Minimum password length: 16
  Password complexity: on
  Password history length: 24
  Minimum password age (days): 1
  Maximum password age (days): 60
  Account lockout threshold: 5
  Account lockout duration (mins): 30
  Reset account lockout counter after (mins): 30
```

---

#### Preguntas de Verificación — Módulo 4

1. **Pregunta 4.1:** ¿Por qué se desaconseja la manipulación manual directa de `/var/lib/samba/private/sam.ldb` mediante `ldbedit` en producción salvo que se realice una recuperación de emergencia?
2. **Pregunta 4.2:** ¿Cuál es la diferencia estructural en Active Directory entre la política global de contraseñas del dominio (`samba-tool domain passwordsettings set`) y un Password Settings Object (PSO)?

---

### Módulo 5: Diagnóstico SRE en Producción y Playbook de Resolución de Problemas (Troubleshooting)

#### Objetivo
Diagnosticar y resolver fallos comunes en producción: Service Principal Names (SPNs) de Kerberos faltantes, desviación (drift) de las listas de control de acceso (ACL) de SYSVOL y corrupción de bases de datos.

#### Paso 5.1: Resolver Fallos de Autenticación de Service Principal Name (SPN)
Simular un error de SPN faltante cuando un servidor Web intenta autenticación Kerberos HTTP (`HTTP/web.corp.example.com`).

```bash
# 1. Query existing SPNs for an application service account
samba-tool spn list svc_web

# 2. Add required SPN mapping to service account
samba-tool spn add HTTP/web.corp.example.com svc_web

# 3. Verify SPN resolution in directory
ldbsearch -H /var/lib/samba/private/sam.ldb "(servicePrincipalName=HTTP/web.corp.example.com)" dn
```

*Salida esperada:*
```ldif
dn: CN=svc_web,CN=Users,DC=corp,DC=example,DC=com
```

#### Paso 5.2: Auditar y Reparar la Integridad de las ACLs de SYSVOL
Los permisos del directorio SYSVOL sufren desviaciones (drift) frecuentemente cuando las utilidades de respaldo o las herramientas RSAT aplican permisos que no cumplen con POSIX.

```bash
# Check SYSVOL ACL integrity
samba-tool ntacl sysvolcheck
```

*Salida esperada cuando está corrupto:*
```text
ERROR(<class 'samba.provision.ProvisioningError'>): ProvisioningError: VFS Security Information mismatch on /var/lib/samba/sysvol/corp.example.com/Policies: action=0x00040000, expected=0x000e0000
```

```bash
# Repair SYSVOL ACLs to original factory specification
samba-tool ntacl sysvolreset

# Re-verify status
samba-tool ntacl sysvolcheck
```

*Salida esperada después de reparar:*
```text
(No error output returned; exit code 0)
```

#### Paso 5.3: Ejecutar Chequeo de Consistencia de Base de Datos e Integridad Cross-NC
Escanear las particiones internas LDB en busca de referencias huérfanas, atributos enlazados rotos o discrepancias de Esquema (Schema mismatches).

```bash
samba-tool dbcheck --cross-ncs
```

*Snippet de salida esperada:*
```text
Checking 18392 objects
Checked 18392 objects (0 errors)
```

---

#### Preguntas de Verificación — Módulo 5

1. **Pregunta 5.1:** ¿Qué problema operativo ocurre si se ejecuta `samba-tool ntacl sysvolreset` mientras se utiliza `rsync` estándar (sin `--xattrs`) para la replicación de SYSVOL entre múltiples DCs?
2. **Pregunta 5.2:** ¿Qué herramienta y argumento debería usar un SRE para inspeccionar los endpoints DCE-RPC activos vinculados en un Samba Domain Controller?

---

<details>
<summary><strong>Soluciones a los Ejercicios y Justificaciones Arquitectónicas</strong></summary>

### Soluciones del Módulo 1

* **Respuesta 1.1:** El flag `--use-rfc2307` puebla el esquema de Active Directory con atributos POSIX (`uidNumber`, `gidNumber`, `unixHomeDirectory`, `loginShell`, `gecos`). Sin esta extensión de esquema, los servidores miembros Linux que utilicen Winbind, SSD o nslcd no pueden mapear los principales de seguridad de Active Directory directamente a UIDs/GIDs nativos de Linux a menos que se configuren rangos de mapeo dinámico arbitrarios (como `idmap_autorid` o `idmap_rid`) en cada cliente individual.
* **Respuesta 1.2:** Ocurre una colisión de puertos de inmediato. El proceso `samba-ad-dc` genera hilos embebidos escuchando en TCP/UDP 389 (LDAP), 636 (LDAPS), 88 (Kerberos), 445 (SMB), 135 (RPC) y 53 (DNS). Si los demonios heredados `smbd`, `nmbd` o `winbindd` se ejecutan simultáneamente, intentan vincularse (bind) a los mismos sockets exactos (por ejemplo, `smbd` en 445/139, `winbindd` en `/var/lib/samba/winbindd_privileged/pipe`), lo que provoca caídas en la inicialización del servicio y split-brain en el directorio.

---

### Soluciones del Módulo 2

* **Respuesta 2.1:**
  * **`transfer`**: Se realiza de manera ordenada (gracefully) cuando el poseedor actual del rol FSMO está en línea y accesible. El DC de origen sincroniza cualquier cambio pendiente, libera la propiedad y actualiza el DC de destino a través de RPC.
  * **`seize`**: Se realiza de manera forzada cuando el poseedor actual del rol ha sufrido un fallo catastrófico permanente y no se puede recuperar en línea. **PRECAUCIÓN:** Una vez que un rol (especialmente Schema Master o RID Master) es forzado (seized), el DC original **NUNCA** debe volverse a poner en línea en el dominio sin un re-aprovisionamiento total; hacerlo provoca una duplicación irreversible de GUID/RID y la corrupción de Active Directory.
* **Respuesta 2.2:** Active Directory estándar define 5 roles FSMO:
  1. Schema Master (A nivel de bosque / Forest-wide)
  2. Domain Naming Master (A nivel de bosque / Forest-wide)
  3. RID Master (A nivel de dominio / Domain-wide)
  4. PDC Emulator (A nivel de dominio / Domain-wide)
  5. Infrastructure Master (A nivel de dominio / Domain-wide)
  
  Samba 4 incluye 2 roles maestros FSMO adicionales específicos de DNS introducidos en Windows Server 2003 para Particiones de Directorio de Aplicación (Application Directory Partitions):
  6. **DomainDnsZones Master** (Controla nombres/actualizaciones para `DC=DomainDnsZones,DC=domain,DC=com`)
  7. **ForestDnsZones Master** (Controla nombres/actualizaciones para `DC=ForestDnsZones,DC=domain,DC=com`)

---

### Soluciones del Módulo 3

* **Respuesta 3.1:** La directiva `tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";` en `named.conf`. Esto permite a BIND9 utilizar el SPN `DNS/dc1.corp.example.com` almacenado en el keytab para validar tickets de Kerberos presentados por clientes Windows/Linux durante operaciones `nsupdate -g`, actualizando dinámicamente el backend LDB sin secretos compartidos estáticos.
* **Respuesta 3.2:** Si se omite `server services = -dns` (o eliminar `dns` de `server services`) en `smb.conf`, el proceso DNS interno de Samba se iniciará durante la inicialización de `samba-ad-dc` e intentará vincularse (bind) al puerto 53 TCP/UDP. Esto causa que BIND9 (o el DNS interno de Samba) falle al iniciar debido a `EADDRINUSE` (Address already in use).

---

### Soluciones del Módulo 4

* **Respuesta 4.1:** Editar `/var/lib/samba/private/sam.ldb` directamente a través de `ldbedit` omite las verificaciones activas de sanidad de LDAP de Samba, los disparadores (triggers) de integridad referencial, las evaluaciones de complejidad de contraseñas y los módulos de aplicación de esquema (schema enforcement). Las ediciones manuales incorrectas pueden corromper contadores USN, romper atributos de enlace GUID o causar fallos fatales de deserialización durante la replicación DRS.
* **Respuesta 4.2:** La política global de contraseñas del dominio (`samba-tool domain passwordsettings set`) se aplica a todas las cuentas por defecto, pero solo puede aplicar **un** único conjunto de reglas en todo el dominio. Un Password Settings Object (PSO), introducido en AD DS (RFC 2307 / nivel funcional Windows 2008), permite a los SRE aplicar políticas de contraseñas personalizadas (Fine-Grained Password Policies - FGPP) con restricciones más estrictas (por ejemplo, longitud mínima de 16 caracteres y bloqueo tras 5 intentos) a usuarios específicos o Grupos de Seguridad Globales sin afectar a las cuentas de dominio estándar.

---

### Soluciones del Módulo 5

* **Respuesta 5.1:** `rsync` estándar sin atributos extendidos (`--xattrs`) y preservación de ACLs POSIX (`--acls`) remueve los atributos NTFS extendidos de Samba (`security.NTACL`) almacenados en los atributos del sistema de archivos `user.NTACL` en `/var/lib/samba/sysvol`. Cuando se ejecuta `samba-tool ntacl sysvolreset` o cuando los clientes verifican la Group Policy, los Objetos de Directiva de Grupo (GPOs) se vuelven ilegibles para las máquinas del dominio debido a la falta de representaciones de ACLs de Windows NT en el directorio POSIX.
* **Respuesta 5.2:** Los SRE utilizan `rpcclient` o diagnósticos de `samba-tool` junto con `netstat` / `ss` / `lsof`. Específicamente, `rpcclient -U "user" dc1 -c "netshareenumall"` o utilidades `epdump` (como escáneres `rpctorture` o `msrpc`) pueden inspeccionar los endpoints vinculados al DCE-RPC endpoint mapper de Samba en el puerto TCP 135.

</details>