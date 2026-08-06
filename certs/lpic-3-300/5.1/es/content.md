# LPIC-3 Exam 300-300 (v3.0) | Topic 305: Linux Identity Management and File Sharing

---

## 1. Motivación Arquitectónica y Planteamiento del Problema en Producción

En los entornos empresariales heterogéneos modernos, la gestión de identidad, autenticación, control de acceso y almacenamiento en red a escala introduce una fricción operacional significativa. Los enfoques históricos—como la sincronización local de `/etc/passwd` mediante Sistemas de Gestión de Configuración (Ansible/Puppet), instancias de OpenLDAP independientes o despliegues fragmentados de Samba—no logran cumplir con la conformidad de seguridad Zero-Trust, los SLA de Alta Disponibilidad (HA) ni la interoperabilidad Cross-Realm fluida con Active Directory (AD).

```
                      +---------------------------------------------------+
                      |      FreeIPA / Red Hat IdM Domain Realm           |
                      |  (MIT Kerberos KDC + 389 Directory Server + CA)   |
                      +-------------------------+-------------------------+
                                                |
               +--------------------------------+--------------------------------+
               | (389-DS Multi-Master Replication)                               | (Kerberos Cross-Realm Trust)
               v                                                                 v
+-----------------------------+                                   +-----------------------------+
|    FreeIPA Replica Server   |                                   |  Microsoft Active Directory |
| (KDC + Directory Server+PKI)|                                   |       Forest (AD DS)        |
+--------------+--------------+                                   +--------------+--------------+
               |                                                                 |
               +-------------------------------+---------------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |        SSSD (System Security Services Daemon)  |
                        |      (Local Cache + ID Mapping + PAM/NSS)     |
                        +----------------------+------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        | Secure Network File System (NFSv4.2) Server   |
                        |  (RPCSEC_GSS / Kerberos sec=krb5p Protection)  |
                        +-----------------------------------------------+
```

### Desafíos Arquitectónicos Clave

1. **Identidad Centralizada y Single Sign-On (SSO):** Operar miles de nodos Linux requiere un controlador de dominio unificado que combine servicios de directorio LDAP (389 Directory Server), MIT Kerberos V5 para SSO basado en tickets, Dogtag PKI para la gestión automatizada de certificados X.509 y DNS BIND Integrado para la localización de servicios (registros `SRV`).
2. **Mecanismos de Alta Disponibilidad y Replicación:** FreeIPA emplea el motor Multi-Master Replication (MMR) de 389 Directory Server utilizando plugins de Changelog y replicación fraccional. La Alta Disponibilidad requiere un diseño de topología donde las actualizaciones de principales de Kerberos y las mutaciones del esquema LDAP se repliquen de forma asíncrona con resolución de conflictos gobernada por CSN (Change Sequence Numbers).
3. **Autorización de Almacenamiento Kerberizado (NFSv4.2 y RPCSEC_GSS):** El NFS heredado (`sec=sys`) se apoya en la confianza de UID/GID del lado del cliente sobre canales no cifrados, vulnerable a suplantación de IP (IP spoofing) y escalada de privilegios. Los entornos de producción requieren **RPCSEC_GSS** (RFC 2203) integrado con Kerberos V5 (`sec=krb5p`), aplicando cargas útiles firmadas criptográficamente por paquete, cifrado AES-256 CTS HMAC SHA1 y traducción de UID del lado del servidor mediante `idmapd` / SSSD.
4. **Federación de Identidades Cross-Realm:** Las infraestructuras empresariales a menudo mantienen Active Directory como el proveedor de identidad (IdP) autoritativo. FreeIPA aborda esto sin modificar el esquema de AD mediante el establecimiento de una **Kerberos 5 Cross-Realm Forest Trust** aprovechando el plugin `idmap_sssd` de SSSD para mapear dinámicamente Identificadores de Seguridad (SIDs) de Active Directory en UIDs/GIDs POSIX de Linux utilizando un hashing algorítmico determinista.

---

## 2. Comparativas Técnicas y Análisis de Compromisos (Trade-offs)

