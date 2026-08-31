# 110.3 Asegurar los datos con cifrado — Ejercicios guiados

**Certificación:** LPIC-1 (Exámenes 101-500 / 102-500), versión 5.0
**Objetivo 110.3:** Configuración y uso del cliente OpenSSH, configuración, uso y revocación de GnuPG.
**Archivos y comandos clave evaluados:** `ssh`, `ssh-keygen`, `ssh-agent`, `ssh-add`, `~/.ssh/id_rsa[.pub]`, `~/.ssh/id_dsa[.pub]`, `~/.ssh/id_ecdsa[.pub]`, `~/.ssh/id_ed25519[.pub]`, `/etc/ssh/ssh_host_*`, `~/.ssh/authorized_keys`, `~/.ssh/known_hosts`, `ssh_known_hosts`, `gpg`, `gpg-agent`, `~/.gnupg/`.

---

## Preparación del laboratorio

Necesitás un sistema Linux con `openssh-client`, `openssh-server` y `gnupg` instalados, y un `sshd` en ejecución. Cada "host remoto" de este laboratorio es `localhost` conectado sobre el protocolo SSH real — las rutas de código del cliente y del servidor son idénticas a las de una conexión remota, así que no hay nada simulado.

```bash
# Debian/Ubuntu
sudo apt-get install -y openssh-client openssh-server gnupg
# RHEL/Fedora/openSUSE
sudo dnf install -y openssh-clients openssh-server gnupg2

sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd
systemctl is-active ssh sshd 2>/dev/null | grep -q active && echo "sshd running"
```

Registrá tu punto de partida para poder comparar más adelante:

```bash
ssh -V
gpg --version | head -2
```

Salida esperada (las versiones van a diferir; anotá las tuyas):

```
OpenSSH_9.6p1 Ubuntu-3ubuntu13.5, OpenSSL 3.0.13 30 Jan 2024
gpg (GnuPG) 2.4.4
libgcrypt 1.10.3
```

> A lo largo de este documento, `student` es tu nombre de usuario. Sustituilo por el tuyo.

---

## Ejercicio 1 — Generar e inspeccionar pares de claves SSH

**Objetivo:** producir claves de tres algoritmos, entender el formato en disco y leer una huella digital tal como la lee `sshd`.

1. Creá el directorio de claves del cliente con la propiedad y el modo correctos:

   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   ls -ld ~/.ssh
   ```

   ```
   drwx------ 2 student student 4096 Aug 31 10:02 /home/student/.ssh
   ```

2. Generá un par de claves Ed25519 con un comentario y una passphrase. Cuando te pida el archivo, aceptá el valor por defecto; cuando te pida la passphrase, escribí `LabPass123` dos veces.

   ```bash
   ssh-keygen -t ed25519 -C "lpic1-lab-$(hostname -s)"
   ```

   ```
   Generating public/private ed25519 key pair.
   Enter file in which to save the key (/home/student/.ssh/id_ed25519):
   Enter passphrase (empty for no passphrase):
   Enter same passphrase again:
   Your identification has been saved in /home/student/.ssh/id_ed25519
   Your public key has been saved in /home/student/.ssh/id_ed25519.pub
   The key fingerprint is:
   SHA256:0kR9nJmYb6Qb2t/9m3n0lVQ1uJ0uS3xW4qz9m8dK1cE lpic1-lab-workstation
   The key's randomart image is:
   +--[ED25519 256]--+
   |        .o+.     |
   |       . o.o     |
   ...
   +----[SHA256]-----+
   ```

3. Generá una clave RSA de 4096 bits en un archivo no predeterminado, sin passphrase, de forma no interactiva:

   ```bash
   ssh-keygen -t rsa -b 4096 -N '' -C "rsa-lab" -f ~/.ssh/id_rsa_lab
   ssh-keygen -t ecdsa -b 521 -N '' -C "ecdsa-lab" -f ~/.ssh/id_ecdsa_lab
   ls -l ~/.ssh/
   ```

   ```
   -rw------- 1 student student 3389 Aug 31 10:05 id_ecdsa_lab
   -rw-r--r-- 1 student student  283 Aug 31 10:05 id_ecdsa_lab.pub
   -rw------- 1 student student  399 Aug 31 10:04 id_ed25519
   -rw-r--r-- 1 student student   99 Aug 31 10:04 id_ed25519.pub
   -rw------- 1 student student 3381 Aug 31 10:05 id_rsa_lab
   -rw-r--r-- 1 student student  743 Aug 31 10:05 id_rsa_lab.pub
   ```

4. Mirá las dos mitades de uno de los pares:

   ```bash
   head -1 ~/.ssh/id_ed25519
   cat  ~/.ssh/id_ed25519.pub
   ```

   ```
   -----BEGIN OPENSSH PRIVATE KEY-----
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9zXxk0k9r4t2c1... lpic1-lab-workstation
   ```

5. Imprimí las huellas digitales — primero la forma SHA256/base64 por defecto, después la forma heredada MD5 en hexadecimal que todavía muestran los servidores viejos:

   ```bash
   ssh-keygen -l -f ~/.ssh/id_ed25519.pub
   ssh-keygen -l -E md5 -f ~/.ssh/id_ed25519.pub
   ssh-keygen -lv -f ~/.ssh/id_rsa_lab.pub | head -3
   ```

   ```
   256 SHA256:0kR9nJmYb6Qb2t/9m3n0lVQ1uJ0uS3xW4qz9m8dK1cE lpic1-lab-workstation (ED25519)
   256 MD5:af:5c:1b:90:2d:7e:44:03:9a:11:c8:6f:e2:0d:73:b4 lpic1-lab-workstation (ED25519)
   4096 SHA256:tR3v2QpL8m0aX9c1... rsa-lab (RSA)
   ```

6. Demostrá que la clave pública se deriva de la privada, no se guarda de forma independiente. Borrá el archivo `.pub`, regeneralo y compará:

   ```bash
   cp ~/.ssh/id_rsa_lab.pub /tmp/original.pub
   rm ~/.ssh/id_rsa_lab.pub
   ssh-keygen -y -f ~/.ssh/id_rsa_lab > ~/.ssh/id_rsa_lab.pub
   diff <(cut -d' ' -f1,2 /tmp/original.pub) <(cut -d' ' -f1,2 ~/.ssh/id_rsa_lab.pub) && echo "IDENTICAL key material"
   ```

   ```
   IDENTICAL key material
   ```

7. Cambiá la passphrase de la clave Ed25519 sin regenerarla (vieja: `LabPass123`, nueva: `NewLabPass456`):

   ```bash
   ssh-keygen -p -f ~/.ssh/id_ed25519
   ```

   ```
   Enter old passphrase:
   Key has comment 'lpic1-lab-workstation'
   Enter new passphrase (empty for no passphrase):
   Enter same passphrase again:
   Your identification has been saved with the new passphrase.
   ```

### Comprobá lo aprendido — bloque 1

1. `ssh-keygen -t ed25519 -b 4096` — ¿qué pasa, y por qué?
2. El paso 6 regeneró `id_rsa_lab.pub` a partir de la clave privada, pero el `diff` comparó solo los campos 1 y 2. ¿Qué campo se excluyó deliberadamente y qué te dice eso sobre dónde vive el comentario?
3. ¿Cuál de los dos archivos de un par puede ser legible por todo el mundo, y cuál hace que `ssh` se niegue a funcionar si lo es?
4. Un administrador de servidor te manda por correo `af:5c:1b:90:...` como huella del host, pero tu cliente imprime `SHA256:0kR9...`. Dá el comando exacto que te permite compararlas.
5. Después de `ssh-keygen -p`, ¿hay que redistribuir el archivo de clave pública a cada servidor que confía en ella?

---

## Ejercicio 2 — Autenticación por clave pública y `authorized_keys`

**Objetivo:** instalar una clave, romperla deliberadamente y leer el lado del servidor de la falla.

1. Confirmá que la autenticación por contraseña funciona antes de cambiar nada, y después instalá la clave pública Ed25519 en tu propio `authorized_keys`:

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub student@localhost
   ```

   ```
   /usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed: "/home/student/.ssh/id_ed25519.pub"
   /usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed
   /usr/bin/ssh-copy-id: INFO: 1 key(s) remain to be installed -- if you are prompted now it is to install the new keys
   student@localhost's password:

   Number of key(s) added: 1
   ```

2. Inspeccioná qué se escribió y con qué permisos:

   ```bash
   ls -l ~/.ssh/authorized_keys
   cat ~/.ssh/authorized_keys
   ```

   ```
   -rw------- 1 student student 99 Aug 31 10:12 /home/student/.ssh/authorized_keys
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9zXxk0k9r4t2c1... lpic1-lab-workstation
   ```

