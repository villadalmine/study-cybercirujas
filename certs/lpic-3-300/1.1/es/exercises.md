# LPIC-3 Exam 300-300 (v3.0) — Topic 1.1: Samba Basics

## 1. Visión general arquitectónica y técnica a fondo

Samba proporciona servicios de archivos e impresión para clientes utilizando el conjunto de protocolos Server Message Block (SMB) / Common Internet File System (CIFS) a través de redes heterogéneas. Comprender Samba a un nivel de SRE de producción requiere dominar su modelo de procesos subyacente, motores de almacenamiento de estado, comportamiento de sockets de red, negociación de dialectos de protocolo y el subsistema de configuración.

### 1.1 Arquitectura de procesos y demonios
Samba opera a través de tres demonios principales:

*   **`smbd` (Servicio SMB/CIFS):** Maneja autenticación, autorización, control de acceso, compartición de archivos/impresión y bloqueo por rango de bytes (byte-range locking). En versiones modernas, `smbd` sigue un modelo de procesos híbrido: un demonio `smbd` padre escucha en puertos TCP y crea un proceso hijo (fork) para cada conexión entrante de cliente, mientras delega tareas en segundo plano a pools de trabajadores (ej. I/O asíncrono, subsistemas de notificación).
*   **`nmbd` (Demonio de Servicio de Nombres NetBIOS):** Proporciona resolución de NetBIOS sobre TCP/IP (NBT) y servicios de navegación (browsing). Gestiona el registro de nombres NetBIOS, resolución (servidor/cliente WINS) y elecciones de local master browser. *Nota: `nmbd` no es requerido cuando se opera en entornos puros de Active Directory o SMB moderno Direct-Hosted sin dependencia de NetBIOS heredado.*
*   **`winbindd` (Demonio de Name Service Switch / Pluggable Authentication Module):** Interfaz unificada para resolver información de usuarios/grupos y autenticar usuarios de dominio contra Active Directory (AD) o dominios NT4. Mapea Windows Security Identifiers (SIDs) a UIDs/GIDs POSIX mediante backends `idmap` configurables.

#### Arquitectura de memoria y capa de base de datos TDB
Samba utiliza **TDB (Trivial Data Base)**—una base de datos clave-valor ligera y no relacional que permite acceso concurrente por parte de múltiples procesos—para mantener estado transitorio y persistente:
*   `passdb.tdb`: Credenciales de usuario local y flags de cuenta (gestionado a través de `pdbedit`).
*   `secrets.tdb`: Contraseñas sensibles de máquinas de dominio, keytabs de Kerberos y SID de máquina local.
*   `gencache.tdb`: Caché para resolución de nombres, controladores de dominio y búsquedas de SID-a-nombre.
*   `locking.tdb`: Rastrea bloqueos por rango de bytes (byte-range locks) activos y bloqueos oportunistas (oplocks / leases).
*   `brlock.tdb`: Asignaciones de bloqueo por rango de bytes POSIX y SMB a través de procesos `smbd` hijos.

### 1.2 Mapeo de protocolos de red y puertos

| Servicio de Protocolo | Puerto / Transporte | Proceso | Función Arquitectónica |
| :--- | :--- | :--- | :--- |
| **NetBIOS Name Service (NBT NS)** | `137/UDP` | `nmbd` | Consulta de nombres NetBIOS, registro y resolución WINS. |
| **NetBIOS Datagram Service** | `138/UDP` | `nmbd` | Anuncios de explorador NetBIOS y mensajes de mail-slot. |
| **NetBIOS Session Service** | `139/TCP` | `smbd` | SMB envuelto dentro de la capa NetBIOS Session (SMB1 heredado). |
| **Direct Hosted SMB** | `445/TCP` | `smbd` | SMB crudo directamente sobre TCP/IP (SMB 2.x / 3.x, omite NBT). |

### 1.3 Dialectos del protocolo SMB y evolución