### 2.1 Comparación de Arquitecturas de Gestión de Identidad

| Característica / Métrica | FreeIPA / Red Hat IdM | SSSD Direct Join a AD | OpenLDAP Heredado + Kerberos | Samba Winbind |
| :--- | :--- | :--- | :--- | :--- |
| **Controlador de Dominio Primario** | Sí (MIT KDC + 389-DS) | No (Confía en AD DC) | Integración Manual | Sí (Samba AD DC) |
| **Almacenamiento de Atributos POSIX** | Nativo en LDAP de FreeIPA | Calculado localmente mediante SSSD o leído de AD | Nativo en LDAP | Calculado a partir del SID |
| **Integración con Active Directory** | Cross-Realm Forest Trust Nativo | Join Directo de Dominio Kerberos/LDAP | Configuración de Trust Manual | Join a Dominio de AD |
| **Gestión de PKI / Certificados** | Dogtag CA / ACME Integrado | Externa (Microsoft CA / Cert-Manager) | Configuración Manual de OpenSSL/Vault | Externa |
| **Gestión de HBAC / Sudo** | Reglas Centralizadas de HBAC y Sudo Nativas | Limitado a Group Policy de AD / Sudo Local | Esquemas LDAP Personalizados | Sudoers Local / GPO |
| **Sobrecarga Operativa** | Moderada (Dominio Linux Dedicado) | Baja (Sin infraestructura de DC Linux) | Muy Alta (Esquema/cableado personalizado) | Alta (Complejidad del protocolo SMB) |

### 2.2 Comparación de Sabores de Seguridad de NFSv4

| Sabor de Seguridad | Autenticación | Protección de Integridad | Cifrado de Carga Útil | Impacto en Rendimiento | Protección contra Amenazas |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `sec=sys` | UID/GID declarado por el cliente | Ninguna | Ninguno | 0% Sobrecarga | Ninguna (Vulnerable a suplantación de IP/UID) |
| `sec=krb5` | Ticket Kerberos V5 | Ninguna | Ninguno | Bajo (Solo Handshake inicial) | Protege contra usuarios no autenticados |
| `sec=krb5i` | Ticket Kerberos V5 | Hash Criptográfico HMAC-SHA1 | Ninguno | Moderado (Cálculo de Checksum por paquete) | Previene la manipulación Man-in-the-Middle (MitM) |
| `sec=krb5p` | Ticket Kerberos V5 | Hash Criptográfico HMAC-SHA1 | Cifrado de Carga Útil AES-256-CTS | Alto (Sobrecarga criptográfica por E/S) | Confidencialidad e integridad completas |

### 2.3 Modelos de Trust Cross-Realm

| Dimensión | Forest Trust de FreeIPA a AD | Sincronización de Active Directory (WinSync) | Join Directo a AD mediante SSSD |
| :--- | :--- | :--- | :--- |
| **Topología de Trust** | Forest Trust Transitivo de 2 vías o 1 vía | Sincronización de cuentas basada en Polling | Vinculación directa Cliente a AD |
| **Mecánica de Kerberos** | Emisión de tickets de referencia cross-realm por KDC | Mapeo de principal local tras copia de cuenta | Ticket Granting Ticket (TGT) Nativo de AD |
| **Transitividad de Kerberos** | Soportada entre dominios | No aplica | Manejada directamente por los DCs de AD |
| **Alteraciones del Esquema** | Cero cambios requeridos en los DCs de AD | Requiere extensiones del esquema POSIX en AD | Opcional (Soporta Mapeo Algorítmico) |
| **Aislamiento de Fallos** | Alto (FreeIPA operativo si caen los enlaces a AD) | Bajo (Hashes de contraseñas desincronizados tras fallo) | Medio (La caché local maneja caídas) |

---

## 3. Infraestructura de Producción y Manifiestos Sintácticamente Válidos

### 3.1 Despliegue Automatizado: Playbook de Ansible para el Servidor Maestro de FreeIPA