3. Autenticate con la clave. Te va a pedir la *passphrase de la clave*, no la contraseña de la cuenta — notá la diferencia en el texto del prompt:

   ```bash
   ssh -i ~/.ssh/id_ed25519 student@localhost 'echo AUTHENTICATED as $(id -un) from $SSH_CONNECTION'
   ```

   ```
   Enter passphrase for key '/home/student/.ssh/id_ed25519':
   AUTHENTICATED as student from 127.0.0.1 43210 127.0.0.1 22
   ```

4. Rompé los permisos a propósito y observá el rechazo del lado del cliente:

   ```bash
   chmod 644 ~/.ssh/id_ed25519
   ssh -i ~/.ssh/id_ed25519 student@localhost true
   ```

   ```
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   @         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   Permissions 0644 for '/home/student/.ssh/id_ed25519' are too open.
   It is required that your private key files are NOT accessible by others.
   This private key will be ignored.
   ```

   ```bash
   chmod 600 ~/.ssh/id_ed25519
   ```

5. Ahora rompé el lado del *servidor* y leé el log. Hacé que el directorio home sea escribible por el grupo, lo que dispara `StrictModes yes`:

   ```bash
   chmod g+w ~
   ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
       -i ~/.ssh/id_ed25519 student@localhost true
   ```

   ```
   student@localhost: Permission denied (publickey).
   ```

   ```bash
   sudo journalctl -u ssh -u sshd -n 5 --no-pager | tail -3
   ```

   ```
   sshd[4471]: Authentication refused: bad ownership or modes for directory /home/student
   ```

   ```bash
   chmod g-w ~
   ```

6. Restringí la clave. Antepone opciones para que esta clave solo pueda ejecutar un comando y no pueda reenviar nada:

   ```bash
   cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
   sed -i '1s|^|restrict,command="/bin/date -u" |' ~/.ssh/authorized_keys
   head -c 80 ~/.ssh/authorized_keys; echo
   ssh -i ~/.ssh/id_ed25519 student@localhost 'rm -rf /tmp/whatever'
   ```

   ```
   restrict,command="/bin/date -u" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9z
   Mon Aug 31 10:19:44 UTC 2026
   ```

7. Restaurá la entrada sin restricciones:

   ```bash
   mv ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys
   ```

### Comprobá lo aprendido — bloque 2

6. En el paso 3 el prompt fue `Enter passphrase for key ...`. ¿Cuál habría sido el prompt si el servidor no hubiera aceptado la clave, y qué prueba cada prompt sobre *dónde* se verifica el secreto?
7. `ssh-copy-id` creó `~/.ssh/authorized_keys` con modo 600. ¿El modo 644 rompería la autenticación bajo el `sshd_config` por defecto? ¿Y el 664?
8. ¿Por qué la falla del paso 5 apareció solo en el journal del servidor y no en la salida de `ssh -v` del cliente?
9. ¿Cuál es la diferencia entre la palabra clave `restrict` y escribir `no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty` de forma explícita?
10. Con `command="/bin/date -u"` en su lugar, el usuario escribió `rm -rf /tmp/whatever`. ¿A dónde fue esa cadena? Nombrá la variable de entorno que todavía la transporta en el servidor.

---

## Ejercicio 3 — Claves de host, `known_hosts` y verificación del host

**Objetivo:** entender la identidad del servidor, el modelo TOFU y cómo reparar una discrepancia de forma segura.

1. Listá las claves de host del servidor y sus huellas digitales:

   ```bash
   sudo ls -l /etc/ssh/ssh_host_*
   for k in /etc/ssh/ssh_host_*_key.pub; do sudo ssh-keygen -l -f "$k"; done
   ```

   ```
   -rw------- 1 root root  505 Jul  2 09:11 /etc/ssh/ssh_host_ecdsa_key
   -rw-r--r-- 1 root root  174 Jul  2 09:11 /etc/ssh/ssh_host_ecdsa_key.pub
   -rw------- 1 root root  399 Jul  2 09:11 /etc/ssh/ssh_host_ed25519_key
   -rw-r--r-- 1 root root   94 Jul  2 09:11 /etc/ssh/ssh_host_ed25519_key.pub
   -rw------- 1 root root 2590 Jul  2 09:11 /etc/ssh/ssh_host_rsa_key
   -rw-r--r-- 1 root root  563 Jul  2 09:11 /etc/ssh/ssh_host_rsa_key.pub
   256 SHA256:hQ2m8Lp0aVc3... root@workstation (ECDSA)
   256 SHA256:Wc9Xy1Zt6Nn4... root@workstation (ED25519)
   3072 SHA256:Kk7Ff3Rr2Dd8... root@workstation (RSA)
   ```

2. Obtené las mismas claves por la red del mismo modo que lo hace un cliente, sin conectar una sesión:

   ```bash
   ssh-keyscan -t ed25519 localhost 2>/dev/null
   ssh-keyscan -t ed25519 localhost 2>/dev/null | ssh-keygen -l -f -
   ```

   ```
   localhost ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9k2v0mQ...
   256 SHA256:Wc9Xy1Zt6Nn4... localhost (ED25519)
   ```

   Compará esta huella con la impresa en el paso 1 — tienen que coincidir.

3. Inspeccioná tu `known_hosts`. En los sistemas de la familia Debian `HashKnownHosts yes` es el valor por defecto, así que los nombres de host se guardan como HMAC:

   ```bash
   head -2 ~/.ssh/known_hosts
   ```

   ```
   |1|Ry8Zl3pQ0nK2m9d4Tt7wXcVbA1s=|Uu6Yh2Nn0Kk8Ff4Dd1Ss9Aa3Qq5= ssh-ed25519 AAAAC3Nza...
   ```

4. Como está hasheado, `grep` no sirve. Usá la búsqueda incorporada:

   ```bash
   ssh-keygen -F localhost
   ```

   ```
   # Host localhost found: line 1
   |1|Ry8Zl3pQ0nK2m9d4Tt7wXcVbA1s=|Uu6Yh2Nn0Kk8Ff4Dd1Ss9Aa3Qq5= ssh-ed25519 AAAAC3Nza...
   ```

5. Simulá un cambio de clave de host (reconstrucción del servidor, o un ataque). Corrompé la entrada guardada y reconectate:

   ```bash
   cp ~/.ssh/known_hosts /tmp/known_hosts.good
   ssh-keygen -R localhost >/dev/null 2>&1
   ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | sed 's/AAAA/AAAB/' >> ~/.ssh/known_hosts
   ssh -o StrictHostKeyChecking=ask student@127.0.0.1 true
   ```

   ```
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
   @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
   IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
   Someone could be eavesdropping on you right now (man-in-the-middle attack)!
   It is also possible that a host key has just been changed.
   The fingerprint for the ED25519 key sent by the remote host is
   SHA256:Wc9Xy1Zt6Nn4...
   Please contact your system administrator.
   Add correct host key in /home/student/.ssh/known_hosts to get rid of this message.
   Offending ECDSA key in /home/student/.ssh/known_hosts:2
   Host key verification failed.
   ```

6. Reparalo de la forma correcta — quitá solo la entrada ofensiva y después re-verificá por fuera de banda antes de aceptar:

   ```bash
   ssh-keygen -R 127.0.0.1
   ssh student@127.0.0.1 'echo reconnected'
   ```

   ```
   # Host 127.0.0.1 found: line 2
   /home/student/.ssh/known_hosts updated.
   Original contents retained as /home/student/.ssh/known_hosts.old
   The authenticity of host '127.0.0.1 (127.0.0.1)' can't be established.
   ED25519 key fingerprint is SHA256:Wc9Xy1Zt6Nn4....
   This key is not known by any other names.
   Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
   Warning: Permanently added '127.0.0.1' (ED25519) to the list of known hosts.
   reconnected
   ```

7. Mirá el equivalente a nivel de sistema, que un administrador pre-carga para que los usuarios nunca vean un prompt TOFU:

   ```bash
   ls -l /etc/ssh/ssh_known_hosts 2>/dev/null || echo "not present (this is normal on a default install)"
   grep -i -E 'GlobalKnownHostsFile|UserKnownHostsFile|StrictHostKeyChecking|HashKnownHosts' /etc/ssh/ssh_config
   ```

### Comprobá lo aprendido — bloque 3

11. `ssh_host_ed25519_key` tiene modo 600 y pertenece a root, pero vos te conectás como un usuario sin privilegios. ¿Qué proceso lo lee, y en qué punto de la conexión?
12. En el paso 6 el prompt ofrecía `yes/no/[fingerprint]`. ¿Qué se consigue escribiendo la huella que no se consigue escribiendo `yes`?
13. ¿Cuál es el costo operativo de `HashKnownHosts yes`, y qué ataque mitiga?
14. Tu pipeline de automatización se cuelga en el prompt TOFU. Un colega sugiere `StrictHostKeyChecking=no`. Indicá la solución correcta y por qué la de tu colega está mal.
15. `ssh-keygen -R host` dice "Original contents retained as ...known_hosts.old". ¿Por qué ese archivo es un problema si estabas rotando claves tras un compromiso sospechado?

