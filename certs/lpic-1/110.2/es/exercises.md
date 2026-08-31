# LPIC-1 · Tema 110.2 — Configurar la seguridad del host

## Ejercicios guiados

> **Cobertura del objetivo (LPI 102-500, 110.2, peso 3):** contraseñas shadow y cómo funcionan; apagar los servicios de red que no se usan; el papel de los TCP wrappers.
> **Archivos, términos y utilidades clave:** `/etc/nologin`, `/etc/passwd`, `/etc/shadow`, `/etc/xinetd.d/`, `/etc/xinetd.conf`, `systemd.socket`, `/etc/inittab`, `/etc/init.d/`, `/etc/hosts.allow`, `/etc/hosts.deny`

---

### Entorno de laboratorio y notas de seguridad

Estos ejercicios modifican bases de datos de autenticación y detienen servicios de red. **Ejecutalos en una VM o un contenedor descartable, nunca en una máquina de la que dependas.**

Requisitos:

* Un sistema Linux con `systemd` (Debian 12+, Ubuntu 22.04+, Rocky/AlmaLinux 9, openSUSE Leap 15+, Fedora 39+).
* Acceso a `root` vía `sudo`.
* Dos terminales abiertas como `root`, o al menos una shell de root que quede abierta durante toda la sesión. Varios pasos pueden dejarte fuera de los nuevos inicios de sesión; una shell de root ya abierta es tu vía de escape.
* Paquetes: `shadow-utils` / `passwd`, `iproute2`, `procps`, `lsof`. Opcionales: `tcpd` / `tcp_wrappers` (solo Debian/Ubuntu en las versiones actuales), `xinetd`.

Tomá una instantánea antes de empezar:

```bash
sudo tar czf /root/pre-lab-backup.tar.gz \
  /etc/passwd /etc/shadow /etc/group /etc/gshadow \
  /etc/hosts.allow /etc/hosts.deny 2>/dev/null
sudo ls -lh /root/pre-lab-backup.tar.gz
```

```
-rw-r--r--. 1 root root 3.1K Aug 31 10:02 /root/pre-lab-backup.tar.gz
```

---

## Ejercicio 1 — Anatomía del conjunto de contraseñas shadow

**Objetivo:** demostrarte a vos mismo *por qué* existen las contraseñas shadow, mirando los permisos y la disposición de campos de ambas bases de datos.

1. Creá dos usuarios de prueba. Uno recibe contraseña, el otro no.

   ```bash
   sudo useradd -m -c "Shadow lab user" alice
   sudo useradd -m -c "Never logs in" svcbot
   echo 'alice:Lab-Passw0rd!' | sudo chpasswd
   ```

2. Mirá en qué se diferencian `/etc/passwd` y `/etc/shadow` en propiedad y modo.

   ```bash
   ls -l /etc/passwd /etc/shadow
   ```

   ```
   -rw-r--r--. 1 root root  2841 Aug 31 10:04 /etc/passwd
   ----------. 1 root root  1523 Aug 31 10:04 /etc/shadow
   ```

   En Debian/Ubuntu vas a ver `-rw-r----- 1 root shadow` en su lugar — modo `0640`, grupo `shadow`.

3. Compará los dos registros de `alice`.

   ```bash
   grep '^alice:' /etc/passwd
   sudo grep '^alice:' /etc/shadow
   ```

   ```
   alice:x:1001:1001:Shadow lab user:/home/alice:/bin/bash
   ```
   ```
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:20696:0:99999:7:::
   ```

4. Confirmá que la `x` del segundo campo de `/etc/passwd` es un *marcador de posición*, no un hash, contando los campos de cada archivo.

   ```bash
   awk -F: '$1=="alice"{print NF" fields in passwd"}' /etc/passwd
   sudo awk -F: '$1=="alice"{print NF" fields in shadow"}' /etc/shadow
   ```

   ```
   7 fields in passwd
   9 fields in shadow
   ```

5. Decodificá el tercer campo del registro shadow — *no* es una marca de tiempo Unix.

   ```bash
   sudo awk -F: '$1=="alice"{print $3}' /etc/shadow
   date -u -d "1970-01-01 UTC + 20696 days" +%F
   echo "today is day $(( $(date -u +%s) / 86400 ))"
   ```

   ```
   20696
   2026-08-31
   today is day 20696
   ```

6. Inspeccioná la cuenta que nunca recibió contraseña.

   ```bash
   sudo grep '^svcbot:' /etc/shadow
   sudo passwd -S svcbot
   sudo passwd -S alice
   ```

   ```
   svcbot:!:20696:0:99999:7:::
   svcbot L 2026-08-31 0 99999 7 -1
   alice P 2026-08-31 0 99999 7 -1
   ```

7. Mirá el prefijo del hash para identificar el algoritmo en uso, y el valor por defecto del sistema.

   ```bash
   sudo awk -F: '$1=="alice"{split($2,a,"$"); print "prefix: $"a[2]"$"}' /etc/shadow
   grep -E '^\s*(ENCRYPT_METHOD|SHA_CRYPT|YESCRYPT)' /etc/login.defs
   ```

   ```
   prefix: $y$
   ENCRYPT_METHOD YESCRYPT
   ```

   En sistemas de la familia RHEL vas a ver típicamente `$6$` y `ENCRYPT_METHOD SHA512`.

8. Ejecutá los verificadores de consistencia.

   ```bash
   sudo pwck -r
   sudo grpck -r
   echo "exit status: $?"
   ```

   ```
   user 'lp': directory '/var/spool/lpd' does not exist
   pwck: no changes
   exit status: 0
   ```

**Verificá tu comprensión**

* **Q1.1** `/etc/passwd` es legible por todo el mundo y `/etc/shadow` no. Nombrá dos piezas de información que *deben* seguir siendo legibles por todos, y explicá qué se rompe si hacés `chmod 600 /etc/passwd`.
* **Q1.2** Enumerá los nueve campos de `/etc/shadow` en orden, con la unidad o el significado de cada uno.
* **Q1.3** En el campo de contraseña de shadow, ¿cuál es la diferencia de efecto entre `!`, `!!`, `*` y un campo vacío?
* **Q1.4** `passwd -S alice` imprimió `P` y `passwd -S svcbot` imprimió `L`. ¿Qué tercera letra puede aparecer ahí, y por qué es peligrosa?
* **Q1.5** El campo de fecha contenía `20696`, no `1788148800`. ¿Cuál es la época y la unidad de ese campo, y qué significa un valor de `0`?

---

## Ejercicio 2 — Migrar entre bases de datos con y sin shadow

**Objetivo:** entender `pwconv` / `pwunconv` viendo cómo un hash se mueve entre archivos. **Hacé esto en un contenedor o una VM descartable.**

1. Tomá una copia de seguridad fresca desde la que puedas restaurar con una shell de root sin ninguna autenticación.

   ```bash
   sudo cp -a /etc/passwd /root/passwd.bak
   sudo cp -a /etc/shadow /root/shadow.bak
   ```

2. Quitá el shadow del sistema y observá qué pasa con los hashes.

   ```bash
   sudo pwunconv
   ls -l /etc/shadow
   grep '^alice:' /etc/passwd
   ```

   ```
   ls: cannot access '/etc/shadow': No such file or directory
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:1001:1001:Shadow lab user:/home/alice:/bin/bash
   ```

3. Confirmá la exposición. Como usuario **sin privilegios**, leé el hash que nunca deberías haber visto.

   ```bash
   su - svcbot -s /bin/bash -c "grep '^alice:' /etc/passwd | cut -d: -f2"
   ```

   ```
   $y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...
   ```

4. Volvé a aplicar shadow de inmediato y verificá que los metadatos de envejecimiento se reconstruyeron.

   ```bash
   sudo pwconv
   ls -l /etc/shadow
   sudo grep '^alice:' /etc/shadow
   grep '^alice:' /etc/passwd
   ```

   ```
   ----------. 1 root root 1523 Aug 31 10:19 /etc/shadow
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:20696:0:99999:7:::
   alice:x:1001:1001:Shadow lab user:/home/alice:/bin/bash
   ```

5. Hacé lo mismo para los grupos y fijate cuál es el archivo análogo.

   ```bash
   sudo grpconv
   ls -l /etc/gshadow
   sudo grep -c . /etc/gshadow
   ```

   ```
   ----------. 1 root root 923 Aug 31 10:20 /etc/gshadow
   62
   ```

**Verificá tu comprensión**

* **Q2.1** Después de `pwunconv`, ¿qué dos campos de shadow sobreviven en `/etc/passwd`, y cuáles siete se pierden?
* **Q2.2** ¿De dónde sacan `pwconv` y `pwunconv` los valores por defecto de `PASS_MIN_DAYS`, `PASS_MAX_DAYS` y `PASS_WARN_AGE` cuando reconstruyen `/etc/shadow`?
* **Q2.3** ¿Por qué nunca hay que editar `/etc/passwd` ni `/etc/shadow` con un simple `vi /etc/shadow`, y qué dos comandos habría que usar en su lugar?
* **Q2.4** `/etc/gshadow` guarda una contraseña de grupo. ¿En qué circunstancia se usa realmente, y qué comando la consume?

---

## Ejercicio 3 — Envejecimiento de contraseñas y bloqueo de cuentas como control de endurecimiento

**Objetivo:** usar `chage`, `usermod` y `passwd` para imponer una política de ciclo de vida, y distinguir *bloqueada* de *expirada* de *sin shell de login*.