```yaml
---
- name: Deploy Production FreeIPA Master Domain Controller
  hosts: ipa_masters
  become: true
  vars:
    ipaserver_domain: infra.internal
    ipaserver_realm: INFRA.INTERNAL
    ipaserver_server_fqdn: idm01.infra.internal
    ipaserver_ip_addresses:
      - 10.100.10.5
    ipaserver_setup_dns: true
    ipaserver_auto_forwarders: true
    ipaserver_forwarders:
      - 10.100.0.2
      - 10.100.0.3
    ipapassword: "VaultSecureAdminPassword123!"
    ipadm_password: "VaultSecureDSManagerPassword123!"
  collections:
    - freeipa.ansible_freeipa
  tasks:
    - name: Ensure Hostname matches FQDN
      ansible.builtin.hostname:
        name: "{{ ipaserver_server_fqdn }}"

    - name: Configure Firewall Rules for FreeIPA Topology
      ansible.posix.firewalld:
        service: "{{ item }}"
        state: enabled
        permanent: true
        immediate: true
      loop:
        - freeipa-ldap
        - freeipa-ldaps
        - dns
        - ntp
        - krb5

    - name: Install FreeIPA Server Package Suite
      ansible.builtin.package:
        name:
          - freeipa-server
          - freeipa-server-dns
          - freeipa-server-trust-ad
        state: present

    - name: Run FreeIPA Server Installation
      include_role:
        name: ipaserver
```

---

### 3.2 Configuración del Cliente SSSD Empresarial (`/etc/sssd/sssd.conf`)

```ini
[sssd]
services = nss, pam, sudo, ssh
config_file_version = 2
domains = infra.internal

[domain/infra.internal]
id_provider = ipa
auth_provider = ipa
access_provider = ipa
chpass_provider = ipa
ipa_server = _srv_, idm01.infra.internal, idm02.infra.internal
ipa_domain = infra.internal
ipa_hostname = app01.infra.internal
krb5_realm = INFRA.INTERNAL

# Security Hardening & Performance Optimizations
cache_credentials = True
entry_cache_timeout = 600
entry_cache_nowait_percentage = 50
krb5_store_password_if_offline = True
ssl_default_verify_scheme = ipa

# Dynamic ID Mapping Configuration for AD Cross-Realm Trust
ldap_id_mapping = True
ldap_idmap_range_min = 200000
ldap_idmap_range_max = 200000000
ldap_idmap_range_size = 200000
ldap_idmap_default_domain_sid = S-1-5-21-3623811015-3361044348-30300820
ldap_idmap_autorid_compatibility = True

# SSSD Sudo Integration
sudo_provider = ipa
ipa_automated_backup_server = True
```

---

### 3.3 Configuración del Cliente Kerberos v5 de Producción (`/etc/krb5.conf`)

```ini
[libdefaults]
    default_realm = INFRA.INTERNAL
    dns_lookup_realm = true
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    udp_preference_limit = 0
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    INFRA.INTERNAL = {
        kdc = idm01.infra.internal:88
        kdc = idm02.infra.internal:88
        master_kdc = idm01.infra.internal:88
        admin_server = idm01.infra.internal:749
        default_domain = infra.internal
        pkinit_anchors = FILE:/etc/ipa/ca.crt
    }

[domain_realm]
    .infra.internal = INFRA.INTERNAL
    infra.internal = INFRA.INTERNAL

[plugins]
    certauth = {
        module = ipa:/usr/lib64/sssd/modules/sssd_krb5_localauth_plugin.so
    }
```

---

### 3.4 Exportación Kerberizada NFSv4.2 de Producción (`/etc/exports` y `/etc/idmapd.conf`)

#### Lado del Servidor: `/etc/exports`
```
/exports/production_storage  *.infra.internal(rw,sync,no_subtree_check,sec=krb5p:krb5i:krb5,root_squash)
```

#### Configuración de Mapeo de ID de NFS: `/etc/idmapd.conf`
```ini
[General]
Verbosity = 2
Pipefs-Directory = /var/lib/nfs/rpc_pipefs
Domain = infra.internal

[Mapping]
Nobody-User = nobody
Nobody-Group = nobody

[Translation]
Method = sssd
```