---

## Ejercicio 4 — `ssh-agent` y `ssh-add`

**Objetivo:** mantener una clave privada descifrada en memoria, controlar su tiempo de vida y entender el socket que da acceso a ella.

1. Verificá si ya hay un agente corriendo en tu sesión:

   ```bash
   echo "SOCK=$SSH_AUTH_SOCK  PID=$SSH_AGENT_PID"
   ssh-add -l; echo "exit=$?"
   ```

   ```
   SOCK=  PID=
   Could not open a connection to your authentication agent.
   exit=2
   ```

2. Arrancá un agente e importá sus variables en la shell actual. Leé primero la salida cruda — el `eval` es lo que hace que las variables surtan efecto:

   ```bash
   ssh-agent -s
   ```

   ```
   SSH_AUTH_SOCK=/tmp/ssh-XXXX8fQ1kM/agent.5012; export SSH_AUTH_SOCK;
   SSH_AGENT_PID=5013; export SSH_AGENT_PID;
   echo Agent pid 5013;
   ```

   ```bash
   eval "$(ssh-agent -s)"
   ssh-add -l; echo "exit=$?"
   ```

   ```
   Agent pid 5031
   The agent has no identities.
   exit=1
   ```

3. Agregá la clave Ed25519 con un tiempo de vida de 120 segundos (passphrase `NewLabPass456`) y listala de dos maneras:

   ```bash
   ssh-add -t 120 ~/.ssh/id_ed25519
   ssh-add -l
   ssh-add -L | cut -c1-60
   ```

   ```
   Enter passphrase for /home/student/.ssh/id_ed25519:
   Identity added: /home/student/.ssh/id_ed25519 (lpic1-lab-workstation)
   Lifetime set to 120 seconds
   256 SHA256:0kR9nJmYb6Qb2t/9m3n0lVQ1uJ0uS3xW4qz9m8dK1cE lpic1-lab-workstation (ED25519)
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH1n0m9zXxk0k9r4t2c
   ```

4. Conectate dos veces sin que te pida la passphrase, y después mirá cómo expira la clave:

   ```bash
   ssh student@localhost 'echo first'; ssh student@localhost 'echo second'
   sleep 125
   ssh-add -l
   ```

   ```
   first
   second
   The agent has no identities.
   ```

5. Agregá todas las claves por defecto de una vez, después eliminá selectivamente y luego por completo:

   ```bash
   ssh-add ~/.ssh/id_rsa_lab ~/.ssh/id_ecdsa_lab
   ssh-add -l | wc -l
   ssh-add -d ~/.ssh/id_ecdsa_lab
   ssh-add -l | wc -l
   ssh-add -D
   ```

   ```
   Identity added: /home/student/.ssh/id_rsa_lab (rsa-lab)
   Identity added: /home/student/.ssh/id_ecdsa_lab (ecdsa-lab)
   2
   Identity removed: /home/student/.ssh/id_ecdsa_lab (ecdsa-lab)
   1
   All identities removed.
   ```

6. Examiná el socket del agente — este es todo el límite de seguridad:

   ```bash
   ls -l "$SSH_AUTH_SOCK"
   ls -ld "$(dirname "$SSH_AUTH_SOCK")"
   ```

   ```
   srw------- 1 student student 0 Aug 31 10:41 /tmp/ssh-XXXX8fQ1kM/agent.5030
   drwx------ 2 student student 60 Aug 31 10:41 /tmp/ssh-XXXX8fQ1kM
   ```

7. Agregá una clave que requiera confirmación en cada uso y después matá al agente:

   ```bash
   ssh-add -c ~/.ssh/id_rsa_lab      # each signature now pops an askpass confirmation
   ssh-add -x                        # lock the agent with a temporary password
   ssh-add -l
   ssh-agent -k
   echo "SOCK=$SSH_AUTH_SOCK"
   ```

   ```
   Identity added: /home/student/.ssh/id_rsa_lab (rsa-lab)
   The user must confirm each use of the key
   Enter lock password:
   Again:
   Agent locked.
   The agent has no identities.
   unset SSH_AUTH_SOCK;
   unset SSH_AGENT_PID;
   echo Agent pid 5030 killed;
   ```

### Comprobá lo aprendido — bloque 4

16. `ssh-add -l` devolvió código de salida 2 en el paso 1 y 1 en el paso 3. ¿Qué significa cada código, y por qué es útil la distinción en un script?
17. ¿Por qué `ssh-agent -s` tiene que envolverse en `eval` en vez de simplemente ejecutarse? ¿Qué pasaría si lo corrieras dentro de una subshell como `$(ssh-agent -s)` sin `eval`?
18. Tu agente tiene una clave cargada. Hacés `ssh -A` a un servidor compartido donde `root` no sos vos. ¿Qué puede hacer exactamente ese usuario root, y qué *no* puede llevarse?
19. El socket del agente tiene modo `srw-------` dentro de un directorio `drwx------`. ¿Cuál de esos dos permisos es el que realmente impide que otro usuario sin privilegios firme con tu clave?
20. En el paso 7 el último comando imprimió `unset SSH_AUTH_SOCK;` pero no la desactivó en tu shell. Corregí la línea de comandos para que sí lo haga.

---

## Ejercicio 5 — Configuración del cliente y reenvío de puertos

**Objetivo:** reemplazar líneas de comando largas con `~/.ssh/config`, y construir túneles locales, remotos y dinámicos.

1. Escribí una configuración de cliente. Notá que gana el *primer* valor obtenido para cada palabra clave, así que los hosts específicos van arriba del comodín:

   ```bash
   cat > ~/.ssh/config <<'EOF'
   Host lab
       HostName localhost
       User student
       Port 22
       IdentityFile ~/.ssh/id_ed25519
       IdentitiesOnly yes
       ServerAliveInterval 30

   Host *
       HashKnownHosts yes
       ForwardAgent no
       ForwardX11 no
   EOF
   chmod 600 ~/.ssh/config
   ssh lab 'echo connected via alias'
   ```

   ```
   connected via alias
   ```

2. Preguntale al cliente qué resolvió realmente para ese alias — este es el comando de diagnóstico, no `cat`:

   ```bash
   ssh -G lab | grep -E '^(hostname|user|port|identityfile|identitiesonly|forwardagent) '
   ```

   ```
   user student
   hostname localhost
   port 22
   forwardagent no
   identityfile ~/.ssh/id_ed25519
   identitiesonly yes
   ```

3. Construí un reenvío **local**. Todo lo que llegue al puerto 8022 de tu interfaz de loopback se tuneliza hacia `localhost:22` *tal como lo ve el servidor*:

   ```bash
   ssh -f -N -L 8022:localhost:22 lab
   ss -tlnp | grep 8022
   ssh -p 8022 -o StrictHostKeyChecking=accept-new student@127.0.0.1 'echo through the tunnel'
   ```

   ```
   LISTEN 0  128  127.0.0.1:8022  0.0.0.0:*  users:(("ssh",pid=5210,fd=5))
   through the tunnel
   ```

4. Construí un reenvío **remoto**: el puerto 9022 del servidor se tuneliza de vuelta a un servicio en tu cliente:

   ```bash
   ssh -f -N -R 9022:localhost:22 lab
   ssh lab "ss -tln | grep 9022"
   ```

   ```
   LISTEN 0  128  127.0.0.1:9022  0.0.0.0:*
   ```

5. Construí un reenvío **dinámico** — un proxy SOCKS5 que resuelve y conecta del lado del servidor:

   ```bash
   ssh -f -N -D 1080 lab
   curl --socks5-hostname 127.0.0.1:1080 -s -o /dev/null -w '%{http_code}\n' http://example.com/
   ```

   ```
   200
   ```

6. Intentá hacer que el reenvío local sea alcanzable desde otras máquinas y observá por qué falla en silencio:

   ```bash
   ssh -f -N -L 0.0.0.0:8023:localhost:22 lab
   ss -tlnp | grep 8023
   ```

   ```
   LISTEN 0  128  0.0.0.0:8023  0.0.0.0:*  users:(("ssh",pid=5288,fd=5))
   ```

   El cliente hace el bind porque vos se lo pediste. Ahora mirá el equivalente para `-R`, que está gobernado por la configuración `GatewayPorts` del **servidor**:

   ```bash
   grep -i gatewayports /etc/ssh/sshd_config
   ```

   ```
   #GatewayPorts no
   ```