1. Leé la política de envejecimiento actual de `alice`.

   ```bash
   sudo chage -l alice
   ```

   ```
   Last password change                                    : Aug 31, 2026
   Password expires                                        : never
   Password inactive                                       : never
   Account expires                                         : never
   Minimum number of days between password change          : 0
   Maximum number of days between password change          : 99999
   Number of days of warning before password expires       : 7
   ```

2. Aplicá una política de estilo productivo: mínimo 1 día, máximo 90 días, 14 días de aviso, 7 días de gracia por inactividad y una expiración dura de la cuenta.

   ```bash
   sudo chage -m 1 -M 90 -W 14 -I 7 -E 2027-01-31 alice
   sudo chage -l alice
   ```

   ```
   Last password change                                    : Aug 31, 2026
   Password expires                                        : Nov 29, 2026
   Password inactive                                       : Dec 06, 2026
   Account expires                                         : Jan 31, 2027
   Minimum number of days between password change          : 1
   Maximum number of days between password change          : 90
   Number of days of warning before password expires       : 14
   Number of days of warning before password expires       : 14
   ```

   ```bash
   sudo awk -F: '$1=="alice"{print}' /etc/shadow
   ```

   ```
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:20696:1:90:14:7:20849:
   ```

3. Forzá un cambio de contraseña en el próximo inicio de sesión sin conocer la contraseña actual.

   ```bash
   sudo chage -d 0 alice
   sudo awk -F: '$1=="alice"{print $3}' /etc/shadow
   ```

   ```
   0
   ```

   Deshacelo para que el resto del laboratorio siga funcionando:

   ```bash
   sudo chage -d $(date -u +%F) alice
   ```

4. Bloqueá la cuenta e inspeccioná el mecanismo.

   ```bash
   sudo usermod -L alice          # equivalent: passwd -l alice
   sudo awk -F: '$1=="alice"{print substr($2,1,4)}' /etc/shadow
   sudo passwd -S alice
   ```

   ```
   !$y$
   alice L 2026-08-31 1 90 14 7
   ```

5. Demostrá que bloquear la *contraseña* no deshabilita *todas* las vías de acceso.

   ```bash
   sudo mkdir -p /home/alice/.ssh
   sudo -u alice ssh-keygen -t ed25519 -N '' -f /home/alice/.ssh/id_ed25519 >/dev/null
   sudo -u alice sh -c 'cat /home/alice/.ssh/id_ed25519.pub >> /home/alice/.ssh/authorized_keys'
   sudo -u alice id
   ```

   ```
   uid=1001(alice) gid=1001(alice) groups=1001(alice)
   ```

   La cuenta está "bloqueada" y, sin embargo, `sudo -u alice`, `su - alice` desde root, los trabajos de cron y la autenticación SSH por clave pública siguen funcionando.

6. Aplicá los dos controles que *sí* cortan esas vías, y comparalos.

   ```bash
   sudo usermod -e 1 alice                  # account expiry: day 1 = 1970-01-02
   sudo su - alice
   ```

   ```
   Your account has expired; please contact your system administrator
   su: User account has expired
   ```

   ```bash
   sudo usermod -s /usr/sbin/nologin svcbot   # /sbin/nologin on RHEL-family
   sudo su - svcbot
   ```

   ```
   This account is currently not available.
   ```

7. Restaurá `alice` para los ejercicios posteriores.

   ```bash
   sudo usermod -U alice
   sudo chage -E -1 alice
   sudo passwd -S alice
   ```

   ```
   alice P 2026-08-31 1 90 14 7
   ```

8. Auditá todo el sistema en busca de cuentas que puedan iniciar sesión con contraseña.

   ```bash
   sudo awk -F: '$2 ~ /^\$/ {print $1}' /etc/shadow
   awk -F: '$3 >= 1000 && $3 < 65534 {print $1" -> "$7}' /etc/passwd
   awk -F: '$2 == "" {print "EMPTY PASSWORD FIELD: "$1}' /etc/shadow
   ```

   ```
   root
   alice
   alice -> /bin/bash
   svcbot -> /usr/sbin/nologin
   ```

**Verificá tu comprensión**

* **Q3.1** ¿Qué escribe exactamente `usermod -L` en `/etc/shadow`, y por qué ese único carácter hace que toda contraseña falle?
* **Q3.2** Dá tres vías de acceso que sobreviven a `passwd -l`. ¿Qué comando las cierra todas de una vez?
* **Q3.3** `chage -d 0 alice` pone el campo de último cambio en cero. ¿Cuál es el efecto visible para el usuario en el próximo inicio de sesión, y por qué `0` no se interpreta como "1 de enero de 1970"?
* **Q3.4** Explicá la diferencia entre los campos `-M` (máximo) e `-I` (inactivo) cuando una contraseña expira.
* **Q3.5** `/usr/sbin/nologin` y `/bin/false` ambos impiden una shell interactiva. ¿Qué hace `nologin` que `false` no hace, y qué archivo lo personaliza?

---

## Ejercicio 4 — Descubrir todos los servicios de red que están escuchando

**Objetivo:** construir el inventario antes de decidir qué apagar. No podés deshabilitar lo que no enumeraste.

1. Listá todos los sockets TCP y UDP en escucha junto con el proceso propietario.

   ```bash
   sudo ss -tulpen
   ```

   ```
   Netid State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
   udp   UNCONN 0      0       127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=680,fd=13)) uid:193 ino:18994
   udp   UNCONN 0      0             0.0.0.0:68         0.0.0.0:*     users:(("dhclient",pid=712,fd=6))         uid:0   ino:19240
   tcp   LISTEN 0      4096    127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=680,fd=14)) uid:193 ino:18995
   tcp   LISTEN 0      128           0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=901,fd=3))            uid:0   ino:20115
   tcp   LISTEN 0      511                 *:80               *:*     users:(("nginx",pid=1042,fd=6))          uid:0   ino:21330
   tcp   LISTEN 0      4096          0.0.0.0:111        0.0.0.0:*     users:(("rpcbind",pid=655,fd=4))         uid:0   ino:18321
   tcp   LISTEN 0      100         127.0.0.1:25         0.0.0.0:*     users:(("master",pid=1180,fd=13))        uid:0   ino:22004
   ```

   Decodificá las opciones: `-t` TCP, `-u` UDP, `-l` solo en escucha, `-p` proceso, `-e` extendido (uid, inodo), `-n` puertos numéricos.

2. Contrastá con `lsof` y con el comando heredado `netstat` que el examen todavía menciona.

   ```bash
   sudo lsof -nP -i -sTCP:LISTEN
   sudo netstat -tulpn 2>/dev/null | head -n 8
   ```

   ```
   COMMAND   PID  USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
   rpcbind   655  rpc    4u IPv4  18321      0t0  TCP *:111 (LISTEN)
   sshd      901  root   3u IPv4  20115      0t0  TCP *:22 (LISTEN)
   nginx    1042  root   6u IPv6  21330      0t0  TCP *:80 (LISTEN)
   master   1180  root  13u IPv4  22004      0t0  TCP 127.0.0.1:25 (LISTEN)
   ```

3. Traducí un número de puerto a su nombre de servicio convencional.

   ```bash
   grep -wE '^(ssh|smtp|sunrpc|http)' /etc/services
   getent services 111
   ```

   ```
   ssh    22/tcp
   smtp   25/tcp
   sunrpc 111/tcp   portmapper rpcbind
   http   80/tcp    www www-http
   sunrpc 111/tcp
   ```

4. Mapeá cada socket en escucha de vuelta a la unidad de systemd que lo posee.

   ```bash
   for p in 655 901 1042 1180; do
     printf '%-6s %s\n' "$p" "$(ps -o unit= -p $p)"
   done
   ```

   ```
   655    rpcbind.service
   901    sshd.service
   1042   nginx.service
   1180   postfix.service
   ```

5. Listá por separado las unidades habilitadas y las activadas por socket — un servicio *detenido* todavía puede ser alcanzable.

   ```bash
   systemctl list-unit-files --type=service --state=enabled --no-pager
   systemctl list-sockets --no-pager
   ```

   ```
   UNIT FILE                  STATE   PRESET
   nginx.service              enabled disabled
   rpcbind.service            enabled enabled
   sshd.service               enabled enabled
   ...

   LISTEN            UNIT                        ACTIVATES
   /run/dbus/system_bus_socket dbus.socket        dbus.service
   /run/rpcbind.sock rpcbind.socket               rpcbind.service
   [::]:22           sshd.socket                  sshd.service
   ```

6. Distinguí "escuchando en loopback" de "escuchando al mundo".

   ```bash
   sudo ss -tlpn | awk 'NR>1 {print $4"\t"$6}' | sed 's/users:(//;s/)$//'
   ```

   ```
   127.0.0.53%lo:53   "systemd-resolve",pid=680,fd=14
   0.0.0.0:22         "sshd",pid=901,fd=3
   *:80               "nginx",pid=1042,fd=6
   0.0.0.0:111        "rpcbind",pid=655,fd=4
   127.0.0.1:25       "master",pid=1180,fd=13
   ```

**Verificá tu comprensión**