---

## 4. Comandos CLI Reales y Logs de Ejecución de Terminal

### 4.1 Inicialización del Controlador de Dominio FreeIPA

```bash
$ sudo ipa-server-install \
    --realm=INFRA.INTERNAL \
    --domain=infra.internal \
    --ds-password="VaultSecureDSManagerPassword123!" \
    --admin-password="VaultSecureAdminPassword123!" \
    --setup-dns \
    --forwarder=10.100.0.2 \
    --no-ntp \
    --unattended
```

```output
The log file for this installation can be found in /var/log/ipaserver-install.log
==============================================================================
This program will set up the FreeIPA Server.
Directory Manager password defined
IPA admin password defined

Installing Directory Server (389-DS)
  [1/8]: creating directory server instance
  [2/8]: configuring certmonger
  [3/8]: setting up initial data
  [4/8]: configuring SSL for directory server
  [5/8]: configuring replication version plugin
  [6/8]: enabling IPA plugin
  [7/8]: configuring schema extensions
  [8/8]: starting directory server instance
Done configuring Directory Server.

Configuring Kerberos KDC (MIT Kerberos)
  [1/7]: adding kerberos principal entries
  [2/7]: configuring KDC
  [3/7]: starting KDC
  [4/7]: configuring admin service
  [5/7]: starting admin service
  [6/7]: creating Master key
  [7/7]: initializing account lockout policy
Done configuring Kerberos KDC.

Setup complete of FreeIPA Server version 4.10.2!
```

---

### 4.2 Gestión de Entidades a través de la CLI de `ipa`

#### Autenticar el Principal Admin
```bash
$ kinit admin
```
```output
Password for admin@INFRA.INTERNAL: 
```

```bash
$ klist
```
```output
Ticket cache: KCM:0:19284
Default principal: admin@INFRA.INTERNAL

Valid starting       Expires              Service principal
08/06/26 13:00:01  08/07/26 13:00:01  krbtgt/INFRA.INTERNAL@INFRA.INTERNAL
	renew until 08/13/26 13:00:01
```

#### Crear Entidades de Usuario, Grupo y Host
```bash
$ ipa user-add sre_developer --first="SRE" --last="Engineer" --password
```
```output
Password: 
Enter Password again to verify: 
---------------------------------
Added user "sre_developer"
---------------------------------
  User login: sre_developer
  First name: SRE
  Last name: Engineer
  Full name: SRE Engineer
  Home directory: /home/sre_developer
  GECOS: SRE Engineer
  Login shell: /bin/bash
  Principal name: sre_developer@INFRA.INTERNAL
  Principal alias: sre_developer@INFRA.INTERNAL
  UID: 754200001
  GID: 754200001
```

```bash
$ ipa group-add devops_team --desc="DevOps SRE Core Team"
```
```output
----------------------------
Added group "devops_team"
----------------------------
  Group name: devops_team
  Description: DevOps SRE Core Team
  GID: 754200002
```

```bash
$ ipa group-add-member devops_team --users=sre_developer
```
```output
  Group name: devops_team
  Description: DevOps SRE Core Team
  GID: 754200002
  Member users: sre_developer
-------------------------
Number of members added 1
-------------------------
```

#### Aprovisionar Principal de Servicio NFS y Emitir Keytab
```bash
$ ipa service-add nfs/nfs-server.infra.internal
```
```output
-------------------------------------------------------------------
Added service "nfs/nfs-server.infra.internal@INFRA.INTERNAL"
-------------------------------------------------------------------
  Principal name: nfs/nfs-server.infra.internal@INFRA.INTERNAL
  Principal alias: nfs/nfs-server.infra.internal@INFRA.INTERNAL
  Managed by: nfs-server.infra.internal
```

```bash
$ sudo ipa-getkeytab \
    -p nfs/nfs-server.infra.internal@INFRA.INTERNAL \
    -k /etc/krb5.keytab
```
```output
Keytab successfully retrieved and stored in: /etc/krb5.keytab
```

