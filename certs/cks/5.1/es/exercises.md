# CKS 5.1 — Minimizar la superficie del sistema operativo del host (reducir la superficie de ataque)

**Certificación:** Certified Kubernetes Security Specialist (CKS), versión de examen 1.34
**Dominio:** System Hardening — **Peso de este tema en el examen: 2.5%**

---

## Requisitos del laboratorio y aviso de seguridad

Estos ejercicios **modifican el sistema operativo del host**. Cada paso es destructivo por diseño: vas a deshabilitar servicios, purgar paquetes, descargar módulos del kernel y bloquear cuentas.

| Requisito | Valor |
|---|---|
| Nodo | Una **VM descartable** con Ubuntu 22.04/24.04 o Debian 12, unida a un clúster kubeadm (1 control-plane + 1 worker es lo ideal) |
| Acceso | `root` o `sudo` sin contraseña, más una **sesión de consola/fuera de banda** (vas a endurecer SSH y podés dejarte afuera) |
| Snapshot | Tomá un snapshot de la VM **antes de empezar**. Vas a necesitar volver atrás. |
| Estado del clúster | Ejecutá `kubectl cordon` / `kubectl drain` sobre el nodo objetivo antes de los bloques de módulos y sysctl |

```bash
# Run this FIRST, from your workstation, targeting the node you will harden.
kubectl cordon cks-worker-1
kubectl drain cks-worker-1 --ignore-daemonsets --delete-emptydir-data --timeout=120s
```

> **Nunca** ejecutes el Bloque 4 (módulos del kernel) ni el Bloque 8 (sysctl) en un nodo que esté sirviendo Pods activamente. Descargar un módulo de netfilter o de overlay bajo un CNI en vivo produce una partición que parece una falla del control-plane y desperdicia una hora de diagnóstico.

---

## Bloque 1 — Establecer la línea base de la superficie de ataque antes de tocar nada

Endurecer sin una línea base no es endurecer; es adivinar. Cada cambio que hagas en los Bloques 2–9 debe poder diferenciarse contra este snapshot.

1. Creá un directorio de trabajo y capturá el inventario de servicios en ejecución.

```bash
sudo mkdir -p /root/cks-baseline && cd /root/cks-baseline

systemctl list-units --type=service --state=running --no-pager --no-legend \
  | awk '{print $1}' | sort > services-running.txt

systemctl list-unit-files --state=enabled --no-pager --no-legend \
  | awk '{print $1}' | sort > units-enabled.txt

wc -l services-running.txt units-enabled.txt
```

Salida esperada en un worker kubeadm estándar:

```
  21 services-running.txt
  34 units-enabled.txt
  55 total
```

2. Capturá cada socket a la escucha, con el proceso propietario. Este es el artefacto más importante: un puerto sin listener no es superficie de ataque, y un listener sin puerto no es alcanzable remotamente.

```bash
sudo ss -tulpnH | sort -k5 > sockets-listening.txt
sudo ss -tulpn
```

Salida representativa en un nodo de control-plane:

```
Netid State  Recv-Q Send-Q     Local Address:Port  Peer Address:Port Process
udp   UNCONN 0      0          127.0.0.54:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=15))
udp   UNCONN 0      0       127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=14))
tcp   LISTEN 0      4096        127.0.0.1:10248        0.0.0.0:*     users:(("kubelet",pid=1023,fd=20))
tcp   LISTEN 0      4096        127.0.0.1:10249        0.0.0.0:*     users:(("kube-proxy",pid=2871,fd=14))
tcp   LISTEN 0      4096        127.0.0.1:10257        0.0.0.0:*     users:(("kube-controller",pid=1499,fd=3))
tcp   LISTEN 0      4096        127.0.0.1:10259        0.0.0.0:*     users:(("kube-scheduler",pid=1512,fd=3))
tcp   LISTEN 0      4096        127.0.0.1:2379         0.0.0.0:*     users:(("etcd",pid=1580,fd=9))
tcp   LISTEN 0      4096    192.168.56.10:2379         0.0.0.0:*     users:(("etcd",pid=1580,fd=8))
tcp   LISTEN 0      4096    192.168.56.10:2380         0.0.0.0:*     users:(("etcd",pid=1580,fd=7))
tcp   LISTEN 0      4096                *:10250              *:*     users:(("kubelet",pid=1023,fd=27))
tcp   LISTEN 0      4096                *:6443               *:*     users:(("kube-apiserver",pid=1466,fd=3))
tcp   LISTEN 0      128           0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=901,fd=3))
```

3. Capturá paquetes, módulos del kernel cargados, cuentas locales y binarios SUID/SGID.

```bash
dpkg-query -W -f='${Package}\n' | sort > packages-all.txt
apt-mark showmanual | sort                > packages-manual.txt

lsmod | awk 'NR>1 {print $1}' | sort > modules-loaded.txt

awk -F: '{printf "%s:%s:%s\n", $1, $3, $7}' /etc/passwd | sort > accounts.txt

sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
  -printf '%m %u %g %p\n' 2>/dev/null | sort -k4 > suid-sgid.txt

wc -l packages-all.txt modules-loaded.txt accounts.txt suid-sgid.txt
```

```
 641 packages-all.txt
  98 modules-loaded.txt
  31 accounts.txt
  26 suid-sgid.txt
```

4. Registrá una huella digital para poder demostrar después qué cambió y cuándo.

```bash
sha256sum ./*.txt | tee baseline.sha256
uname -r | tee kernel-version.txt
```

### Preguntas de comprensión — Bloque 1

1. `ss` informa dos entradas para etcd en el puerto 2379: una en `127.0.0.1` y otra en `192.168.56.10`. ¿Por qué eliminar el listener de loopback rompe el clúster, mientras que restringir el listener de `192.168.56.10` no?
2. ¿Por qué `apt-mark showmanual` es un punto de partida más útil para la reducción de paquetes que `dpkg-query -W`?
3. El comando `find` usa `-xdev`. ¿Qué te perderías sin él en un nodo Kubernetes, y por qué esa omisión es *deseable* acá?
4. Un listener enlazado a `*:10250` y uno enlazado a `127.0.0.1:10248` pertenecen al mismo proceso. Explicá, en términos de superficie de ataque, por qué solo uno de ellos está dentro del alcance de este tema.

---

## Bloque 2 — Deshabilitar y enmascarar servicios innecesarios (incluida la activación por socket)

Un `systemctl stop` sobrevive hasta que la siguiente dependencia lo dispare. Un `systemctl disable` sobrevive hasta que algo lo active por socket. Solo `mask` es incondicional.

1. Listá las unidades habilitadas e identificá candidatos que ningún nodo Kubernetes necesita.

```bash
systemctl list-unit-files --state=enabled --type=service --no-pager
```

```
UNIT FILE                      STATE   PRESET
apache2.service                enabled enabled
cron.service                   enabled enabled
containerd.service             enabled enabled
cups.service                   enabled enabled
kubelet.service                enabled enabled
rpcbind.service                enabled enabled
snapd.service                  enabled enabled
ssh.service                    enabled enabled
systemd-resolved.service       enabled enabled
```

2. Antes de eliminar nada, confirmá qué expone realmente un candidato.

```bash
sudo ss -tulpn | grep -E 'apache2|cups|rpcbind'
```

```
tcp   LISTEN 0 511      *:80              *:*   users:(("apache2",pid=1802,fd=4))
tcp   LISTEN 0 4096     *:111             *:*   users:(("rpcbind",pid=744,fd=8))
udp   UNCONN 0 0        *:111             *:*   users:(("rpcbind",pid=744,fd=5))
tcp   LISTEN 0 128 127.0.0.1:631     0.0.0.0:*  users:(("cupsd",pid=903,fd=7))
```

3. Detené, deshabilitá y enmascará el servidor HTTP. Verificá cada etapa por separado para internalizar la diferencia.

```bash
sudo systemctl disable --now apache2.service
systemctl is-enabled apache2.service ; systemctl is-active apache2.service
```

```
disabled
inactive
```

4. Ahora ocupate de `rpcbind`, que está **activado por socket**. Deshabilitá solo el `.service` y vuelve enseguida.

```bash
systemctl list-sockets --no-pager | grep -i rpcbind
```

```
/run/rpcbind.sock  rpcbind.socket  rpcbind.service
0.0.0.0:111        rpcbind.socket  rpcbind.service
```

```bash
sudo systemctl disable --now rpcbind.service rpcbind.socket
sudo systemctl mask rpcbind.service rpcbind.socket
systemctl is-enabled rpcbind.socket
```

```
masked
```

5. Demostrá que enmascarar es más fuerte que deshabilitar.

```bash
sudo systemctl start rpcbind.service
```

```
Failed to start rpcbind.service: Unit rpcbind.service is masked.
```

```bash
ls -l /etc/systemd/system/rpcbind.service
```

```
lrwxrwxrwx 1 root root 9 Aug  4 11:02 /etc/systemd/system/rpcbind.service -> /dev/null
```

6. Volvé a revisar la tabla de sockets y compará contra la línea base.

```bash
sudo ss -tulpnH | sort -k5 > /root/cks-baseline/sockets-after-block2.txt
diff /root/cks-baseline/sockets-listening.txt /root/cks-baseline/sockets-after-block2.txt
```

### Preguntas de comprensión — Bloque 2