* **Q4.1** ¿Por qué hay que ejecutar `ss -tulpen` como `root` para que sea útil? ¿Qué falta en la salida cuando lo ejecuta un usuario normal?
* **Q4.2** En la salida de arriba, ¿cuáles dos listeners *no* son alcanzables desde otro host, y cómo se puede saber solo a partir de la columna `Local Address:Port`?
* **Q4.3** `systemctl list-sockets` mostró `sshd.socket` activando `sshd.service`. Si ejecutás `systemctl stop sshd.service` y nada más, ¿el TCP 22 sigue siendo alcanzable? Explicá.
* **Q4.4** `/etc/services` mapea 111/tcp a `sunrpc`. ¿Editar ese archivo cambia el puerto al que se enlaza `rpcbind`? ¿Por qué sí o por qué no?
* **Q4.5** Un puerto muestra `LISTEN` con la columna `Process` vacía incluso bajo `sudo`. Dá una explicación plausible.

---

## Ejercicio 5 — Apagar los servicios que no necesitás

**Objetivo:** la diferencia entre `stop`, `disable`, `mask` y quitar el paquete — y la trampa de la unidad socket.

1. Elegí un servicio genuinamente innecesario. En la mayoría de los sistemas `rpcbind` es un buen candidato salvo que uses NFS.

   ```bash
   systemctl is-active rpcbind.service
   systemctl is-enabled rpcbind.service
   systemctl is-enabled rpcbind.socket
   ```

   ```
   active
   enabled
   enabled
   ```

2. Detenelo y volvé a probar el puerto de inmediato.

   ```bash
   sudo systemctl stop rpcbind.service
   sudo ss -tlpn | grep ':111' || echo "111 closed"
   ```

   ```
   tcp LISTEN 0 4096 0.0.0.0:111 0.0.0.0:* users:(("systemd",pid=1,fd=42))
   ```

   El puerto *sigue abierto* — `systemd` (PID 1) lo mantiene en nombre de `rpcbind.socket`.

3. Detené y deshabilitá también la unidad socket, y volvé a probar.

   ```bash
   sudo systemctl disable --now rpcbind.socket rpcbind.service
   sudo ss -tlpn | grep ':111' || echo "111 closed"
   ```

   ```
   Removed "/etc/systemd/system/sockets.target.wants/rpcbind.socket".
   Removed "/etc/systemd/system/multi-user.target.wants/rpcbind.service".
   111 closed
   ```

4. Verificá que no vuelva tras un cambio de estado equivalente a un reinicio.

   ```bash
   systemctl is-enabled rpcbind.service rpcbind.socket
   ```

   ```
   disabled
   disabled
   ```

5. Hacé que el servicio sea imposible de iniciar, incluso como dependencia de otra cosa.

   ```bash
   sudo systemctl mask rpcbind.socket
   ls -l /etc/systemd/system/rpcbind.socket
   sudo systemctl start rpcbind.socket
   ```

   ```
   lrwxrwxrwx. 1 root root 9 Aug 31 10:41 /etc/systemd/system/rpcbind.socket -> /dev/null
   Failed to start rpcbind.socket: Unit rpcbind.socket is masked.
   ```

6. Leé una unidad socket para ver de dónde sale realmente el número de puerto.

   ```bash
   systemctl cat rpcbind.socket | head -n 20
   ```

   ```
   # /usr/lib/systemd/system/rpcbind.socket
   [Unit]
   Description=RPCbind Server Activation Socket

   [Socket]
   ListenStream=/run/rpcbind.sock
   ListenStream=0.0.0.0:111
   ListenDatagram=0.0.0.0:111
   BindIPv6Only=ipv6-only

   [Install]
   WantedBy=sockets.target
   ```

7. Restringí un servicio que *sí* necesitás en lugar de eliminarlo. Enlazá `sshd` a una sola dirección con un drop-in de sobreescritura en vez de editar la unidad provista.

   ```bash
   sudo systemctl edit --force sshd.socket
   ```

   ```ini
   ### /etc/systemd/system/sshd.socket.d/override.conf
   [Socket]
   ListenStream=
   ListenStream=192.168.178.20:22
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart sshd.socket
   sudo ss -tlpn | grep ':22'
   ```

   ```
   tcp LISTEN 0 4096 192.168.178.20:22 0.0.0.0:* users:(("systemd",pid=1,fd=44))
   ```

8. Inspeccioná los mecanismos de la era SysV que el objetivo todavía lista, para poder leer una máquina heredada.

   ```bash
   ls /etc/init.d/ 2>/dev/null | head
   ls /etc/rc3.d/ 2>/dev/null | head -n 5
   cat /etc/inittab 2>/dev/null || echo "/etc/inittab absent — systemd system"
   systemctl get-default
   ```

   ```
   README
   S01rsyslog
   S02ssh
   /etc/inittab absent — systemd system
   multi-user.target
   ```

9. Deshacé los cambios que afectarían a los ejercicios posteriores.

   ```bash
   sudo systemctl unmask rpcbind.socket
   sudo rm -f /etc/systemd/system/sshd.socket.d/override.conf
   sudo systemctl daemon-reload
   ```

**Verificá tu comprensión**

* **Q5.1** Ordená estos de más débil a más fuerte, y decí con precisión qué previene cada uno: `systemctl stop`, `systemctl disable`, `systemctl mask`, eliminación del paquete.
* **Q5.2** En el paso 2, el puerto quedó abierto después de detener el servicio y el proceso mostrado fue `systemd` con PID 1. Explicá el mecanismo en una oración.
* **Q5.3** ¿Por qué `systemctl disable` por sí solo deja corriendo un servicio que está en ejecución, y qué opción arregla eso en un solo comando?
* **Q5.4** Enmascaraste una unidad. `systemctl cat` sigue mostrando el contenido del archivo original. ¿Dónde vive la máscara, y de qué es un enlace simbólico?
* **Q5.5** En un sistema con SysV init, ¿cuál es el equivalente de `systemctl disable sshd`, expresado en términos de `/etc/init.d/` y los directorios de niveles de ejecución?
* **Q5.6** `systemctl get-default` devolvió `multi-user.target`. ¿Qué directiva de `/etc/inittab` reemplazó eso, y cuál era el nivel de ejecución numérico correspondiente?

---

## Ejercicio 6 — El super-servidor heredado: `inetd` y `xinetd`

**Objetivo:** leer y razonar sobre la configuración de un super-servidor. La mayoría de las distribuciones actuales ya no instalan `xinetd`; el examen todavía evalúa la disposición de los archivos, así que el ejercicio está escrito para funcionar con o sin el paquete.

1. Comprobá si existe un super-servidor en tu sistema.

   ```bash
   command -v xinetd inetd 2>/dev/null || echo "no super-server installed"
   ls -d /etc/xinetd.conf /etc/xinetd.d /etc/inetd.conf 2>/dev/null || echo "no super-server config"
   ```

   ```
   no super-server installed
   no super-server config
   ```

2. Reconstruí el archivo de configuración principal y leelo como documentación.

   ```bash
   sudo mkdir -p /etc/xinetd.d
   sudo tee /etc/xinetd.conf >/dev/null <<'EOF'
   defaults
   {
       instances      = 60
       log_type       = SYSLOG authpriv
       log_on_success = HOST PID
       log_on_failure = HOST
       cps            = 25 30
       per_source     = 10
   }

   includedir /etc/xinetd.d
   EOF
   sudo cat /etc/xinetd.conf
   ```

3. Escribí un archivo por servicio que esté deliberadamente deshabilitado y con acceso restringido.

   ```bash
   sudo tee /etc/xinetd.d/telnet >/dev/null <<'EOF'
   service telnet
   {
       disable         = yes
       socket_type     = stream
       protocol        = tcp
       wait            = no
       user            = root
       server          = /usr/sbin/in.telnetd
       only_from       = 192.168.178.0/24
       no_access       = 192.168.178.99
       access_times    = 08:00-18:00
       bind            = 192.168.178.20
       log_on_failure += USERID
   }
   EOF
   sudo cat /etc/xinetd.d/telnet
   ```

4. Razoná sobre cada directiva sin ejecutar el demonio.

   ```bash
   grep -E 'disable|only_from|no_access|access_times|bind|wait|instances|cps|per_source' \
     /etc/xinetd.conf /etc/xinetd.d/telnet
   ```

   ```
   /etc/xinetd.conf:    instances      = 60
   /etc/xinetd.conf:    cps            = 25 30
   /etc/xinetd.conf:    per_source     = 10
   /etc/xinetd.d/telnet:    disable         = yes
   /etc/xinetd.d/telnet:    only_from       = 192.168.178.0/24
   /etc/xinetd.d/telnet:    no_access       = 192.168.178.99
   /etc/xinetd.d/telnet:    access_times    = 08:00-18:00
   /etc/xinetd.d/telnet:    bind            = 192.168.178.20
   ```

5. Compará con la sintaxis más antigua de archivo único de `inetd`.

   ```bash
   sudo tee /etc/inetd.conf.example >/dev/null <<'EOF'
   # <service> <socket> <proto> <flags> <user> <server_path>      <args>
   ftp        stream    tcp     nowait  root   /usr/sbin/tcpd     in.ftpd -l -a
   telnet     stream    tcp     nowait  root   /usr/sbin/tcpd     in.telnetd
   #tftp      dgram     udp     wait    root   /usr/sbin/tcpd     in.tftpd -s /srv/tftp
   EOF
   awk '!/^#/ && NF {print $1"\t"$4"\t"$6"\t"$7}' /etc/inetd.conf.example
   ```

   ```
   ftp     nowait  /usr/sbin/tcpd  in.ftpd
   telnet  nowait  /usr/sbin/tcpd  in.ftpd
   ```