7. Practicá las secuencias de escape dentro de una sesión interactiva. Conectate, después presioná `Enter` seguido de `~?`, `~#` y finalmente `~.`:

   ```bash
   ssh lab
   ```

   ```
   student@workstation:~$          <-- press Enter, then ~?
   Supported escape sequences:
    ~.   - terminate connection (and any multiplexed sessions)
    ~B   - send a BREAK to the remote system
    ~C   - open a command line
    ~R   - request rekey
    ~#   - list forwarded connections
    ~&   - background ssh (when waiting for connections to terminate)
    ~?   - this message
    ~~   - send the escape character by typing it twice
   ```

8. Desarmá todos los túneles en segundo plano:

   ```bash
   pkill -f 'ssh -f -N' ; ss -tlnp | grep -E '8022|8023|9022|1080' || echo "all tunnels closed"
   ```

### Comprobá lo aprendido — bloque 5

21. En `-L 8022:localhost:22`, ¿en qué máquina se resuelve el nombre `localhost`? ¿Y en `-R 9022:localhost:22`?
22. ¿Qué cambia `IdentitiesOnly yes`, dado que `IdentityFile` ya estaba especificado?
23. ¿Por qué se combina `-N` con `-f` en los pasos 3–5, y qué pasaría si quitaras `-N`?
24. El paso 6 mostró que `-L 0.0.0.0:8023` hace bind sin problemas mientras que `-R` necesita `GatewayPorts`. Explicá la asimetría en términos de quién es dueño del socket que escucha.
25. Un usuario reporta que el escape `~.` no hace nada. Nombrá dos configuraciones que lo explicarían.
26. Con `-D 1080`, ¿dónde se realiza la resolución DNS de `example.com` cuando se usa `--socks5-hostname`? ¿Por qué importa eso para un host bastión?

---

## Ejercicio 6 — GnuPG: generación de claves y anatomía del llavero

**Objetivo:** crear un par de claves OpenPGP, leer `~/.gnupg/` y distinguir la clave de certificación de sus subclaves.

1. Inspeccioná el directorio home antes de hacer nada, y definí `GPG_TTY` para que `pinentry` pueda alcanzar tu terminal:

   ```bash
   export GPG_TTY=$(tty)
   gpgconf --list-dirs homedir
   ls -la ~/.gnupg 2>/dev/null || echo "not created yet"
   ```

   ```
   /home/student/.gnupg
   ```

2. Generá un par de claves de forma no interactiva (passphrase `GpgLab789` cuando la pida), y después repetí el concepto de forma interactiva para haber visto ambos menús:

   ```bash
   gpg --quick-generate-key "Ada Lovelace <ada@lab.example>" ed25519 default 1y
   ```

   ```
   gpg: directory '/home/student/.gnupg' created
   gpg: keybox '/home/student/.gnupg/pubring.kbx' created
   gpg: /home/student/.gnupg/trustdb.gpg: trustdb created
   gpg: key 9F3C1D77A2B40E51 marked as ultimately trusted
   gpg: directory '/home/student/.gnupg/openpgp-revocs.d' created
   gpg: revocation certificate stored as '/home/student/.gnupg/openpgp-revocs.d/4B1E...A2B40E51.rev'
   public and secret key created and signed.

   pub   ed25519 2026-08-31 [SC] [expires: 2027-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid                      Ada Lovelace <ada@lab.example>
   sub   cv25519 2026-08-31 [E]
   ```

   ```bash
   gpg --full-generate-key      # walk the menu: (1) RSA and RSA, 3072 bits, 2y, "Bob Tester <bob@lab.example>"
   ```

3. Listá los llaveros público y secreto, con huellas digitales e IDs de clave:

   ```bash
   gpg --list-keys --keyid-format LONG
   gpg --list-secret-keys
   gpg --fingerprint ada@lab.example
   ```

   ```
   /home/student/.gnupg/pubring.kbx
   --------------------------------
   pub   ed25519/9F3C1D77A2B40E51 2026-08-31 [SC] [expires: 2027-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid                 [ultimate] Ada Lovelace <ada@lab.example>
   sub   cv25519/1C0A55E93BD27F64 2026-08-31 [E]

   sec   ed25519 2026-08-31 [SC] [expires: 2027-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid           [ultimate] Ada Lovelace <ada@lab.example>
   ssb   cv25519 2026-08-31 [E]
   ```

4. Mapeá la disposición en disco. GnuPG moderno (2.1+) **no** usa `secring.gpg`:

   ```bash
   ls -la ~/.gnupg
   ls -l ~/.gnupg/private-keys-v1.d/
   ls -l ~/.gnupg/openpgp-revocs.d/
   ```

   ```
   drwx------ 4 student student 4096 Aug 31 10:58 .
   -rw------- 1 student student 2510 Aug 31 10:58 pubring.kbx
   drwx------ 2 student student 4096 Aug 31 10:58 private-keys-v1.d
   drwx------ 2 student student 4096 Aug 31 10:58 openpgp-revocs.d
   -rw------- 1 student student 1360 Aug 31 10:58 trustdb.gpg
   -rw------- 1 student student   32 Aug 31 10:58 gpg.conf
   ```

5. Exportá la clave pública en ASCII armor, y también la clave secreta. Compará sus tamaños y encabezados:

   ```bash
   gpg --armor --export ada@lab.example > /tmp/ada.pub.asc
   gpg --armor --export-secret-keys ada@lab.example > /tmp/ada.sec.asc
   head -1 /tmp/ada.pub.asc; head -1 /tmp/ada.sec.asc
   ```

   ```
   -----BEGIN PGP PUBLIC KEY BLOCK-----
   -----BEGIN PGP PRIVATE KEY BLOCK-----
   ```

6. Simulá recibir la clave de Bob del lado de Ada: importala en un home de GnuPG *separado* para que las dos identidades sean realmente distintas:

   ```bash
   mkdir -p /tmp/bobhome && chmod 700 /tmp/bobhome
   gpg --armor --export bob@lab.example > /tmp/bob.pub.asc
   gpg --homedir /tmp/bobhome --import /tmp/bob.pub.asc
   gpg --homedir /tmp/bobhome --list-keys
   ```

   ```
   gpg: key 77D0E4A9B3115C82: public key "Bob Tester <bob@lab.example>" imported
   gpg: Total number processed: 1
   gpg:               imported: 1
   ```

### Comprobá lo aprendido — bloque 6

27. La clave primaria muestra `[SC]` y la subclave `[E]`. Desarrollá cada letra y explicá por qué el cifrado vive en una subclave separada.
28. ¿Qué archivo contiene el material de clave privada de Ada, y cuál el llavero público? Nombrá el archivo que solía contener las claves secretas antes de GnuPG 2.1.
29. `gpg --quick-generate-key` dijo "marked as ultimately trusted" sin preguntar. ¿Por qué eso es seguro para tu propia clave y nunca es correcto para una importada?
30. Dá la relación de la huella completa de 40 caracteres hexadecimales con `9F3C1D77A2B40E51` y con un ID corto como `A2B40E51`. ¿Cuál de los tres tenés que usar al verificar una clave en persona?
31. ¿Qué logró `--homedir /tmp/bobhome` que `--keyring` por sí solo no habría logrado?

---

## Ejercicio 7 — Cifrar, descifrar, firmar y verificar

**Objetivo:** ejercitar los modos asimétrico y simétrico, producir firmas separadas y leer la estructura de paquetes del resultado.

1. Creá un documento de prueba:

   ```bash
   echo "Analytical Engine boot sequence: step 1, wind the crank." > /tmp/notes.txt
   sha256sum /tmp/notes.txt
   ```

2. Cifrá **para Bob** (asimétrico) y confirmá que no podés leerlo como Ada:

   ```bash
   gpg --armor --encrypt --recipient bob@lab.example --output /tmp/notes.asc /tmp/notes.txt
   head -2 /tmp/notes.asc
   gpg --decrypt /tmp/notes.asc > /dev/null
   ```

   ```
   -----BEGIN PGP MESSAGE-----

   gpg: encrypted with rsa3072 key, ID 77D0E4A9B3115C82, created 2026-08-31
         "Bob Tester <bob@lab.example>"
   ```

   (Como acá ambas claves están en el mismo llavero, el descifrado tiene éxito; hacelo desde `/tmp/bobhome`, que solo tiene la clave *pública* de Bob, para ver la falla real:)

   ```bash
   gpg --homedir /tmp/bobhome --decrypt /tmp/notes.asc
   ```

   ```
   gpg: encrypted with RSA key, ID 77D0E4A9B3115C82
   gpg: decryption failed: No secret key
   ```