5. Describí los tres estados distintos que producen `stop`, `disable` y `mask`, y dá un escenario de falla concreto para cada uno de los dos más débiles.
6. `systemctl disable --now rpcbind.service` por sí solo dejó el puerto 111 abierto. Rastreá el mecanismo exacto por el cual el servicio reapareció.
7. ¿Cuáles dos de los servicios listados en el paso 1 **nunca** deben enmascararse en un worker de Kubernetes, y qué se rompe de inmediato si lo hacés?
8. Enmascarás una unidad y después necesitás recuperarla. ¿Cuál es el comando exacto, y por qué `systemctl enable` no alcanza por sí solo?

---

## Bloque 3 — Eliminar paquetes innecesarios

El software deshabilitado sigue siendo un sistema de archivos lleno de binarios explotables alcanzables por cualquier proceso que logre ejecución de código — incluido un contenedor que se escapa con un montaje del host.

1. Identificá los paquetes instalados más grandes y el conjunto instalado manualmente.

```bash
dpkg-query -W -f='${Installed-Size}\t${Package}\n' | sort -rn | head -15
```

```
187341  linux-image-6.8.0-45-generic
 94210  containerd.io
 41022  snapd
 22876  apache2
 15203  gcc-12
 11940  cups-daemon
  9884  build-essential
  8612  tcpdump
  6210  netcat-openbsd
```

2. Simulá una purga antes de ejecutarla. `--dry-run` no es opcional en producción.

```bash
sudo apt-get purge --dry-run apache2 apache2-utils cups cups-daemon
```

```
The following packages will be REMOVED:
  apache2* apache2-bin* apache2-data* apache2-utils* cups* cups-common*
  cups-daemon* libapache2-mod-php8.1*
0 upgraded, 0 newly installed, 8 to remove and 0 not upgraded.
```

3. Ejecutá la purga y después recuperá las dependencias huérfanas.

```bash
sudo apt-get purge -y apache2 apache2-utils cups cups-daemon
sudo apt-get autoremove --purge -y
```

4. Eliminá la huella de herramientas ofensivas y de compiladores. Un compilador en un nodo convierte una primitiva de exploit de solo lectura en una primitiva de payload arbitrario.

```bash
sudo apt-get purge -y gcc-12 build-essential tcpdump netcat-openbsd nmap
dpkg -l | grep -cE '^ii' 
```

5. Confirmá que no queda residuo de configuración (el estado `rc` significa que el paquete fue eliminado pero sus archivos de configuración persisten).

```bash
dpkg -l | awk '/^rc/ {print $2}'
```

```
(no output)
```

6. Volvé a tomar la línea base y cuantificá la reducción.

```bash
dpkg-query -W -f='${Package}\n' | sort > /root/cks-baseline/packages-after-block3.txt
diff /root/cks-baseline/packages-all.txt /root/cks-baseline/packages-after-block3.txt | grep -c '^<'
```

```
34
```

### Preguntas de comprensión — Bloque 3

9. ¿Cuál es la diferencia operativa entre `apt remove` y `apt purge`, y por qué importa esa diferencia para una auditoría estilo CIS?
10. Un paquete muestra el estado `rc` en `dpkg -l`. ¿Se eliminó su superficie de ataque? Justificá.
11. Eliminar `gcc` es una recomendación clásica de hardening. Dá una capacidad concreta de post-explotación que le niega a un atacante — y una razón realista por la cual el control es más débil en 2026 de lo que era en 2010.
12. ¿Por qué purgar `tcpdump` del nodo es un control significativamente distinto de negar `NET_RAW` a los Pods, aunque ambos apunten a la captura de paquetes?

---

## Bloque 4 — Reducir la huella de módulos del kernel

Cada módulo cargable es código en modo kernel alcanzable desde el espacio de usuario. Los módulos de sistemas de archivos y protocolos exóticos de clase `CVE` son la superficie clásica de escalada local de privilegios.

1. Revisá qué módulos objetivo están cargados actualmente.

```bash
lsmod | grep -E '^(cramfs|freevxfs|jffs2|hfs|hfsplus|udf|usb_storage|dccp|sctp|rds|tipc)'
```

```
sctp                  405504  0
usb_storage            81920  0
```

2. Distinguí los módulos cargables del código compilado dentro del kernel. Los built-in no pueden descargarse y ponerlos en lista negra es una operación sin efecto que no debés reportar como remediada.

```bash
grep -E 'sctp|overlay|br_netfilter' /lib/modules/$(uname -r)/modules.builtin
modinfo -n sctp
```

```
/lib/modules/6.8.0-45-generic/kernel/net/sctp/sctp.ko.zst
```

3. Descargá los módulos activos. `modprobe -r` se niega si el contador de referencias no es cero, que es el comportamiento seguro.

```bash
sudo modprobe -r sctp usb_storage
lsmod | grep -E 'sctp|usb_storage' || echo "unloaded"
```

```
unloaded
```

4. Hacelo persistente. **Se requieren dos directivas**: `blacklist` detiene la carga automática/por alias; `install ... /bin/false` detiene además un `modprobe <name>` explícito.

```bash
sudo tee /etc/modprobe.d/99-cks-hardening.conf >/dev/null <<'EOF'
# CKS 5.1 — deny rarely-used filesystems and network protocols.
# blacklist  : prevents alias/auto-load (udev, filesystem autodetect)
# install ... : also defeats an explicit `modprobe <name>`
blacklist cramfs
install cramfs /bin/false
blacklist freevxfs
install freevxfs /bin/false
blacklist jffs2
install jffs2 /bin/false
blacklist hfs
install hfs /bin/false
blacklist hfsplus
install hfsplus /bin/false
blacklist udf
install udf /bin/false
blacklist usb-storage
install usb-storage /bin/false
blacklist dccp
install dccp /bin/false
blacklist sctp
install sctp /bin/false
blacklist rds
install rds /bin/false
blacklist tipc
install tipc /bin/false
EOF

sudo depmod -a
sudo update-initramfs -u
```

5. Verificá que la denegación realmente resiste ante un intento de carga explícito.

```bash
sudo modprobe sctp ; echo "exit=$?"
modprobe --showconfig | grep -E '^(install|blacklist) sctp'
```

```
exit=1
blacklist sctp
install sctp /bin/false
```

6. **Punto de control de compromisos.** Inspeccioná los módulos que Kubernetes mismo requiere. Poner cualquiera de estos en lista negra deja el nodo fuera de línea.

```bash
lsmod | grep -E '^(overlay|br_netfilter|nf_conntrack|ip_vs|ip_tables|nf_nat|vxlan|xt_)' | head
```

```
overlay               196608  84
br_netfilter           32768  0
nf_conntrack          188416  6
ip_vs_rr               16384  1
ip_vs                 233472  3 ip_vs_rr
nf_nat                 57344  4
vxlan                 143360  0
```

7. *(Avanzado, puerta de una sola dirección.)* `kernel.modules_disabled=1` congela la tabla de módulos hasta el reinicio. Leé el compromiso antes de considerarlo en producción.

```bash
# DO NOT run this yet on a node whose CNI loads modules lazily.
# sudo sysctl -w kernel.modules_disabled=1
sysctl kernel.modules_disabled
```

```
kernel.modules_disabled = 0
```

### Preguntas de comprensión — Bloque 4

13. ¿Por qué `blacklist <mod>` por sí solo es insuficiente, y qué intercepta exactamente `install <mod> /bin/false` que `blacklist` no?
14. Agregás `blacklist overlay` a `/etc/modprobe.d/` y reiniciás un worker. Predecí el síntoma observable, tanto en la capa de `systemctl` como en la de `kubectl`.
15. ¿Qué logra `update-initramfs -u` acá, y nombrá una clase de módulo para la cual saltearlo derrota silenciosamente tu lista negra.
16. `kernel.modules_disabled=1` se describe como una puerta de una sola dirección. Explicá la restricción de orden que la hace utilizable siquiera en un nodo Kubernetes, y un modo de falla que provoca con Calico o Cilium.

---

## Bloque 5 — Auditar usuarios, grupos y rutas de autenticación

1. Enumerá las cuentas usables por humanos (UID ≥ 1000) y cualquier cuenta con shell de login.

```bash
awk -F: '($3>=1000)&&($1!="nobody"){print $1" uid="$3" shell="$7}' /etc/passwd
```

```
ubuntu uid=1000 shell=/bin/bash
jenkins uid=1001 shell=/bin/bash
deploy uid=1002 shell=/bin/bash
oldadmin uid=1003 shell=/bin/bash
```

2. Buscá las tres desconfiguraciones clásicas: UID 0 duplicado, contraseñas vacías y permisos sudo obsoletos.

```bash
awk -F: '($3==0){print "UID0: "$1}' /etc/passwd
sudo awk -F: '($2==""){print "EMPTY-PASSWD: "$1}' /etc/shadow
getent group sudo adm root
sudo grep -rE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/
```

```
UID0: root
UID0: backdoor
sudo:x:27:ubuntu,jenkins,oldadmin
adm:x:4:syslog,ubuntu
root:x:0:
/etc/sudoers.d/90-cloud-init-users:ubuntu ALL=(ALL) NOPASSWD:ALL
/etc/sudoers.d/jenkins:jenkins ALL=(ALL) NOPASSWD:ALL
```

3. Eliminá de inmediato la segunda cuenta con UID 0 — es una cuenta root por definición, sin importar su nombre.

```bash
sudo userdel -r backdoor
awk -F: '($3==0){print $1}' /etc/passwd
```

```
root
```

4. Bloqueá la cuenta obsoleta y hacela expirar, en lugar de borrarla, cuando la propiedad de los archivos deba preservarse para análisis forense.