6. Fijate cómo se recarga un `xinetd` en ejecución (no ejecutes esto si el demonio no está presente).

   ```bash
   # Soft reconfigure: re-read config, keep existing connections
   # sudo kill -HUP $(pidof xinetd)
   # Hard reconfigure: also kill running child servers
   # sudo kill -USR2 $(pidof xinetd)
   echo "SIGHUP = reconfigure; SIGUSR2 = hard reconfigure; SIGTERM = quit"
   ```

7. Limpiá los archivos reconstruidos.

   ```bash
   sudo rm -f /etc/xinetd.conf /etc/xinetd.d/telnet /etc/inetd.conf.example
   sudo rmdir /etc/xinetd.d 2>/dev/null
   ```

**Verificá tu comprensión**

* **Q6.1** ¿Qué problema se diseñó para resolver el super-servidor, y cuál es su equivalente moderno en systemd?
* **Q6.2** En `/etc/xinetd.d/telnet`, ¿cuál es el efecto de `disable = yes` frente a borrar el archivo? ¿Cuál es preferible en un sistema auditado?
* **Q6.3** Aparecen tanto `only_from` como `no_access`. ¿Cuál gana cuando una dirección coincide con ambos, y por qué?
* **Q6.4** Explicá `wait = no` para un servicio `stream` y `wait = yes` para un servicio `dgram`. ¿Qué se rompería si los intercambiaras?
* **Q6.5** En `/etc/inetd.conf`, el campo del servidor es `/usr/sbin/tcpd` y el demonio real aparece en los argumentos. ¿Qué está haciendo `tcpd` ahí?
* **Q6.6** `cps = 25 30` en el bloque `defaults`. Interpretá ambos números y nombrá la clase de ataque que mitiga.

---

## Ejercicio 7 — TCP wrappers: `/etc/hosts.allow` y `/etc/hosts.deny`

**Objetivo:** determinar si un binario reconoce los wrappers, escribir reglas correctas y probarlas *sin* dejarte afuera.

1. Determiná si los TCP wrappers existen siquiera en este sistema.

   ```bash
   ls -l /etc/hosts.allow /etc/hosts.deny 2>/dev/null
   ls -l /lib/*/libwrap.so* /usr/lib64/libwrap.so* 2>/dev/null
   command -v tcpdchk tcpdmatch 2>/dev/null || echo "tcpd utilities not installed"
   ```

   Debian/Ubuntu:
   ```
   -rw-r--r-- 1 root root 411 Aug 31 10:55 /etc/hosts.allow
   -rw-r--r-- 1 root root 711 Aug 31 10:55 /etc/hosts.deny
   -rw-r--r-- 1 root root 42280 /lib/x86_64-linux-gnu/libwrap.so.0.7.6
   ```
   Fedora / RHEL 8+:
   ```
   ls: cannot access '/etc/hosts.allow': No such file or directory
   tcpd utilities not installed
   ```

2. Probá si un demonio específico está realmente enlazado contra `libwrap`. **Esta es la comprobación decisiva** — los archivos son inertes para cualquier binario que no la enlace.

   ```bash
   ldd "$(command -v sshd || echo /usr/sbin/sshd)" | grep -i libwrap || echo "sshd: NOT wrapper-aware"
   ldd /usr/sbin/rpcbind 2>/dev/null | grep -i libwrap || echo "rpcbind: NOT wrapper-aware"
   ```

   ```
   sshd: NOT wrapper-aware
   rpcbind: NOT wrapper-aware
   ```

   OpenSSH eliminó el soporte de `libwrap` en la versión 6.7 (2014). Verificá tu versión:

   ```bash
   sshd -V 2>&1 | head -n 1 || ssh -V
   ```

   ```
   OpenSSH_9.6p1, OpenSSL 3.0.13 30 Jan 2024
   ```

3. Escribí el par clásico de denegación por defecto. El orden importa: creá primero las reglas de `allow`.

   ```bash
   sudo tee /etc/hosts.allow >/dev/null <<'EOF'
   # <daemon list> : <client list> [: <shell command>]
   sshd, in.telnetd : 192.168.178.0/255.255.255.0
   vsftpd           : .example.com EXCEPT ftp-guest.example.com
   ALL              : LOCAL
   EOF

   sudo tee /etc/hosts.deny >/dev/null <<'EOF'
   ALL : ALL : spawn /bin/echo "$(date) denied %d from %h (%a)" >> /var/log/tcpwrap.log
   EOF

   sudo cat /etc/hosts.allow /etc/hosts.deny
   ```

4. Comprobá la sintaxis con el linter propio del wrapper (Debian/Ubuntu, paquete `tcpd`).

   ```bash
   sudo tcpdchk -v
   ```

   ```
   Using network configuration file: /etc/inetd.conf

   >>> Rule /etc/hosts.allow line 2:
   daemons:  sshd in.telnetd
   clients:  192.168.178.0/255.255.255.0
   access:   granted

   >>> Rule /etc/hosts.deny line 1:
   daemons:  ALL
   clients:  ALL
   option:   spawn /bin/echo ...
   access:   denied
   ```

5. Simulá una decisión para un par demonio/cliente concreto — sin necesidad de paquetes.

   ```bash
   tcpdmatch sshd 192.168.178.50
   tcpdmatch sshd 203.0.113.9
   tcpdmatch vsftpd ftp-guest.example.com
   ```

   ```
   client:   address 192.168.178.50
   server:   process sshd
   access:   granted

   client:   address 203.0.113.9
   server:   process sshd
   access:   denied

   client:   hostname ftp-guest.example.com
   server:   process vsftpd
   access:   denied
   ```

6. Rastreá el orden de evaluación deliberadamente agregando una regla contradictoria.

   ```bash
   printf 'sshd : 203.0.113.9\n' | sudo tee -a /etc/hosts.allow >/dev/null
   tcpdmatch sshd 203.0.113.9
   ```

   ```
   access:   granted
   ```

   Se consultó primero `hosts.allow` y hubo coincidencia, así que nunca se llegó a `hosts.deny`.

7. Aprendé las formas de patrón de dirección probando cada una.

   ```bash
   for pat in '192.168.178.' '192.168.178.0/24' '192.168.178.0/255.255.255.0' '.example.com' 'LOCAL' 'PARANOID'; do
     printf '%-32s ' "$pat"
     echo "sshd : $pat" | sudo tee /tmp/pattern-test >/dev/null && echo "syntax ok"
   done
   ```

   ```
   192.168.178.                     syntax ok
   192.168.178.0/24                 syntax ok
   192.168.178.0/255.255.255.0      syntax ok
   .example.com                     syntax ok
   LOCAL                            syntax ok
   PARANOID                         syntax ok
   ```

   Nota: la forma de longitud de prefijo `/24` está soportada por las compilaciones recientes de `libwrap`; la forma de máscara de red `0/255.255.255.0` es la portable y la correcta para el examen.

8. Restaurá los originales.

   ```bash
   sudo tar xzf /root/pre-lab-backup.tar.gz -C / etc/hosts.allow etc/hosts.deny 2>/dev/null \
     || sudo rm -f /etc/hosts.allow /etc/hosts.deny
   ```

**Verificá tu comprensión**

* **Q7.1** Enunciá el algoritmo completo de evaluación en tres pasos de los TCP wrappers, incluyendo qué pasa cuando ninguno de los dos archivos coincide.
* **Q7.2** `ldd $(which sshd)` no imprimió nada para `libwrap`. ¿Qué significa eso para las dos reglas que escribiste para `sshd`, y qué habría que usar en su lugar en un sistema actual?
* **Q7.3** ¿Qué nombre hace coincidir la lista de demonios — la ruta en `/etc/inetd.conf`, el nombre del proceso, o la unidad de systemd? ¿Por qué importa la diferencia entre `in.telnetd` y `telnetd`?
* **Q7.4** Explicá `LOCAL`, `KNOWN`, `UNKNOWN` y `PARANOID`. ¿Cuáles dos dependen de un DNS inverso funcional, y cuál es el riesgo operativo de confiar en ellos?
* **Q7.5** Escribí una única línea que deniegue todo excepto la red 10.0.0.0/8, usando solo `/etc/hosts.deny`. Después explicá por qué la forma de dos archivos sigue siendo preferible.
* **Q7.6** ¿Cuál es la diferencia entre `spawn` y `twist` en el tercer campo opcional?

---

## Ejercicio 8 — `/etc/nologin`: bloquear inicios de sesión durante el mantenimiento

**Objetivo:** usar el bloqueo estándar de mantenimiento, entender que root está exento y encontrar dónde lo aplica PAM.

1. Creá el archivo de bloqueo con un mensaje dirigido al operador.

   ```bash
   sudo tee /etc/nologin >/dev/null <<'EOF'
   System is down for scheduled maintenance until 12:00 UTC.
   Contact ops@example.com for emergencies.
   EOF
   sudo chmod 644 /etc/nologin
   ```

2. Intentá un inicio de sesión como no-root y observá el mensaje.

   ```bash
   sudo login -f alice < /dev/null
   ```

   ```
   System is down for scheduled maintenance until 12:00 UTC.
   Contact ops@example.com for emergencies.
   ```

3. Verificá que root sigue siendo admitido.

   ```bash
   sudo login -f root < /dev/null && echo "root login permitted"
   ```

   ```
   root login permitted
   ```