```bash
$ sudo ktutil
```
```output
ktutil:  read_kt /etc/krb5.keytab
ktutil:  list
slot KVNO Principal
---- ---- ---------------------------------------------------------------------
   1    1 nfs/nfs-server.infra.internal@INFRA.INTERNAL
   2    1 nfs/nfs-server.infra.internal@INFRA.INTERNAL
```

---

### 4.3 Configuración de Trust Cross-Realm con Active Directory

```bash
$ sudo ipa-adtrust-install \
    --netbios-name=INFRA \
    --add-sids \
    --unattended
```
```output
Configuring CIFS Services...
  [1/4]: setting up CIFS configuration
  [2/4]: adding admin principal to Samba keytab
  [3/4]: starting Samba service (smb)
  [4/4]: starting Winbind service (winbind)
Done configuring CIFS Services.
IPA AD Trust installation successful.
```

```bash
$ ipa trust-add \
    --type=ad corporate.local \
    --admin Administrator \
    --password
```
```output
Active Directory domain administrator's password: 
--------------------------------------------------
Added Active Directory trust for "corporate.local"
--------------------------------------------------
  Realm name: corporate.local
  Domain netbios name: CORPORATE
  Domain Security Identifier: S-1-5-21-3623811015-3361044348-30300820
  Trust type: Active Directory domain
  Trust direction: Two-way trust
```

---

### 4.4 Montar Recurso Compartido NFS Kerberizado en el Cliente

```bash
$ sudo mount -t nfs4 -o sec=krb5p idm01.infra.internal:/exports/production_storage /mnt/secure_data
```

```bash
$ df -T -h /mnt/secure_data
```
```output
Filesystem                                    Type  Size  Used Avail Use% Mounted on
idm01.infra.internal:/exports/production_storage nfs4   500G   45G  456G  10% /mnt/secure_data
```

```bash
$ mount | grep secure_data
```
```output
idm01.infra.internal:/exports/production_storage on /mnt/secure_data type nfs4 (rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=krb5p,clientaddr=10.100.10.12,local_lock=none,addr=10.100.10.5)
```

---

## 5. Verificación, Diagnósticos en Producción y Guía de Resolución de Problemas

### 5.1 Matriz del Sistema: Modos de Fallo y Remediación

```
+------------------------------------+------------------------------------+------------------------------------+
| Symptom / Error                    | Root Cause                         | Diagnostic Command & Fix           |
+------------------------------------+------------------------------------+------------------------------------+
| kinit: Clock skew too great        | NTP drift between client and KDC   | chronyc tracking                   |
| (Error 37)                         | exceeds 300 seconds default.       | chronyc -a makestep                |
+------------------------------------+------------------------------------+------------------------------------+
| NFS mount hangs or gives           | Service principal missing in       | klist -k /etc/krb5.keytab          |
| "Permission Denied" (sec=krb5p)    | keytab or GSSProxy inactive.       | systemctl restart gssproxy         |
+------------------------------------+------------------------------------+------------------------------------+
| Files owned by nobody:nobody       | Domain mismatch in idmapd.conf     | nfsidmap -c                        |
| on NFSv4 volume                    | or SSSD NSS mapping failed.        | sssctl domain-status               |
+------------------------------------+------------------------------------+------------------------------------+
| ipa trust-add fails with           | DNS SRV record lookup for AD       | dig SRV _ldap._tcp.corporate.local |
| "Active Directory domain unreachable" DC failed over DNS topology. | verify named forwarding rules.     |
+------------------------------------+------------------------------------+------------------------------------+
```

---

### 5.2 Diagnósticos Profundos de SSSD

#### Habilitar Depuración en `/etc/sssd/sssd.conf`
```ini
[domain/infra.internal]
debug_level = 9
```

#### Secuencia de Ejecución de Diagnóstico
```bash
$ sudo systemctl restart sssd
$ sudo sssctl domain-status infra.internal
```
```output
Online status: Online

Active servers:
IPA: idm01.infra.internal

Discovered servers:
- idm01.infra.internal
- idm02.infra.internal
```