1.  **SMB 1.0 / CIFS:** Protocolo conversador (chatty) y de alta latencia. Vulnerable a exploits estructurales (ej. WannaCry / EternalBlue). Obsoleto y deshabilitado por defecto (`server min protocol = SMB2_02`).
2.  **SMB 2.02 / 2.1:** Introducido en Windows Vista/7 y Samba 3.6. Redujo la cantidad de comandos (combinando múltiples solicitudes en paquetes individuales), aumentó los tamaños de búfer, admitió reautenticación dinámica y agregó handles resilientes en el lado del cliente.
3.  **SMB 3.0 / 3.02:** Introducido en Samba 4.0. Agregó cifrado AES-128-CCM de extremo a extremo, SMB Multichannel (vinculación de múltiples interfaces de red para mayor rendimiento y tolerancia a fallos) y Directory Leasing.
4.  **SMB 3.1.1:** Introdujo integridad previa a la autenticación (hashes SHA-512 de intercambios de negociación para prevenir ataques de degradación / downgrade attacks), cifrado AES-128-GCM y manejo mejorado del estado de cluster.

### 1.4 Paradigma arquitectónico de Samba 3 vs. Samba 4

*   **Samba 3:** Enfocado en roles de servidor de archivos, autenticación independiente (standalone), Primary Domain Controller (PDC) al estilo NT4 y membresía de dominio. Dependía fuertemente de configuraciones externas de LDAP y Heimdal/MIT Kerberos.
*   **Samba 4:** Reescritura completa que introduce una implementación totalmente integrada de **Active Directory Domain Controller (AD DC)**. Incluye un KDC (Kerberos Key Distribution Center) embebido, servidor DNS interno / plugin de BIND9, servidor LDAP interno (`ldb`) y protocolos de replicación de Active Directory (DRSUAPI). Samba 4 aún puede ejecutarse en el modo clásico de servidor de archivos (usando `smbd` y `winbindd` sin los servicios AD DC habilitados).

---

## 2. Referencias oficiales y enlaces de citación