4. Encontrá el módulo PAM que lo aplica, y mirá qué servicios lo incluyen.

   ```bash
   grep -rl pam_nologin /etc/pam.d/
   grep -h pam_nologin /etc/pam.d/* | sort -u
   ```

   ```
   /etc/pam.d/login
   /etc/pam.d/sshd
   /etc/pam.d/postlogin
   account required pam_nologin.so
   auth  required pam_nologin.so
   ```

5. Fijate en el segundo archivo que PAM consulta, y en la unidad de systemd que lo administra.

   ```bash
   ls -l /run/nologin 2>/dev/null || echo "/run/nologin absent"
   systemctl cat systemd-user-sessions.service | grep -A3 '\[Service\]'
   man 8 pam_nologin | grep -A4 'nologin file'
   ```

   ```
   /run/nologin absent
   [Service]
   Type=oneshot
   RemainAfterExit=yes
   ExecStart=/usr/lib/systemd/systemd-user-sessions start
   ExecStop=/usr/lib/systemd/systemd-user-sessions stop
   ```

6. Demostrá que `/etc/nologin` no detiene todo.

   ```bash
   sudo -u alice id            # sudo does not include pam_nologin in most defaults
   sudo crontab -u alice -l 2>/dev/null || echo "no crontab for alice"
   sudo systemctl is-active cron 2>/dev/null || systemctl is-active crond
   ```

   ```
   uid=1001(alice) gid=1001(alice) groups=1001(alice)
   no crontab for alice
   active
   ```

7. Liberá el bloqueo — y hacé que liberarlo sea parte de tu procedimiento, no una ocurrencia tardía.

   ```bash
   sudo rm -f /etc/nologin
   sudo login -f alice < /dev/null && echo "logins restored"
   ```

   ```
   logins restored
   ```

**Verificá tu comprensión**

* **Q8.1** ¿Qué usuario está exento de `/etc/nologin`, y dónde está implementada esa exención — en `login`, en PAM o en el kernel?
* **Q8.2** PAM comprueba dos rutas. Nombrá ambas, indicá el orden y explicá por qué un sistema con systemd prefiere la que está bajo `/run`.
* **Q8.3** `/etc/nologin` (el archivo) y `/usr/sbin/nologin` (la shell) tienen nombres confusamente parecidos. Enunciá el propósito de cada uno y el del tercer archivo relacionado, `/etc/nologin.txt`.
* **Q8.4** Nombrá dos vías de acceso que `/etc/nologin` **no** bloquea, y dá un control adicional para cada una.
* **Q8.5** Después de un `shutdown -h +30`, los usuarios informan que no pueden iniciar sesión aunque la máquina sigue levantada. ¿Qué pasó, y cómo lo cancelás?

---

## Ejercicio 9 — Consolidación: una auditoría repetible de seguridad del host

**Objetivo:** convertir todo lo anterior en un único script que puedas ejecutar antes y después del endurecimiento.

1. Escribí el script de auditoría.

   ```bash
   sudo tee /usr/local/sbin/host-security-audit >/dev/null <<'EOF'
   #!/bin/bash
   # Minimal LPIC-1 110.2 host security audit. Read-only; prints findings.
   set -u

   echo "=== 1. Shadow suite ==="
   [ -f /etc/shadow ] && echo "OK   /etc/shadow present" || echo "FAIL passwords are not shadowed"
   stat -c '%a %U:%G %n' /etc/passwd /etc/shadow
   awk -F: '$2 == "" {print "FAIL empty password: "$1}' /etc/shadow
   awk -F: '$3 == 0 && $1 != "root" {print "WARN extra uid-0 account: "$1}' /etc/passwd

   echo
   echo "=== 2. Password aging on human accounts ==="
   awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | while read -r u; do
     max=$(awk -F: -v u="$u" '$1==u{print $5}' /etc/shadow)
     [ "${max:-99999}" -ge 99999 ] && echo "WARN $u: password never expires"
   done

   echo
   echo "=== 3. Listening sockets ==="
   ss -tulpnH | awk '{print $1, $5, $7}'

   echo
   echo "=== 4. Externally reachable listeners ==="
   ss -tlpnH | awk '$4 !~ /^(127\.|\[::1\])/ {print "REVIEW "$4"  "$6}'

   echo
   echo "=== 5. Enabled units and socket activation ==="
   systemctl list-unit-files --type=service --state=enabled --no-legend | wc -l | \
     xargs printf 'INFO %s enabled service units\n'
   systemctl list-sockets --no-legend --no-pager | wc -l | \
     xargs printf 'INFO %s active socket units\n'

   echo
   echo "=== 6. Super-server ==="
   [ -d /etc/xinetd.d ] && grep -L 'disable\s*=\s*yes' /etc/xinetd.d/* 2>/dev/null \
     | sed 's/^/WARN enabled xinetd service: /' || echo "OK   no xinetd configuration"

   echo
   echo "=== 7. TCP wrappers ==="
   if [ -f /etc/hosts.deny ]; then
     grep -q '^ALL\s*:\s*ALL' /etc/hosts.deny && echo "OK   default-deny present" \
       || echo "WARN /etc/hosts.deny has no ALL:ALL default"
   else
     echo "INFO tcp_wrappers not configured on this system"
   fi

   echo
   echo "=== 8. Maintenance lock ==="
   for f in /etc/nologin /run/nologin; do
     [ -f "$f" ] && echo "WARN $f present — non-root logins are blocked"
   done
   exit 0
   EOF
   sudo chmod 750 /usr/local/sbin/host-security-audit
   ```

2. Ejecutalo y leé los hallazgos.

   ```bash
   sudo /usr/local/sbin/host-security-audit
   ```

   ```
   === 1. Shadow suite ===
   OK   /etc/shadow present
   644 root:root /etc/passwd
   640 root:shadow /etc/shadow

   === 2. Password aging on human accounts ===
   WARN svcbot: password never expires

   === 3. Listening sockets ===
   udp 127.0.0.53%lo:53 users:(("systemd-resolve",pid=680,fd=13))
   tcp 0.0.0.0:22 users:(("sshd",pid=901,fd=3))
   tcp 127.0.0.1:25 users:(("master",pid=1180,fd=13))

   === 4. Externally reachable listeners ===
   REVIEW 0.0.0.0:22  users:(("sshd",pid=901,fd=3))

   === 5. Enabled units and socket activation ===
   INFO 18 enabled service units
   INFO 9 active socket units

   === 6. Super-server ===
   OK   no xinetd configuration

   === 7. TCP wrappers ===
   INFO tcp_wrappers not configured on this system

   === 8. Maintenance lock ===
   ```

3. Remediá un hallazgo y volvé a ejecutar para confirmar la diferencia.

   ```bash
   sudo chage -M 90 -W 14 svcbot
   sudo /usr/local/sbin/host-security-audit | sed -n '/=== 2/,/=== 3/p'
   ```

   ```
   === 2. Password aging on human accounts ===

   === 3. Listening sockets ===
   ```

4. Desarmá los usuarios del laboratorio.

   ```bash
   sudo userdel -r alice
   sudo userdel -r svcbot
   sudo rm -f /usr/local/sbin/host-security-audit /root/pre-lab-backup.tar.gz
   ```

**Verificá tu comprensión**

* **Q9.1** La sección 4 del script filtra las direcciones que empiezan con `127.` — pero el filtro es incompleto para un host de doble pila. ¿Qué se le escapa, y cómo arreglarías el patrón?
* **Q9.2** La sección 1 avisa sobre cuentas extra con UID 0. ¿Por qué una segunda cuenta con UID 0 es un hallazgo de seguridad del host aunque tenga una contraseña fuerte?
* **Q9.3** El script es de solo lectura por diseño. Dá dos razones por las que una herramienta de auditoría no debería remediar automáticamente.
* **Q9.4** ¿Cuál de las tres áreas del objetivo (contraseñas shadow / servicios sin usar / TCP wrappers) cubre *peor* este script, y qué agregarías?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** `/etc/passwd` debe seguir siendo legible por todos porque es el mapeo UID→nombre y GID→nombre del sistema y la fuente del directorio home y de la shell de login. `ls -l`, `ps`, `find -user` y cualquier programa que llame a `getpwuid()` lo necesitan. Si hacés `chmod 600 /etc/passwd`, `ls -l` imprime UID numéricos crudos en lugar de nombres, la salida de `ps` se degrada, muchos demonios que bajan privilegios por nombre fallan al iniciar, y `su`/`sudo` pueden romperse. El diseño de shadow existe precisamente para que el *hash* pueda sacarse de ese archivo legible por todos en lugar de volver secreto el archivo entero.

**A1.2** En orden, separados por dos puntos:

| # | Campo | Significado |
|---|-------|-------------|
| 1 | Nombre de login | Debe coincidir con el campo 1 de `/etc/passwd` |
| 2 | Contraseña cifrada | `$id$salt$hash`, o `!`/`*`/vacío |
| 3 | Último cambio | Días desde 1970-01-01 (UTC) |
| 4 | Edad mínima | Días que deben pasar antes de que la contraseña pueda cambiarse de nuevo |
| 5 | Edad máxima | Días tras los cuales la contraseña debe cambiarse |
| 6 | Período de aviso | Días de aviso antes de la expiración |
| 7 | Período de inactividad | Días de gracia *después* de la expiración antes de que la cuenta se deshabilite |
| 8 | Fecha de expiración | Expiración absoluta de la cuenta, días desde 1970-01-01 |
| 9 | Reservado | Sin uso |