```bash
$ sudo sssctl user-checks sre_developer
```
```output
user-checks requested for user sre_developer
sssd_nss user lookup result:
  Username: sre_developer
  UID: 754200001
  GID: 754200001
  Home directory: /home/sre_developer
  Shell: /bin/bash

pam_acct_mgmt result for account sre_developer: Success
```

#### Inspeccionar Flujos de Logs en Vivo
```bash
$ sudo tail -n 25 /var/log/sssd/sssd_infra.internal.log
```
```output
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [be_get_account_info] (0x0200): Got request for [0x1][BE_REQ_USER][1][name=sre_developer]
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [sdap_get_users_send] (0x0400): Requesting info for user sre_developer from LDAP
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [sdap_get_generic_ext_step] (0x0400): calling ldap_search_ext with [(&(uid=sre_developer)(objectClass=posixAccount))]
(2026-08-06 13:15:02): [sssd[be[infra.internal]]] [sdap_save_user] (0x0400): Save user entry: sre_developer
```

---

### 5.3 Rastreo de Kerberos y Depuración de GSS-API

#### Rastrear Handshakes de Kerberos
Establecé la variable `KRB5_TRACE` para interceptar las llamadas a la API directamente:

```bash
$ env KRB5_TRACE=/dev/stdout kinit sre_developer
```
```output
[19302] 1786036502.12000: Getting initial tickets for sre_developer@INFRA.INTERNAL
[19302] 1786036502.12001: Sending request (182 bytes) to INFRA.INTERNAL
[19302] 1786036502.12002: Resolving KDC hostname idm01.infra.internal
[19302] 1786036502.12003: Initiating TCP connection to 10.100.10.5:88
[19302] 1786036502.12004: Received answer (1520 bytes) from 10.100.10.5:88
[19302] 1786036502.12005: Selected etype aes256-cts-hmac-sha1-96
[19302] 1786036502.12006: PKINIT client has no configured anchors
[19302] 1786036502.12007: AS key verified successfully
[19302] 1786036502.12008: Storing krbtgt/INFRA.INTERNAL@INFRA.INTERNAL in KCM:0:19284
```

---

### 5.4 Verificación de la Topología de Replicación del Directory Server

Verificá el estado del acuerdo multi-master entre controladores de dominio:

```bash
$ sudo ipa-replica-manage list-help idm01.infra.internal
```
```bash
$ sudo ipa-replica-manage list idm01.infra.internal
```
```output
idm02.infra.internal: replica
```

```bash
$ sudo ipa-replica-manage force-sync --from idm02.infra.internal
```
```output
Directory Manager password: 
Endpoint idm02.infra.internal updated successfully.
```

```bash
$ sudo tail -n 20 /var/log/dirsrv/slapd-INFRA-INTERNAL/errors
```
```output
[06/Aug/2026:13:20:00.123456789 +0000] NSERLugin - agmt="cn=meToidm02.infra.internal,cn=replica,cn=dc\3Dinfra\2Cdc\3Dinternal,cn=mapping tree,cn=config" (idm02:389): Replication agreement is in sync.
```

---

## 6. Referencias

- [Linux Professional Institute: LPIC-3 300 Exam Objectives](https://www.lpi.org/our-certifications/lpic-3-300-overview/)
- [FreeIPA Official Architecture & Documentation](https://www.freeipa.org/page/Documentation)
- [Red Hat Enterprise Linux Identity Management Design & Deployment](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/accessing_identity_management_services/)
- [RFC 7530: Network File System (NFS) version 4 Protocol](https://datatracker.ietf.org/doc/html/rfc7530)
- [RFC 4120: The Kerberos Network Authentication Service (V5)](https://datatracker.ietf.org/doc/html/rfc4120)
- [RFC 2203: RPCSEC_GSS Protocol Specification](https://datatracker.ietf.org/doc/html/rfc2203)
- [SSSD Project Documentation and Architecture Guides](https://sssd.io/documentation/index.html)