3. Inspeccioná la estructura del texto cifrado sin descifrarlo:

   ```bash
   gpg --list-packets /tmp/notes.asc | head -4
   ```

   ```
   # off=0 ctb=85 tag=1 hlen=3 plen=268
   :pubkey enc packet: version 3, algo 1, keyid 77D0E4A9B3115C82
           data: [3071 bits]
   :encrypted data packet:
   ```

4. Cifrá **simétricamente** con una passphrase (`SharedSecret42`), y después probá qué cifrador se usó:

   ```bash
   gpg --symmetric --cipher-algo AES256 --output /tmp/notes.sym.gpg /tmp/notes.txt
   gpg --list-packets /tmp/notes.sym.gpg | head -3
   gpg --decrypt /tmp/notes.sym.gpg
   ```

   ```
   # off=0 ctb=8c tag=3 hlen=2 plen=13
   :symkey enc packet: version 4, cipher 9, aead 0, s2k 3, hash 8
           salt A1B2C3D4E5F60718, count 65011712 (255)
   gpg: AES256.CFB encrypted data
   gpg: encrypted with 1 passphrase
   Analytical Engine boot sequence: step 1, wind the crank.
   ```

5. Firmá en los tres modos distintos y compará los artefactos:

   ```bash
   gpg --local-user ada@lab.example --sign        --output /tmp/notes.sig.gpg /tmp/notes.txt   # binary, embeds document
   gpg --local-user ada@lab.example --clearsign   --output /tmp/notes.clear.asc /tmp/notes.txt # readable + signature
   gpg --local-user ada@lab.example --detach-sign --armor --output /tmp/notes.txt.asc /tmp/notes.txt
   ls -l /tmp/notes.txt /tmp/notes.sig.gpg /tmp/notes.clear.asc /tmp/notes.txt.asc
   head -3 /tmp/notes.clear.asc
   ```

   ```
   -rw-r--r-- 1 student student   57 Aug 31 11:12 /tmp/notes.txt
   -rw-r--r-- 1 student student  178 Aug 31 11:14 /tmp/notes.sig.gpg
   -rw-r--r-- 1 student student  349 Aug 31 11:14 /tmp/notes.clear.asc
   -rw-r--r-- 1 student student  228 Aug 31 11:14 /tmp/notes.txt.asc
   -----BEGIN PGP SIGNED MESSAGE-----
   Hash: SHA512

   ```

6. Verificá cada una, incluyendo un caso alterado deliberadamente:

   ```bash
   gpg --verify /tmp/notes.txt.asc /tmp/notes.txt
   echo "step 2, ignore the crank." >> /tmp/notes.txt
   gpg --verify /tmp/notes.txt.asc /tmp/notes.txt; echo "exit=$?"
   ```

   ```
   gpg: Signature made Mon 31 Aug 2026 11:14:02 AM UTC
   gpg:                using EDDSA key 4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   gpg: Good signature from "Ada Lovelace <ada@lab.example>" [ultimate]
   gpg: BAD signature from "Ada Lovelace <ada@lab.example>" [ultimate]
   exit=1
   ```

7. Verificá desde el llavero de Bob, donde la clave de Ada es desconocida y después meramente no confiable:

   ```bash
   gpg --homedir /tmp/bobhome --verify /tmp/notes.clear.asc
   gpg --homedir /tmp/bobhome --import /tmp/ada.pub.asc
   gpg --homedir /tmp/bobhome --verify /tmp/notes.clear.asc
   ```

   ```
   gpg: Can't check signature: No public key
   gpg: key 9F3C1D77A2B40E51: public key "Ada Lovelace <ada@lab.example>" imported
   gpg: Good signature from "Ada Lovelace <ada@lab.example>" [unknown]
   gpg: WARNING: This key is not certified with a trusted signature!
   gpg:          There is no indication that the signature belongs to the owner.
   Primary key fingerprint: 4B1E 9A70 C6D5 F033 8821  B0DE 9F3C 1D77 A2B4 0E51
   ```

8. Combiná ambas operaciones — firmar y cifrar en una sola pasada, el caso normal en producción:

   ```bash
   printf 'confidential and attributable\n' > /tmp/both.txt
   gpg --armor --sign --encrypt --local-user ada@lab.example --recipient bob@lab.example \
       --output /tmp/both.asc /tmp/both.txt
   gpg --decrypt /tmp/both.asc
   ```

### Comprobá lo aprendido — bloque 7

32. `--list-packets` mostró `cipher 9` para el archivo simétrico. ¿Qué algoritmo es ése, y cómo supo el lado que *descifra* qué cifrador usar sin que se lo dijeran?
33. En el paso 7 la firma fue `Good` pero traía un `WARNING`. Distinguí la pregunta criptográfica que GnuPG respondió de la que se negó a responder.
34. ¿Cuál de los tres modos de firma deja que `grep` siga leyendo el texto del documento, y cuál usarías para firmar una imagen ISO de 4 GB? Justificá ambos.
35. La verificación de `--detach-sign` necesita dos argumentos de archivo. ¿Cuál es el orden de los argumentos, y qué pasa si solo suministrás el `.asc`?
36. Ada cifró para Bob y aun así pudo descifrarlo en el paso 2 desde su propio llavero. ¿Qué opción agregarías para que una copia sea *intencionalmente* legible por el remitente, y por qué eso no es el comportamiento por defecto?

---

## Ejercicio 8 — `gpg-agent`, expiración y revocación

**Objetivo:** controlar el caché de passphrases, extender la vida de una clave y revocarla correctamente.

1. Observá el agente que GnuPG arrancó implícitamente, y las claves que tiene:

   ```bash
   gpgconf --list-components | grep gpg-agent
   pgrep -a gpg-agent
   gpg-connect-agent 'keyinfo --list' /bye
   ```

   ```
   gpg-agent:GPG-Agent:/usr/bin/gpg-agent
   5401 gpg-agent --homedir /home/student/.gnupg --use-standard-socket --daemon
   S KEYINFO 8A1B...F09 D - - - P - - -
   S KEYINFO 3C2D...E71 D - - - P - - -
   OK
   ```

2. Configurá el caché y el pinentry, y después recargá el agente (para la mayoría de los ajustes no hace falta matarlo):

   ```bash
   cat > ~/.gnupg/gpg-agent.conf <<'EOF'
   default-cache-ttl 60
   max-cache-ttl 300
   pinentry-program /usr/bin/pinentry-curses
   EOF
   gpgconf --reload gpg-agent
   ```

3. Demostrá que el caché funciona, y después que expira:

   ```bash
   echo test > /tmp/c.txt
   gpg --local-user ada@lab.example --detach-sign -o /tmp/c.sig /tmp/c.txt   # asks for passphrase
   gpg --local-user ada@lab.example --detach-sign -o /tmp/c2.sig /tmp/c.txt  # silent — cached
   sleep 65
   gpg --local-user ada@lab.example --detach-sign -o /tmp/c3.sig /tmp/c.txt  # asks again
   ```

4. Vaciá el caché a demanda y reiniciá el agente por completo:

   ```bash
   gpg-connect-agent reloadagent /bye
   gpgconf --kill gpg-agent && pgrep -a gpg-agent || echo "agent stopped; it will respawn on next gpg use"
   ```

5. Extendé la fecha de expiración de la clave a través del menú de edición:

   ```bash
   gpg --edit-key ada@lab.example
   ```

   ```
   gpg> expire
   Changing expiration time for the primary key.
   Please specify how long the key should be valid.
            0 = key does not expire
         <n>  = key expires in n days
   Key is valid for? (0) 2y
   Key expires at Tue 31 Aug 2028 11:31:00 AM UTC
   Is this correct? (y/N) y

   gpg> key 1
   gpg> expire        <-- repeat for the encryption subkey
   gpg> save
   ```

   ```bash
   gpg --list-keys ada@lab.example | grep expires
   ```

6. Localizá el certificado de revocación que GnuPG generó para vos, y generá un segundo de forma explícita:

   ```bash
   ls ~/.gnupg/openpgp-revocs.d/
   gpg --output /tmp/ada-revoke.asc --gen-revoke ada@lab.example
   ```

   ```
   Create a revocation certificate for this key? (y/N) y
   Please select the reason for the revocation:
     0 = No reason specified
     1 = Key has been compromised
     2 = Key is no longer used
     3 = User ID is no longer valid
   Your decision? 1
   Enter an optional description: laptop stolen 2026-08-31
   Is this okay? (y/N) y
   ASCII armored output forced.
   Revocation certificate created.
   ```

