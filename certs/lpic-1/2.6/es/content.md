# 2.6 Security

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En Platform Engineering y SRE, la seguridad dej\u00f3 de ser un per\u00edmetro est\u00e1tico (el *firewall* corporativo) para convertirse en un modelo **Zero Trust**. El problema arquitect\u00f3nico principal es el "Movimiento Lateral" y el "Escalamiento de Privilegios". Si un atacante compromete un contenedor o una aplicaci\u00f3n web expuesta, el objetivo del dise\u00f1o de seguridad del host es confinar el da\u00f1o exclusivamente a ese binario.

Para lograr esto, las herramientas cl\u00e1sicas de administraci\u00f3n de seguridad (SUID/SGID, sudo) deben ser configuradas meticulosamente bajo el **Principio de Menor Privilegio (PoLP)**. Adem\u00e1s, los datos est\u00e1ticos (*Data at Rest*) y en tr\u00e1nsito (*Data in Transit*) deben estar cifrados criptogr\u00e1ficamente. Si un disco duro de un servidor de base de datos se corrompe y debe ser desechado o es robado, el SRE garantiza que la informaci\u00f3n sea ilegible mediante el cifrado de bloques completo (LUKS) o cifrado asim\u00e9trico de secretos (GPG/SSH Keys).

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Escalamiento Controlado de Privilegios: `su` vs. `sudo` vs. `doas`

| Herramienta | Arquitectura de Autenticaci\u00f3n | Trazabilidad (Audit) | Caso de Uso SRE |
| :--- | :--- | :--- | :--- |
| **su** (Substitute User) | Requiere la contrase\u00f1a del usuario **destino** (ej. root). | Muy baja. Todo ocurre dentro del shell del destino. | Antipatr\u00f3n en producci\u00f3n. Compartir la clave de root anula el accountability. |
| **sudo** (Superuser Do) | Requiere la contrase\u00f1a del usuario **invocador** (quien ejecuta). | Alta. Loguea cada comando en `/var/log/auth.log`. | Est\u00e1ndar de la industria. Permite control granular (ej. "Juan solo puede reiniciar nginx"). |
| **doas** | Alternativa minimalista importada de OpenBSD. | Alta, pero sin los cientos de plugins complejos de sudo. | Entornos embebidos o distribuciones enfocadas en seguridad (Alpine) donde sudo es muy pesado. |

### Cifrado de Datos: Sim\u00e9trico vs. Asim\u00e9trico en Operaciones

| Criptograf\u00eda | Claves Involucradas | Rendimiento | Caso de Uso Pr\u00e1ctico (SRE) |
| :--- | :--- | :--- | :--- |
| **Sim\u00e9trica** (AES, ChaCha20) | Una sola clave compartida cifra y descifra. | Extremadamente r\u00e1pido. | Cifrado de disco (LUKS) o cifrado del tr\u00e1fico de red crudo (Wireguard). |
| **Asim\u00e9trica** (RSA, Ed25519) | Par de claves (P\u00fablica para cifrar, Privada para descifrar). | Lento y costoso computacionalmente. | Autenticaci\u00f3n SSH, firmas GPG para commits de Git, establecimiento inicial de t\u00faneles TLS. |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

### Configuraci\u00f3n Granular de Sudo (`/etc/sudoers.d/sre-team`)

El SRE configura el acceso para el equipo de guardia (On-Call) evitando que usen `sudo su -` (acceso root irrestricto), permitiendo \u00fanicamente reiniciar servicios cr\u00edticos y leer logs.

```text
# /etc/sudoers.d/sre-team
# NUNCA editar este archivo con vim/nano directo, usar siempre 'visudo -f /etc/sudoers.d/sre-team'
# para validar la sintaxis. Un error de sintaxis bloquea el acceso root de todo el servidor.

# Definir alias de comandos permitidos
Cmnd_Alias WEB_SERVICES = /bin/systemctl restart nginx.service, /bin/systemctl reload nginx.service
Cmnd_Alias LOG_READ = /usr/bin/journalctl, /usr/bin/cat /var/log/*

# El grupo %sre-oncall puede ejecutar los comandos permitidos sin pedir contrase\u00f1a (NOPASSWD)
# Ideal para integraci\u00f3n con herramientas de automatizaci\u00f3n.
%sre-oncall ALL=(root) NOPASSWD: WEB_SERVICES

# Pero para leer logs, s\u00ed requerimos que re-autentiquen su identidad
%sre-oncall ALL=(root) LOG_READ

# Prevenir el escape de shell: Impedir que invoquen editores como root que 
# permitir\u00edan un shell spawn (!/usr/bin/vim)
%sre-oncall ALL=(root) !/usr/bin/vim, !/usr/bin/nano
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Auditor\u00eda de Puertos Abiertos y Red

La primera regla de host security es reducir la superficie de ataque apagando demonios innecesarios.

```bash
# Validar qu\u00e9 procesos est\u00e1n escuchando p\u00fablicamente en todas las interfaces (0.0.0.0 o ::)
$ sudo ss -tulpn
Netid State  Recv-Q Send-Q  Local Address:Port   Peer Address:Port Process
tcp   LISTEN 0      128           0.0.0.0:22          0.0.0.0:*    users:(("sshd",pid=809,fd=3))
tcp   LISTEN 0      4096          0.0.0.0:80          0.0.0.0:*    users:(("nginx",pid=1120,fd=8))