```bash
sudo usermod -L -s /usr/sbin/nologin -e 1 oldadmin
sudo passwd -S oldadmin
sudo gpasswd -d oldadmin sudo
```

```
oldadmin L 08/04/2026 0 99999 7 -1
```

5. Convertí cada cuenta de servicio a un shell sin login y verificá que ninguna pueda obtener una shell.

```bash
awk -F: '($3<1000)&&($7!~/(nologin|false|sync)$/){print $1" -> "$7}' /etc/passwd
```

```
sync -> /bin/sync
```

6. Confirmá la reducción.

```bash
awk -F: '($7~/(bash|sh|zsh)$/){print $1}' /etc/passwd | tee /root/cks-baseline/shell-accounts-after.txt
```

```
root
ubuntu
jenkins
deploy
```

### Preguntas de comprensión — Bloque 5

17. Una cuenta llamada `backdoor` tiene UID 0. ¿Por qué su *nombre* es irrelevante, y qué compara realmente el kernel al autorizar una syscall privilegiada?
18. `usermod -L` antepone un `!` al hash de la contraseña. ¿Eso bloquea **todas** las rutas de autenticación de la cuenta? Nombrá al menos una ruta que deja abierta y el flag que la cierra.
19. Distinguí `usermod -L` de `chage -E 0` / `usermod -e 1`. ¿Cuál de las dos sobrevive a un posterior reseteo de `passwd` por parte de un administrador?
20. Existe una entrada `NOPASSWD:ALL` en sudoers para una cuenta de CI. Explicá la cadena de escalada específica que esto habilita, desde "escape de contenedor hacia el UID `jenkins`" hasta "cluster-admin".

---

## Bloque 6 — Endurecer el demonio SSH

SSH suele ser el único punto de entrada remoto *intencional* que queda después de los bloques anteriores. Su configuración es, por lo tanto, estructural.

1. Leé la configuración efectiva, no el archivo. `sshd -T` resuelve las directivas `Include`, los bloques `Match` y los valores por defecto compilados.

```bash
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|permitemptypasswords|maxauthtries|x11forwarding|logingracetime|kbdinteractiveauthentication)'
```

```
permitrootlogin yes
passwordauthentication yes
kbdinteractiveauthentication yes
permitemptypasswords no
maxauthtries 6
x11forwarding yes
logingracetime 120
```

2. **Antes de deshabilitar la autenticación por contraseña, comprobá que el login por clave funciona.** Saltear este paso es la forma más común de dejar inutilizable un nodo de laboratorio.

```bash
# From your workstation, in a SEPARATE terminal you keep open:
ssh -o PasswordAuthentication=no ubuntu@cks-worker-1 'echo KEY-AUTH-OK'
```

```
KEY-AUTH-OK
```

3. Escribí un drop-in en lugar de editar `/etc/ssh/sshd_config`. En Ubuntu 22.04+ el archivo principal termina con `Include /etc/ssh/sshd_config.d/*.conf`, y **gana la primera aparición de una palabra clave** — así que un drop-in incluido arriba sobrescribe los valores por defecto posteriores.

```bash
sudo tee /etc/ssh/sshd_config.d/99-cks-hardening.conf >/dev/null <<'EOF'
# CKS 5.1 — SSH attack-surface reduction
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups ssh-users
EOF

sudo groupadd -f ssh-users
sudo usermod -aG ssh-users ubuntu
```

4. **Validá la sintaxis antes de recargar.** Un archivo mal formado más un reinicio equivale a un nodo inalcanzable.

```bash
sudo sshd -t && echo "CONFIG OK"
```

```
CONFIG OK
```

5. Recargá (no reinicies) y volvé a leer la configuración efectiva.

```bash
sudo systemctl reload ssh
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|allowgroups)'
```

```
permitrootlogin no
passwordauthentication no
maxauthtries 3
allowgroups ssh-users
```

6. Verificá negativamente — el control debe observarse fallando, no asumirse.

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@cks-worker-1
```

```
root@cks-worker-1: Permission denied (publickey).
```

### Preguntas de comprensión — Bloque 6

21. ¿Por qué `sshd -T` es autoritativo mientras que `grep PermitRootLogin /etc/ssh/sshd_config` es engañoso? Nombrá dos mecanismos de configuración que `grep` se pierde.
22. `PermitRootLogin prohibit-password` es un término medio habitual. ¿Qué permite todavía exactamente, y en qué escenario es estrictamente mejor que `no`?
23. Se usó `systemctl reload ssh` en lugar de `restart`. ¿Cuál es la diferencia práctica para una sesión que tenés abierta en este momento?
24. Está configurado `AllowGroups ssh-users` y `deploy` no está en ese grupo. ¿Puede `deploy` obtener igualmente una shell en el nodo? Enumerá las rutas restantes.

---

## Bloque 7 — Reducir los binarios SUID/SGID

Un binario SUID-root es una primitiva de escalada de privilegios intencional y permanente. El control no es "eliminarlos todos" — es "conservar solo aquellos cuya escalada es necesaria, y fijar esa decisión para que las actualizaciones de paquetes no puedan deshacerla".

1. Enumerá y clasificá.

```bash
sudo find / -xdev -type f -perm -4000 -printf '%m %u %g %p\n' 2>/dev/null | sort -k4
```

```
4755 root root /usr/bin/chfn
4755 root root /usr/bin/chsh
4755 root root /usr/bin/fusermount3
4755 root root /usr/bin/gpasswd
4755 root root /usr/bin/mount
4755 root root /usr/bin/newgrp
4755 root root /usr/bin/passwd
4755 root root /usr/bin/su
4755 root root /usr/bin/sudo
4755 root root /usr/bin/umount
4755 root root /usr/bin/pkexec
4755 root root /usr/lib/openssh/ssh-keysign
```

2. Atribuí cada binario a su paquete propietario. Un binario SUID sin atribución es un incidente, no un hallazgo.

```bash
for f in $(sudo find / -xdev -type f -perm -4000 2>/dev/null); do
  pkg=$(dpkg -S "$f" 2>/dev/null | cut -d: -f1)
  printf '%-45s %s\n' "$f" "${pkg:-*** UNOWNED ***}"
done
```

```
/usr/bin/chsh                                 passwd
/usr/bin/passwd                               passwd
/usr/bin/sudo                                 sudo
/usr/bin/pkexec                               policykit-1
/tmp/.cache/nginx-worker                      *** UNOWNED ***
```

3. Quitá el bit SUID de los binarios sin justificación operativa en un nodo sin interfaz gráfica.

```bash
sudo chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp
sudo chmod u-s /usr/bin/pkexec        # CVE-2021-4034 class; unused headless
ls -l /usr/bin/chsh /usr/bin/pkexec
```

```
-rwxr-xr-x 1 root root 72712 Mar 23  2025 /usr/bin/chsh
-rwxr-xr-x 1 root root 31032 Feb 21  2025 /usr/bin/pkexec
```

4. **Fijá la decisión.** Un `chmod` simple es revertido por el siguiente `apt upgrade` del paquete propietario; `dpkg-statoverride` no.

```bash
sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chsh
sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chfn
sudo dpkg-statoverride --list | grep -E 'chsh|chfn'
```

```
root root 0755 /usr/bin/chfn
root root 0755 /usr/bin/chsh
```

5. Investigá el binario sin propietario — este es el patrón de una puerta trasera persistida.

```bash
sudo stat /tmp/.cache/nginx-worker
sudo sha256sum /tmp/.cache/nginx-worker
sudo find / -xdev -type f -perm -4000 -newer /etc/hostname 2>/dev/null
```

6. Repetí para SGID y confirmá la diferencia contra la línea base.

```bash
sudo find / -xdev -type f -perm -2000 -printf '%m %u %g %p\n' 2>/dev/null | sort -k4 \
  > /root/cks-baseline/sgid-after.txt
diff <(grep -c . /root/cks-baseline/suid-sgid.txt) <(sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l)
```

### Preguntas de comprensión — Bloque 7

25. ¿Qué significa el `4` inicial en el modo `4755`, y con qué UID se ejecuta el proceso cuando un usuario normal lo ejecuta?
26. Hacés `chmod u-s /usr/bin/passwd`. ¿Qué se rompe, y por qué es un mal intercambio en un nodo multiusuario pero posiblemente aceptable en un nodo donde todos los humanos se autentican solo con clave SSH?
27. Explicá por qué `dpkg-statoverride` es necesario para que el control sobreviva, y qué vería un auditor tres meses después de un `chmod u-s` simple.
28. Un binario SUID en `/tmp` no pertenece a ningún paquete. Más allá de eliminarlo, nombrá dos artefactos que recolectarías antes de borrarlo y por qué importa el orden.

---

## Bloque 8 — Endurecimiento de parámetros del kernel y de `/proc` (con la trampa de `ip_forward`)

1. Leé los valores actuales de los parámetros que vas a cambiar.

```bash
sysctl kernel.dmesg_restrict kernel.kptr_restrict kernel.yama.ptrace_scope \
       fs.suid_dumpable fs.protected_hardlinks net.ipv4.ip_forward
```

```
kernel.dmesg_restrict = 0
kernel.kptr_restrict = 1
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 2
fs.protected_hardlinks = 1
net.ipv4.ip_forward = 1
```

2. Aplicá el conjunto de endurecimiento. Prestá atención a lo que está **deliberadamente ausente**.

```bash
sudo tee /etc/sysctl.d/99-cks-hardening.conf >/dev/null <<'EOF'
# CKS 5.1 — kernel attack-surface reduction