7. Revocá la clave importando el certificado, y después observá el efecto sobre el cifrado:

   ```bash
   gpg --import /tmp/ada-revoke.asc
   gpg --list-keys ada@lab.example
   gpg --encrypt --recipient ada@lab.example --output /tmp/x.gpg /tmp/c.txt
   ```

   ```
   gpg: key 9F3C1D77A2B40E51: "Ada Lovelace <ada@lab.example>" revocation certificate imported
   gpg: Total number processed: 1
   gpg:      new key revocations: 1

   pub   ed25519 2026-08-31 [SC] [revoked: 2026-08-31]
         4B1E9A70C6D5F0338821B0DE9F3C1D77A2B40E51
   uid           [ revoked] Ada Lovelace <ada@lab.example>

   gpg: 4B1E9A70...: skipped: Unusable public key
   gpg: /tmp/c.txt: encryption failed: Unusable public key
   ```

8. Distribuí la revocación — el paso que la gente olvida:

   ```bash
   gpg --armor --export ada@lab.example > /tmp/ada-revoked.pub.asc
   gpg --homedir /tmp/bobhome --import /tmp/ada-revoked.pub.asc
   gpg --homedir /tmp/bobhome --list-keys ada@lab.example | head -2
   ```

   ```
   gpg: key 9F3C1D77A2B40E51: "Ada Lovelace <ada@lab.example>" revocation certificate imported
   pub   ed25519 2026-08-31 [SC] [revoked: 2026-08-31]
   ```

### Comprobá lo aprendido — bloque 8

37. `default-cache-ttl 60` y `max-cache-ttl 300` están ambos configurados. Describí una secuencia de firmas donde la passphrase se pide en t=0 y otra vez exactamente en t=300 a pesar del uso continuo.
38. Revocar la clave hizo fallar el *cifrado hacia Ada*, pero ¿qué pasa con las firmas que Ada hizo el año pasado, y con los documentos ya cifrados para ella?
39. ¿Dónde guarda GnuPG 2.1+ un certificado de revocación automático, y cuál es el riesgo operativo de dejarlo en el mismo disco que `private-keys-v1.d/`?
40. Revocaste la clave localmente. Bob, en otro continente, sigue cifrando hacia ella. Nombrá los dos mecanismos que habrían propagado la revocación y la única alternativa manual usada en el paso 8.
41. `gpgconf --reload gpg-agent` versus `gpgconf --kill gpg-agent` — ¿cuál preserva las passphrases en caché, y qué cambio de configuración fuerza la opción más drástica?
42. La clave de Ada expiró en vez de ser revocada. ¿Puede todavía extenderla después de que pasó la fecha de expiración? ¿Qué te dice eso sobre lo que realmente es una fecha de expiración?

---

## Limpieza

```bash
pkill -f 'ssh -f -N'; ssh-agent -k 2>/dev/null
rm -f ~/.ssh/id_rsa_lab* ~/.ssh/id_ecdsa_lab* ~/.ssh/config ~/.ssh/known_hosts.old
cp /tmp/known_hosts.good ~/.ssh/known_hosts 2>/dev/null
gpgconf --kill gpg-agent
rm -rf /tmp/bobhome /tmp/notes* /tmp/both* /tmp/ada* /tmp/bob* /tmp/c*.txt /tmp/c*.sig /tmp/x.gpg
# To discard the lab OpenPGP keys entirely:
# gpg --delete-secret-and-public-key ada@lab.example
```

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar las respuestas a las 42 preguntas</strong></summary>

### Bloque 1 — Generación e inspección de claves

**1.** El `-b 4096` se ignora en silencio. Ed25519 es un algoritmo de tamaño fijo: la curva determina una clave de 256 bits, así que no hay tamaño para elegir. `ssh-keygen` acepta el flag y produce la misma clave de 256 bits; `ssh-keygen -l` va a seguir informando `256`. Solo RSA (`-b 2048/3072/4096`) y ECDSA (`-b 256/384/521`, que selecciona la curva NIST, no una longitud arbitraria) lo respetan.

**2.** El campo 3, el comentario. El archivo de clave pública es `<tipo> <blob-de-clave-base64> <comentario>`, y `ssh-keygen -y` reconstruye solo los dos primeros campos porque el comentario está guardado dentro de la *clave privada cifrada*, no se deriva del material de la clave. Regenerar un `.pub` por lo tanto pierde el comentario a menos que lo vuelvas a agregar con `-C`. Esto también prueba el punto: la clave pública no contiene ninguna información que no sea computable a partir de la privada.

**3.** El archivo `.pub` puede ser — y normalmente es — legible por todo el mundo (644); es público por definición. La clave privada no debe ser accesible por grupo ni por otros. `ssh` hace cumplir esto por sí mismo y se niega a usar una clave cuyo modo sea más laxo que 600 (lectura/escritura del propietario), imprimiendo el cartel `UNPROTECTED PRIVATE KEY FILE`. Notá que ésta es una comprobación *del lado del cliente* sobre los archivos que él lee, independiente del `StrictModes` de `sshd`.

**4.** `ssh-keygen -l -E md5 -f <keyfile>`. Desde OpenSSH 6.8 el hash de huella por defecto es SHA256 representado en base64 (y se imprime con el prefijo `SHA256:`); `-E md5` selecciona la representación heredada MD5 en hexadecimal con dos puntos. La clave es la misma — solo difieren el digest y la codificación. También podés comparar en la otra dirección pidiéndole al par una huella SHA256.

**5.** No. La passphrase cifra el archivo de clave privada en reposo; nunca sale de tu máquina y no es parte del par de claves. `ssh-keygen -p` vuelve a cifrar el mismo material de clave privada bajo una passphrase nueva. La clave pública es idéntica byte a byte, así que no cambia nada en ningún servidor.

### Bloque 2 — Autenticación por clave pública

**6.** Habría sido `student@localhost's password:` — el prompt de la contraseña de la cuenta. La distinción ubica el secreto: un prompt de *passphrase* es local, lo produce el cliente para descifrar `~/.ssh/id_ed25519`, y significa que el servidor ya aceptó la mitad pública de esta clave como una oferta que vale la pena seguir. Un prompt de *password* significa que la autenticación por clave pública falló o nunca se intentó, y el cliente cayó de vuelta al método `password`/`keyboard-interactive`, enviando un secreto por el canal (cifrado) hacia el servidor.

**7.** El modo 644 funciona sin problemas. El `StrictModes yes` de `sshd` rechaza `authorized_keys` solo cuando es escribible por grupo u otros — la legibilidad es irrelevante, ya que el archivo contiene claves públicas. El modo 664 **rompe** la autenticación: escribible por grupo significa que otra cuenta de ese grupo podría agregar su propia clave y hacerse pasar por vos. La misma regla se aplica a `~/.ssh` y al propio directorio home, que es lo que demostró el paso 5.

**8.** Porque `sshd` deliberadamente no le dice al cliente *por qué* falló la autenticación — informar "tu directorio home es escribible por el grupo" filtraría estado del sistema de archivos a un par no autenticado. El cliente solo ve `Permission denied (publickey)`. Éste es el hábito más importante para diagnosticar autenticación por clave: `ssh -vvv` te muestra qué clave se *ofreció*, pero solo `journalctl -u sshd` (o `LogLevel DEBUG` en `sshd_config`) muestra por qué se *rechazó*.

**9.** `restrict` (OpenSSH 7.2+) es un "denegar todo" por defecto: deshabilita el reenvío de puertos, el reenvío del agente, el reenvío de X11, la asignación de PTY, la ejecución de `~/.ssh/rc` y cualquier capacidad *futura* que OpenSSH agregue. La lista explícita deshabilita solo lo que existía cuando la escribiste — una funcionalidad nueva agregada en una versión posterior quedaría permitida. Por eso `restrict` es la forma segura, y las capacidades individuales pueden volver a habilitarse después de ella (p. ej. `restrict,pty`).

**10.** El cliente igual envía el comando solicitado, y `sshd` lo coloca en la variable de entorno `SSH_ORIGINAL_COMMAND` antes de ejecutar en su lugar el `command=` forzado. Nada se ejecuta a partir de la cadena del usuario — pero el comando forzado puede leerla, que es exactamente cómo los scripts de compuerta (como `git-shell` o los wrappers de rsync) implementan el despacho selectivo. Si tu comando forzado pasa `SSH_ORIGINAL_COMMAND` a una shell, reintrodujiste la ejecución arbitraria.

### Bloque 3 — Claves de host y `known_hosts`

**11.** La lee `sshd`, corriendo como root, durante el intercambio de claves — antes de cualquier autenticación. El servidor firma el hash del intercambio con su clave privada de host; el cliente verifica esa firma contra la clave pública guardada en `known_hosts`. Esto es lo que ata el canal cifrado a una identidad de servidor específica, y es por eso que una clave privada de host robada permite un ataque de intermediario incluso sin ninguna credencial de usuario.