**A1.3**
* `!` — la cuenta está **bloqueada**. El `!` lo antepone al hash existente `usermod -L`/`passwd -l`, de modo que ninguna contraseña provista puede producir jamás una cadena coincidente; quitar el `!` restaura la contraseña original.
* `!!` — usado por el `useradd` de la familia RHEL para significar "nunca se estableció una contraseña". Funcionalmente también es inutilizable.
* `*` — usado convencionalmente para cuentas de sistema/servicio que nunca deben autenticarse con contraseña. Como `!`, no es un hash válido; la diferencia práctica es solo la convención y el hecho de que no destruye ningún hash previo.
* **Vacío** — **no se requiere contraseña**. Según la configuración de PAM (`nullok`), la cuenta puede iniciar sesión sin credenciales en absoluto. Esto siempre es un hallazgo.

**A1.4** Los tres estados son `P` (contraseña utilizable), `L` (bloqueada) y `NP` (**sin contraseña** — el campo está vacío). `NP` es peligroso porque la cuenta puede autenticarse con una cadena vacía dondequiera que PAM permita contraseñas nulas, lo que funcionalmente es un inicio de sesión sin autenticación.

**A1.5** La época es 1970-01-01 UTC y la unidad son **días**, no segundos. Un valor de `0` es un caso especial: *no* significa 1 de enero de 1970 sino "la contraseña debe cambiarse en el próximo inicio de sesión" — esto es lo que establecen `chage -d 0` y `passwd -e`. Un campo **vacío** significa que el envejecimiento está deshabilitado para esa cuenta.

### Ejercicio 2

**A2.1** Solo sobreviven el **nombre de login** y la **contraseña cifrada**; la contraseña vuelve al campo 2 de `/etc/passwd`, reemplazando la `x`. Los siete campos de envejecimiento — último cambio, mín, máx, aviso, inactivo, expiración, reservado — se descartan, porque `/etc/passwd` no tiene lugar donde almacenarlos. Por eso `pwunconv` es una operación con pérdida.

**A2.2** De `/etc/login.defs` — `PASS_MIN_DAYS`, `PASS_MAX_DAYS` y `PASS_WARN_AGE`. `pwconv` además pone el campo de último cambio en la fecha de hoy para cada cuenta que migra, lo cual es en sí un efecto secundario sutil.

**A2.3** La edición directa arriesga corromper el archivo y, peor, compite con un `passwd`, `useradd` o `chage` concurrente que sostiene `/etc/passwd.lock` — los dos escritores pueden pisarse y dejar cuentas inutilizables. Usá **`vipw`** para `/etc/passwd` (y `vipw -s` para `/etc/shadow`) y **`vigr`** para `/etc/group` (`vigr -s` para `/etc/gshadow`). Estos toman el bloqueo correcto, invocan `$EDITOR` y validan al salir.

**A2.4** La contraseña de grupo en `/etc/gshadow` la consume **`newgrp`** (y `sg`): un usuario que *no* es miembro del grupo puede unirse a él durante la vida de una nueva shell proporcionando esa contraseña. Se usa rara vez y en general se considera obsoleta; la mayoría de los sitios la dejan como `!` o `*` y gestionan la pertenencia explícitamente.

### Ejercicio 3

**A3.1** Antepone un único carácter `!` a la cadena de hash existente en el campo 2. La verificación de contraseña funciona volviendo a hashear la contraseña provista con la sal almacenada y comparando el resultado con la cadena almacenada; una cadena que empieza con `!` no es un hash válido de nada, así que la comparación nunca puede tener éxito. El hash original se conserva intacto detrás del `!`, que es por lo que `usermod -U` restaura la contraseña previa exactamente.

**A3.2** Entre las vías que sobreviven están: autenticación SSH por **clave pública**, `su - user` ejecutado por root, `sudo -u user`, trabajos de cron y de temporizadores de systemd que corren como ese usuario, y cualquier servicio que autentique al usuario por un mecanismo distinto de la contraseña (Kerberos, LDAP con un bind diferente, módulos PAM que saltean `pam_unix`). El control que las cierra todas de una vez es la **expiración de la cuenta**: `usermod -e 1 user` o `chage -E 1970-01-02 user`, que hace que la fase de cuenta de PAM rechace al usuario sin importar el método de autenticación.

**A3.3** En el próximo inicio de sesión el usuario se autentica normalmente y luego es forzado de inmediato a un cambio de contraseña antes de obtener una shell (`passwd -e` hace lo mismo). El `0` no se lee como fecha porque `shadow` lo reserva como centinela que significa "expirada, cambiala ahora"; un 1970-01-01 genuino sería indistinguible, lo cual es una verruga histórica aceptada.

**A3.4** `-M` (máximo) es cuándo la contraseña **expira** — después de esa cantidad de días el usuario es forzado a cambiarla en el próximo inicio de sesión, pero todavía puede iniciar sesión para hacerlo. `-I` (inactivo) es la **ventana de gracia posterior** a la expiración: una vez que pasaron máx + inactivo días sin un cambio, la cuenta se deshabilita por completo y el usuario ya no puede iniciar sesión para arreglarlo. `-I -1` deshabilita la ventana de gracia (gracia ilimitada); `-I 0` deshabilita la cuenta en el momento en que la contraseña expira.

**A3.5** `/bin/false` sale de inmediato con estado 1 y no imprime nada — el usuario ve una desconexión silenciosa. `/usr/sbin/nologin` imprime un mensaje cortés de rechazo y luego sale, y además registra el intento vía syslog. El mensaje se personaliza creando **`/etc/nologin.txt`**; si ese archivo existe, `nologin` imprime su contenido en lugar del "This account is currently not available." incorporado.

### Ejercicio 4

**A4.1** Leer las entradas de `/proc/<pid>/fd` necesarias para mapear un inodo de socket a un proceso requiere privilegios sobre ese proceso. Sin root, la columna `Process` está vacía para todo socket que no te pertenezca, así que obtenés puertos sin propietarios — suficiente para ver *que* algo escucha, no *qué*. Los campos `uid:` e `ino:` de `-e` quedan igualmente incompletos.

**A4.2** `127.0.0.53%lo:53` y `127.0.0.1:25`. Ambos están enlazados a direcciones de loopback, así que el kernel no aceptará paquetes para ellos que lleguen por una interfaz física. `0.0.0.0:*` (o `*:*`) en la columna de dirección local significa "todas las direcciones IPv4"; `[::]` significa todas las direcciones IPv6; cualquier cosa en `127.0.0.0/8` o `[::1]` es solo loopback.

**A4.3** **Sí, el puerto 22 sigue siendo alcanzable.** Con la activación por socket, `systemd` (PID 1) sostiene el socket en escucha. Detener el servicio solo mata al demonio; la próxima conexión entrante hace que systemd inicie `sshd.service` de nuevo. Tenés que detener *y deshabilitar* también la unidad socket: `systemctl disable --now sshd.socket sshd.service`.

**A4.4** **No.** `/etc/services` es una tabla de consulta nombre↔número consultada por `getservbyname()`/`getaddrinfo()` y por herramientas de visualización. Un demonio se enlaza al puerto que especifique su propia configuración (`Port` en `sshd_config`, `ListenStream=` en una unidad socket, un valor por defecto embebido). Algunos demonios *sí* buscan su nombre en `/etc/services` para su valor por defecto, pero cambiar el archivo no mueve retroactivamente un socket ya enlazado, y la mayoría de los demonios modernos lo ignoran.

**A4.5** Lo más probable es que el socket pertenezca a un proceso dentro de un **espacio de nombres de red o de PID** distinto — un contenedor, o un invitado `systemd-nspawn`/VM — así que el inodo no es resoluble desde tu espacio de nombres. Otras posibilidades: el socket lo sostiene un hilo del kernel (por ejemplo, servidor NFS, listeners `kernel_tcp`), o el proceso terminó entre la enumeración de sockets y el recorrido de `/proc`.

### Ejercicio 5

**A5.1** De más débil a más fuerte:
1. **`systemctl stop`** — mata la instancia en ejecución ahora. Nada impide que vuelva a iniciarse en el arranque o bajo demanda.
2. **`systemctl disable`** — quita los enlaces simbólicos de `.wants/` para que no arranque en el boot. Todavía puede iniciarse manualmente o ser arrastrado como dependencia de otra unidad.
3. **`systemctl mask`** — enlaza la unidad a `/dev/null`, de modo que no puede iniciarse por *ningún* medio, incluso como dependencia. Reversible con `unmask`.
4. **Eliminación del paquete** — el binario ya no está; nada puede iniciarse y ninguna actualización futura reinstala la unidad. Lo más fuerte, y la respuesta correcta para cualquier cosa que estés seguro de no necesitar nunca.

**A5.2** `rpcbind.socket` es una unidad de **activación por socket**: el propio PID 1 abre y sostiene el socket en escucha, y solo inicia `rpcbind.service` cuando llega una conexión, pasándole el descriptor de archivo ya abierto. Detener el servicio, por lo tanto, deja el puerto abierto bajo la propiedad de systemd.

**A5.3** `disable` solo manipula los enlaces simbólicos de `[Install]` — es una declaración de tiempo de arranque, no de tiempo de ejecución, y systemd mantiene los dos deliberadamente separados para que puedas preparar un cambio sin una caída. Usá **`systemctl disable --now <unit>`**, que es exactamente `disable` + `stop`. (`enable --now` es la forma simétrica.)