# Kernel information leaks
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3

# Local privilege escalation primitives
kernel.yama.ptrace_scope = 1
kernel.kexec_load_disabled = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# eBPF surface (unprivileged eBPF is a recurring LPE vector)
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Network stack
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0

# DELIBERATELY NOT SET — required by the CNI and kube-proxy:
#   net.ipv4.ip_forward            must remain 1
#   net.bridge.bridge-nf-call-iptables  must remain 1
#   net.ipv4.conf.all.rp_filter    leave at the CNI's value (Calico expects 0 on cali* ifaces)
EOF

sudo sysctl --system | tail -20
```

3. Verificá que los valores tomaron efecto y que el reenvío quedó intacto.

```bash
sysctl kernel.dmesg_restrict kernel.kptr_restrict kernel.unprivileged_bpf_disabled net.ipv4.ip_forward
```

```
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.ipv4.ip_forward = 1
```

4. Observá un control funcionando. Como usuario no root, los punteros del kernel ahora deben leerse como ceros y `dmesg` debe ser denegado.

```bash
su - ubuntu -c 'dmesg | head -2'
su - ubuntu -c 'grep " commit_creds" /proc/kallsyms'
```

```
dmesg: read kernel buffer failed: Operation not permitted
0000000000000000 T commit_creds
```

5. Demostrá la trampa de `ip_forward` que los scripts de hardening CIS provocan habitualmente. Ejecutalo, observá y revertí.

```bash
sudo sysctl -w net.ipv4.ip_forward=0
kubectl run trap-test --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl exec trap-test -- wget -qO- --timeout=3 http://10.96.0.10:53 ; echo "exit=$?"
```

```
wget: download timed out
exit=1
```

```bash
sudo sysctl -w net.ipv4.ip_forward=1     # restore immediately
kubectl delete pod trap-test
```

6. *(Avanzado, con un compromiso real.)* Ocultá los procesos de otros usuarios en `/proc`.

```bash
sudo groupadd -f procmon
sudo mount -o remount,hidepid=invisible,gid=$(getent group procmon | cut -d: -f3) /proc
su - ubuntu -c 'ps aux | wc -l'
```

```
7
```

```bash
# Persist only after validating your monitoring agents still work:
# /proc  /proc  proc  defaults,hidepid=invisible,gid=procmon  0 0
```

### Preguntas de comprensión — Bloque 8

29. Dá el significado de cada valor de `kernel.kptr_restrict` (0, 1, 2) e indicá cuál se requiere para anular una filtración de `/proc/kallsyms` desde un proceso *sin privilegios*.
30. ¿Por qué `net.ipv4.ip_forward` debe permanecer en `1`, y qué dos componentes de Kubernetes dejan de funcionar en `0`? Describí el síntoma que reporta un usuario.
31. Se configura `fs.suid_dumpable = 0`. ¿Qué clase de divulgación de información cierra esto, y dónde terminarían esos datos de otro modo?
32. `kernel.unprivileged_bpf_disabled = 1` reduce una superficie real de LPE pero tiene un costo en algunos clústeres. Nombrá la categoría de carga de trabajo que puede romperse y cómo la detectarías antes de desplegarlo a toda la flota.
33. `hidepid=invisible` oculta procesos de `ps`. Nombrá dos agentes a nivel de nodo que comúnmente se rompen, y explicá el rol de la opción `gid=` para mitigarlo.

---

## Bloque 9 — Reducir la exposición de los demonios de nodo y del runtime

Los agentes de nodo de Kubernetes *son* parte de la huella del sistema operativo del host. Un kubelet con un puerto de solo lectura anónimo es una superficie de ataque mayor que cualquier paquete que hayas eliminado.

1. Inspeccioná la configuración efectiva del kubelet.

```bash
sudo grep -E 'readOnlyPort|anonymous|authorization|mode:|enabled:' /var/lib/kubelet/config.yaml
```

```
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: false
authorization:
  mode: AlwaysAllow