*   **LPI Official Exam Objectives:** [LPIC-3 Exam 300-300 Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
*   **Samba Official Documentation & HowTos:** [Samba Wiki & Manual Pages](https://www.samba.org/samba/docs/)
*   **Samba Architecture & Internals:** [Samba Tech Docs - TDB & Process Architecture](https://wiki.samba.org/index.php/Samba_Internal_Architecture)
*   **SMB Protocol Specification (Microsoft Open Specs):** [MS-SMB2 Protocol Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/)

---

## 3. Ejercicios guiados prácticos

### Requisitos previos de configuración
Asegúrese de contar con una instancia de Linux (Debian/Ubuntu o RHEL/Rocky Linux) con acceso root y `samba`, `samba-common`, `smbclient`, `tdb-tools` y `tshark`/`tcpdump` instalados.

---

### Ejercicio 1: Inspección de demonios a bajo nivel, vinculación de puertos y negociación de dialecto SMB

#### Instrucciones paso a paso

1.  Inspeccione los binarios de Samba instalados y verifique los servicios del sistema. Habilite e inicie `smbd` y `nmbd`:
    ```bash
    sudo systemctl stop smbd nmbd winbind 2>/dev/null
    sudo systemctl enable --now smbd nmbd
    sudo systemctl status smbd nmbd --no-pager
    ```
    *Expected Output snippet:*
    ```text
    ● smbd.service - Samba SMB Daemon
       Loaded: loaded (/lib/systemd/system/smbd.service; enabled; vendor preset: enabled)
       Active: active (running) since Thu 2026-08-06 12:45:00 UTC; 5s ago
         Docs: man:smbd(8)
               man:samba(7)
               man:smb.conf(5)
       Main PID: 14205 (smbd)
         Status: "smbd: ready to serve requests..."
          Tasks: 4 (limit: 4915)
         Memory: 21.4M
     CGroup: /system.slice/smbd.service
             ├─14205 /usr/sbin/smbd --foreground --no-process-group
             ├─14207 /usr/sbin/smbd --foreground --no-process-group
             ├─14208 /usr/sbin/smbd --foreground --no-process-group
             └─14210 /usr/sbin/smbd --foreground --no-process-group
    ```

2.  Verifique las vinculaciones de sockets y los puertos TCP/UDP en escucha utilizando `ss`:
    ```bash
    sudo ss -tulpn | grep -E 'smbd|nmbd'
    ```
    *Expected Output:*
    ```text
    udp   UNCONN 0      0           0.0.0.0:137       0.0.0.0:*    users:(("nmbd",pid=14215,fd=17))
    udp   UNCONN 0      0           0.0.0.0:138       0.0.0.0:*    users:(("nmbd",pid=14215,fd=18))
    tcp   LISTEN 0      50          0.0.0.0:139       0.0.0.0:*    users:(("smbd",pid=14205,fd=39))
    tcp   LISTEN 0      50          0.0.0.0:445       0.0.0.0:*    users:(("smbd",pid=14205,fd=38))
    tcp   LISTEN 0      50             [::]:139          [::]:*    users:(("smbd",pid=14205,fd=37))
    tcp   LISTEN 0      50             [::]:445          [::]:*    users:(("smbd",pid=14205,fd=36))
    ```

3.  Consulte el sistema local para obtener nombres NetBIOS utilizando `nmblookup`:
    ```bash
    nmblookup -A 127.0.0.1
    ```
    *Expected Output:*
    ```text
    Looking up status of 127.0.0.1
        SAMBA-HOST      <00> -         B <ACTIVE> 
        SAMBA-HOST      <03> -         B <ACTIVE> 
        SAMBA-HOST      <20> -         B <ACTIVE> 
        WORKGROUP       <00> - <GROUP> B <ACTIVE> 
        WORKGROUP       <1e> - <GROUP> B <ACTIVE> 

    MAC Address = 00-00-00-00-00-00
    ```

4.  Conéctese localmente con `smbclient` especificando dialectos de protocolo explícitos para rastrear la negociación. Primero, intente una conexión forzando SMB3_11:
    ```bash
    smbclient -L //localhost -U guest% -m SMB3_11
    ```
    *Expected Output:*
    ```text
    Sharename       Type      Comment
    ---------       ----      -------
    print$          Disk      Printer Drivers
    IPC$            IPC       IPC Service (Samba 4.19.5-Ubuntu)
    SMB1 trading disabled serve mode
    ```

5.  Inspeccione las conexiones de clientes activas, los IDs de procesos y los dialectos conectados utilizando `smbstatus`:
    ```bash
    sudo smbstatus
    ```
    *Expected Output:*
    ```text
    Samba version 4.19.5-Ubuntu
    PID     Username     Group        Machine--------------Protocol Version----------------
    14312   nobody       nogroup      127.0.0.1 (ipv4:127.0.0.1:48392) SMB3_11           

    Service      pid     Machine       Connected at                     Encryption   Signing     
    ---------------------------------------------------------------------------------------------
    IPC$         14312   127.0.0.1     Thu Aug  6 12:48:10 2026 UTC     -            -           

    No locked files
    ```

---

#### Preguntas de verificación — Ejercicio 1

*   **Pregunta 1.1:** ¿Por qué `smbd` escucha por defecto tanto en el puerto TCP 139 como en el puerto TCP 445, y qué sucede con el overhead de paquetes de red cuando un cliente se conecta exclusivamente a través del puerto 445?
*   **Pregunta 1.2:** En la salida de `smbstatus`, un PID hijo `14312` está adjunto a `127.0.0.1`. ¿Cuál es el ciclo de vida de este proceso hijo específico en relación con el demonio padre `smbd` principal?

---

### Ejercicio 2: Configuración de `smb.conf` de grado de producción, sustitución de variables macro e inspección de estado TDB

#### Instrucciones paso a paso

1.  Haga una copia de seguridad del archivo `smb.conf` por defecto:
    ```bash
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    ```

2.  Cree un archivo `smb.conf` de producción optimizado que incluya endurecimiento de seguridad global, uso de macros, expansión dinámica de rutas y estrofas de recursos compartidos (shares) personalizadas:
    ```bash
    cat << 'EOF' | sudo tee /etc/samba/smb.conf
    [global]
       workgroup = ENTERPRISE
       server string = Core Storage Node %h (Samba %v)
       netbios name = STOR-NODE-01
       security = user
       passdb backend = tdbsam
       
       # Protocol Hardening & Dialects
       server min protocol = SMB2_10
       server max protocol = SMB3_11
       client max protocol = SMB3_11
       smb encrypt = required
       server signing = required
       
       # Logging and Diagnostics
       log file = /var/log/samba/log.%m
       max log size = 10000
       logging = file
       log level = 1 auth:3 smb2:2

       # Disable legacy NetBIOS if standalone
       disable netbios = no

    [eng-data]
       comment = Engineering Data Depository for %U
       path = /srv/samba/eng/%U
       read only = no
       browseable = yes
       valid users = @eng-team
       create mask = 0660
       directory mask = 0770
       force group = eng-team

    [node-audit]
       comment = Node Access Logs for Client %I
       path = /srv/samba/audit/%m
       read only = yes
       guest ok = no
       valid users = admin
    EOF
    ```

3.  Valide la sintaxis de `/etc/samba/smb.conf` utilizando `testparm`:
    ```bash
    testparm -s
    ```
    *Expected Output:*
    ```text
    Load smb config files from /etc/samba/smb.conf
    Loaded services file OK.
    Weak crypto is allowed
    Server role: ROLE_STANDALONE

    # Processing section "[global]"
    # Processing section "[eng-data]"
    # Processing section "[node-audit]"
    Global parameter server signing = required changed to always!
    Loaded services file OK.
    [global]
    	client max protocol = SMB3_11
    	log file = /var/log/samba/log.%m
    	log level = 1 auth:3 smb2:2
    	max log size = 10000
    	netbios name = STOR-NODE-01
    	passdb backend = tdbsam
    	security = USER
    	server max protocol = SMB3_11
    	server min protocol = SMB2_10
    	server signing = REQUIRED
    	server string = Core Storage Node %h (Samba %v)
    	smb encrypt = REQUIRED
    	workgroup = ENTERPRISE
    	idmap config * : backend = tdb

    [eng-data]
    	browseable = Yes
    	comment = Engineering Data Depository for %U
    	create mask = 0660
    	directory mask = 0770
    	force group = eng-team
    	path = /srv/samba/eng/%U
    	read only = No
    	valid users = @eng-team

    [node-audit]
    	comment = Node Access Logs for Client %I
    	path = /srv/samba/audit/%m
    	valid users = admin
    ```

4.  Ejecute `testparm` con el flag verbose `-v` filtrado para inspeccionar los valores por defecto de las configuraciones sensibles a macros:
    ```bash
    testparm -v | grep -E "lock directory|state directory|private dir"
    ```
    *Expected Output:*
    ```text
    	lock directory = /var/cache/samba
    	state directory = /var/lib/samba
    	private dir = /var/lib/samba/private
    ```

5.  Cree un grupo POSIX local `eng-team` y el usuario `developer01`, agregue el usuario a la base de datos `passdb.tdb` de Samba utilizando `smbpasswd`:
    ```bash
    sudo groupadd eng-team
    sudo useradd -m -g eng-team -s /bin/false developer01
    sudo mkdir -p /srv/samba/eng/developer01
    sudo chown -R developer01:eng-team /srv/samba/eng/developer01
    sudo chmod 0770 /srv/samba/eng/developer01

    # Set Samba user password
    (echo "SecureP@ss2026!"; echo "SecureP@ss2026!") | sudo smbpasswd -a developer01
    ```
    *Expected Output:*
    ```text
    Added user developer01.
    ```

6.  Inspeccione la entrada de cuenta en passdb local de Samba utilizando `pdbedit`:
    ```bash
    sudo pdbedit -L -v -u developer01
    ```
    *Expected Output:*
    ```text
    Unix username:        developer01
    NT username:          
    Account Flags:        [U          ]
    User SID:             S-1-5-21-3921827401-1823912381-912830192-1001
    Primary Group SID:    S-1-5-21-3921827401-1823912381-912830192-513
    Full Name:            
    Home Directory:       \\STOR-NODE-01\developer01
    HomeDir Drive:        
    Logon Script:         
    Profile Path:         \\STOR-NODE-01\developer01\profile
    Domain:               STOR-NODE-01
    Account created:      Thu, 06 Aug 2026 12:50:12 UTC
    Password last set:    Thu, 06 Aug 2026 12:50:12 UTC
    ```

7.  Inspeccione la estructura binaria cruda de `passdb.tdb` utilizando `tdbdump`:
    ```bash
    sudo tdbdump /var/lib/samba/private/passdb.tdb | head -n 20
    ```
    *Expected Output snippet:*
    ```text
    key(13) = "USER_developer01\00"
    data(218) = "\00\00\00\00\09\70\35\67\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\07\64\65\76\65\6C\6F\70\65\72\30\31\00..."
    key(9) = "INFO/version\00"
    data(4) = "\04\00\00\00"
    key(19) = "RID_000003e9\00"
    data(13) = "developer01\00"
    ```

---

#### Preguntas de verificación — Ejercicio 2

*   **Pregunta 2.1:** ¿Cuál es la diferencia operativa específica entre las variables macro `%u`, `%U`, `%m`, `%I` y `%v` cuando se evalúan en tiempo de ejecución en `smb.conf`?
*   **Pregunta 2.2:** ¿Qué riesgo de seguridad se mitiga al configurar `server min protocol = SMB2_10` y `smb encrypt = required` a nivel global?

---

### Ejercicio 3: Operaciones en tiempo de ejecución, gestión de señales en vivo y mantenimiento de TDB

#### Instrucciones paso a paso

1.  Recargue la configuración de Samba dinámicamente sin terminar los sockets de clientes activos utilizando `smbcontrol`:
    ```bash
    sudo smbcontrol smbd reload-config
    ```
    *Expected Output:*
    ```text
    (No output indicates successful signal dispatch via IPC messaging sub-system)
    ```

2.  Incremente la verbosidad de registro de autenticación en vivo en tiempo de ejecución sin reiniciar el demonio:
    ```bash
    sudo smbcontrol smbd set-log-level 3
    ```

3.  Verifique la configuración actualizada del nivel de registro utilizando `smbcontrol`:
    ```bash
    sudo smbcontrol smbd profile status 2>/dev/null || sudo tail -n 10 /var/log/samba/log.smbd
    ```

4.  Realice una copia de seguridad en línea de los archivos de base de datos de estado y cuentas activos de Samba (`secrets.tdb` y `passdb.tdb`) utilizando `tdbbackup`:
    ```bash
    sudo mkdir -p /var/backups/samba
    sudo tdbbackup /var/lib/samba/private/passdb.tdb -s .bak /var/backups/samba/passdb.tdb.bak
    sudo tdbbackup /var/lib/samba/private/secrets.tdb -s .bak /var/backups/samba/secrets.tdb.bak
    ls -la /var/backups/samba/
    ```
    *Expected Output:*
    ```text
    total 16
    drwxr-xr-x 2 root root 4096 Aug  6 12:55 .
    drwxr-xr-x 3 root root 4096 Aug  6 12:55 ..
    -rw------- 1 root root 4218 Aug  6 12:55 passdb.tdb.bak
    -rw------- 1 root root 8192 Aug  6 12:55 secrets.tdb.bak
    ```

5.  Verifique la integridad de la base de datos TDB respaldada utilizando `tdbtool`:
    ```bash
    sudo tdbtool /var/backups/samba/passdb.tdb.bak check
    ```
    *Expected Output:*
    ```text
    Database integrity check passed. 3 records found.
    ```

6.  Restablezca el nivel de registro de nuevo al valor por defecto operacional (1):
    ```bash
    sudo smbcontrol smbd set-log-level 1
    ```

---

#### Preguntas de verificación — Ejercicio 3

*   **Pregunta 3.1:** ¿Por qué se prefiere `tdbbackup` sobre las utilidades de copia de archivos estándar (`cp` o `rsync`) al respaldar archivos de estado de Samba mientras `smbd` está ejecutándose?
*   **Pregunta 3.2:** ¿Qué mecanismo de IPC utiliza `smbcontrol` para comunicar modificaciones de estado a los demonios `smbd` y `nmbd` en ejecución?

---

## 4. Soluciones de verificación y respuestas técnicas

<details>
<summary><strong>Haga clic para desplegar Soluciones y Explicaciones Detalladas</strong></summary>

### Solución al Ejercicio 1

*   **Respuesta 1.1:**
    *   **Puerto 139 (SMB sobre NBT):** Opera encapsulando tramas SMB dentro de la capa NetBIOS Session Service (RFC 1001/1002). Esto requiere un handshake de establecimiento de sesión NetBIOS previo a la negociación de SMB.
    *   **Puerto 445 (Direct-Hosted SMB):** Elimina por completo la capa NetBIOS Session. Las PDUs (Protocol Data Units) de SMB se transmiten directamente sobre TCP crudo con un encabezado de longitud de 4 bytes.
    *   **Reducción de Overhead:** Conectarse exclusivamente a través del Puerto 445 elimina el overhead de encapsulamiento NetBIOS, elimina los RTTs (round-trips) adicionales de NBT Session Request durante el establecimiento de la conexión y omite las dependencias de resolución de nombres NetBIOS (`nmbd`).
*   **Respuesta 1.2:**
    *   Cuando un cliente se conecta al puerto TCP 445 o 139, el proceso padre principal `smbd` llama a `accept()` para obtener un nuevo socket de cliente.
    *   El proceso padre llama inmediatamente a `fork()` para crear un proceso hijo dedicado (PID `14312` en este caso) para manejar esa conexión de cliente específica.
    *   El proceso hijo hereda el socket del cliente, descarta privilegios innecesarios cuando corresponde, procesa solicitudes SMB y actualiza memoria compartida/archivos TDB (`locking.tdb`, `smbstatus`).
    *   Cuando el cliente finaliza la sesión SMB o interrumpe la conexión TCP, el proceso hijo cierra sus recursos y finaliza de manera limpia. El demonio padre `smbd` permanece ejecutándose continuamente para aceptar nuevas conexiones.

---

### Solución al Ejercicio 2

*   **Respuesta 2.1:**
    *   `%u`: Nombre de usuario efectivo de la sesión actual de Samba (después del mapeo de usuario de Samba).
    *   `%U`: Nombre de usuario solicitado por el cliente (la cadena de nombre de usuario en crudo suministrada por el cliente durante SMB Session Setup antes del mapeo).
    *   `%m`: Nombre NetBIOS de la máquina cliente (derivado de NBT o alternativa de DNS inverso).
    *   `%I`: Dirección IP de la máquina cliente (ej., `192.168.1.50`).
    *   `%v`: Versión de Samba actualmente en ejecución (ej., `4.19.5-Ubuntu`).
*   **Respuesta 2.2:**
    *   Configurar `server min protocol = SMB2_10` bloquea completamente los intentos de conexión utilizando **SMB1 / CIFS**. Esto mitiga vectores de vulnerabilidades críticas como exploits de ejecución remota de código orientados a fallas del analizador (parser) de SMB1 (ej., MS17-010 / EternalBlue), ataques de coerción de sesiones NULL y exploits de degradación de protocolo (downgrade).
    *   Configurar `smb encrypt = required` fuerza el cifrado AES-128-CCM / AES-128-GCM en todas las sesiones de transporte SMB3. Esto previene la escucha no autorizada de red (eavesdropping), la alteración de paquetes y el secuestro de sesión Man-In-The-Middle (MITM) en redes no confiables.

---

### Solución al Ejercicio 3

*   **Respuesta 3.1:**
    *   `tdbbackup` utiliza bloqueos de lectura por rango de bytes (byte-range read locks) internos en los encabezados y estructuras de registros de la base de datos TDB mientras recorre el archivo.
    *   Si se ejecuta `cp` o `rsync` mientras `smbd` está escribiendo activamente en un archivo TDB, una operación de escritura a mitad de la copia puede producir un respaldo de base de datos corrupto que contenga cadenas de hash parciales o registros divididos.
    *   `tdbbackup` garantiza la consistencia transaccional para la copia de destino incluso mientras `smbd` muta activamente la base de datos.
*   **Respuesta 3.2:**
    *   `smbcontrol` se comunica con los demonios de Samba en ejecución utilizando el **subsistema de mensajería** interno de Samba (`messages.tdb` o sockets de dominio Unix bajo `/var/lib/samba/cores/` / `/run/samba/`).
    *   Envía mensajes de señal estructurados (ej., `MSG_SMB_CONF_UPDATED`, `MSG_REQ_POOL_USAGE`) a IDs de proceso (PIDs) específicos o los transmite (broadcast) a todos los procesos `smbd`/`nmbd` registrados en la tabla TDB de mensajería.

</details>