**A5.4** La máscara vive en `/etc/systemd/system/<unit>` (o `/run/systemd/system/<unit>` para una máscara en tiempo de ejecución, creada con `mask --runtime`), como un **enlace simbólico a `/dev/null`**. Como `/etc/systemd/system` tiene mayor precedencia que `/usr/lib/systemd/system`, la unidad nula ensombrece la unidad del proveedor. `systemctl cat` muestra el archivo del proveedor como referencia, pero `systemctl status` informa `masked`.

**A5.5** Quitar los enlaces simbólicos de inicio de los directorios de niveles de ejecución — clásicamente `update-rc.d ssh disable` / `update-rc.d -f ssh remove` en Debian, o `chkconfig sshd off` en Red Hat. Mecánicamente, esto borra `/etc/rc<N>.d/S??ssh` para los niveles de ejecución en los que arrancaba (y normalmente deja o agrega un enlace de terminación `K??ssh`). El script en sí, `/etc/init.d/ssh`, permanece en su lugar y todavía puede invocarse manualmente.

**A5.6** Reemplazó la línea **`initdefault`**, escrita como `id:3:initdefault:` en `/etc/inittab`. El nivel de ejecución **3** (multiusuario con red, sin login gráfico) corresponde a `multi-user.target`; el nivel 5 corresponde a `graphical.target`.

### Ejercicio 6

**A6.1** El super-servidor resuelve el costo de recursos de mantener residentes muchos demonios que se usan poco: un proceso escucha en todos sus puertos y bifurca el demonio real solo cuando llega una conexión, y provee registro, control de acceso y limitación de tasa *centralizados* para servicios que carecen de ellos. El equivalente moderno es la **activación por socket de systemd** (unidades `systemd.socket` con `Accept=yes` para el modelo por conexión, al estilo inetd).

**A6.2** `disable = yes` mantiene la definición del servicio, sus reglas de control de acceso y su documentación en el árbol, a la vez que hace que `xinetd` se niegue a escuchar por él. Borrar el archivo elimina la definición por completo. **`disable = yes` es preferible en un sistema auditado**: el archivo permanece como evidencia de una decisión deliberada, es visible para la gestión de configuración y para un revisor, y puede rehabilitarse sin reconstruir las reglas de memoria. (`enable =` en `xinetd.conf` es la contraparte de lista blanca.)

**A6.3** **Gana `no_access`.** `xinetd` compara la especificidad de las reglas coincidentes: decide la regla con el prefijo coincidente más largo y, cuando son igual de específicas, `no_access` deniega. `192.168.178.99` es una coincidencia más específica que `192.168.178.0/24`, así que el host queda denegado. El principio general es que la denegación se evalúa para poder recortar excepciones dentro de un rango permitido.

**A6.4** `wait` le dice a `xinetd` si debe **esperar a que el hijo termine** antes de volver a escuchar.
* `wait = no` (multihilo) para `stream`/TCP: `xinetd` acepta la conexión, bifurca un servidor para esa conexión y vuelve a `accept()` de inmediato, de modo que se atiende a muchos clientes concurrentemente.
* `wait = yes` (monohilo) para `dgram`/UDP: no hay `accept()`; `xinetd` entrega el *socket mismo* al servidor, que lee los datagramas, y `xinetd` no debe tocar el socket hasta que ese servidor termine.

Intercambiarlos rompe ambos: un servicio TCP con `wait = yes` se serializa a un cliente por vez y se atasca; un servicio UDP con `wait = no` deja a `xinetd` y al hijo compitiendo por leer el mismo socket, produciendo datagramas perdidos o duplicados y una tormenta de forks.

**A6.5** `tcpd` es la interfaz de los **TCP wrappers**. `inetd` ejecuta `tcpd` en lugar del demonio real; `tcpd` busca la solicitud en `/etc/hosts.allow` y `/etc/hosts.deny`, la registra vía syslog y solo entonces hace `exec()` del demonio real nombrado en la lista de argumentos — o descarta la conexión. Así es como se adaptaron el control de acceso y el registro a demonios que no tenían ninguno de los dos, sin recompilarlos.

**A6.6** `cps = 25 30` significa: aceptar como máximo **25 conexiones por segundo**; si se excede esa tasa, **deshabilitar el servicio durante 30 segundos** antes de volver a escuchar. Mitiga la **denegación de servicio por inundación de conexiones** (y, combinado con `instances` y `per_source`, el agotamiento de recursos al estilo de una fork bomb). `instances = 60` limita el total de servidores concurrentes para el servicio; `per_source = 10` limita las conexiones concurrentes desde cualquier dirección de origen individual.

### Ejercicio 7

**A7.1**
1. Leer `/etc/hosts.allow` de arriba a abajo. En la **primera** regla `daemon : client` que coincida, **conceder** acceso y detenerse.
2. Si no, leer `/etc/hosts.deny` de arriba a abajo. En la primera regla que coincida, **denegar** el acceso y detenerse.
3. Si ninguno de los dos archivos coincide (incluso si los archivos faltan o están vacíos), **conceder** el acceso.

El valor por defecto es por lo tanto permisivo, y por eso la configuración endurecida clásica pone `ALL : ALL` en `hosts.deny` y enumera las excepciones en `hosts.allow`.

**A7.2** Las reglas son **inertes** para `sshd`. El control de acceso por `libwrap` solo ocurre si el binario está enlazado contra ella (o se invoca a través de `tcpd`); OpenSSH abandonó `libwrap` en 6.7, y RHEL/Fedora eliminaron por completo la biblioteca `tcp_wrappers` de la distribución. En un sistema actual usá **`nftables`/`firewalld`** para el filtrado a nivel de red, y `AllowUsers`/`DenyUsers`/`AllowGroups` de `sshd_config` más un bloque `Match Address` para la restricción a nivel de aplicación. Los archivos de wrappers siguen siendo material de examen y siguen siendo relevantes para un puñado de demonios empaquetados por Debian que todavía enlazan `libwrap`.

**A7.3** La lista de demonios hace coincidir el **nombre base del proceso tal como fue invocado** — `argv[0]` — no el nombre de la unidad ni la ruta completa. Por eso `in.telnetd` y `telnetd` son patrones distintos: en un sistema donde `inetd` ejecuta `/usr/sbin/tcpd in.telnetd`, el wrapper ve `in.telnetd`, y una regla escrita para `telnetd` nunca coincide. Cuando un demonio llama a `libwrap` internamente, el nombre es el que el demonio pasa a `request_init()`, que suele ser su propio nombre corto (`sshd`, `vsftpd`, `rpcbind`). `tcpdchk` y `tcpdmatch` existen para atrapar exactamente esta clase de error de tipeo.

**A7.4**
* **`LOCAL`** — cualquier host cuyo nombre no contenga ningún punto, es decir, en el dominio local.
* **`KNOWN`** — tanto el nombre de host *como* la dirección son conocidos: las búsquedas directa e inversa resuelven y la búsqueda de usuario tuvo éxito.
* **`UNKNOWN`** — no se pudo determinar el nombre o la dirección.
* **`PARANOID`** — el nombre de host no concuerda con la dirección: falla el DNS inverso confirmado hacia adelante. Cuando `tcpd` se compila con `-DPARANOID` estos hosts se descartan antes incluso de consultar las reglas.

**`KNOWN`, `UNKNOWN` y `PARANOID` dependen todos del DNS** (`LOCAL` depende solo de la forma del nombre resuelto). El riesgo operativo es que el DNS lo controla un tercero y puede fallar o ser envenenado: una caída transitoria del resolver puede convertir a todos los clientes en `UNKNOWN` y dejar a todo el mundo afuera, mientras que un atacante que controle el DNS inverso de su propio rango de direcciones puede influir en `KNOWN`. Las reglas basadas en direcciones son más confiables.

**A7.5**

```
ALL : ALL EXCEPT 10.0.0.0/255.0.0.0
```

La forma de dos archivos es preferible porque `hosts.allow` se evalúa primero y corta el circuito: poner las excepciones ahí mantiene la regla de denegación como un `ALL : ALL` simple y auditable, y te permite agregar o quitar excepciones sin editar una expresión compuesta cuya precedencia de `EXCEPT` (es asociativa por la izquierda, y `a EXCEPT b EXCEPT c` se interpreta como `a EXCEPT (b EXCEPT c)`) es fácil de equivocar.

**A7.6** Ambos toman un comando de shell en el tercer campo opcional.
* **`spawn`** ejecuta el comando como un **hijo en segundo plano**, desacoplado de la conexión; stdin/stdout/stderr son `/dev/null`. La decisión de acceso (conceder/denegar) no se ve afectada. Usalo para registrar, alertar o disparar una regla de firewall.
* **`twist`** **reemplaza** el servicio solicitado por el comando — stdin/stdout del comando quedan conectados al socket del cliente, y el cliente habla con él en lugar de con el demonio real. Usalo para devolver un banner o un mensaje de rechazo enlatado. `twist` no puede usarse en una regla que además conceda acceso al servicio real, ya que consume la conexión.

Ambos soportan las expansiones `%`: `%a` dirección del cliente, `%h` nombre de host del cliente, `%d` nombre del demonio, `%u` usuario del cliente, `%c` información del cliente, `%p` PID del servidor.