**12.** Escribir `yes` significa "acepto cualquier clave que me acabás de mostrar" — puro trust-on-first-use sin verificación. Escribir (pegar) la huella hace que el *cliente* la compare con la clave que el servidor realmente presentó y aborte si no coinciden, así que no podés aceptar accidentalmente la clave de un atacante escribiendo `yes` por reflejo. Solo ayuda si obtuviste la huella por un canal independiente (salida de consola, gestión de configuración, un documento firmado).

**13.** Costo: ya no podés hacer `grep` ni leer `known_hosts`; tenés que usar `ssh-keygen -F host` para buscar y `-R host` para eliminar, y no podés auditar de un vistazo a qué hosts se conectó un usuario. Mitigación: si el archivo es robado — por malware o desde un respaldo — el atacante no puede enumerar tu infraestructura a partir de él, lo que históricamente fue un mapa favorito de movimiento lateral para los gusanos.

**14.** La solución correcta es pre-cargar la clave de host: distribuir `/etc/ssh/ssh_known_hosts` (o un `known_hosts` por usuario) desde la gestión de configuración usando huellas recolectadas de una fuente confiable, o usar la salida de `ssh-keyscan` verificada contra el propio `ssh-keygen -l /etc/ssh/ssh_host_*_key.pub` del servidor. `StrictHostKeyChecking=no` acepta *cualquier* clave en silencio y además deshabilita la advertencia de discrepancia, así que convierte un cuelgue en una exposición permanente e invisible a un intermediario. `accept-new` es un punto medio: acepta automáticamente hosts desconocidos pero igual rechaza ante una clave *cambiada*.

**15.** `known_hosts.old` todavía contiene la entrada vieja, posiblemente provista por el atacante. Si más adelante restaurás o fusionás ese archivo — o si un script de respaldo lo levanta — reinstaurás en silencio la confianza en la clave comprometida. Después de un compromiso sospechado, borrá `known_hosts.old` explícitamente y re-verificá la nueva huella por fuera de banda.

### Bloque 4 — `ssh-agent` / `ssh-add`

**16.** Salida 2 = no se puede contactar al agente en absoluto (`SSH_AUTH_SOCK` sin definir o el socket está muerto). Salida 1 = el agente respondió, pero no tiene identidades. Salida 0 = hay al menos una identidad cargada. Un script puede así distinguir "arrancar un agente" (2) de "pedirle al usuario que haga `ssh-add`" (1) en vez de adivinar a partir del texto de salida.

**17.** `ssh-agent -s` bifurca el demonio e imprime *código de shell* en stdout; no puede modificar el entorno de su shell padre. `eval` ejecuta ese código en la shell actual para que `SSH_AUTH_SOCK` y `SSH_AGENT_PID` queden exportados donde `ssh` los va a ver. Correr `$(ssh-agent -s)` sin `eval` hace que la shell intente ejecutar la primera palabra de la salida — `SSH_AUTH_SOCK=/tmp/...` — como un comando, lo que no define nada útil y típicamente da error; mientras tanto el proceso del agente queda corriendo, huérfano e inalcanzable.

**18.** Mientras tu sesión esté viva, root en ese host puede leer `SSH_AUTH_SOCK`, conectarse al socket reenviado y pedirle a tu agente que firme desafíos — autenticándose efectivamente como vos ante cualquier host que confíe en tu clave, mientras sigas conectado. Lo que **no** puede hacer es extraer la clave privada: el agente solo devuelve firmas, nunca material de clave. Mitigaciones: `ssh-add -c` (confirmar cada uso), tiempos de vida `-t` cortos, `ForwardAgent no` por defecto con habilitación por host, o `ProxyJump` en lugar de reenvío del agente.

**19.** El modo del directorio. Los permisos del propio socket son consultivos en el manejo de sockets Unix de algunos kernels, así que OpenSSH no depende de ellos: crea el socket dentro de un directorio `0700` de tu propiedad, y el permiso de recorrido del directorio es lo que realmente le niega a otros usuarios la capacidad de hacer `connect()`. Notá que root pasa por encima de ambos.

**20.** Envolvelo en `eval` igual que al arrancar: `eval "$(ssh-agent -k)"`. Como con `-s`, la opción `-k` mata el demonio e imprime los comandos de shell (`unset ...`) necesarios para limpiar el entorno, pero no puede alterar tu shell por sí sola.

### Bloque 5 — Configuración del cliente y reenvío

**21.** Para `-L 8022:localhost:22`, el cliente escucha localmente y el *servidor* resuelve y se conecta a `localhost:22` — así que `localhost` es el propio servidor SSH. Para `-R 9022:localhost:22`, el servidor escucha y el *cliente* resuelve y se conecta a `localhost:22` — así que `localhost` es tu estación de trabajo. La regla: el host:puerto de destino en una especificación de reenvío siempre lo resuelve el extremo que abre la conexión saliente, que es el opuesto al que escucha.

**22.** Sin `IdentitiesOnly yes`, `ssh` ofrece las entradas de `IdentityFile` *más* cada clave cargada en el agente, en el orden del agente. Con muchas claves cargadas, el servidor puede alcanzar `MaxAuthTries` (6 por defecto) y rechazarte antes de que se ofrezca la clave correcta — el clásico error "too many authentication failures". `IdentitiesOnly yes` restringe la oferta a las claves nombradas en la configuración (aunque el agente siga *conteniéndolas*).

**23.** `-N` significa "no ejecutar un comando remoto", así que la conexión transporta solo el túnel; `-f` manda `ssh` a segundo plano después de la autenticación, para que tu shell vuelva. Sin `-N`, `-f` mandaría a segundo plano una shell de login completa sin terminal asociada, que típicamente sale de inmediato (o se cuelga esperando entrada), llevándose el túnel con ella. Combinar ambos da un proceso de túnel puro y persistente.

**24.** Para `-L`, el socket de escucha pertenece al proceso *cliente* corriendo bajo tu cuenta en tu máquina — tenés derecho a hacer bind a cualquier dirección no privilegiada allí, así que no interviene ningún permiso del servidor. Para `-R`, el socket de escucha lo abre `sshd` en el servidor; exponerlo más allá de loopback dejaría entrar a terceros arbitrarios en tu túnel, así que el administrador del servidor lo controla con `GatewayPorts` (`no` = solo loopback, `yes` = cualquier dirección, `clientspecified` = respetar la dirección de bind del cliente).

**25.** (a) El carácter de escape fue deshabilitado o cambiado — `EscapeChar none` en `ssh_config`, o `-e none` en la línea de comandos (común en sesiones automatizadas). (b) El `~` no fue el primer carácter después de una nueva línea; los escapes solo se reconocen inmediatamente después de un salto de línea, así que presionar `Enter` primero es obligatorio. Un tercer caso: estás en una sesión SSH *anidada*, donde el cliente exterior consume el escape — usá `~~.` para llegar al interior.

**26.** Con `--socks5-hostname` (SOCKS5h), el nombre de host se envía al proxy como nombre y lo resuelve el **servidor SSH**, en el extremo lejano del túnel. Eso importa en un bastión porque los nombres DNS internos que no resuelven en tu estación de trabajo igual funcionan, y porque tu resolvedor local nunca ve qué hosts internos estás visitando. El `--socks5` simple resuelve localmente y reenvía solo la dirección IP, lo que rompe el DNS de horizonte partido y filtra la consulta.

### Bloque 6 — Claves y llavero de GnuPG

**27.** `S` = Sign (firmar), `C` = Certify (certificar: firmar otras claves y tus propios UID), `E` = Encrypt (cifrar); también podés ver `A` = Authenticate (autenticar). El cifrado va en una subclave porque los dos roles tienen ciclos de vida distintos y semánticas de pérdida distintas: una subclave de cifrado puede rotarse o revocarse y reemplazarse sin destruir tu identidad ni la red de confianza construida sobre la clave primaria, mientras que perder la subclave de cifrado te cuesta el acceso al texto cifrado del pasado. La clave primaria, capaz de certificar, es la identidad de largo plazo y a menudo se mantiene fuera de línea.

**28.** El material de clave privada vive en `~/.gnupg/private-keys-v1.d/<KEYGRIP>.key`, un archivo por clave, gestionado exclusivamente por `gpg-agent`. El llavero público es `~/.gnupg/pubring.kbx` (formato keybox). Antes de GnuPG 2.1 las claves secretas vivían en `~/.gnupg/secring.gpg`; ese archivo ya no existe y se migra en el primer uso de un GnuPG moderno — una distinción favorita de los exámenes.

**29.** Confianza definitiva ("ultimate") significa "las firmas hechas por esta clave son, a efectos del cálculo de confianza, tan buenas como las mías" — correcto para una clave cuya mitad privada acabás de generar y controlás. Asignarla a una clave importada le dice a GnuPG que acepte todo lo que esa clave haya certificado, transitivamente, así que una sola importación mala valida en silencio un conjunto arbitrario de identidades. Las claves importadas deberían validarse verificando la huella por fuera de banda y luego firmándolas/certificándolas, dejando que el cálculo de la red de confianza asigne la validez.