readOnlyPort: 10255
```

2. Confirmá la exposición empíricamente desde otro host, antes de arreglarla.

```bash
curl -sk https://192.168.56.11:10250/pods | head -c 200
curl -s  http://192.168.56.11:10255/pods | jq -r '.items[].metadata.name' | head
```

```
{"kind":"PodList","apiVersion":"v1","metadata":{},"items":[{"metadata":{"name":"etcd-cks-cp",...
kube-proxy-8xqzt
coredns-5d78c9869d-rl7bq
```

3. Aplicá el arreglo.

```bash
sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak
sudo tee /var/lib/kubelet/config.yaml.patch >/dev/null <<'EOF'
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
readOnlyPort: 0
EOF
# Merge the stanzas above into /var/lib/kubelet/config.yaml, then:
sudo systemctl restart kubelet
sudo systemctl is-active kubelet
```

```
active
```

4. Verificá negativamente.

```bash
curl -sk https://192.168.56.11:10250/pods
curl -s --max-time 3 http://192.168.56.11:10255/pods ; echo "exit=$?"
```

```
Unauthorized
exit=7
```

5. Auditá el socket del runtime de contenedores — el objeto del host de mayor valor que se le puede entregar a un Pod.

```bash
ls -l /run/containerd/containerd.sock
sudo find / -xdev -perm -0002 -type f 2>/dev/null | head
```

```
srw-rw---- 1 root root 0 Aug  4 09:12 /run/containerd/containerd.sock
```

6. Encontrá cada Pod del clúster al que se le haya concedido una porción del host.

```bash
kubectl get pods -A -o json | jq -r '
  .items[] | select(
    .spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true or
    (.spec.volumes // [])[]? .hostPath != null
  ) | "\(.metadata.namespace)/\(.metadata.name)"' | sort -u
```

```
default/debug-shell
kube-system/etcd-cks-cp
kube-system/kube-apiserver-cks-cp
kube-system/kube-proxy-8xqzt
```

7. Restringí los puertos del control-plane en el firewall del host. El orden importa: un firewall de host en un nodo Kubernetes coexiste con las cadenas de kube-proxy.

```bash
sudo ufw default deny incoming
sudo ufw allow from 192.168.56.0/24 to any port 22   proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 6443 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 10250 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 2379:2380 proto tcp
sudo ufw allow in on cni0
sudo ufw --force enable
sudo ufw status numbered
```

```
Status: active
     To                         Action      From
     --                         ------      ----
[1]  22/tcp                     ALLOW IN    192.168.56.0/24
[2]  6443/tcp                   ALLOW IN    192.168.56.0/24
[3]  10250/tcp                  ALLOW IN    192.168.56.0/24
[4]  2379:2380/tcp              ALLOW IN    192.168.56.0/24
[5]  Anywhere on cni0           ALLOW IN    Anywhere
```

8. Validá de inmediato que el clúster sobrevivió al firewall.

```bash
kubectl get nodes
kubectl run fw-check --image=busybox:1.36 --restart=Never --rm -it -- \
  nslookup kubernetes.default.svc.cluster.local
```

### Preguntas de comprensión — Bloque 9

34. El puerto 10255 devolvió una lista completa de Pods sin credenciales. Enumerá lo que un atacante aprende de `/pods`, `/metrics` y `/runningpods` en ese puerto.
35. `anonymous.enabled: true` combinado con `authorization.mode: AlwaysAllow` en el puerto 10250 es mucho peor que el puerto de solo lectura. ¿Qué única petición convierte eso en RCE sobre el nodo, y qué endpoint del kubelet la sirve?
36. ¿Por qué habilitar un firewall de host en un nodo Kubernetes requiere un permiso explícito para la interfaz del CNI, y qué hace kube-proxy con lo que interfiere una política ingenua de `deny incoming`?
37. Un Pod monta `/run/containerd/containerd.sock` vía `hostPath`. El socket tiene modo `srw-rw----` y pertenece a `root:root`. ¿Te protege el modo del archivo? Explicá el mapeo de UID del contenedor que determina la respuesta.

---

## Bloque 10 — Verificar, comparar e informar

1. Volvé a ejecutar la captura completa de la línea base en un segundo directorio y compará cada artefacto.

```bash
sudo mkdir -p /root/cks-after && cd /root/cks-after
systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}' | sort > services-running.txt
sudo ss -tulpnH | sort -k5 > sockets-listening.txt
dpkg-query -W -f='${Package}\n' | sort > packages-all.txt
lsmod | awk 'NR>1 {print $1}' | sort > modules-loaded.txt
sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %g %p\n' 2>/dev/null | sort -k4 > suid-sgid.txt

for f in services-running.txt sockets-listening.txt packages-all.txt modules-loaded.txt suid-sgid.txt; do
  printf '\n=== %s ===\n' "$f"
  diff /root/cks-baseline/$f ./$f | grep -E '^[<>]' | sort | uniq -c
done
```

2. Ejecutá un benchmark automatizado y compará su veredicto con tus propios hallazgos.

```bash
kubectl run kube-bench --image=docker.io/aquasec/kube-bench:v0.10.4 \
  --restart=Never --overrides='
{
  "apiVersion": "v1",
  "spec": {
    "hostPID": true,
    "containers": [{
      "name": "kube-bench",
      "image": "docker.io/aquasec/kube-bench:v0.10.4",
      "command": ["kube-bench","run","--targets","node"],
      "volumeMounts": [
        {"name":"var-lib-kubelet","mountPath":"/var/lib/kubelet","readOnly":true},
        {"name":"etc-kubernetes","mountPath":"/etc/kubernetes","readOnly":true}
      ]
    }],
    "volumes": [
      {"name":"var-lib-kubelet","hostPath":{"path":"/var/lib/kubelet"}},
      {"name":"etc-kubernetes","hostPath":{"path":"/etc/kubernetes"}}
    ]
  }
}'
kubectl logs kube-bench | grep -E '^\[(FAIL|WARN)\]' | head -20
```

3. Devolvé el nodo al servicio y confirmá que la planificación funciona de extremo a extremo.

```bash
kubectl uncordon cks-worker-1
kubectl run post-harden --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeName":"cks-worker-1"}}' -- sleep 60
kubectl get pod post-harden -o wide
```

```
NAME           READY   STATUS    RESTARTS   AGE   IP           NODE
post-harden    1/1     Running   0          8s    10.244.1.7   cks-worker-1
```

4. **Paso estratégico.** Compará tu distribución de propósito general endurecida contra un sistema operativo de nodo inmutable diseñado a propósito. Contá lo que sigue siendo alcanzable.

```bash
ls /usr/bin | wc -l ; ls /bin /sbin /usr/sbin 2>/dev/null | wc -l
```

```
1204
843
```

Contrastá con el punto de diseño de Talos Linux, Bottlerocket, Flatcar y Fedora CoreOS: sin shell, sin SSH, sin gestor de paquetes, `/usr` de solo lectura, configuración dirigida por API. Talos incluye aproximadamente una docena de binarios y ninguna ruta de login interactivo — el contenido completo de los Bloques 2, 3, 5, 6 y 7 se vuelve *irrepresentable* en lugar de *remediado*.

### Preguntas de comprensión — Bloque 10

38. Tu diff muestra 34 paquetes eliminados y 6 listeners cerrados, pero `kube-bench` sigue reportando `[FAIL]` en una verificación del kubelet. ¿A cuál de las dos señales le creés, y cuál es el procedimiento para resolver el desacuerdo?
39. `kube-bench` se despliega con `hostPID: true` y montajes del host. Reconciliá eso con todo lo que enseñó el Bloque 9 sobre el acceso al host. ¿Qué controles compensatorios lo vuelven aceptable?
40. Nombrá dos clases distintas de superficie de ataque que endurecer una distribución de propósito general **no puede** reducir pero que un sistema operativo de nodo inmutable elimina por construcción.
41. Tenés que justificar este trabajo ante un equipo de plataforma. Ordená los diez bloques por reducción de riesgo por hora de esfuerzo de ingeniería, y defendé los dos primeros.

---

## Fuentes

- CNCF, *CKS Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Ports and Protocols* — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubernetes, *Kubelet authentication/authorization* — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes, *Set Kubelet Parameters Via A Configuration File* — https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/
- Kubernetes, *Using sysctls in a Kubernetes Cluster* — https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Linux kernel, *Documentation/admin-guide/sysctl/kernel.rst* — https://docs.kernel.org/admin-guide/sysctl/kernel.html
- Linux kernel, *Yama LSM* — https://docs.kernel.org/admin-guide/LSM/Yama.html
- `man 5 modprobe.d`, `man 8 dpkg-statoverride`, `man 5 sshd_config`, `man 8 systemctl`, `man 5 proc`
- CIS, *Benchmarks* (Ubuntu Linux, Kubernetes) — https://www.cisecurity.org/cis-benchmarks
- Aqua Security, *kube-bench* — https://github.com/aquasecurity/kube-bench
- Sidero Labs, *Talos Linux — Philosophy* — https://www.talos.dev/latest/learn-more/philosophy/
- AWS, *Bottlerocket* — https://github.com/bottlerocket-os/bottlerocket

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**1.** El listener de loopback en `127.0.0.1:2379` sirve a los componentes del control-plane coubicados — `kube-apiserver` se conecta a etcd por loopback en una topología kubeadm apilada — y el endpoint de salud de etcd (`2381`) está igualmente enlazado a loopback. Eliminarlo rompe el backend de almacenamiento del API server y el nodo deja de servir al clúster. El listener `192.168.56.10:2379` sirve tráfico de pares/clientes a través de la red y es el que debe restringirse por firewall únicamente a la subred del control-plane. El principio general: un listener de loopback solo es alcanzable por procesos que ya están en el host, así que pertenece al modelo de amenaza *local*; un listener en una dirección enrutable pertenece al *remoto*, que es lo que "reducir la superficie de ataque" ataca primero.

**2.** `dpkg-query -W` lista cada paquete instalado, incluidas las dependencias traídas automáticamente, así que la lista está dominada por bibliotecas que no podés eliminar de forma independiente. `apt-mark showmanual` lista solo los paquetes que un operador instaló explícitamente — el conjunto real de decisiones. Eliminá un paquete manual y `apt autoremove --purge` recolecta automáticamente sus dependencias ahora huérfanas, lo cual es una estrategia de reducción mucho más segura que ir eligiendo paquetes de bibliotecas de una lista plana.

**3.** `-xdev` impide que `find` descienda a otros sistemas de archivos. Sin él en un nodo Kubernetes, `find` recorre cada capa de overlayfs de cada contenedor bajo `/var/lib/containerd/`, cada `emptyDir` bajo `/var/lib/kubelet/pods/` y cada PV montado — produciendo miles de binarios SUID que pertenecen a imágenes de contenedores, no al host. Esa omisión es deseable porque este tema trata sobre la huella del **sistema operativo del host**; los binarios SUID de las imágenes de contenedores son material de los Dominios 4/6 y se remedian reconstruyendo imágenes, no con `chmod` en el nodo.

**4.** `*:10250` es la API del kubelet, enlazada a todas las interfaces y alcanzable desde cualquier host que pueda enrutar hasta el nodo — es superficie de ataque remota y está dentro del alcance. `127.0.0.1:10248` es el endpoint healthz del kubelet, alcanzable solo por un proceso que ya se ejecuta en el host. Llegar hasta él ya requiere la ejecución de código que el endpoint healthz podría otorgar. Es defensa en profundidad en el mejor de los casos; 10250 es el perímetro.

### Bloque 2

**5.**
- `stop` — cambia solo el estado de ejecución actual. La unidad se reinicia en el siguiente arranque, en la siguiente activación por dependencia o en la siguiente conexión al socket.
- `disable` — elimina los enlaces simbólicos `WantedBy`/`RequiredBy` para que la unidad no sea iniciada en el arranque por un target. **No** impide la activación como dependencia de otra unidad en ejecución, ni la activación por socket/path/timer. Escenario de falla: hacés `disable` de `apache2` pero una unidad de monitoreo lista `Requires=apache2.service` — arranca igual.
- `mask` — enlaza simbólicamente el nombre de la unidad a `/dev/null` en `/etc/systemd/system/`, de modo que systemd no puede construir la unidad en absoluto. Toda ruta de arranque falla, incluidas la manual y la impulsada por dependencias. Escenario de falla para `stop`: una remediación de solo `stop` reporta verde en una corrida de auditoría y revierte silenciosamente en el siguiente reinicio.

**6.** `rpcbind.socket` siguió habilitado. systemd mantenía él mismo el socket a la escucha en `0.0.0.0:111`, y en la primera conexión entrante realizó la activación por socket: generó `rpcbind.service` y le pasó el descriptor de archivo ya enlazado. Como la unidad de socket es dueña del puerto, `ss` muestra el puerto abierto incluso mientras el servicio está inactivo. Los servicios activados por socket deben tener la unidad `.socket` deshabilitada *y* enmascarada, o la denegación del `.service` es cosmética.

**7.** `containerd.service` y `kubelet.service`. Enmascarar `containerd` deja al kubelet sin endpoint CRI — registra `failed to get container runtime status ... connection refused` y el nodo queda `NotReady`. Enmascarar `kubelet` detiene toda la gestión del ciclo de vida de los Pods en ese nodo; los contenedores existentes siguen ejecutándose bajo containerd pero nada los reconcilia, y el nodo queda `NotReady` después de `nodeStatusUpdateFrequency` × el vencimiento del lease.

**8.** `sudo systemctl unmask <unit>` seguido de `sudo systemctl enable --now <unit>`. `enable` solo falla porque el enlace simbólico `/etc/systemd/system/<unit>` → `/dev/null` tiene precedencia sobre la unidad del proveedor en `/lib/systemd/system/`; `enable` intentaría crear su propio enlace simbólico en la misma ubicación y systemd sigue resolviendo la unidad a `/dev/null`. `unmask` borra primero ese enlace.

### Bloque 3

**9.** `apt remove` borra los binarios y datos del paquete pero deja sus archivos de configuración (`/etc/…`) y cualquier contenido marcado como conffile en disco, y el paquete pasa al estado `rc`. `apt purge` borra también esos. Para una auditoría esto importa porque la configuración remanente puede contener credenciales (un archivo `htpasswd`, un DSN de base de datos en un vhost de Apache, una definición de impresora `cups` con una contraseña SMB), y porque una reinstalación posterior del paquete restaura silenciosamente la configuración vieja, posiblemente insegura, en lugar del valor por defecto del proveedor.

**10.** En su mayor parte, sí — los ejecutables ya no están, así que no queda ruta de código. Pero no está *completamente* eliminada: los archivos de configuración persisten y pueden filtrar secretos a cualquier proceso que pueda leer `/etc`, y el paquete se reactiva trivialmente con su configuración vieja mediante `apt install`. `rc` es por lo tanto un hallazgo: ejecutá `apt purge` sobre el nombre del paquete para llegar al estado `un`/ausente.

**11.** Capacidad negada: compilar un exploit de escalada local de privilegios *en el objetivo* a partir del código fuente, que es como se distribuyen típicamente los PoC de LPE del kernel. Más débil en 2026 porque los atacantes envían mayoritariamente payloads precompilados y enlazados estáticamente (el herramental de Go y Rust lo vuelve trivial), y porque en un nodo Kubernetes un atacante que puede crear un Pod simplemente trae una imagen de contenedor que contiene un toolchain completo. Eliminar `gcc` eleva el costo de los ataques oportunistas; no detiene a uno preparado.

**12.** Operan en capas distintas y cubren actores distintos. Negar `NET_RAW` (vía los Pod Security Standards *Baseline*/*Restricted* o un `securityContext.capabilities.drop`) impide que los *contenedores* abran sockets raw — restringe cargas de trabajo. Purgar `tcpdump` elimina la herramienta del espacio de nombres del *host*, que es donde aterriza un atacante después de un escape de contenedor o un compromiso de SSH, y donde tiene `CAP_NET_RAW` del host y puede ver todo el tráfico del nodo, incluidos los flujos Pod a Pod de otros inquilinos y los handshakes TLS del kubelet. Ninguno sustituye al otro.

### Bloque 4

**13.** `blacklist <mod>` solo suprime la carga *implícita*: la resolución de alias, los eventos hotplug de udev y la autodetección del tipo de sistema de archivos al montar. Explícitamente **no** detiene un `modprobe <mod>` tipeado por un usuario o invocado por un script — ese es el comportamiento documentado en `modprobe.d(5)`. `install <mod> /bin/false` sobrescribe por completo el comando de instalación del módulo: cualquier intento de carga, implícito o explícito, ejecuta `/bin/false` en lugar de insertar el módulo, y devuelve un valor distinto de cero. Necesitás ambos porque `blacklist` cubre la ruta de alias con la semántica correcta e `install` cubre la ruta directa.

**14.** `systemctl status containerd` muestra el servicio ejecutándose pero fallando al iniciar contenedores; `journalctl -u containerd` registra `failed to create shim / mount overlay: no such device` o `failed to mount overlay: invalid argument`. `kubelet` reporta `Failed to create pod sandbox`. En la capa de `kubectl`: cada Pod de ese nodo queda en `ContainerCreating`, `kubectl describe pod` muestra `FailedCreatePodSandBox`, y el nodo termina reportando `NotReady` porque el kubelet no puede arrancar sus propios Pods estáticos. Overlayfs es el snapshotter por defecto de containerd — sin él no hay sistema de archivos de contenedor.

**15.** `update-initramfs -u` regenera el ramdisk inicial para que la configuración de modprobe esté presente durante la fase de arranque temprano. Saltearlo derrota silenciosamente las listas negras para cualquier módulo cargado desde el initramfs antes de que se monte el sistema de archivos raíz — notablemente los controladores de almacenamiento/sistemas de archivos y, en muchas distribuciones, `usb-storage` (cargado por udev temprano para soportar el arranque desde USB). El módulo termina cargado antes de que `/etc/modprobe.d/` sea siquiera legible, y `lsmod` después lo muestra presente pese a un archivo de configuración de apariencia correcta.

**16.** `kernel.modules_disabled=1` es un interruptor de escritura única: una vez puesto en 1 no puede devolverse a 0 sin reiniciar. Solo es utilizable si se aplica **al final de la secuencia de arranque**, después de que el CNI, kube-proxy y containerd hayan cargado cada módulo que necesitan — en la práctica vía una unidad de `systemd` ordenada con `After=kubelet.service` y con retardo, no vía `/etc/sysctl.d/` (que es aplicado por `systemd-sysctl.service` temprano en el arranque). Modo de falla con Calico o Cilium: ambos cargan módulos de forma perezosa en respuesta a la configuración — Calico puede cargar `ipip`, `vxlan` o extensiones netfilter `xt_*` cuando se crea por primera vez un IPPool o una política coincidente; Cilium carga módulos adyacentes a eBPF y `xt_*` cuando se activan nuevas funciones del datapath. Con la carga de módulos congelada, el primer Pod que requiera una coincidencia `xt_` no cargada falla al programar su regla y el tráfico se pierde silenciosamente — sin ninguna línea de log que apunte a la carga de módulos.

### Bloque 5

**17.** El nombre de la cuenta es una etiqueta almacenada en `/etc/passwd`; no cumple ningún rol en la autorización. El kernel compara el `euid` numérico de la estructura de credenciales del proceso contra `0` (o, en las rutas conscientes de capacidades, evalúa el conjunto de capacidades efectivas, que un proceso con UID 0 recibe completo por defecto). `backdoor` con UID 0 es root según cada verificación del kernel: puede leer `/etc/shadow`, cargar módulos y abrir `/run/containerd/containerd.sock`. Justamente por esto un duplicado de UID 0 es un hallazgo de incidente, no de higiene.

**18.** No. `usermod -L` antepone un `!` al hash almacenado en `/etc/shadow`, lo que vuelve el hash incomparable y por lo tanto bloquea únicamente la autenticación por **contraseña**. Deja abiertas: la autenticación por clave pública SSH (la clave está en `~/.ssh/authorized_keys`, no se consulta contraseña), cualquier módulo PAM que no consulte `pam_unix` (LDAP, Kerberos, `pam_ssh_agent_auth`), `su` desde root, y la ejecución vía cron/timer de systemd como ese usuario. El flag que cierra las rutas interactivas es `usermod -e 1` (o `chage -E 0`), que fija un vencimiento de cuenta en el pasado — la gestión de cuenta de `pam_unix` entonces deniega la cuenta sin importar el método de autenticación, así que el SSH por clave también falla.

**19.** `usermod -L` es un control de *autenticación* que muta el hash de la contraseña. `chage -E 0` / `usermod -e 1` es un control de *cuenta* que fija `sp_expire` en `/etc/shadow` y se aplica durante la fase de cuenta de PAM. `chage -E` sobrevive a un posterior reseteo con `passwd`: un administrador que fija una nueva contraseña limpia el `!` del bloqueo pero no toca el campo de vencimiento, así que la cuenta sigue denegada. Por eso el control de vencimiento es el duradero y el bloqueo es el cómodo — configurá ambos.

**20.** El escape de contenedor deja al atacante como UID 1001 (`jenkins`) en el nodo. `sudo -n true` tiene éxito por el `NOPASSWD:ALL`, dando root inmediato en el host. Como root el atacante lee `/etc/kubernetes/kubelet.conf` y `/var/lib/kubelet/pki/kubelet-client-current.pem` — el certificado de cliente del nodo, que porta la identidad `system:node:<name>` — y, en un nodo de control-plane, `/etc/kubernetes/admin.conf`, que es `cluster-admin` directamente. Incluso en un worker, root puede leer cada token de ServiceAccount montado bajo `/var/lib/kubelet/pods/*/volumes/kubernetes.io~projected/`; si algún Pod de ese nodo corre con una ServiceAccount vinculada a `cluster-admin` (o con permiso para crear Pods, o para leer Secrets a nivel de clúster), ese token es la escalada. La cadena es: sudo `NOPASSWD` → root en el host → credenciales del nodo y cada token de ServiceAccount coubicado → cluster-admin.

**21.** `sshd -T` le pide al demonio que vuelque su configuración **efectiva** tras el parseo completo. `grep` sobre el archivo principal se pierde (a) los drop-ins de `Include /etc/ssh/sshd_config.d/*.conf`, que en Ubuntu 22.04+ son donde cloud-init y los paquetes del proveedor colocan las sobrescrituras, y (b) los valores por defecto compilados para palabras clave ausentes del archivo por completo — `PermitRootLogin` toma el valor por defecto `prohibit-password` cuando no está definido, así que un `grep` que no devuelve nada no te dice nada. También se pierde los bloques `Match`, cuyos ajustes condicionales `sshd -T` mostrará si pasás `-C user=...,host=...,addr=...`.

**22.** `prohibit-password` (antes `without-password`) permite el login de root por **clave pública**, GSSAPI o autenticación basada en host, pero deniega la contraseña y el modo interactivo por teclado. Es estrictamente mejor que `no` en exactamente un escenario: automatización que debe ejecutarse como root por SSH con una clave — gestión de configuración, agentes de backup, alternativas al estilo `rsync --rsync-path="sudo rsync"`, o una ruta de emergencia de rotura de cristal — donde cambiar a una cuenta no root más `sudo` requeriría un permiso `NOPASSWD` que en sí mismo es un peor control (ver respuesta 20).

**23.** `reload` envía `SIGHUP`; el `sshd` maestro relee su configuración y se re-ejecuta, pero **las conexiones existentes se preservan** porque cada sesión es servida por un proceso hijo bifurcado que queda intacto. `restart` derriba al maestro y, según el `KillMode` de la unidad, puede matar a los hijos — cortando tu sesión. Si la configuración nueva está rota, `reload` te deja conectado y con capacidad de arreglarla, mientras que `restart` puede dejarte afuera con un demonio que no arrancó. Por eso la secuencia es siempre `sshd -t` → `systemctl reload`.

**24.** Sí, quedan varias rutas. `AllowGroups` lo aplica solo `sshd`, así que restringe únicamente los logins por **SSH**. `deploy` todavía puede obtener una shell vía: la consola física/serial/del hipervisor y cualquier `getty`; `su - deploy` o `sudo -u deploy -i` desde otra cuenta autorizada; un trabajo cron o una unidad de usuario de systemd corriendo como `deploy` que ejecute un script controlado por el atacante; y — lo más relevante en un nodo Kubernetes — cualquier Pod o proceso que se ejecute con UID 1002. El control de acceso a nivel de host es la unión de todas estas rutas, no solo la de SSH.

### Bloque 7

**25.** El `4` inicial es el bit setuid (`S_ISUID`, octal `04000`). Cuando cualquier usuario con permiso de ejecución corre el archivo, el kernel fija el UID **efectivo** del proceso (y el set-UID guardado) al del propietario del archivo — `root` acá — mientras que el UID real sigue siendo el del usuario invocante. El programa por lo tanto se ejecuta con la autoridad de root para operaciones privilegiadas, que es precisamente por qué un error de implementación en un binario así es una escalada local de privilegios.

**26.** Los usuarios no root ya no pueden cambiar su propia contraseña: `passwd` necesita escribir en `/etc/shadow`, que es `-rw-r----- root:shadow`, y sin SUID corre como el invocante sin privilegios y falla con `passwd: Authentication token manipulation error`. Las herramientas relacionadas que lo llaman (`chage` para autoservicio, algunos flujos de cambio de contraseña de PAM, el login con contraseña expirada) también se rompen. En un nodo multiusuario esto es un mal intercambio — rompiste una operación de seguridad rutinaria. En un nodo donde todos los humanos se autentican con clave SSH y está configurado `PasswordAuthentication no`, nadie cambia nunca una contraseña Unix, así que el binario no tiene invocante legítimo y quitarle el bit elimina una primitiva real a costo operativo cero.

**27.** Un `chmod u-s` simple cambia solo los bits de modo del inodo. `dpkg` registra los permisos previstos en los metadatos del paquete y los vuelve a aplicar cada vez que el paquete propietario se desempaqueta — así que el siguiente `apt upgrade` de `passwd`, `util-linux` o `policykit-1` restaura silenciosamente el bit SUID. `dpkg-statoverride` registra la desviación en `/var/lib/dpkg/statoverride`, que `dpkg` consulta durante el desempaquetado y respeta en lugar del valor por defecto del paquete. Tres meses después de un `chmod` simple, un auditor que reejecutara el escaneo con `find` vería el bit SUID de vuelta en `chsh`, `chfn` y `pkexec`, sin nada en el registro de cambios que lo explique — la clásica regresión silenciosa.

**28.** Recolectá, en este orden: (1) las marcas de tiempo y metadatos del inodo del archivo vía `stat` — el tiempo de `Change` es el que un atacante no puede fijar con `touch -t`, y data el compromiso; (2) un hash criptográfico (`sha256sum`) más una copia del binario mismo preservada fuera del host para ingeniería inversa y coincidencia de IOC. También vale capturar: el proceso propietario si está corriendo (`fuser`/`lsof` sobre la ruta), y el listado del directorio padre. El orden importa porque leer el archivo con `sha256sum` o `cp` actualiza el tiempo de acceso, y cualquier escritura o movimiento destruye el tiempo de cambio — tenés que registrar los metadatos *antes* de tocar el contenido, y tenés que copiar el artefacto *antes* de borrarlo, o destruiste la única evidencia de cómo se comprometió el nodo.

### Bloque 8

**29.** `kernel.kptr_restrict` controla si se exponen los punteros con el especificador de formato `%pK`:
- `0` — los punteros se imprimen para todos, sin restricción.
- `1` — los punteros se ocultan (se imprimen como ceros) a los procesos **que carecen de `CAP_SYSLOG`**. Este es el valor que ya oculta las direcciones de símbolos de `/proc/kallsyms` a un lector sin privilegios, y es lo que demuestra el ejercicio.
- `2` — los punteros se imprimen como ceros **sin importar el privilegio**, incluso para root o poseedores de `CAP_SYSLOG`.

`1` alcanza para anular la filtración de `/proc/kallsyms` sin privilegios; `2` es la opción endurecida porque también se lo niega a un proceso que ya obtuvo `CAP_SYSLOG` — un estado intermedio realista en un nodo — y cierra filtraciones vía otros consumidores de `%pK`.

**30.** `net.ipv4.ip_forward=1` hace que el kernel enrute paquetes entre interfaces. La red de Kubernetes está construida sobre eso: **kube-proxy** hace DNAT de una ClusterIP a una IP de Pod backend y depende del kernel para reenviar el paquete reescrito por la interfaz del CNI, y el **plugin CNI** (Flannel, Calico, Cilium en modos de enrutamiento no eBPF) reenvía el tráfico Pod a Pod entre los pares veth y el enlace ascendente del nodo. En `0`, el kernel descarta esos paquetes. El síntoma visible para el usuario: la resolución DNS dentro de los Pods expira (`nslookup: can't resolve ...`), las conexiones a Services se cuelgan y luego fallan con `connection timed out` en lugar de `connection refused`, el tráfico de Pods entre nodos muere mientras que el del mismo nodo en algunos CNIs todavía funciona — y nada en `kubectl describe` ni en los logs del CNI apunta al sysctl. Es una falsa remediación de primer nivel porque los benchmarks CIS genéricos de Linux recomiendan legítimamente `ip_forward=0` para un host que no es un router; un nodo Kubernetes *es* un router.

**31.** Cierra la divulgación vía **volcados de memoria de programas setuid/setgid**. Con `fs.suid_dumpable` en `1` (todos volcables) o `2` (volcable pero legible solo por root), un binario SUID que se cae escribe un archivo core que contiene toda la memoria del proceso que tenía mientras corría como root — hashes de contraseñas leídos de `/etc/shadow`, claves privadas, secretos descifrados, punteros del kernel. El volcado aterriza donde indique `kernel.core_pattern`: típicamente el CWD del proceso, `/var/crash`, o canalizado a `systemd-coredump` / `apport`, desde donde puede quedar legible por todos, enviarse a un servicio de reporte de fallas, o simplemente quedar en disco. `0` deshabilita por completo el volcado para procesos que cambian de privilegio.

**32.** Pueden romperse las cargas de trabajo basadas en eBPF que cargan programas desde un contexto no root o con capacidades reducidas. En la práctica, en Kubernetes este riesgo es más acotado de lo que suena: **Cilium**, el **driver de eBPF moderno de Falco**, **Pixie** y la mayoría de los agentes de observabilidad eBPF corren como root con `CAP_BPF`/`CAP_SYS_ADMIN`, y `kernel.unprivileged_bpf_disabled=1` restringe solo las llamadas `bpf()` *sin privilegios* (sin `CAP_BPF`) — así que no se ven afectados. La rotura realista está en herramientas internas o de terceros que llaman a `bpf()` desde un proceso sin privilegios, y en agentes más viejos que dependen de programas de filtro de socket sin privilegios. Detección antes del despliegue a la flota: fijá el valor en un único nodo canario y luego observá las llamadas `bpf()` que devuelven `EPERM` — rastreá con `sudo bpftrace -e 'tracepoint:syscalls:sys_exit_bpf /args->ret == -1/ { printf("%s %d\n", comm, args->ret); }'` (o `auditd` sobre la syscall `bpf`) — y confirmá que cada DaemonSet de agente se mantiene `Ready` durante un ciclo completo de despliegue.

**33.** Se rompen comúnmente: los exportadores de nodo y agentes de métricas (el colector de procesos de `node_exporter`, la vista de procesos del host de `cAdvisor`), los agentes de APM/profiling (Datadog Agent, Dynatrace OneAgent, Pixie), y cualquier monitoreo basado en procesos o enviador de logs que resuelva PIDs a líneas de comando. `gid=` designa un grupo cuyos miembros conservan visibilidad completa de `/proc` pese a `hidepid`; agregás la cuenta de servicio del agente de monitoreo a ese grupo para que siga funcionando mientras que los usuarios comunes — y cualquier proceso en el que aterrice un atacante — ven solo sus propios procesos. Sin `gid=`, `hidepid=invisible` obliga a que cada agente de monitoreo corra como root, lo cual es una pérdida neta.

### Bloque 9

**34.** El puerto de solo lectura 10255 no requiere autenticación y expone:
- `/pods` — el `PodList` completo del nodo, incluyendo la especificación de cada Pod: imágenes de contenedores y tags (un inventario de imágenes para cruzar con CVEs), comando y argumentos, **variables de entorno**, definiciones de volúmenes con destinos `hostPath`, nombres de ServiceAccount, nombre del nodo y disposición de namespaces. Las variables de entorno contienen habitualmente credenciales inyectadas por CI o Helm.
- `/metrics` y `/metrics/cadvisor` — métricas de recursos por contenedor: nombres de contenedores, namespaces, identificadores de imágenes y rutas de cgroup. Útiles para mapear el clúster y para canales laterales de temporización.
- `/runningpods` — los Pods actualmente en ejecución con IDs de contenedores, lo que permite a un atacante correlacionar contra el runtime de contenedores.

En conjunto esto es un dossier de reconocimiento completo del nodo y, vía los nombres de ServiceAccount y namespaces, una lista de objetivos para el clúster. La remediación es `readOnlyPort: 0` — el puerto no tiene ningún mecanismo de autenticación, así que no puede asegurarse, solo cerrarse.

**35.** Un `POST` a `/run/{namespace}/{pod}/{container}` o una petición de upgrade a `/exec/{namespace}/{pod}/{container}?command=...` en el puerto 10250. Con `anonymous.enabled: true` el kubelet acepta la petición no autenticada, y con `authorization.mode: AlwaysAllow` omite la SubjectAccessReview que de otro modo la denegaría. El atacante obtiene ejecución de comandos dentro de **cualquier contenedor del nodo** — incluyendo, en un nodo de control-plane, `kube-apiserver` o `etcd`, cuyos sistemas de archivos contienen `/etc/kubernetes/pki/` y todo el almacén de datos del clúster. Desde cualquier contenedor también pueden leer el token de ServiceAccount montado y pivotear hacia el API server. Este es el clásico compromiso total del clúster a partir de una única petición HTTP no autenticada; el arreglo es `anonymous.enabled: false`, `authorization.mode: Webhook`, y un `clientCAFile` para autenticación de cliente x509.

**36.** kube-proxy programa reglas `nat` y `filter` en iptables/nftables para implementar los Services, y el CNI programa sus propias reglas de `FORWARD` y `nat` para la red de Pods. `ufw` instala una política `FORWARD` por defecto de `DROP` más sus propias cadenas, y un `ufw default deny incoming` ingenuo también descarta el tráfico que llega por el bridge del CNI (`cni0`, `flannel.1`, `cali*`, `cilium_host`). El resultado es que el tráfico Pod a Pod, Pod a Service y Pod a DNS es descartado por el firewall del host aunque las reglas de DNAT de kube-proxy se hayan disparado correctamente. Un `ufw allow in on <cni-iface>` explícito (y, en algunos CNIs, `ufw default allow routed` / una política `FORWARD` permisiva) lo restaura. El punto más profundo: en un nodo Kubernetes el firewall del host comparte las tablas de netfilter con el propio datapath del clúster, así que el orden de las reglas y las políticas por defecto son un recurso compartido — por eso la segmentación a nivel de red (grupos de seguridad, un firewall físico) suele ser el mejor lugar para restringir 6443/10250/2379.

**37.** No, el modo del archivo no te protege. Un contenedor por defecto corre como root (UID 0) dentro de su espacio de nombres de usuario, y a menos que esté habilitado el **remapeo de espacios de nombres de usuario**, el UID 0 del contenedor *es* el UID 0 del host — el kernel compara el mismo UID numérico contra el modo `srw-rw----` `root:root` del socket y concede el acceso. Montar el socket por lo tanto le entrega al Pod la API de containerd, desde la cual puede lanzar un nuevo contenedor con `privileged: true`, el espacio de nombres PID del host y `/` montado — es decir, root completo en el host. Los bits de modo importarían solo si el contenedor corriera con un UID no root *y* no estuviera en el grupo `root` *y* no tuviera `CAP_DAC_OVERRIDE` (que un contenedor root por defecto sí tiene). Dado cuántas de esas condiciones deben cumplirse simultáneamente, el control correcto es prohibir el montaje: el `hostPath` sobre el socket del runtime está denegado por el Pod Security Standard *Baseline*, y debería bloquearse por política de admisión (Pod Security Admission `baseline`/`restricted`, o una regla de Kyverno/Gatekeeper) en vez de confiarse a los permisos de archivo.

### Bloque 10

**38.** No le creas ciegamente a ninguna — el desacuerdo es el hallazgo. Tu diff prueba *qué cambió en este host*; `kube-bench` evalúa *un control de benchmark específico* y puede estar verificando una ruta de archivo distinta, un nombre de flag distinto, o un control que tus cambios no apuntaban. El procedimiento: leé la línea exacta de `[FAIL]`, que nombra el número de control de CIS y el texto de remediación; localizá el archivo y la clave que realmente inspecciona (`kube-bench` imprime el comando de auditoría en la salida `--json` o en `/opt/kube-bench/cfg/`); verificá ese valor a mano en el nodo. Los dos desenlaces son (a) una brecha real que tu trabajo manual omitió — arreglala; o (b) un falso positivo del benchmark, típicamente porque la verificación hace grep sobre la línea de comandos del `kubelet` buscando un flag que vos configuraste en `config.yaml`, o apunta a una ruta que tu distribución ubica en otro lado. Documentá cuál fue; un `[FAIL]` suprimido sin documentar es la forma en que las brechas reales sobreviven a las auditorías.

**39.** `kube-bench` genuinamente requiere acceso al host — su tarea es leer `/var/lib/kubelet/config.yaml`, `/etc/kubernetes/manifests/`, y la propiedad y permisos de archivos en el nodo. La tensión se resuelve no negando el acceso sino restringiendo su radio de impacto: los montajes son `readOnly: true`; el Pod tiene `restartPolicy: Never` y vida corta, se elimina inmediatamente después; corre en un namespace dedicado con una ServiceAccount sin permisos de API; el digest de la imagen está fijado y verificado; el Pod queda exento del Pod Security Standard mediante una excepción explícita, nombrada y auditable en vez de aflojando el valor por defecto del namespace. El principio general: el herramental privilegiado es aceptable cuando es *efímero, de alcance acotado, exceptuado individualmente y registrado* — el modo de falla es un DaemonSet privilegiado permanente que nadie elimina.

**40.** Dos clases:
1. **La superficie de acceso interactivo en sí.** Una distribución de propósito general tiene una shell, un gestor de paquetes, un demonio SSH y un `/usr` escribible — podés endurecer cada uno, pero cada uno de ellos sigue siendo una ruta de código que un atacante que llegue al nodo puede usar, y cada paquete futuro instalado por un operador reabre parte de eso. Talos y Bottlerocket no incluyen shell ni SSH: no hay sesión interactiva que comprometer, y la configuración se aplica a través de una API autenticada. `chmod`, `mask` y `purge` no pueden producir esa propiedad; solo eliminar los componentes de la imagen puede.
2. **La deriva de configuración y binarios a lo largo de la vida del nodo.** Tu nodo Ubuntu endurecido diverge de su línea base en el momento en que alguien ejecuta `apt install`, una actualización de paquete restaura un bit SUID, o una sesión de respuesta a incidentes deja una herramienta atrás — y esa deriva es invisible sin reescaneo continuo. Un sistema operativo inmutable monta `/usr` en solo lectura, entrega actualizaciones atómicas basadas en imágenes con reversión, y a menudo verifica el sistema de archivos raíz con dm-verity, así que la deriva es estructuralmente imposible en lugar de meramente auditada. Relacionado: el mecanismo de actualización mismo se vuelve un único artefacto verificable en lugar de cientos de paquetes versionados de forma independiente.

**41.** Un ordenamiento defendible por reducción de riesgo por hora, con el razonamiento que importa más que el orden exacto:

| Puesto | Bloque | Por qué acá |
|---|---|---|
| 1 | **9 — exposición de demonios de nodo** | Minutos de trabajo; cierra RCE no autenticado y reconocimiento a nivel de clúster |
| 2 | **5 — usuarios y sudo** | Minutos; elimina el root permanente y la cadena de escape a cluster-admin |
| 3 | **6 — endurecimiento de SSH** | ~30 min; cierra el principal punto de entrada remoto dejándolo solo con clave |
| 4 | **2 — servicios y sockets** | Rápido, reversible, elimina directamente puertos a la escucha |
| 5 | **8 — sysctl** | Un solo archivo; bloquea amplias clases de LPE y de filtración de información — pero carga con la trampa de `ip_forward` |
| 6 | **3 — paquetes** | Alto volumen, valor moderado; sobre todo eleva el costo para el atacante |
| 7 | **7 — SUID/SGID** | Valor real, pero el análisis por binario es lento y propenso a regresiones sin `dpkg-statoverride` |
| 8 | **4 — módulos del kernel** | Reducción genuina de LPE, el mayor riesgo de rotura, requiere drain + validación tras reinicio |
| 9 | **1 / 10 — línea base y verificación** | Cero reducción directa, pero cada bloque de arriba es inverificable sin ellos |

Defensa de los dos primeros. El **Bloque 9** es el primero porque es el único bloque que aborda una vulnerabilidad *alcanzable remotamente, no autenticada y previa a la autenticación*. Un kubelet anónimo en 10250 con `AlwaysAllow` es ejecución de comandos en el nodo a partir de una única petición HTTP — sin credencial, sin interacción del usuario, sin punto de apoyo previo. Nada más en la lista es explotable por un atacante que no haya llegado ya al host, y la remediación son tres claves en un archivo YAML más un reinicio de servicio. La reducción de riesgo por hora es efectivamente ilimitada.

El **Bloque 5** es el segundo porque apunta a la mitad de *escalada* de la cadena de ataque en vez de a la de entrada, y porque es el camino más corto desde "el atacante tiene cualquier punto de apoyo" hasta "el atacante tiene cluster-admin". Una cuenta con UID 0 duplicado o una entrada `NOPASSWD:ALL` en sudoers convierte un escape de contenedor de severidad baja — que te deja como un UID sin privilegios y sin nada interesante — en root en el host, credenciales del nodo y cada token de ServiceAccount montado en el nodo. Auditar duplicados de UID 0, contraseñas vacías y permisos de sudo lleva cuatro comandos, y a diferencia de los Bloques 3, 4 y 7 no tiene esencialmente riesgo de rotura y no requiere reinicio. El patrón que justifica todo el ordenamiento: **priorizá los controles que rompen de plano un eslabón de la cadena de ataque por sobre los que meramente elevan el costo para el atacante**, y entre esos, preferí los que no necesitan drain ni reinicio.

</details>