# Con 'lsof' ver si alg\u00fan usuario no privilegiado abri\u00f3 un socket oculto
$ sudo lsof -i -P -n | grep LISTEN
sshd      809 root    3u  IPv4   18392      0t0  TCP *:22 (LISTEN)
```

### Gesti\u00f3n de Claves Criptogr\u00e1ficas (GPG)

Los SREs utilizan GnuPG (GPG) para cifrar secretos antes de subirlos a repositorios, o para firmar paquetes `.deb`/`.rpm`.

```bash
# Generar un par de claves (requiere entrop\u00eda/movimiento del rat\u00f3n)
$ gpg --full-generate-key

# Cifrar un archivo de secretos usando la clave p\u00fablica del destinatario (ej. ops@empresa.com)
$ gpg --encrypt --recipient ops@empresa.com db_password.txt
# Esto genera db_password.txt.gpg (binario cifrado que solo el due\u00f1o de la clave privada puede abrir)

# Descifrar el archivo (pedir\u00e1 la frase de paso de la clave privada)
$ gpg --decrypt db_password.txt.gpg > secret_decrypted.txt
```

### Seguridad de Conexi\u00f3n y T\u00faneles (SSH)

Deshabilitar la autenticaci\u00f3n por contrase\u00f1a es obligatorio en Cloud.

```bash
# Auditar c\u00f3mo se intentan conectar a nuestro servidor (Trazabilidad)
$ sudo grep "Failed password" /var/log/auth.log
Oct 25 10:15:32 prod-db-1 sshd[14523]: Failed password for invalid user admin from 192.0.2.45 port 54322 ssh2

# Generar una clave SSH moderna y matem\u00e1ticamente m\u00e1s fuerte y r\u00e1pida que RSA (Ed25519)
$ ssh-keygen -t ed25519 -C "sre-juan@empresa.com" -f ~/.ssh/id_ed25519_prod

# Configurar SSH local (~/.ssh/config) para usar esta clave autom\u00e1ticamente al saltar a Prod
Host *.prod.internal
    User sre-admin
    IdentityFile ~/.ssh/id_ed25519_prod
    # Desactivar PasswordAuthentication del lado del cliente
    PasswordAuthentication no
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Permisos SUID/SGID creando brechas de seguridad**:
   Cualquier ejecutable con el bit SUID (`s`) se ejecuta con los privilegios del **propietario** del archivo (usualmente root), no del invocador. Si un binario SUID tiene una vulnerabilidad de *buffer overflow*, un atacante gana acceso root instant\u00e1neo.
   *Auditor\u00eda:* Corre peri\u00f3dicamente este comando para encontrar binarios SUID/SGID escondidos en tu filesystem y alertas de anomal\u00edas:
   `sudo find / -type f -perm -4000 -o -perm -2000 -exec ls -l {} +`

2. **Bloqueo accidental (Lockout) de sudo**:
   Modificaste `/etc/sudoers` usando `nano` y cometiste un error de sintaxis. Ahora, cualquier comando `sudo` responde con `parse error in /etc/sudoers` y no tienes clave de root directo.
   *Resoluci\u00f3n:* Nunca edites el archivo directamente; usa SIEMPRE `visudo`. Si ya te quedaste bloqueado, la \u00fanica soluci\u00f3n es reiniciar el servidor, alterar los par\u00e1metros del gestor de arranque (GRUB) adjuntando `init=/bin/bash` al final de la l\u00ednea del kernel, arrancar en un shell de root directo, montar el disco como lectura-escritura (`mount -o remount,rw /`), usar `visudo` para arreglar el error, y reiniciar.

3. **SSH rechaza una clave p\u00fablica v\u00e1lida (Permission denied, publickey)**:
   A\u00f1adiste tu clave p\u00fablica a `~/.ssh/authorized_keys` en el servidor, pero SSH sigue pidiendo contrase\u00f1a o rechazando la conexi\u00f3n.
   *Diagn\u00f3stico:* El demonio SSH es extremadamente estricto con los permisos de los archivos (StrictModes). Si otros usuarios pueden modificar tus claves, SSH ignora el archivo por seguridad.
   *Resoluci\u00f3n:* Ajusta los permisos en el servidor destino exactamente as\u00ed:
   `chmod 700 ~/.ssh` y `chmod 600 ~/.ssh/authorized_keys`.

## 6. Referencias

* LPIC-1 Objetivos (Topic 110): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* Sudo Manual (sudoers): [https://www.sudo.ws/docs/man/sudoers.man/](https://www.sudo.ws/docs/man/sudoers.man/)
* SSH Security Guidelines (Mozilla INFOSEC): [https://infosec.mozilla.org/guidelines/openssh](https://infosec.mozilla.org/guidelines/openssh)
* GnuPG Privacy Guard Handbook: [https://www.gnupg.org/gph/en/manual.html](https://www.gnupg.org/gph/en/manual.html)