### Ejercicio 8

**A8.1** **root (UID 0) está exento.** La exención está implementada en **PAM**, en `pam_nologin.so`: el módulo devuelve `PAM_SUCCESS` cuando el UID del usuario que se autentica es 0, y `PAM_AUTH_ERR` (después de imprimir el archivo) en caso contrario. `login(1)` históricamente implementaba la comprobación por sí mismo, que es por lo que también honra el archivo cuando se compila sin PAM, pero en una distribución moderna el punto de aplicación es la pila de PAM — que es también por lo que un servicio cuyo archivo en `/etc/pam.d/` omite `pam_nologin` (comúnmente `sudo`) no se ve afectado.

**A8.2** `pam_nologin` comprueba **primero `/var/run/nologin`**, y solo si no existe recurre a **`/etc/nologin`**. (`/var/run` es un enlace simbólico a `/run` en los sistemas actuales.) La ruta `/run` es preferible bajo systemd porque `/run` es un tmpfs que se limpia en cada arranque: el bloqueo no puede sobrevivir a un reinicio por accidente. `systemd-user-sessions.service` crea `/run/nologin` temprano en el apagado (y durante el arranque hasta que el sistema está listo) y lo elimina cuando debe permitirse el inicio de sesión multiusuario. `/etc/nologin` persiste entre reinicios, que es lo que querés para un bloqueo de mantenimiento deliberado — y exactamente la trampa que deja una máquina sin posibilidad de inicio de sesión tras un reinicio imprevisto.

**A8.3**
* **`/etc/nologin`** — un *archivo bandera*. Si existe, PAM deniega los inicios de sesión de no-root y muestra su contenido al usuario. Bloqueo de mantenimiento; borralo para restaurar los inicios de sesión.
* **`/usr/sbin/nologin`** (`/sbin/nologin` en la familia RHEL) — un *ejecutable*, usado como **shell** de login en el campo 7 de `/etc/passwd` para impedir que una cuenta específica obtenga una shell interactiva. Afecta a una cuenta, permanentemente, sin importar el estado del sistema.
* **`/etc/nologin.txt`** — el *archivo de mensaje* que lee el **programa** `/usr/sbin/nologin`. Si está presente, su contenido reemplaza el "This account is currently not available." por defecto. No tiene nada que ver con `/etc/nologin`.

**A8.4** Ejemplos:
* **Sesiones SSH por clave pública hacia un servicio que omite `pam_nologin`** o tiene `UsePAM no` — se soluciona poniendo `UsePAM yes` y confirmando que `account required pam_nologin.so` está en `/etc/pam.d/sshd`, o deteniendo `sshd` por completo durante la ventana.
* **cron / temporizadores de systemd** que corren como el usuario — detené `cron`/`crond` o enmascará los temporizadores relevantes durante la ventana; `/etc/nologin` es un control de *inicio de sesión* y los trabajos de cron no son inicios de sesión.
* **`sudo -u user` y `su - user` desde root** — root está exento por diseño; restringí con `sudoers` si eso importa.
* **Sesiones ya establecidas** — `/etc/nologin` bloquea solo los inicios de sesión *nuevos*; las shells existentes siguen corriendo. Usá `pkill -u <user>` o `loginctl terminate-user` para limpiarlas.

**A8.5** `shutdown` con un retraso crea **`/run/nologin`** (históricamente `/etc/nologin`) apenas se programa, para impedir que los usuarios inicien sesión en una máquina que está por caerse; el mensaje contiene la hora del apagado. Cancelalo con **`shutdown -c`**, que elimina el archivo y aborta el apagado pendiente. Si el archivo lo dejó un `shutdown` que se colgó o fue matado, eliminalo manualmente: `rm -f /run/nologin /etc/nologin`.

### Ejercicio 9

**A9.1** Se le escapa el loopback IPv6 en sus formas sin corchetes y el comodín IPv6 no es el problema — los huecos concretos son `[::1]:port` (el patrón de awk ancla `^\[::1\]` pero `ss` puede imprimir `[::1]:25`, que el patrón sí atrapa) y, más importante, **cualquier otra dirección en `127.0.0.0/8`** queda atrapada, mientras que un listener enlazado a una dirección privada específica como `192.168.178.20:22` se reporta como REVIEW aunque no sea alcanzable desde el mundo, y `*:80` (IPv6-any) se marca correctamente. El arreglo realista es filtrar sobre el conjunto completo de loopback y ser explícito sobre el comodín:

```bash
ss -tlpnH | awk '$4 !~ /^(127\.[0-9.]+|\[::1\]|localhost)/ {print "REVIEW "$4"  "$6}'
```

El punto más profundo: "enlazado a una dirección enrutable" no es lo mismo que "alcanzable" — el firewall es la otra mitad de la respuesta, y una auditoría de sockets por sí sola no puede decírtelo.

**A9.2** El UID 0 *es* la comprobación de privilegio en Linux — el kernel autoriza por UID numérico, no por nombre. Una segunda cuenta con UID 0 es una cuenta root completa con una credencial separada, un envejecimiento de contraseña separado y claves SSH separadas, y es fácil de pasar por alto en una auditoría que solo mira la línea de `root`. Multiplica las credenciales que hay que proteger y rotar, normalmente escapa por completo al registro de `sudo`, y es un mecanismo de persistencia clásico tras un compromiso. Contraseña fuerte o no, es un hallazgo.

**A9.3** Entre las razones:
* **Disponibilidad.** Deshabilitar automáticamente un listener o expirar una cuenta puede tirar abajo un servicio de producción; la herramienta de auditoría no tiene forma de saber que el puerto 8080 es la pasarela de pagos. La remediación debe ser una decisión humana con una ventana de cambio.
* **Auditabilidad y reproducibilidad.** Una herramienta de solo lectura puede ejecutarla cualquiera, en cualquier host, en cualquier momento, incluso un auditor que no está autorizado a cambiar nada. Una vez que muta el estado, su salida ya no es una descripción del host sino una descripción de lo que le hizo al host, y ejecutarla dos veces da resultados distintos.
* **Radio de impacto ante falsos positivos.** Las heurísticas de detección son aproximadas; la auto-remediación convierte cada falso positivo en una caída.

**A9.4** **Los TCP wrappers** son lo peor cubierto, y deliberadamente así — el script solo comprueba una línea de denegación por defecto en `/etc/hosts.deny`, lo cual no prueba nada sobre si algún demonio del host la consulta realmente. Una mejor comprobación ejecuta `ldd` contra cada binario en escucha para informar cuáles están genuinamente enlazados a `libwrap`, ejecuta `tcpdchk` cuando las utilidades `tcpd` están presentes y — dado que la respuesta honesta en la mayoría de los sistemas actuales es "los wrappers no son el control aquí" — informa en su lugar el estado de `nftables`/`firewalld`. Secundariamente, la sección de shadow comprueba el envejecimiento pero no la fortaleza del hash: agregar una comprobación de que todo hash usa `$6$` o `$y$` (rechazando `$1$` MD5 y los hashes de 13 caracteres al estilo DES) cerraría un hueco real.

</details>

---

## Fuentes

* LPI — *Exam 102-500 Objectives*, tema 110.2 "Setup host security": <https://www.lpi.org/our-certifications/exam-102-objectives/>
* LPI — *Exam 101-500 Objectives*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
* Proyecto upstream shadow-utils (`passwd`, `chage`, `pwconv`, `vipw`, `shadow(5)`, `login.defs(5)`): <https://github.com/shadow-maint/shadow>
* Página de manual `shadow(5)`: <https://man7.org/linux/man-pages/man5/shadow.5.html>
* Página de manual `chage(1)`: <https://man7.org/linux/man-pages/man1/chage.1.html>
* Páginas de manual `nologin(5)` y `nologin(8)`: <https://man7.org/linux/man-pages/man5/nologin.5.html> · <https://man7.org/linux/man-pages/man8/nologin.8.html>
* Linux-PAM — Guía del administrador de sistemas de `pam_nologin`: <https://www.man7.org/linux/man-pages/man8/pam_nologin.8.html>
* systemd — `systemd.socket(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html>
* systemd — `systemctl(1)`, incluidos `mask`/`disable --now`: <https://www.freedesktop.org/software/systemd/man/latest/systemctl.html>
* systemd — `systemd-user-sessions.service(8)` y `/run/nologin`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-user-sessions.service.html>
* `hosts_access(5)` — lenguaje de control de acceso de los TCP wrappers: <https://man7.org/linux/man-pages/man5/hosts_access.5.html>
* `hosts_options(5)` — `spawn`, `twist` y el lenguaje extendido: <https://man7.org/linux/man-pages/man5/hosts_options.5.html>
* `tcpd(8)`, `tcpdchk(8)`, `tcpdmatch(8)`: <https://man7.org/linux/man-pages/man8/tcpd.8.html>
* Proyecto Fedora — propuesta de cambio *Deprecate TCP wrappers*: <https://fedoraproject.org/wiki/Changes/Deprecate_TCP_wrappers>
* Notas de la versión 6.7 de OpenSSH (eliminación del soporte de TCP wrappers): <https://www.openssh.com/txt/release-6.7>
* Proyecto upstream xinetd y `xinetd.conf(5)`: <https://github.com/xinetd-org/xinetd> · <https://linux.die.net/man/5/xinetd.conf>
* iproute2 — `ss(8)`: <https://man7.org/linux/man-pages/man8/ss.8.html>