**30.** Son la misma clave, truncada desde la derecha: la huella de 40 caracteres hexadecimales (160 bits) es el identificador completo; el ID largo `9F3C1D77A2B40E51` son sus últimos 64 bits; el ID corto `A2B40E51` son los últimos 32 bits. Solo la **huella completa** es aceptable para la verificación en persona — los IDs cortos ya han sido colisionados públicamente (de forma deliberada y a bajo costo), y los IDs largos están al alcance de un atacante decidido. Preferí `--keyid-format LONG` como mínimo, y compará huellas completas cuando importa.

**31.** `--homedir` le da a Bob un estado de GnuPG completamente separado: su propio llavero, su propio `trustdb.gpg`, su propio `private-keys-v1.d/` y su propio agente. `--keyring` solo agregaría otro archivo de llavero público al home *actual*, seguiría compartiendo la base de datos de confianza de Ada y, críticamente, sus claves secretas — así que una prueba de "Bob no puede descifrar esto" tendría éxito en silencio usando la clave privada de Ada. Aislar el directorio home es la única forma de simular honestamente una segunda parte en una sola máquina.

### Bloque 7 — Cifrar, descifrar, firmar, verificar

**32.** El cifrador 9 es AES-256 (7 = AES-128, 8 = AES-192, 2 = 3DES). El lado que descifra no necesita que se lo digan por fuera de banda: el paquete de clave de sesión cifrada con clave simétrica lleva el ID de algoritmo, el especificador S2K (modo 3 = iterado+con sal), el hash y la sal, así que `gpg` deriva la misma clave a partir de tu passphrase y sabe qué cifrador instanciar. Lo mismo vale para el cifrado de clave pública, donde la clave de sesión se entrega dentro del `pubkey enc packet`.

**33.** GnuPG respondió la pregunta *criptográfica*: esta firma fue producida por la clave privada que corresponde a la huella `4B1E…0E51`, y el documento no fue alterado desde entonces. Se negó a responder la pregunta de *identidad*: nada en el llavero de Bob establece que esa clave pertenezca realmente a una humana llamada Ada Lovelace. La validez es un cálculo de confianza sobre certificaciones, no una propiedad de la matemática — que es por lo que la advertencia aparece aunque la firma sea `Good`.

**34.** `--clearsign` mantiene el texto legible: envuelve el original en `BEGIN PGP SIGNED MESSAGE` con la firma agregada en armor, que es por lo que se usa para publicaciones en listas de correo y anuncios. Para una ISO de 4 GB usá `--detach-sign`: la firma es un archivo pequeño y separado, así que la imagen se distribuye sin modificar, puede verificarse sin reescribir ni copiar 4 GB, y quienes no se interesen por las firmas pueden usarla tal cual. `--sign` (binario, embebido y comprimido) produciría un segundo artefacto de 4 GB que hay que desenvolver antes de usar.

**35.** El orden es `gpg --verify <archivo-de-firma> <archivo-de-datos>` — la firma primero. Si solo suministrás el `.asc`, GnuPG aplica su regla de adivinanza: quita un sufijo `.asc`/`.sig`/`.gpg` y busca un archivo con ese nombre en el mismo directorio. Eso funciona cuando los nombres coinciden (`notes.txt.asc` → `notes.txt`) y falla de forma confusa cuando no, así que ser explícito es el hábito que vale la pena construir.

**36.** Agregá `--recipient <tu-propia-clave>` una segunda vez, o configurá `default-recipient-self` / `encrypt-to <tu-key-id>` en `~/.gnupg/gpg.conf`. No es el comportamiento por defecto porque cifrar hacia una clave adicional es una decisión de divulgación, no una comodidad: amplía en silencio el conjunto de destinatarios, es visible para cualquiera que corra `--list-packets` sobre el texto cifrado (revelando que también cifraste para vos mismo), y en ciertos modelos de amenaza el punto entero es que el remitente no pueda ser obligado después a producir el texto plano.

### Bloque 8 — Agente, expiración, revocación

**37.** `default-cache-ttl` es un temporizador de *inactividad* que se reinicia con cada uso; `max-cache-ttl` es un techo absoluto medido desde el momento en que se ingresó la passphrase, y nunca se reinicia. Firmá en t=0 (pide la passphrase), después otra vez en t=50, t=100, t=150, t=250 — cada una dentro de los 60 s de la anterior, así que el temporizador de inactividad nunca se dispara. En t=300 expira el máximo absoluto y la entrada del caché se descarta sin importar la actividad, así que la firma siguiente vuelve a pedirla.

**38.** Las firmas que Ada hizo *antes* de la revocación siguen siendo verificables y, según el motivo declarado, pueden seguir siendo confiables: revocar por "key is no longer used" (motivo 2) deja válidas las firmas pasadas, mientras que "key has been compromised" (motivo 1) las invalida retroactivamente, ya que un atacante podría haberlas producido. Los documentos ya cifrados para ella siguen siendo descifrables — ella todavía tiene la clave privada; la revocación es una declaración pública de no *usar* la clave en adelante, no una destrucción del material de clave.

**39.** En `~/.gnupg/openpgp-revocs.d/<FINGERPRINT>.rev`, modo 600, generado automáticamente al crear la clave desde GnuPG 2.1. El riesgo es simétrico a su propósito: cualquiera que pueda leer ese archivo puede publicarlo y revocar permanentemente tu clave (una denegación de servicio sobre tu identidad), y cualquiera que destruya tu disco destruye tanto la clave *como* la capacidad de anunciar su revocación. La buena práctica es moverlo a un medio offline separado — impreso o en otro dispositivo cifrado — no dejarlo al lado de `private-keys-v1.d/`.

**40.** (a) Un servidor de claves, si la clave fue publicada allí y Bob refresca con `gpg --refresh-keys` (o tiene `auto-key-retrieve` / un keyserver configurado). (b) Web Key Directory (WKD), donde el dueño del dominio publica la clave actual sobre HTTPS en una URL bien conocida y `gpg --locate-keys` la obtiene. La alternativa manual usada en el paso 8 es exportar la clave pública ya revocada y entregarla por fuera de banda para `gpg --import` — importar la *clave* trae consigo la firma de revocación, que es por lo que reimportar una clave existente igual actualiza su estado.

**41.** `--reload` envía una señal de recarga: el agente vuelve a leer `gpg-agent.conf` y sigue corriendo, así que las passphrases en caché sobreviven. `--kill` termina el demonio, descartando todo el caché; la siguiente invocación de `gpg` arranca un agente nuevo. Cambiar `pinentry-program` es el caso que normalmente requiere el kill, porque el agente vincula su ayudante pinentry al arrancar — igual que las opciones relacionadas con sockets, como `extra-socket` y `enable-ssh-support`.

**42.** Sí. Una fecha de expiración no es un candado; es una autofirma sobre la clave que declara un período de validez, y quien posee la clave primaria siempre puede emitir una nueva autofirma con una fecha posterior — incluso años después de que venció — y republicar la clave. Precisamente por eso la expiración es un *interruptor de hombre muerto* y no un control de seguridad: hace que una clave abandonada se vea visiblemente rancia para todos los que la refrescan, sin dejar de ser plenamente recuperable por su dueño legítimo. La revocación, en cambio, es irreversible.

</details>

---

### Fuentes oficiales

- LPI — Objetivos del examen 101-500: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Objetivos del examen 102-500 (tema 110.3): https://www.lpi.org/our-certifications/exam-102-objectives/
- OpenSSH — `ssh(1)`: https://man.openbsd.org/ssh.1
- OpenSSH — `ssh_config(5)`: https://man.openbsd.org/ssh_config.5
- OpenSSH — `ssh-keygen(1)`: https://man.openbsd.org/ssh-keygen.1
- OpenSSH — `ssh-agent(1)` / `ssh-add(1)`: https://man.openbsd.org/ssh-agent.1 · https://man.openbsd.org/ssh-add.1
- OpenSSH — `sshd(8)`, `AUTHORIZED_KEYS FILE FORMAT`: https://man.openbsd.org/sshd.8
- GnuPG — Using the GNU Privacy Guard (manual): https://www.gnupg.org/documentation/manuals/gnupg/
- GnuPG — Opciones de `gpg-agent`: https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html
- GnuPG — Cambios de GnuPG 2.1 (eliminación de `secring.gpg`, directorio de revocación): https://www.gnupg.org/faq/whats-new-in-2.1.html
- RFC 4880 — OpenPGP Message Format (tipos de paquete, IDs de cifradores): https://www.rfc-editor.org/rfc/rfc4880