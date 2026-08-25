# LPIC-3 303 — Tema 333.2: Mandatory Access Control

## Ejercicios guiados

> **Contexto del examen.** El objetivo 333.2 abarca los conceptos TE/RBAC/MAC/DAC, la configuración y el mantenimiento de SELinux, y el conocimiento general de AppArmor y Smack. Utilidades incluidas en el alcance: `getenforce`, `setenforce`, `selinuxenabled`, `getsebool`, `setsebool`, `togglesebool`, `fixfiles`, `restorecon`, `setfiles`, `newrole`, `runcon`, `semanage`, `sestatus`, `seinfo`, `apol`, `seaudit`, `audit2why`, `audit2allow`, `/etc/selinux/*`, y el conjunto de herramientas de AppArmor.
> Fuente: [LPI Exam 303 Objectives (303-300, v3.0)](https://www.lpi.org/our-certifications/exam-303-objectives/)

---

## Entorno de laboratorio

Dos máquinas (VMs, contenedores con un init completo, o instancias en la nube). **No** ejecute esto en un host de producción: varios pasos generan denegaciones deliberadamente, reetiquetan sistemas de archivos y recargan la política del kernel.

| Host | Distribución | Rol |
|---|---|---|
| `mac-rhel` | Rocky Linux 9 / RHEL 9 / Fedora 40+ | SELinux (Ejercicios 1–9, 11) |
| `mac-deb` | Ubuntu 24.04 LTS (o Debian 12) | AppArmor (Ejercicio 10) |

Paquetes requeridos:

```bash
# mac-rhel
sudo dnf install -y httpd curl policycoreutils policycoreutils-python-utils \
     setools-console selinux-policy-devel setroubleshoot-server audit attr

# mac-deb
sudo apt install -y apparmor apparmor-utils apparmor-profiles auditd attr
```

Las salidas que se muestran a continuación son representativas. Los PID, inodos, nombres de dispositivo, números de versión de política y cantidades de reglas difieren en cada sistema — lo que usted debe ser capaz de leer es la *forma* de la salida.

---

## Ejercicio 1 — Demostrar que MAC no es DAC

El objetivo de este ejercicio no es "SELinux bloqueó a Apache". Es que **una configuración DAC completamente permisiva no es suficiente**, porque DAC y MAC son dos compuertas independientes y el kernel evalúa ambas.

### Pasos

1. Cree contenido fuera de toda ruta que Apache normalmente tenga permitido leer:

   ```bash
   sudo mkdir -p /srv/lab333/html
   echo '<h1>333.2 MAC lab</h1>' | sudo tee /srv/lab333/html/index.html
   ```

2. Haga que DAC sea lo más permisivo posible, y confírmelo:

   ```bash
   sudo chown -R apache:apache /srv/lab333
   sudo chmod -R 0777 /srv/lab333
   ls -ld /srv/lab333 /srv/lab333/html /srv/lab333/html/index.html
   ```

   ```
   drwxrwxrwx. 3 apache apache 19 Aug 24 10:02 /srv/lab333
   drwxrwxrwx. 2 apache apache 24 Aug 24 10:02 /srv/lab333/html
   -rwxrwxrwx. 1 apache apache 24 Aug 24 10:02 /srv/lab333/html/index.html
   ```

3. Apunte Apache hacia ese directorio:

   ```bash
   sudo tee /etc/httpd/conf.d/lab333.conf >/dev/null <<'EOF'
   DocumentRoot "/srv/lab333/html"
   <Directory "/srv/lab333/html">
       Require all granted
   </Directory>
   EOF
   sudo systemctl enable --now httpd
   ```

4. Solicite la página:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ```

   ```
   403
   ```

5. Demuestre que la falla no es de DAC — lea el mismo archivo con el mismo UID bajo el que corre Apache:

   ```bash
   sudo -u apache cat /srv/lab333/html/index.html
   ```

   ```
   <h1>333.2 MAC lab</h1>
   ```

6. Ahora observe la segunda compuerta:

   ```bash
   ls -Z /srv/lab333/html/index.html
   ps -eZ | grep -m1 httpd
   ```

   ```
   unconfined_u:object_r:var_t:s0 /srv/lab333/html/index.html
   system_u:system_r:httpd_t:s0    1487 ?  00:00:00 httpd
   ```

7. Lea la denegación que registró el kernel:

   ```bash
   sudo ausearch -m AVC -ts recent | tail -n 20
   ```

   ```
   type=AVC msg=audit(1756029773.114:412): avc:  denied  { getattr } for  pid=1489
     comm="httpd" path="/srv/lab333/html/index.html" dev="dm-0" ino=17825920
     scontext=system_u:system_r:httpd_t:s0
     tcontext=unconfined_u:object_r:var_t:s0
     tclass=file permissive=0
   ```

### Punto de control 1

- **Q1.1** — El paso 5 tuvo éxito como `apache` pero el paso 4 devolvió 403. Explique con precisión por qué, en términos del orden en que el kernel evalúa DAC y los hooks LSM.
- **Q1.2** — En el registro AVC, identifique qué denota cada uno de `scontext`, `tcontext`, `tclass` y `permissive=0`. ¿Cuál le indica la *acción* que fue rechazada?
- **Q1.3** — El archivo fue creado por `root`, y sin embargo su usuario SELinux es `unconfined_u`, no `system_u` ni `root`. ¿De dónde salió ese primer campo?
- **Q1.4** — Enuncie en una oración la diferencia definitoria entre DAC y MAC, usando este escenario como ejemplo. ¿Por qué `chmod 777` nunca puede ser un bypass de MAC?

---

## Ejercicio 2 — Modo, estado, y qué significa realmente "disabled"

### Pasos

1. Consulte las tres herramientas de estado y observe que responden tres preguntas distintas:

   ```bash
   getenforce
   selinuxenabled; echo "exit status: $?"
   sestatus
   ```

   ```
   Enforcing
   exit status: 0
   SELinux status:                 enabled
   SELinuxfs mount:                /sys/fs/selinux
   SELinux root directory:         /etc/selinux
   Loaded policy name:             targeted
   Current mode:                   enforcing
   Mode from config file:          enforcing
   Policy MLS status:              enabled
   Policy deny_unknown status:     allowed
   Memory protection checking:     actual (secure)
   Max kernel policy version:      33
   ```

2. Inspeccione el pseudo-sistema de archivos a través del cual el kernel exporta la interfaz:

   ```bash
   mount | grep selinuxfs
   cat /sys/fs/selinux/enforce
   ls /sys/fs/selinux/
   ```

   ```
   selinuxfs on /sys/fs/selinux type selinuxfs (rw,nosuid,noexec,relatime)
   1
   access  avc  booleans  checkreqprot  class  commit_pending_bools  context
   create  deny_unknown  enforce  initial_contexts  member  mls  policy  policyvers
   relabel  status  user  validatetrans
   ```

3. Observe la caché de vectores de acceso mientras genera tráfico:

   ```bash
   cat /sys/fs/selinux/avc/cache_stats
   for i in $(seq 200); do curl -s -o /dev/null http://localhost/; done
   cat /sys/fs/selinux/avc/cache_stats
   ```

   ```
   lookups hits misses allocations reclaims frees
   1049873 1046412 3461 3461 2496 2560
   ```

4. Cambie a permissive en tiempo de ejecución, vuelva a probar, y regrese:

   ```bash
   sudo setenforce 0 && getenforce
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   sudo setenforce 1 && getenforce
   ```

   ```
   Permissive
   200
   Enforcing
   ```

5. Confirme que el cambio en tiempo de ejecución **no** tocó el archivo de configuración:

   ```bash
   sudo grep -Ev '^\s*(#|$)' /etc/selinux/config
   sestatus | grep -E 'Current mode|Mode from config'
   ```

   ```
   SELINUX=enforcing
   SELINUXTYPE=targeted
   Current mode:                   enforcing
   Mode from config file:          enforcing
   ```

6. Inspeccione qué vive realmente bajo `/etc/selinux`:

   ```bash
   ls /etc/selinux/
   ls /etc/selinux/targeted/
   ls /etc/selinux/targeted/contexts/files/
   ```

   ```
   config  semanage.conf  targeted
   active  contexts  policy  setrans.conf  logins
   file_contexts  file_contexts.bin  file_contexts.homedirs
   file_contexts.homedirs.bin  file_contexts.local  file_contexts.subs_dist
   media
   ```

7. Lea (no aplique) las dos anulaciones disponibles en tiempo de arranque:

   ```
   enforcing=0     # policy loaded, all denials logged only
   selinux=0       # SELinux not initialised at all, nothing labelled
   ```

### Punto de control 2

- **Q2.1** — `getenforce`, `selinuxenabled` y `sestatus` se solapan. ¿Qué le dice cada uno de forma única, y cuál es el único utilizable directamente en un condicional de shell?
- **Q2.2** — Ejecuta `setenforce 0`, reinicia, y el sistema vuelve en Enforcing. ¿Por qué? ¿Qué archivo habría tenido que editar, y cuál es la contrapartida frente al comando de tiempo de ejecución?
- **Q2.3** — Un sistema está corriendo con `SELINUX=disabled` en `/etc/selinux/config` y ahora usted quiere Enforcing. ¿Por qué `setenforce 1` está garantizado que va a fallar, y qué debe hacer — incluyendo un paso que es fácil de olvidar y que, si se omite, dejará al sistema imposible de arrancar a un estado utilizable?
- **Q2.4** — Contraste `enforcing=0` y `selinux=0` como parámetros de la línea de comandos del kernel. ¿Cuál es seguro usar al diagnosticar una falla de arranque que usted sospecha relacionada con SELinux, y por qué el otro es una opción mucho peor para ese propósito?
- **Q2.5** — ¿Qué significa `Policy deny_unknown status: allowed`, y cuál es la consecuencia de seguridad del ajuste opuesto?

---

## Ejercicio 3 — Contextos, etiquetado y la trampa de `chcon`

### Pasos

1. Muestre el contexto de un proceso, un usuario, un archivo y un socket, y observe la gramática idéntica de cuatro campos:

   ```bash
   id -Z
   ps -eZ | grep -m1 'httpd$'
   ls -Z /var/www/html
   sudo ss -ltnpZ | grep -m1 httpd
   ```

   ```
   unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
   system_u:system_r:httpd_t:s0     1487 ? 00:00:00 httpd
   system_u:object_r:httpd_sys_content_t:s0 index.html
   LISTEN 0 511 *:80 *:* users:(("httpd",pid=1487,fd=4,proc_ctx=system_u:system_r:httpd_t:s0))
   ```

2. Demuestre que la etiqueta es un atributo extendido en disco, no una base de datos:

   ```bash
   getfattr -m . -d /srv/lab333/html/index.html
   ```

   ```
   getfattr: Removing leading '/' from absolute path names
   # file: srv/lab333/html/index.html
   security.selinux="unconfined_u:object_r:var_t:s0"
   ```

3. Pregúntele a la política cuál *debería* ser la etiqueta, sin cambiar nada:

   ```bash
   sudo selabel_lookup -b file -k /srv/lab333/html/index.html
   sudo matchpathcon /var/www/html/index.html     # legacy equivalent
   ```

   ```
   Default context: system_u:object_r:var_t:s0
   /var/www/html/index.html	system_u:object_r:httpd_sys_content_t:s0
   ```

4. Aplique una etiqueta **solo en tiempo de ejecución** y confirme que el sitio ahora funciona:

   ```bash
   sudo chcon -R -t httpd_sys_content_t /srv/lab333/html
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ls -Z /srv/lab333/html/index.html
   ```

   ```
   200
   unconfined_u:object_r:httpd_sys_content_t:s0 /srv/lab333/html/index.html
   ```

5. Ahora active la trampa — simule cualquier evento que dispare un reetiquetado:

   ```bash
   sudo restorecon -Rv /srv/lab333
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ```

   ```
   Relabeled /srv/lab333/html from unconfined_u:object_r:httpd_sys_content_t:s0 to unconfined_u:object_r:var_t:s0
   Relabeled /srv/lab333/html/index.html from unconfined_u:object_r:httpd_sys_content_t:s0 to unconfined_u:object_r:var_t:s0
   403
   ```

6. Hágalo correctamente — registre primero la regla en el almacén de políticas, y después reetiquete:

   ```bash
   sudo semanage fcontext -a -t httpd_sys_content_t '/srv/lab333/html(/.*)?'
   sudo restorecon -Rv /srv/lab333/html
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html
   ```

   ```
   Relabeled /srv/lab333/html from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
   Relabeled /srv/lab333/html/index.html from ... to unconfined_u:object_r:httpd_sys_content_t:s0
   200
   ```

7. Muestre que la regla ahora es persistente e inspeccione dónde quedó escrita:

   ```bash
   sudo semanage fcontext -l -C
   sudo cat /etc/selinux/targeted/contexts/files/file_contexts.local
   ```

   ```
   SELinux fcontext              type       Context

   /srv/lab333/html(/.*)?        all files  system_u:object_r:httpd_sys_content_t:s0

   # This file is auto-generated by libsemanage
   # Do not edit directly.
   /srv/lab333/html(/.*)?    system_u:object_r:httpd_sys_content_t:s0
   ```

8. Observe la diferencia entre `cp` y `mv` respecto de las etiquetas:

   ```bash
   cd /tmp && echo hi > t1 && ls -Z t1
   sudo cp t1 /srv/lab333/html/copied.html   && ls -Z /srv/lab333/html/copied.html
   sudo cp -a t1 /srv/lab333/html/copied2.html && ls -Z /srv/lab333/html/copied2.html
   sudo mv t1 /srv/lab333/html/moved.html    && ls -Z /srv/lab333/html/moved.html
   ```

   ```
   unconfined_u:object_r:user_tmp_t:s0 t1
   unconfined_u:object_r:httpd_sys_content_t:s0 /srv/lab333/html/copied.html
   unconfined_u:object_r:user_tmp_t:s0          /srv/lab333/html/copied2.html
   unconfined_u:object_r:user_tmp_t:s0          /srv/lab333/html/moved.html
   ```

9. Compare las herramientas de alcance total del sistema de archivos:

   ```bash
   sudo fixfiles -v check /srv/lab333        # report only
   sudo fixfiles -R httpd restore            # relabel every path owned by a package
   sudo setfiles -v /etc/selinux/targeted/contexts/files/file_contexts /srv/lab333
   ```

10. Aprenda el reetiquetado de emergencia que sobrevive a un sistema de archivos raíz sin etiquetar:

    ```bash
    sudo touch /.autorelabel     # then reboot; init relabels everything and reboots again
    sudo fixfiles -F onboot      # equivalent, -F also resets user and role fields
    ```

### Punto de control 3

- **Q3.1** — Nombre los cuatro campos de un contexto SELinux en orden. En la política `targeted`, ¿qué campo carga esencialmente todas las decisiones de enforcement, y para qué se usan mayormente los otros tres?
- **Q3.2** — El paso 4 arregló el sitio y el paso 5 lo rompió de nuevo con un comando que no cambió ninguna política. Explique el mecanismo, y enuncie la regla práctica sobre cuándo `chcon` es legítimo.
- **Q3.3** — En el paso 8, `cp` produjo una etiqueta distinta a la de `cp -a` y a la de `mv`. Explique cada uno de los tres resultados en términos de si se crea un inodo o simplemente se renombra.
- **Q3.4** — `restorecon`, `setfiles` y `fixfiles` reetiquetan todos. Distíngalos según *qué provee la especificación* y *sobre qué alcance operan*. ¿Cuál es la herramienta correcta para "un árbol de directorios para el que acabo de agregar una regla", y cuál para "todo el sistema después de que SELinux estuvo deshabilitado durante un mes"?
- **Q3.5** — Agrega una regla fcontext pero olvida `restorecon`. ¿Cambia el comportamiento del sistema en ejecución? ¿Cambia después de un reinicio? Explique.
- **Q3.6** — `semanage fcontext -a -e /srv/lab333/html /var/www/html` hace algo distinto de `-t`. ¿Qué, y cuándo lo preferiría?

---

## Ejercicio 4 — Type Enforcement, dominios y transiciones

### Pasos

1. Obtenga el tamaño y la forma de la política cargada:

   ```bash
   seinfo
   ```

   ```
   Statistics for policy file: /sys/fs/selinux/policy
   Policy Version:             33 (MLS enabled)
   Target Policy:              selinux
   Handle unknown classes:     allow

     Classes:           135    Permissions:       326
     Sensitivities:       1    Categories:       1024
     Types:            5089    Attributes:        253
     Users:               8    Roles:             14
     Booleans:          326    Cond. Expr.:      371
     Allow:          113480    Neverallow:         0
     Type_trans:      27204    Type_change:       232
   ```

2. Inspeccione un tipo de dominio y los atributos a través de los cuales hereda privilegios:

   ```bash
   seinfo -t httpd_t -x | head -n 20
   seinfo -r system_r -x | head -n 5
   ```

3. Pregunte *por qué* Apache puede leer su contenido — la regla allow concreta:

   ```bash
   sesearch -A -s httpd_t -t httpd_sys_content_t -c file -p read
   ```

   ```
   allow httpd_t httpd_sys_content_t:file { getattr ioctl lock map open read };
   ```

4. Confirme lo inverso: no existe ninguna regla para `var_t`, que es la razón por la que falló el Ejercicio 1:

   ```bash
   sesearch -A -s httpd_t -t var_t -c file -p read
   echo "matches: $?"
   ```

5. Encuentre la transición de dominio automática que convierte a `systemd` en un servidor web confinado:

   ```bash
   sesearch -T -s init_t -t httpd_exec_t -c process
   ls -Z /usr/sbin/httpd
   ```

   ```
   type_transition init_t httpd_exec_t:process httpd_t;
   system_u:object_r:httpd_exec_t:s0 /usr/sbin/httpd
   ```

6. Verifique que existen las tres reglas que requiere una transición:

   ```bash
   sesearch -A -s init_t -t httpd_exec_t -c file -p execute      # source may execute the entrypoint
   sesearch -A -s init_t -t httpd_t     -c process -p transition # source may transition to target domain
   sesearch -A -s httpd_t -t httpd_exec_t -c file -p entrypoint  # target domain may be entered via it
   ```

7. Fuerce un contexto manualmente y observe qué permite la política:

   ```bash
   id -Z
   runcon -t httpd_t id -Z
   runcon -u system_u -r system_r -t httpd_t /usr/bin/cat /srv/lab333/html/index.html
   ```

   ```
   unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
   unconfined_u:unconfined_r:httpd_t:s0-s0:c0.c1023
   <h1>333.2 MAC lab</h1>
   ```

8. Pruebe la herramienta de cambio de rol (política targeted, usuario unconfined):

   ```bash
   newrole -r sysadm_r -t sysadm_t
   ```

   ```
   newrole: failure forking: Operation not permitted
   ```

   (En una política donde su usuario SELinux está autorizado para `sysadm_r`, `newrole` lo reautentica y lanza una nueva shell con el rol solicitado.)

### Punto de control 4

- **Q4.1** — Defina *dominio*, *tipo* y *entrypoint*, y enuncie la relación entre un dominio y un tipo en el modelo de datos de SELinux.
- **Q4.2** — Una transición de dominio requiere tres reglas allow separadas. Nombre las tres y explique qué ataque previene cada una de forma independiente si falta.
- **Q4.3** — ¿Por qué `runcon -t httpd_t` tiene éxito para una shell unconfined en el paso 7 mientras `newrole` falla en el paso 8? ¿Cuál es la diferencia esencial entre lo que cambia cada uno de los dos comandos?
- **Q4.4** — Explique cómo se componen RBAC y TE en SELinux: cuál de los dos deniega un acceso, y qué papel juega realmente el campo de rol.
- **Q4.5** — `sesearch` informó una regla allow con origen `httpd_t`, pero `seinfo -t httpd_t -x` mostró que el tipo pertenece a muchos atributos. ¿Por qué `sesearch -A` puede devolver reglas que nunca fueron escritas literalmente con `httpd_t` a la izquierda, y qué opción restringe la salida a las que sí lo fueron?
- **Q4.6** — Un binario se copia de `/usr/sbin/httpd` a `/usr/local/bin/httpd` y systemd lo lanza. ¿Qué contexto obtiene el proceso, y por qué esto es una *escalada* de privilegios desde el punto de vista de la política aunque nada haya cambiado en ella?

---

## Ejercicio 5 — Booleans: política que puede cambiar sin escribir política

### Pasos

1. Provoque una denegación de red. Agregue una directiva de proxy y un listener:

   ```bash
   sudo tee -a /etc/httpd/conf.d/lab333.conf >/dev/null <<'EOF'
   ProxyPass        /up/ http://127.0.0.1:9999/
   ProxyPassReverse /up/ http://127.0.0.1:9999/
   EOF
   sudo systemctl restart httpd
   (printf 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nup\n'; sleep 30) | nc -l 9999 &
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/up/
   ```

   ```
   503
   ```

2. Lea la denegación:

   ```bash
   sudo ausearch -m AVC -ts recent | tail -n 6
   ```

   ```
   type=AVC msg=audit(1756030411.883:498): avc:  denied  { name_connect } for  pid=1902
     comm="httpd" dest=9999 scontext=system_u:system_r:httpd_t:s0
     tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket permissive=0
   ```

   > Confirme el tipo del puerto de destino en *su* política en lugar de confiar en la transcripción: `sudo semanage port -l | grep -w 9999`.

3. Encuentre el boolean que lo gobierna, y lea su descripción:

   ```bash
   sudo semanage boolean -l | grep httpd_can_network
   getsebool -a | grep httpd_can_network_connect
   ```

   ```
   httpd_can_network_connect      (off  ,  off)  Allow httpd to can network connect
   httpd_can_network_connect_db   (off  ,  off)  Allow httpd to can network connect db
   httpd_can_network_connect off
   ```

4. Confirme que el boolean realmente es lo que controla la regla:

   ```bash
   sesearch -A -b httpd_can_network_connect -s httpd_t -c tcp_socket -p name_connect
   ```

   ```
   allow httpd_t port_type:tcp_socket { name_connect recv_msg send_msg }; [ httpd_can_network_connect ]
   ```

5. Cámbielo de forma no persistente, pruebe, y luego cámbielo de forma persistente:

   ```bash
   sudo setsebool httpd_can_network_connect on
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost/up/
   sudo semanage boolean -l -C
   ```

   ```
   200
   SELinux boolean          State  Default  Description
   httpd_can_network_connect (on ,  off)  Allow httpd to can network connect
   ```

   ```bash
   sudo setsebool -P httpd_can_network_connect on
   sudo semanage boolean -l -C
   ```

   ```
   httpd_can_network_connect (on ,   on)  Allow httpd to can network connect
   ```

6. Compare con la herramienta que solo alterna y con la interfaz cruda del kernel:

   ```bash
   sudo togglesebool httpd_can_network_connect
   getsebool httpd_can_network_connect
   cat /sys/fs/selinux/booleans/httpd_can_network_connect
   sudo setsebool -P httpd_can_network_connect on
   ```

   ```
   httpd_can_network_connect => off
   httpd_can_network_connect off
   0 1
   ```

7. Exporte y reimporte sus personalizaciones locales — la forma de moverlas entre hosts:

   ```bash
   sudo semanage export -f /tmp/lab333-local.mod
   cat /tmp/lab333-local.mod
   # on another host:  sudo semanage import -f /tmp/lab333-local.mod
   ```

   ```
   boolean -m -1 httpd_can_network_connect
   fcontext -a -f a -t httpd_sys_content_t -r 's0' '/srv/lab333/html(/.*)?'
   ```

### Punto de control 5

- **Q5.1** — `semanage boolean -l` muestra dos estados por boolean. ¿Cuáles son, y qué le dice el par `(on , off)` sobre cómo se comportará esta máquina después de un reinicio?
- **Q5.2** — Distinga `setsebool`, `setsebool -P` y `togglesebool` por persistencia y por si requieren que usted conozca el valor actual.
- **Q5.3** — El paso 6 mostró `0 1` en `/sys/fs/selinux/booleans/…`. Interprete ambos números.
- **Q5.4** — Tanto un boolean como un módulo `allow` personalizado pueden hacer desaparecer una denegación. Dé dos razones concretas para preferir el boolean cuando existe uno.
- **Q5.5** — `httpd_can_network_connect` permite conexiones a `port_type`, un atributo que cubre esencialmente todos los puertos etiquetados. ¿Cuál es el costo de seguridad de habilitarlo comparado con etiquetar un puerto específico como `http_port_t` (Ejercicio 6)?

---

## Ejercicio 6 — `semanage`: puertos, logins, usuarios y el almacén local

### Pasos

1. Mueva Apache a un puerto no estándar y observe cómo falla al arrancar:

   ```bash
   sudo sed -i 's/^Listen 80$/Listen 8088/' /etc/httpd/conf/httpd.conf
   sudo systemctl restart httpd; echo "exit: $?"
   sudo systemctl status httpd --no-pager -l | tail -n 8
   ```

   ```
   exit: 1
   httpd[2044]: (13)Permission denied: AH00072: make_sock: could not bind to address [::]:8088
   httpd[2044]: no listening sockets available, shutting down
   ```

2. Confirme que es MAC, y no un conflicto de puertos ni un problema de capabilities:

   ```bash
   sudo ss -ltnp | grep 8088 ; echo "in use: $?"
   sudo ausearch -m AVC -ts recent | tail -n 5
   ```

   ```
   in use: 1
   type=AVC msg=audit(1756030880.702:531): avc:  denied  { name_bind } for  pid=2044
     comm="httpd" src=8088 scontext=system_u:system_r:httpd_t:s0
     tcontext=system_u:object_r:unreserved_port_t:s0 tclass=tcp_socket permissive=0
   ```

3. Inspeccione la base de datos de etiquetas de puertos y la regla de política que hay detrás:

   ```bash
   sudo semanage port -l | grep -w http_port_t
   seinfo --portcon=8088
   ```

   ```
   http_port_t   tcp   80, 81, 443, 488, 8008, 8009, 8443, 9000
   portcon tcp 8088 system_u:object_r:unreserved_port_t:s0
   ```

4. Etiquete el puerto y reinicie:

   ```bash
   sudo semanage port -a -t http_port_t -p tcp 8088
   sudo semanage port -l -C
   sudo systemctl restart httpd; echo "exit: $?"
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8088/index.html
   ```

   ```
   SELinux Port Type   Proto   Port Number
   http_port_t         tcp     8088
   exit: 0
   200
   ```

5. Observe la diferencia entre agregar y modificar:

   ```bash
   sudo semanage port -a -t http_port_t -p tcp 80
   ```

   ```
   ValueError: Port tcp/80 already defined
   ```

   ```bash
   sudo semanage port -m -t http_port_t -p tcp 9000   # -m modifies an existing definition
   ```

6. Explore el lado de usuarios confinados de `semanage`:

   ```bash
   sudo semanage user -l
   sudo semanage login -l
   ```

   ```
   SELinux User  Labeling Prefix  MLS/MCS Level  MLS/MCS Range        SELinux Roles
   guest_u       user             s0             s0                   guest_r
   staff_u       user             s0             s0-s0:c0.c1023       staff_r sysadm_r system_r unconfined_r
   sysadm_u      user             s0             s0-s0:c0.c1023       sysadm_r
   unconfined_u  user             s0             s0-s0:c0.c1023       system_r unconfined_r
   user_u        user             s0             s0                   user_r
   xguest_u      user             s0             s0                   xguest_r

   Login Name   SELinux User   MLS/MCS Range     Service
   __default__  unconfined_u   s0-s0:c0.c1023    *
   root         unconfined_u   s0-s0:c0.c1023    *
   ```

7. Confine una cuenta Linux real y observe el efecto:

   ```bash
   sudo useradd -m kiosk && echo 'kiosk:Lab333pass!' | sudo chpasswd
   sudo semanage login -a -s user_u kiosk
   sudo semanage login -l | grep kiosk
   ```

   ```
   kiosk        user_u         s0                *
   ```

   Inicie sesión como `kiosk` en una consola de texto (no vía `su`, que no vuelve a ejecutar la asignación de contexto de PAM de la misma manera) y verifique:

   ```bash
   id -Z
   sudo -i
   ```

   ```
   user_u:user_r:user_t:s0
   sudo: PERM_ROOT: setresuid(0, -1, 0): Operation not permitted
   ```

8. Limpieza:

   ```bash
   sudo semanage login -d kiosk
   sudo userdel -r kiosk
   ```

### Punto de control 6

- **Q6.1** — Apache corre como root al momento del bind y por lo tanto posee `CAP_NET_BIND_SERVICE`. Explique por qué aun así no pudo hacer bind en 8088, y qué dice eso sobre la relación entre capabilities y MAC.
- **Q6.2** — Dé la invocación exacta de `semanage` para permitir que un servicio etiquetado `mysqld_t` escuche en TCP 3307, y explique cómo verificaría primero si el puerto ya está definido.
- **Q6.3** — ¿Cuál es la diferencia práctica entre `semanage port -a` y `semanage port -m`, y qué error le indica que necesitaba el otro?
- **Q6.4** — Explique el mapeo de tres capas: usuario Linux → usuario SELinux → rol → dominio. ¿Qué subcomando de `semanage` configura cada salto?
- **Q6.5** — En el paso 7, `sudo -i` falló para `kiosk` incluso si `kiosk` pudiera estar en `wheel`. ¿Qué mecanismo lo bloqueó, y en qué se diferencia esto de quitar a `kiosk` de `wheel`?
- **Q6.6** — `semanage export` produjo un archivo corto. ¿Qué clase de configuración captura, y qué *no* captura deliberadamente? ¿Por qué importa eso al reconstruir un host?

---

## Ejercicio 7 — Leer denegaciones: `audit2why`, `audit2allow`, `dontaudit`, dominios permissive

### Pasos

1. Fabrique una denegación nueva que un boolean no pueda arreglar:

   ```bash
   sudo mkdir -p /srv/lab333/writable
   sudo semanage fcontext -a -t httpd_sys_content_t '/srv/lab333/writable(/.*)?'
   sudo restorecon -Rv /srv/lab333/writable
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/touch /srv/lab333/writable/upload.tmp
   ```

   ```
   /usr/bin/touch: cannot touch '/srv/lab333/writable/upload.tmp': Permission denied
   ```

2. Busque en el log de auditoría de varias maneras — conozca las tres:

   ```bash
   sudo ausearch -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts recent -i
   sudo journalctl -t setroubleshoot --since '-10 min'
   sudo grep -c 'avc:  denied' /var/log/audit/audit.log
   ```

3. Obtenga una explicación en lenguaje humano con `setroubleshoot`:

   ```bash
   sudo journalctl -t setroubleshoot --since '-10 min' | tail -n 3
   sudo sealert -l '*' | head -n 30
   ```

   ```
   SELinux is preventing touch from write access on the directory writable.
   *****  Plugin catchall_labels (83.8 confidence) suggests  *******************
   If you want to allow touch to have write access on the writable directory
   Then you need to change the label on writable
   Do
   # semanage fcontext -a -t FILE_TYPE 'writable'
   ```

4. Pregunte *por qué* fue denegado, en términos de política:

   ```bash
   sudo ausearch -m AVC -ts recent | audit2why
   ```

   ```
   type=AVC msg=audit(1756031204.551:602): avc:  denied  { write } for  pid=2210
     comm="touch" name="writable" dev="dm-0" ino=17825923
     scontext=system_u:system_r:httpd_t:s0
     tcontext=system_u:object_r:httpd_sys_content_t:s0
     tclass=dir permissive=0

   	Was caused by:
   	Missing type enforcement (TE) allow rule.

   	You can use audit2allow to generate a loadable module to allow this access.
   ```

5. Vea cómo se vería una regla **generada** — no la instale todavía:

   ```bash
   sudo ausearch -m AVC -ts recent | audit2allow
   ```

   ```
   #============= httpd_t ==============
   allow httpd_t httpd_sys_content_t:dir { add_name write };
   allow httpd_t httpd_sys_content_t:file { create write };
   ```

6. Reconozca en cambio la respuesta correcta: la política ya trae un *tipo* para contenido web escribible:

   ```bash
   sudo semanage fcontext -m -t httpd_sys_rw_content_t '/srv/lab333/writable(/.*)?'
   sudo restorecon -Rv /srv/lab333/writable
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/touch /srv/lab333/writable/upload.tmp && echo OK
   ```

   ```
   Relabeled /srv/lab333/writable from ...httpd_sys_content_t:s0 to ...httpd_sys_rw_content_t:s0
   OK
   ```

7. Ahora practique el flujo de trabajo de módulos con una denegación que genuinamente no tiene respuesta en la política:

   ```bash
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/cat /var/log/dnf5.log 2>/dev/null
   sudo ausearch -m AVC -ts recent -c cat | audit2allow -M lab333-readlog
   cat lab333-readlog.te
   ```

   ```
   ******************** IMPORTANT ***********************
   To make this policy package active, execute:

   semodule -i lab333-readlog.pp

   module lab333-readlog 1.0;

   require {
   	type httpd_t;
   	type var_log_t;
   	class file { getattr open read };
   }

   #============= httpd_t ==============
   allow httpd_t var_log_t:file { getattr open read };
   ```

8. Instale, verifique, y luego quite:

   ```bash
   sudo semodule -i lab333-readlog.pp
   sudo semodule --list=full | grep lab333
   sudo -u apache runcon -u system_u -r system_r -t httpd_t \
        /usr/bin/head -1 /var/log/dnf5.log && echo ALLOWED
   sudo semodule -r lab333-readlog
   ```

   ```
   400 lab333-readlog  pp
   2026-08-24T09:11:04+0000 INFO --- logging initialized ---
   ALLOWED
   ```

9. Use un **dominio permissive** — la manera correcta de recolectar un conjunto completo de reglas sin deshabilitar el enforcement globalmente:

   ```bash
   sudo semanage permissive -a httpd_t
   sudo semanage permissive -l
   getenforce
   # exercise the application fully here; every would-be denial is logged with permissive=1
   sudo ausearch -m AVC -ts recent | grep -c 'permissive=1'
   sudo semanage permissive -d httpd_t
   ```

   ```
   Builtin Permissive Types

   Customized Permissive Types

   httpd_t
   Enforcing
   ```

10. Revele las denegaciones que la política está ocultando deliberadamente:

    ```bash
    sesearch --dontaudit -s httpd_t | head -n 5
    sudo semodule -DB          # rebuild policy with all dontaudit rules disabled
    # reproduce the problem, collect AVCs
    sudo semodule -B           # restore dontaudit rules
    ```

### Punto de control 7

- **Q7.1** — Explique la división del trabajo entre `ausearch`, `audit2why` y `audit2allow`. ¿Cuál requiere una política cargada para responder su pregunta, y por qué?
- **Q7.2** — En el paso 4, `audit2why` dijo "Missing type enforcement (TE) allow rule." Enumere al menos otras tres causas que `audit2why` puede informar, y explique por qué en cada caso la salida de `audit2allow` sería inútil o dañina.
- **Q7.3** — El paso 5 generó una regla allow sintácticamente correcta que usted deliberadamente no instaló, y el paso 6 resolvió el problema con un reetiquetado. Formule la regla general para elegir entre "cambiar la etiqueta" y "agregar una regla".
- **Q7.4** — `semodule --list=full` mostró `400 lab333-readlog pp`. ¿Qué es 400, qué prioridad usan los módulos de la distribución, y cómo instalaría un módulo que sobrescriba uno provisto por ella?
- **Q7.5** — Compare `setenforce 0` y `semanage permissive -a httpd_t` como técnicas de diagnóstico. Dé dos ventajas distintas de la segunda.
- **Q7.6** — ¿Qué es una regla `dontaudit`, por qué la política incluye miles de ellas, y describa el escenario exacto en el que `semodule -DB` es la única forma de avanzar. ¿Qué debe recordar después?
- **Q7.7** — El runbook de un ingeniero junior dice: "si la app se rompe, ejecutá `ausearch -m AVC -ts today | audit2allow -M fixit && semodule -i fixit.pp`." Dé tres razones específicas por las que esto es peligroso, al menos una de las cuales sea sobre la *ventana temporal*.

---

## Ejercicio 8 — Escribir política a mano: fuente TE y CIL

### Pasos

1. Confirme que el entorno de desarrollo está presente:

   ```bash
   rpm -q selinux-policy-devel
   ls /usr/share/selinux/devel/Makefile /usr/share/selinux/devel/include/ | head -n 4
   ```

2. Escriba un módulo en fuente TE. Este crea un tipo privado para un directorio de spool, lo etiqueta mediante un archivo `fc`, y le otorga a Apache exactamente el acceso que necesita:

   ```bash
   mkdir -p ~/lab333-policy && cd ~/lab333-policy
   cat > lab333spool.te <<'EOF'
   policy_module(lab333spool, 1.0.0)

   require {
       type httpd_t;
       type unconfined_t;
       role unconfined_r;
   }

   type lab333_spool_t;
   files_type(lab333_spool_t)

   # Apache may read, write and create inside the spool
   allow httpd_t lab333_spool_t:dir  { getattr search open read write add_name remove_name };
   allow httpd_t lab333_spool_t:file { getattr open read write create unlink append };

   # Administrators may manage it interactively
   allow unconfined_t lab333_spool_t:dir  { relabelfrom relabelto };
   allow unconfined_t lab333_spool_t:file { relabelfrom relabelto };
   EOF

   cat > lab333spool.fc <<'EOF'
   /srv/lab333/spool(/.*)?    gen_context(system_u:object_r:lab333_spool_t,s0)
   EOF
   ```

3. Compile con el makefile de la reference policy:

   ```bash
   make -f /usr/share/selinux/devel/Makefile lab333spool.pp
   ls -l lab333spool.pp
   ```

   ```
   Compiling targeted lab333spool module
   Creating targeted lab333spool.pp policy package
   rm tmp/lab333spool.mod tmp/lab333spool.mod.fc
   -rw-r--r--. 1 root root 1284 Aug 24 11:20 lab333spool.pp
   ```

4. Compile lo mismo por la vía de bajo nivel, para saber qué hace el makefile:

   ```bash
   checkmodule -M -m -o lab333spool.mod lab333spool.te
   semodule_package -o lab333spool-manual.pp -m lab333spool.mod -f lab333spool.fc
   ```

   ```
   checkmodule:  loading policy configuration from lab333spool.te
   checkmodule:  policy configuration loaded
   checkmodule:  writing binary representation (version 19) to lab333spool.mod
   ```

5. Instale y verifique que el nuevo tipo realmente existe en la política en ejecución:

   ```bash
   sudo semodule -i lab333spool.pp
   seinfo -t lab333_spool_t -x
   sudo mkdir -p /srv/lab333/spool && sudo restorecon -Rv /srv/lab333/spool
   ls -Zd /srv/lab333/spool
   ```

   ```
   Types: 1
      type lab333_spool_t;
         file_type
         non_security_file_type
   Relabeled /srv/lab333/spool from unconfined_u:object_r:var_t:s0 to system_u:object_r:lab333_spool_t:s0
   system_u:object_r:lab333_spool_t:s0 /srv/lab333/spool
   ```

6. Haga lo mismo con CIL, el lenguaje al que `semodule` compila todo:

   ```bash
   cat > lab333cil.cil <<'EOF'
   (allow httpd_t lab333_spool_t (dir (rmdir)))
   EOF
   sudo semodule -X 300 -i lab333cil.cil
   sudo semodule --list=full | grep lab333
   ```

   ```
   300 lab333cil       cil
   400 lab333spool     pp
   ```

7. Vuelque un módulo provisto por la distribución como CIL para leer fuente de política real:

   ```bash
   sudo semodule -c -E apache 2>/dev/null || \
     sudo /usr/libexec/selinux/hll/pp /var/lib/selinux/targeted/active/modules/100/apache/hll \
       > /tmp/apache.cil
   head -n 20 /tmp/apache.cil
   ```

8. Limpieza:

   ```bash
   sudo semodule -X 300 -r lab333cil
   sudo semodule -r lab333spool
   ```

### Punto de control 8

- **Q8.1** — Trace la cadena de herramientas: `.te` + `.fc` → `.mod` → `.pp` → política cargada. Nombre la herramienta responsable de cada flecha y qué artefacto produce cada una.
- **Q8.2** — ¿Para qué sirve el bloque `require { }`, y qué pasa si referencia `httpd_t` sin él?
- **Q8.3** — ¿Por qué el módulo necesitó un archivo `.fc` *y* una ejecución de `restorecon`? ¿Qué habría pasado si instalaba el módulo y creaba el directorio pero nunca reetiquetaba?
- **Q8.4** — El paso 6 instaló un archivo `.cil` directamente mientras que el paso 5 instaló un `.pp` compilado. ¿Cuál es el rol de CIL en el espacio de usuario moderno de SELinux, y qué implica eso para el formato `.pp` de aquí en adelante?
- **Q8.5** — El módulo define un tipo completamente nuevo en lugar de reutilizar `httpd_sys_rw_content_t`. Enuncie un argumento sólido a favor de cada opción en un despliegue de producción.
- **Q8.6** — ¿Por qué debe aplicarse `files_type()` (o una asignación de atributo equivalente) a un tipo de archivo nuevo? ¿Qué se rompe si declara un `type lab333_spool_t;` pelado y nada más?

---

## Ejercicio 9 — MLS/MCS: la segunda dimensión

### Pasos

1. Confirme que la política targeted tiene la maquinaria de MCS habilitada:

   ```bash
   sestatus | grep MLS
   seinfo | grep -E 'Sensitivities|Categories'
   id -Z
   ```

   ```
   Policy MLS status:              enabled
     Sensitivities:       1    Categories:       1024
   unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
   ```

2. Cree dos archivos y ponga uno en una categoría:

   ```bash
   sudo mkdir -p /srv/lab333/mcs
   echo 'public data'  | sudo tee /srv/lab333/mcs/open.txt   >/dev/null
   echo 'tenant-A data'| sudo tee /srv/lab333/mcs/tenantA.txt >/dev/null
   sudo chcat +c100 /srv/lab333/mcs/tenantA.txt
   ls -Z /srv/lab333/mcs/
   ```

   ```
   unconfined_u:object_r:var_t:s0       open.txt
   unconfined_u:object_r:var_t:s0:c100  tenantA.txt
   ```

3. Lea ambos como su usuario unconfined, cuyo rango es `s0-s0:c0.c1023`:

   ```bash
   sudo cat /srv/lab333/mcs/tenantA.txt
   ```

   ```
   tenant-A data
   ```

4. Ahora léalos desde un proceso fijado a un nivel *inferior*:

   ```bash
   sudo runcon -l s0 /usr/bin/cat /srv/lab333/mcs/open.txt
   sudo runcon -l s0 /usr/bin/cat /srv/lab333/mcs/tenantA.txt
   ```

   ```
   public data
   /usr/bin/cat: /srv/lab333/mcs/tenantA.txt: Permission denied
   ```

5. Otorgue exactamente la única categoría necesaria:

   ```bash
   sudo runcon -l s0:c100 /usr/bin/cat /srv/lab333/mcs/tenantA.txt
   ```

   ```
   tenant-A data
   ```

6. Observe cómo se ve la denegación del paso 4, y qué dice `audit2why` al respecto:

   ```bash
   sudo ausearch -m AVC -ts recent -c cat | tail -n 5
   sudo ausearch -m AVC -ts recent -c cat | audit2why | tail -n 6
   ```

   ```
   type=AVC msg=audit(1756032980.221:701): avc:  denied  { read } for pid=2551 comm="cat"
     name="tenantA.txt" scontext=unconfined_u:unconfined_r:unconfined_t:s0
     tcontext=unconfined_u:object_r:var_t:s0:c100 tclass=file permissive=0

   	Was caused by:
   	Constraint violation.

   	Check policy/constraints.
   	Typically, you just need to add a type attribute to the domain
   	or the type to satisfy the constraint.
   ```

7. Vea el mismo mecanismo haciendo trabajo real — aislamiento de contenedores:

   ```bash
   sudo dnf install -y podman
   sudo podman run -d --name c1 registry.access.redhat.com/ubi9/ubi sleep 300
   sudo podman run -d --name c2 registry.access.redhat.com/ubi9/ubi sleep 300
   ps -eZ | grep -E 'sleep 300'
   ```

   ```
   system_u:system_r:container_t:s0:c214,c806   3011 ? 00:00:00 sleep
   system_u:system_r:container_t:s0:c455,c1002  3062 ? 00:00:00 sleep
   ```

8. Inspeccione la etiqueta de un volumen montado con bind:

   ```bash
   sudo mkdir -p /srv/lab333/vol && echo hi | sudo tee /srv/lab333/vol/f >/dev/null
   sudo podman run --rm -v /srv/lab333/vol:/data:Z ubi9/ubi cat /data/f
   ls -Zd /srv/lab333/vol
   ```

   ```
   hi
   system_u:object_r:container_file_t:s0:c214,c806 /srv/lab333/vol
   ```

9. Limpieza:

   ```bash
   sudo podman rm -f c1 c2
   sudo chcat -d +c100 /srv/lab333/mcs/tenantA.txt 2>/dev/null || \
     sudo chcon -l s0 /srv/lab333/mcs/tenantA.txt
   ```

### Punto de control 9

- **Q9.1** — Distinga MLS de MCS. ¿Cuántas sensibilidades define la política `targeted`, y qué le dice eso sobre cuál de las dos está implementando realmente?
- **Q9.2** — En el paso 4, el mismo archivo era legible por un proceso y no por otro, con tipo idéntico en ambos lados. ¿Qué parte de la política lo denegó, y por qué eso es arquitectónicamente distinto de una regla `allow` faltante?
- **Q9.3** — `audit2why` informó "Constraint violation" y sugirió agregar un atributo de tipo. Explique por qué ejecutar `audit2allow -M` aquí produciría un módulo que se instala sin problemas y no cambia nada.
- **Q9.4** — Un proceso tiene el rango `s0-s0:c0.c1023`. Explique la "dominancia" y diga cuáles de estos puede leer: `s0`, `s0:c5`, `s0:c1024`, `s1:c5`.
- **Q9.5** — Dos contenedores recibieron pares de categorías distintos. Explique cómo esto logra aislamiento entre inquilinos usando una política en la que ambos procesos tienen el *mismo* tipo, y qué ocurre si lanza un contenedor con `--security-opt label=disable`.
- **Q9.6** — ¿Qué hace el sufijo `:Z` en un bind mount de podman, y cuál es la diferencia con `:z`? Nombre una situación en la que `:Z` sobre el directorio equivocado es destructivo.

---

## Ejercicio 10 — AppArmor: MAC basado en rutas en Debian/Ubuntu

Ejecute este bloque en `mac-deb`.

### Pasos

1. Establezca la línea de base:

   ```bash
   sudo aa-status
   cat /sys/kernel/security/lsm
   cat /sys/module/apparmor/parameters/enabled
   ```

   ```
   apparmor module is loaded.
   58 profiles are loaded.
   38 profiles are in enforce mode.
      /usr/bin/man
      /usr/lib/NetworkManager/nm-dhcp-client.action
      ...
   20 profiles are in complain mode.
   0 profiles are in kill mode.
   0 profiles are in unconfined mode.
   4 processes have profiles defined.
   4 processes are in enforce mode.
   0 processes are in complain mode.
   0 processes are unconfined but have a profile defined.

   lockdown,capability,landlock,yama,apparmor,bpf,ipe
   Y
   ```

2. Identifique procesos que *deberían* estar confinados y no lo están:

   ```bash
   sudo aa-unconfined | head
   ```

3. Cree el programa que va a confinar:

   ```bash
   sudo mkdir -p /srv/lab333/public /srv/lab333/private
   echo 'public'  | sudo tee /srv/lab333/public/ok.txt   >/dev/null
   echo 'secrets' | sudo tee /srv/lab333/private/key.txt >/dev/null

   sudo tee /usr/local/bin/lab333-reader >/dev/null <<'EOF'
   #!/bin/bash
   for f in "$@"; do
       printf '%s: ' "$f"
       cat -- "$f" 2>&1
   done
   EOF
   sudo chmod 0755 /usr/local/bin/lab333-reader
   /usr/local/bin/lab333-reader /srv/lab333/public/ok.txt /srv/lab333/private/key.txt
   ```

   ```
   /srv/lab333/public/ok.txt: public
   /srv/lab333/private/key.txt: secrets
   ```

4. Genere un perfil esqueleto y léalo:

   ```bash
   sudo aa-autodep /usr/local/bin/lab333-reader
   sudo cat /etc/apparmor.d/usr.local.bin.lab333-reader
   ```

   ```
   # Last Modified: Mon Aug 24 12:04:11 2026
   abi <abi/4.0>,

   include <tunables/global>

   /usr/local/bin/lab333-reader {
     include <abstractions/base>
     include <abstractions/bash>

     /usr/local/bin/lab333-reader r,
   }
   ```

5. Escriba el perfil real a mano:

   ```bash
   sudo tee /etc/apparmor.d/usr.local.bin.lab333-reader >/dev/null <<'EOF'
   abi <abi/4.0>,
   include <tunables/global>

   profile lab333-reader /usr/local/bin/lab333-reader {
     include <abstractions/base>
     include <abstractions/bash>

     /usr/local/bin/lab333-reader   r,
     /usr/bin/bash                  ix,
     /usr/bin/cat                   ix,

     /srv/lab333/public/**          r,
     deny /srv/lab333/private/**    rwklx,

     owner @{HOME}/lab333/**        rw,

     capability,
     deny capability sys_admin,

     network inet stream,
     deny network inet dgram,
   }
   EOF
   ```

   > En Ubuntu 22.04 / Debian 12 use `abi <abi/3.0>,` — verifique con `ls /etc/apparmor.d/abi/`.

6. Verifique la sintaxis antes de cargar, y luego cargue en modo complain:

   ```bash
   sudo apparmor_parser -Q /etc/apparmor.d/usr.local.bin.lab333-reader && echo "syntax OK"
   sudo apparmor_parser -r /etc/apparmor.d/usr.local.bin.lab333-reader
   sudo aa-complain /etc/apparmor.d/usr.local.bin.lab333-reader
   sudo aa-status | grep -A2 'complain mode' | grep lab333
   ```

   ```
   syntax OK
   Setting /etc/apparmor.d/usr.local.bin.lab333-reader to complain mode.
      lab333-reader
   ```

7. Ejercítelo y lea los registros de auditoría:

   ```bash
   /usr/local/bin/lab333-reader /srv/lab333/public/ok.txt /srv/lab333/private/key.txt
   sudo ausearch -m AVC -ts recent | grep apparmor | tail -n 3
   ```

   ```
   /srv/lab333/public/ok.txt: public
   /srv/lab333/private/key.txt: secrets

   type=AVC msg=audit(1756034041.117:822): apparmor="ALLOWED" operation="open"
     class="file" profile="lab333-reader" name="/srv/lab333/private/key.txt"
     pid=4417 comm="cat" requested_mask="r" denied_mask="r" fsuid=0 ouid=0
   ```

8. Cambie a enforce y repita:

   ```bash
   sudo aa-enforce /etc/apparmor.d/usr.local.bin.lab333-reader
   /usr/local/bin/lab333-reader /srv/lab333/public/ok.txt /srv/lab333/private/key.txt
   sudo ausearch -m AVC -ts recent | grep apparmor | tail -n 2
   ```

   ```
   Setting /etc/apparmor.d/usr.local.bin.lab333-reader to enforce mode.
   /srv/lab333/public/ok.txt: public
   /srv/lab333/private/key.txt: cat: /srv/lab333/private/key.txt: Permission denied

   type=AVC msg=audit(1756034102.556:830): apparmor="DENIED" operation="open"
     class="file" profile="lab333-reader" name="/srv/lab333/private/key.txt"
     pid=4462 comm="cat" requested_mask="r" denied_mask="r" fsuid=0 ouid=0
   ```

9. Confirme la etiqueta de confinamiento en un proceso vivo, y ejecute un comando arbitrario bajo un perfil:

   ```bash
   sudo aa-exec -p lab333-reader -- /bin/bash -c 'cat /proc/self/attr/current; cat /srv/lab333/private/key.txt'
   ```

   ```
   lab333-reader (enforce)
   cat: /srv/lab333/private/key.txt: Permission denied
   ```

10. Use el ciclo de refinamiento guiado por logs:

    ```bash
    sudo aa-logprof
    ```

    ```
    Reading log entries from /var/log/audit/audit.log.
    Updating AppArmor profiles in /etc/apparmor.d.

    Profile:  lab333-reader
    Path:     /etc/lab333.conf
    New Mode: owner r
    Severity: unknown

     [1 - #include <abstractions/lab333>]
      2 - owner /etc/lab333.conf r,
    (A)llow / [(D)eny] / (I)gnore / (G)lob / Glob with (E)xt / (N)ew / Audi(t) / (O)wner permissions off / Abo(r)t / (F)inish
    ```

11. Compare las formas de dejar de aplicar un perfil:

    ```bash
    sudo aa-disable /etc/apparmor.d/usr.local.bin.lab333-reader
    ls -l /etc/apparmor.d/disable/
    sudo apparmor_parser -R /etc/apparmor.d/usr.local.bin.lab333-reader   # unload only, not persistent
    sudo aa-enforce /etc/apparmor.d/usr.local.bin.lab333-reader           # re-enable
    ```

    ```
    Disabling /etc/apparmor.d/usr.local.bin.lab333-reader.
    lrwxrwxrwx 1 root root 44 Aug 24 12:31 usr.local.bin.lab333-reader -> /etc/apparmor.d/usr.local.bin.lab333-reader
    ```

12. Observe la restricción moderna de espacios de nombres de usuario que Ubuntu entrega como perfil de AppArmor:

    ```bash
    sysctl kernel.apparmor_restrict_unprivileged_userns
    unshare -Ur id 2>&1 | head -n 1
    ```

    ```
    kernel.apparmor_restrict_unprivileged_userns = 1
    unshare: unshare failed: Permission denied
    ```

### Punto de control 10

- **Q10.1** — Enuncie la diferencia arquitectónica más importante entre AppArmor y SELinux, y derive de ella dos consecuencias operativas prácticas (una ventaja de cada uno).
- **Q10.2** — En el paso 5, `/usr/bin/cat ix,` le dio a `cat` inherit-execute. Explique la diferencia entre `ix`, `Px`, `Cx` y `ux`, y diga cuál usaría para un helper que tiene su propio perfil.
- **Q10.3** — El perfil deniega `/srv/lab333/private/**`. Describa cómo un enlace duro podría, en principio, derrotar una regla basada en rutas, y qué hace AppArmor al respecto.
- **Q10.4** — Explique las tres formas de poner un perfil en modo complain, y cuál sobrevive a un `apparmor_parser -r`.
- **Q10.5** — Distinga `aa-disable`, `apparmor_parser -R`, y simplemente borrar el archivo de perfil, en términos de persistencia y de bajo qué corre el proceso después.
- **Q10.6** — `aa-genprof` y `aa-logprof` se solapan. ¿Qué agrega cada uno, y a qué flujo de trabajo pertenecen? ¿Por qué el modo complain es un prerrequisito para que ambos sean útiles?
- **Q10.7** — En el paso 7, el AVC dice `apparmor="ALLOWED"` y sin embargo `denied_mask="r"` está poblado. Reconcilie esos dos campos.
- **Q10.8** — Compare `abstractions/`, `tunables/` y `local/` bajo `/etc/apparmor.d/`. ¿Cuál debería contener sus agregados específicos del sitio a un perfil provisto por la distribución, y por qué?

---

## Ejercicio 11 — Smack, y elegir entre los tres

Normalmente Smack no es el LSM activo en RHEL ni en Ubuntu. Los pasos 1–2 corren en cualquier lado; los pasos 3–6 requieren un kernel arrancado con Smack como LSM mayor y están marcados como tales.

### Pasos

1. Determine qué LSM están activos y en qué orden:

   ```bash
   cat /sys/kernel/security/lsm
   ls /sys/kernel/security/
   sudo cat /proc/cmdline
   ```

   ```
   lockdown,capability,landlock,yama,selinux,bpf,ipe
   apparmor  evm  integrity  ipe  lockdown  lsm  selinux  tpm0
   BOOT_IMAGE=/vmlinuz-5.14.0-503.el9.x86_64 root=/dev/mapper/rl-root ro rhgb quiet
   ```

2. Lea el parámetro de arranque que seleccionaría Smack en su lugar:

   ```
   lsm=lockdown,capability,yama,smack
   ```

   Luego reconstruya el initramfs / actualice el gestor de arranque y reinicie. **Solo uno de SELinux, AppArmor y Smack puede ser el LSM mayor activo en un kernel estándar.**

3. *(Solo con kernel Smack.)* Confirme smackfs y la etiqueta actual:

   ```bash
   mount | grep smackfs
   ls /sys/fs/smackfs/
   cat /proc/self/attr/current
   ```

   ```
   smackfs on /sys/fs/smackfs type smackfs (rw,relatime)
   access  access2  ambient  change-rule  cipso  cipso2  direct  doi  ipv6host
   load  load2  logging  netlabel  onlycap  ptrace  relabel-self  revoke-subject
   syslog  unconfined
   _
   ```

4. *(Solo con kernel Smack.)* Etiquete un objeto e inspeccione el atributo extendido:

   ```bash
   sudo mkdir -p /srv/lab333/smack
   echo 'tenant data' | sudo tee /srv/lab333/smack/f >/dev/null
   sudo chsmack -a TenantA /srv/lab333/smack/f
   sudo chsmack /srv/lab333/smack/f
   getfattr -m . -d /srv/lab333/smack/f
   ```

   ```
   /srv/lab333/smack/f access="TenantA"
   # file: srv/lab333/smack/f
   security.SMACK64="TenantA"
   ```

5. *(Solo con kernel Smack.)* Cargue una regla de acceso y pruébela:

   ```bash
   echo -n 'WebApp TenantA r--' | sudo tee /sys/fs/smackfs/load2
   cat /sys/fs/smackfs/load2 | grep TenantA
   sudo smackload --help 2>/dev/null | head -n 3
   ```

   ```
   WebApp TenantA r--
   ```

6. *(Solo con kernel Smack.)* Observe los demás atributos y las etiquetas especiales:

   ```
   security.SMACK64          label of the object
   security.SMACK64EXEC      label a process takes when it executes this file
   security.SMACK64MMAP      label required to mmap this file
   security.SMACK64TRANSMUTE directory: new objects inherit the directory's label
   security.SMACK64IPIN      label for data received on this socket
   security.SMACK64IPOUT     label for data sent from this socket

   _  floor    ^  hat    *  star    ?  unlabelled/wildcard    @  web
   ```

7. Construya la comparación sobre la que lo van a evaluar:

   | | SELinux | AppArmor | Smack |
   |---|---|---|---|
   | Modelo | TE + RBAC + MLS/MCS, basado en etiquetas | Perfiles basados en rutas | Basado en etiquetas, simplificado |
   | Identidad del objeto | Atributo extendido en el inodo | Ruta del sistema de archivos al momento del open | Atributo extendido en el inodo |
   | Distros por defecto | RHEL/Fedora/CentOS, Android | Ubuntu/Debian/openSUSE | Tizen, AGL, embebidos/IoT |
   | Tamaño de la política | ~113k reglas allow provistas | Archivos de perfil por aplicación | Un puñado de reglas por par de etiquetas |
   | ¿Requiere reetiquetar el sistema de archivos? | Sí | No | Sí |
   | Modos | Enforcing / Permissive / Disabled (+ permissive por dominio) | Enforce / Complain / Kill / Unconfined (por perfil) | Solo enforcing |
   | Configuración clave | `/etc/selinux/` | `/etc/apparmor.d/` | `/sys/fs/smackfs/`, xattrs |
   | Herramientas de aprendizaje | `audit2allow`, `sealert` | `aa-genprof`, `aa-logprof` | ninguna comparable |

### Punto de control 11

- **Q11.1** — ¿Por qué solo uno de SELinux, AppArmor y Smack puede estar activo como LSM mayor, y cómo determina cuál está activo en una máquina que acaban de entregarle?
- **Q11.2** — Enuncie con sus palabras las siete reglas de acceso de Smack (el procedimiento de decisión ordenado que aplica el kernel). ¿Qué etiqueta deja a un *sujeto* sin poder, y cuál vuelve a un *objeto* universalmente accesible?
- **Q11.3** — ¿Qué logra `security.SMACK64TRANSMUTE` en un directorio, y cuál es el mecanismo de SELinux funcionalmente más análogo?
- **Q11.4** — Un cliente opera un dispositivo IoT con ~15 procesos y un rootfs de solo lectura. Argumente a favor de Smack sobre SELinux para esa plataforma, y diga qué es lo único que pierden.
- **Q11.5** — Debe confinar un único binario de terceros en un servidor Ubuntu, con un plazo de dos días y sin experiencia en escritura de políticas en el equipo. ¿Qué sistema MAC elige, y justifíquelo con dos propiedades de la tabla comparativa.
- **Q11.6** — Tanto SELinux como Smack exponen la etiqueta del proceso vía `/proc/self/attr/current`, y AppArmor usa el mismo archivo. ¿Qué le dice eso sobre cómo están integrados estos sistemas en el kernel?

---

## Solucionario

<details>
<summary><b>Clic para revelar todas las respuestas (Puntos de control 1–11)</b></summary>

### Punto de control 1

**A1.1** — El kernel evalúa las dos compuertas en secuencia: la verificación DAC tradicional (UID/GID, bits de modo, ACLs) corre **primero**, y solo si concede el acceso el kernel invoca el hook LSM, donde SELinux consulta la política cargada. En el paso 5, `cat` corrió en el dominio `unconfined_t`, al que la política targeted le permite leer `var_t`, así que ambas compuertas pasaron. En el paso 4 el lector era `httpd`, corriendo en `httpd_t`, y ninguna regla permite a `httpd_t` leer archivos `var_t` — DAC pasó, MAC denegó, `open()` devolvió `EACCES`, y Apache lo tradujo a un HTTP 403. Ambas compuertas deben conceder; cualquiera de las dos puede denegar.

**A1.2** —
- `scontext` — el contexto **origen**, es decir, la etiqueta del proceso que intenta el acceso (`system_u:system_r:httpd_t:s0`).
- `tcontext` — el contexto **destino**, la etiqueta del objeto al que se accede (`unconfined_u:object_r:var_t:s0`).
- `tclass` — la **clase de objeto** (`file`, `dir`, `tcp_socket`, `process`, …), que determina el vocabulario de permisos aplicable.
- `permissive=0` — la decisión fue **aplicada**; la syscall realmente falló. `permissive=1` significa que el acceso fue registrado pero permitido (modo permissive global o un dominio permissive).
La acción rechazada está entre llaves después de `denied`: `{ getattr }`.

**A1.3** — El campo de **usuario** SELinux de un objeto recién creado se hereda del proceso creador, no del UID de Linux. El login de `root` estaba mapeado al usuario SELinux `unconfined_u` (ver `semanage login -l`, `__default__` → `unconfined_u`), así que los archivos que crea reciben `unconfined_u`. `system_u` está reservado para objetos creados por procesos del sistema y para el valor por defecto en `file_contexts`; un `restorecon -F` posterior lo restablecería a `system_u`.

**A1.4** — Bajo DAC, el **dueño de un recurso decide** quién puede acceder, y esa decisión es discrecional e irrestricta (`chmod 777` se lo concede al mundo entero). Bajo MAC, decide una **política definida por el administrador, de alcance sistémico**, y ningún dueño de recurso — ni siquiera root — puede conceder en tiempo de ejecución un acceso que la política no permita. `chmod 777` solo ensancha la compuerta DAC; no escribe nada en la política, así que la compuerta MAC queda intacta. Cambiar MAC requiere cambiar etiquetas o política, lo que es a su vez una operación sujeta a control de acceso.

### Punto de control 2

**A2.1** —
- `getenforce` imprime exactamente una palabra — el **modo actual en tiempo de ejecución** (`Enforcing`/`Permissive`/`Disabled`).
- `selinuxenabled` no imprime nada y se comunica puramente por estado de salida: `0` si SELinux está habilitado, `1` si no. Es el único diseñado para scripting (`if selinuxenabled; then …; fi`), porque parsear la salida de `getenforce` es frágil y tanto `Permissive` como `Enforcing` cuentan como habilitado.
- `sestatus` es el informe completo: modo en tiempo de ejecución *y* modo del archivo de configuración lado a lado (la única herramienta que muestra la divergencia entre ambos), el nombre de la política, el punto de montaje de SELinuxfs, el estado de MLS, el manejo de `deny_unknown`, y la versión de la política.

**A2.2** — `setenforce` escribe únicamente en `/sys/fs/selinux/enforce`, una perilla de tiempo de ejecución del kernel sin persistencia. En el arranque, el sistema de init lee `SELINUX=` de `/etc/selinux/config` y fija el modo a partir de ahí. Para persistir, ponga `SELINUX=permissive` en ese archivo. La contrapartida es el punto del diseño: el comando de tiempo de ejecución es deliberadamente volátil para que un `setenforce 0` accidental o malicioso se deshaga con un reinicio, y para que el diagnóstico no pueda convertirse silenciosamente en un cambio permanente de postura.

**A2.3** — Con SELinux deshabilitado, el kernel no mantiene etiquetas: todo archivo escrito o modificado mientras estuvo deshabilitado tiene un xattr `security.selinux` obsoleto o ausente, y no hay política cargada dentro de la cual cambiar de modo. `setenforce` por lo tanto falla (`setenforce: SELinux is disabled`) porque la transición Disabled→Enforcing no es una operación de tiempo de ejecución. El procedimiento es:
1. Poner `SELINUX=permissive` en `/etc/selinux/config` (**no** `enforcing` — pase primero por permissive).
2. **Crear `/.autorelabel`** — este es el paso fácil de olvidar. Sin él, el sistema arranca con una política cargada pero miles de archivos sin etiquetar o mal etiquetados, y servicios esenciales fallan de formas que pueden dejarlo sin poder iniciar sesión.
3. Reiniciar; init reetiqueta todo el sistema de archivos y reinicia de nuevo.
4. Revisar los AVC recolectados en modo permissive, corregirlos, y luego poner `SELINUX=enforcing` y reiniciar.

**A2.4** —
- `enforcing=0` — SELinux se inicializa normalmente y la política se carga; solo se suprime la decisión de enforcement. **Las etiquetas se siguen manteniendo correctamente** y toda denegación potencial se registra con `permissive=1`. Este es el parámetro de diagnóstico seguro: usted arranca, recolecta el conjunto completo de denegaciones, lo corrige, y reinicia sin él.
- `selinux=0` — SELinux nunca se inicializa. Sin política, sin etiquetado. Cualquier archivo creado o modificado durante ese arranque termina con una etiqueta obsoleta o faltante, así que rehabilitarlo más tarde requiere un reetiquetado completo del sistema de archivos. Además produce cero información de diagnóstico: usted aprende que la máquina arranca sin SELinux, no *cuál* denegación era el problema.
Use `enforcing=0` para diagnosticar; reserve `selinux=0` para el caso en que el propio subsistema SELinux sea lo que impide el arranque.

**A2.5** — `deny_unknown` controla qué hace el kernel con clases de objeto y permisos que el *kernel* conoce pero la *política cargada* no define — típicamente después de una actualización de kernel que trae hooks nuevos que el paquete de política todavía no alcanzó. `allowed` significa que esos permisos desconocidos se permiten (fail-open, priorizando disponibilidad); `denied` significa que se rechazan (fail-closed, más seguro pero puede romper funcionalidad nueva del kernel sin regla correspondiente). Se configura en `/etc/selinux/semanage.conf` (`handle-unknown=`) y requiere reconstruir la política.

### Punto de control 3

**A3.1** — `user:role:type:level` — usuario SELinux, rol, tipo (llamado el *dominio* cuando etiqueta un proceso), y el nivel o rango MLS/MCS. En la política `targeted`, prácticamente toda decisión es una decisión de Type Enforcement, así que el campo **type** carga el enforcement. El **role** restringe hacia qué tipos puede transicionar un sujeto (RBAC), el **user** restringe qué roles son alcanzables, y el **level** se usa casi exclusivamente para separación por categorías MCS (contenedores, sVirt, `chcat`) en lugar de seguridad multinivel verdadera.

**A3.2** — `chcon` escribe la etiqueta directamente en el atributo extendido `security.selinux` del inodo; no toca la base de datos de contextos de archivo de la política. `restorecon` lee la especificación *de la política* (`file_contexts` más `file_contexts.local`) y restablece la etiqueta a lo que la política dice que debería ser esa ruta — que, al nunca haber sido informada sobre `/srv/lab333`, seguía siendo `var_t`. Cualquier evento de reetiquetado deshace `chcon`: un `restorecon` explícito, `fixfiles`, `/.autorelabel`, o una operación de paquetes que reetiquete sus archivos. **Regla práctica:** `chcon` es para experimentos temporales y para confirmar una hipótesis antes de escribir la regla real; `semanage fcontext -a` + `restorecon` es la única forma duradera.

**A3.3** —
- `cp` crea un **inodo nuevo**. Los objetos nuevos reciben la etiqueta que las reglas de type-transition de la política especifican para ese directorio padre y ese dominio creador — acá, `httpd_sys_content_t` proveniente de la regla fcontext heredada vía el directorio. Este es el comportamiento "correcto" y la razón por la que `cp` suele ser lo que usted quiere.
- `cp -a` implica `--preserve=all`, que incluye el contexto SELinux, así que copia explícitamente la etiqueta de origen (`user_tmp_t`) al inodo nuevo, derrotando la transición.
- `mv` dentro del mismo sistema de archivos es un **rename**: no se crea un inodo nuevo, así que el xattr existente se mueve con él sin cambios (`user_tmp_t`). Esta es la causa clásica de "moví mi sitio a DocumentRoot y me da 403" y la razón por la que `restorecon -R` debería seguir a todo `mv` hacia un árbol etiquetado. (`mv` *entre* sistemas de archivos degrada a copiar+borrar y se comporta como `cp`.)

**A3.4** —
- `restorecon` — la especificación viene del **valor por defecto activo** (`file_contexts` + `file_contexts.local` de la política actual); el alcance son las rutas que usted nombra (`-R` para recursivo, `-v` verboso, `-n` simulación, `-F` fuerza también los campos de usuario y rol, no solo el tipo).
- `setfiles` — usted pasa el **archivo de especificación explícitamente** como primer argumento. Es la primitiva usada al instalar y al reetiquetar, cuando no hay política activa que consultar, por ejemplo desde un instalador o un entorno de rescate.
- `fixfiles` — un wrapper de shell alrededor de `setfiles`/`restorecon` que agrega **alcances a nivel de sistema**: `fixfiles check` (solo informe), `fixfiles relabel` (todo, con una advertencia sobre `/tmp`), `fixfiles -R <pkg> restore` (toda ruta perteneciente a un RPM), `fixfiles -F onboot` (programa un reetiquetado completo en el próximo arranque creando `/.autorelabel`).
"Un árbol de directorios para el que acabo de agregar una regla" → `restorecon -Rv`. "Todo el sistema después de que SELinux estuvo deshabilitado" → `fixfiles -F onboot` (o `touch /.autorelabel`) y luego reiniciar.

**A3.5** — No, y no. `semanage fcontext -a` solo agrega una regla a `file_contexts.local` en el almacén de políticas; no toca un solo inodo. Las etiquetas en disco quedan sin cambios, así que el sistema en ejecución se comporta idénticamente. Un reinicio tampoco cambia nada — el kernel lee xattrs, no la base de datos fcontext, al momento del acceso. La regla surte efecto solo cuando algo reetiqueta los archivos: `restorecon`, `fixfiles`, o un reetiquetado completo. Esta asimetría es la causa más común de "ejecuté el comando semanage de la documentación y sigue sin funcionar".

**A3.6** — `-e` crea una regla de **equivalencia** (sustitución): le dice a la maquinaria de etiquetado que trate `/srv/lab333/html` como si fuera `/var/www/html`, de modo que el conjunto *entero* de reglas que aplica a la ruta destino — incluidas reglas específicas de subdirectorios como `cgi-bin` → `httpd_sys_script_exec_t` — aplica a la ruta nueva. `-t` fija un único tipo plano para todo lo que coincida con una expresión regular. Prefiera `-e` cuando esté reubicando el árbol de directorios completo de un servicio que la política provista ya etiqueta de forma granular (un `/var/www`, `/home` o `/var/lib/mysql` mudado); prefiera `-t` para un árbol nuevo propio con contenido uniforme. Las equivalencias se listan con `semanage fcontext -l -e`.

### Punto de control 4

**A4.1** —
- **Tipo** — el tercer campo del contexto; una etiqueta de seguridad abstracta adjunta a cualquier objeto (archivos, sockets, puertos, claves, procesos). Los tipos no tienen significado inherente; las reglas de la política se lo dan.
- **Dominio** — lo mismo, pero la palabra que se usa cuando el tipo etiqueta un *proceso*. `httpd_t` es un dominio cuando etiqueta un Apache en ejecución y un tipo cuando se lo discute en abstracto. La distinción es convencional, no estructural — SELinux unificó deliberadamente sujetos y objetos bajo un único espacio de nombres de tipos.
- **Entrypoint** — un permiso de la clase `file`. Un dominio solo puede ser ingresado ejecutando un archivo sobre cuyo tipo el dominio tiene `entrypoint`. `httpd_t` tiene `entrypoint` sobre `httpd_exec_t`, así que la única forma de entrar al dominio `httpd_t` es ejecutando algo etiquetado `httpd_exec_t`.

**A4.2** —
1. `allow <source_domain> <exec_type>:file execute;` — sin ella el proceso origen simplemente no puede ejecutar el binario en absoluto. Previene que un dominio lance programas fuera de su competencia.
2. `allow <source_domain> <target_domain>:process transition;` — sin ella el exec tiene éxito pero el proceso permanece en el dominio *viejo*, lo que normalmente significa un nivel de privilegio inesperado. Previene que un dominio arbitrario engendre un dominio privilegiado.
3. `allow <target_domain> <exec_type>:file entrypoint;` — sin ella nada puede entrar nunca al dominio destino a través de ese binario. Esta es la crucial: significa que un atacante que planta un binario malicioso no puede lograr que corra como `httpd_t`, porque su binario no llevará `httpd_exec_t`. Ata un dominio a un programa específico, etiquetado, en disco.
(Un cuarto elemento, `type_transition`, hace que la transición sea *automática*; sin él la transición debe solicitarse explícitamente, por ejemplo con `setexeccon()` o `runcon`.)

**A4.3** — `runcon` fija el contexto de un **proceso nuevo al momento del exec**; la política targeted permite a `unconfined_t` transicionar a la mayoría de los dominios, así que la solicitud tiene éxito. `newrole` cambia el **rol de su sesión de login actual**, reautenticándolo primero — es el análogo SELinux de `su` para roles, y requiere que su *usuario SELinux* esté autorizado para el rol solicitado. En un sistema targeted, su login mapea a `unconfined_u`, que está autorizado para `unconfined_r` y `system_r` pero no para `sysadm_r`, así que la solicitud es rechazada. En esencia: `runcon` opera en la dimensión TE sobre un proceso hijo, `newrole` opera en la dimensión RBAC sobre su sesión.

**A4.4** — TE es lo que efectivamente deniega: toda decisión de acceso se reduce en última instancia a "¿existe una regla `allow <stype> <ttype>:<class> <perm>`?" RBAC es una **capa de restricción encima**: la política declara qué roles puede asumir un usuario SELinux dado (`semanage user -l`) y con qué tipos puede asociarse cada rol (`role httpd_r types httpd_t;`). Un proceso no puede entrar a un dominio a menos que su rol actual esté autorizado para ese tipo, de modo que RBAC limita el *conjunto alcanzable* de dominios en lugar de decidir accesos individuales a archivos. En `targeted`, RBAC es en gran medida vestigial para los servicios del sistema (todo aterriza en `system_r`); hace trabajo real en configuraciones con usuarios confinados (`user_r`, `staff_r`, `sysadm_r`).

**A4.5** — La política SELinux hace uso intensivo de **atributos**: una regla puede escribirse contra un atributo como `httpdcontent` o `port_type`, y todo tipo que porte ese atributo hereda la regla. `sesearch -A` expande los atributos por defecto, así que usted ve el conjunto de permisos *efectivo*, que es lo que normalmente quiere al responder "¿puede este dominio hacer esto?". Use `-d` / `--direct` para restringir la salida a reglas escritas literalmente con ese tipo, que es lo que quiere cuando está buscando la línea fuente a parchear.

**A4.6** — Obtiene el dominio que produzcan las reglas de transición para la etiqueta de `/usr/local/bin/httpd` — que será `bin_t` (el valor por defecto para `/usr/local/bin`), no `httpd_exec_t`. No hay ningún `type_transition init_t bin_t:process httpd_t`, así que el proceso corre en `init_t` — el propio dominio de systemd, altamente privilegiado — en lugar del estrictamente confinado `httpd_t`. Nada cambió en la política, pero el resultado práctico es que el servidor web, el proceso más expuesto de la máquina, ahora corre efectivamente sin confinar. Esto es exactamente por qué el mecanismo de entrypoint ata un dominio a un binario *etiquetado*, y por qué hacer `restorecon` después de mover binarios de servicios es una operación de seguridad, no tareas domésticas.

### Punto de control 5

**A5.1** — El par es `(actual , por defecto)` — el valor en efecto ahora mismo, y el valor almacenado de forma persistente en el almacén de políticas. `(on , off)` significa que el boolean está actualmente activado, pero no se escribió nada en el almacén, así que un reinicio lo devuelve a `off`. Este par es cómo usted detecta la divergencia entre lo que alguien hizo con `setsebool` durante un incidente y lo que la máquina hará realmente mañana. `semanage boolean -l -C` lista solo los booleans cuyo valor almacenado difiere del valor por defecto de la política — el informe efectivo de "qué se personalizó acá".

**A5.2** —
- `setsebool <bool> on|off` — fija un valor explícito, **solo en tiempo de ejecución**, se pierde al reiniciar. El efecto es inmediato.
- `setsebool -P <bool> on|off` — fija un valor explícito y lo confirma en el almacén de políticas, así que sobrevive al reinicio. Reconstruye y recarga la política, por lo que es notablemente más lento (segundos).
- `togglesebool <bool>` — **invierte** el valor actual, sea cual sea, solo en tiempo de ejecución, y no tiene forma persistente. Como no toma un valor destino, ejecutarlo dos veces no hace nada y ejecutarlo desde un script sin conocer el estado previo es no determinista. Prefiera `setsebool` en automatización.

**A5.3** — Dos valores separados por un espacio: valor **actual** y valor **pendiente**. `0 1` significa que el boolean está actualmente en off pero hay un cambio a on preparado y todavía no confirmado. Las escrituras en `/sys/fs/selinux/booleans/<name>` preparan un cambio; escribir `1` en `/sys/fs/selinux/commit_pending_bools` aplica atómicamente todos los cambios pendientes. `setsebool` realiza ambos pasos por usted.

**A5.4** — (1) El boolean fue escrito por los autores de la política, que acotaron las reglas condicionales exactamente a los permisos que esa funcionalidad necesita, y es revisado y mantenido a lo largo de las actualizaciones de política; un módulo escrito a mano refleja solo las denegaciones que usted casualmente disparó durante las pruebas, y nadie lo revisa después. (2) Un boolean es autodocumentado y descubrible — `semanage boolean -l` muestra su descripción, y `sesearch -b` muestra exactamente qué reglas controla — así que el siguiente ingeniero puede ver por qué el sistema está configurado así; un `.pp` personalizado en `/root` es invisible para cualquiera que no ejecute `semodule --list=full`. Una tercera razón: los booleans son portables vía `semanage export`, sobreviven limpiamente a las actualizaciones del paquete de política, y no pueden introducir sintaxis que entre en conflicto con una versión futura de la política.

**A5.5** — `httpd_can_network_connect` concede conexiones salientes a **todo tipo de puerto en la política** — SSH, puertos de base de datos, LDAP, todo. Si Apache es comprometido, se convierte en un pivote de propósito general hacia la red interna. Etiquetar un solo puerto en cambio (`semanage port -a -t http_port_t -p tcp 9999`) concede acceso saliente únicamente a ese número de puerto específico, así que un Apache comprometido puede alcanzar el único backend al que se suponía que debía llegar y nada más. El boolean es la respuesta conveniente; la etiqueta de puerto es la correcta. Donde exista un boolean de propósito específico — `httpd_can_network_connect_db`, `httpd_can_network_relay`, `httpd_can_connect_ldap` — prefiéralo por sobre el general.

### Punto de control 6

**A6.1** — `CAP_NET_BIND_SERVICE` satisface la verificación *equivalente a DAC* para hacer bind en un puerto privilegiado; es una verificación de capability, evaluada antes del hook LSM. SELinux luego aplica una verificación independiente sobre el permiso `name_bind` para la clase `tcp_socket`, contrastando el dominio con el tipo del **puerto**. El puerto 8088 era `unreserved_port_t`, y `httpd_t` tiene `name_bind` solo sobre `http_port_t` (y unos pocos más). Las capabilities son un refinamiento de DAC — subdividen el poder de root — y están sujetas a MAC como todo lo demás. Tener todas las capabilities del mundo no crea una regla allow.

**A6.2** —
```bash
sudo semanage port -l | grep -w 3307        # is it already defined, and under what type?
sudo semanage port -a -t mysqld_port_t -p tcp 3307
```
Si el grep muestra que el puerto ya está asignado a otro tipo, `-a` fallará con `ValueError: Port tcp/3307 already defined` y deberá usar `-m` para reasignarlo — lo cual conviene pensar primero, porque le está sacando el puerto a cualquiera que sea el servicio al que la política se lo asignó.

**A6.3** — `-a` **agrega** una definición local nueva y se niega si el número de puerto/protocolo ya está definido en cualquier parte de la política (provista o local). `-m` **modifica** una definición existente, reasignando el puerto a un tipo distinto. El error `ValueError: Port tcp/80 already defined` le dice que use `-m`; el error `ValueError: Port tcp/8088 is not defined` le dice que use `-a`. `-d` elimina una definición local y restaura la provista.

**A6.4** —
1. **Usuario Linux → usuario SELinux**: `semanage login`. Consultado por PAM (`pam_selinux`) al momento del login. `__default__` captura todo lo no mapeado.
2. **Usuario SELinux → roles (y rango MLS)**: `semanage user`. Declara qué roles puede asumir un usuario SELinux y qué rango de habilitación obtiene.
3. **Rol → tipos/dominios**: fijado por las declaraciones `role … types …` de la política; se cambia solo escribiendo e instalando un módulo de política, no con `semanage`.
El salto en tiempo de ejecución **dominio → dominio** es la transición de tipo del Ejercicio 4, también definida por la política.

**A6.5** — El único rol de `user_u` es `user_r`, cuyo dominio asociado `user_t` no tiene permitidas las capabilities `setuid`/`setgid` ni la transición a `sysadm_t` que `sudo -i` necesita. El bloqueo vino de MAC, no de `sudoers`. La diferencia es significativa: quitar a `kiosk` de `wheel` es un cambio DAC/`sudoers` que `kiosk` podría deshacer si alguna vez obtuviera root por otra vía (un bug setuid, un servicio mal configurado), mientras que el confinamiento SELinux significa que incluso un proceso que *se convierta* en UID 0 permanece en `user_t` y sigue sin poder hacer lo que `user_t` no puede hacer. Ese es todo el argumento a favor de los usuarios confinados: restringe cuánto vale la equivalencia con root.

**A6.6** — `semanage export` captura las **personalizaciones locales registradas en el almacén de políticas**: booleans modificados, reglas fcontext, asignaciones de puertos, mapeos de login, contextos de interfaz y de nodo, dominios permissive. Deliberadamente **no** captura los módulos de política instalados (archivos `.pp`/`.cil` — debe copiarlos e instalarlos con `semodule -i` por separado), ni las etiquetas en disco propiamente dichas (un `semanage import` en el host nuevo igual necesita una corrida de `restorecon`/`fixfiles`). Al reconstruir un host, `semanage export`/`import` le da la configuración pero además debe: reinstalar los módulos personalizados, y reetiquetar. Olvidar el reetiquetado reproduce la trampa del Ejercicio 3 a escala de sistema completo.

### Punto de control 7

**A7.1** —
- `ausearch` — una **herramienta de consulta de logs**. Parsea `/var/log/audit/audit.log`, filtra por tipo de mensaje, tiempo, comando, clave, PID, y con `-i` resuelve campos numéricos a nombres. No sabe nada de política.
- `audit2why` — toma registros AVC por entrada estándar y explica **por qué** el acceso fue denegado: regla TE faltante, boolean apagado, violación de restricción, dontaudit, permiso desconocido, dominio permissive. Debe **cargar la política actual** (`/sys/fs/selinux/policy`) para responder, porque "no hay ninguna regla para esto" y "hay una regla pero un boolean la desactiva" son indistinguibles solo a partir del log. Es el mismo binario que `audit2allow -w`.
- `audit2allow` — toma registros AVC y **emite las reglas allow** que habrían permitido esos accesos, opcionalmente empaquetándolas como módulo cargable con `-M`. Es una herramienta de transcripción: no razona sobre si el acceso *debería* permitirse.

**A7.2** — Otros veredictos de `audit2why` y por qué las reglas generadas serían incorrectas:
- **"One of the following booleans was set incorrectly"** — la regla existe pero está desactivada por el boolean. La solución es `setsebool -P`; instalar una regla allow incondicional duplicada saltea el boolean y elimina permanentemente la capacidad de un administrador de desactivar esa funcionalidad.
- **"Constraint violation"** — la denegación vino de una restricción MLS/MCS o RBAC, que las reglas allow no pueden anular. El módulo generado se instala sin problemas y no cambia nada, desperdiciando una ventana de indisponibilidad (ver A9.3).
- **"Access was denied by a dontaudit rule"** (visto después de `semodule -DB`) — los autores de la política marcaron deliberadamente ese acceso como ruido esperado e inofensivo. Permitirlo concede privilegio real para silenciar un mensaje que nunca fue un síntoma.
- **"Missing or disabled TE allow rule" / registros de dominio permissive (`permissive=1`)** — el acceso ya tuvo éxito; el registro documenta qué *habría* sido denegado. Alimentar estos a `audit2allow` sin revisión es cómo se termina concediendo el conjunto completo de accesos que una aplicación intentó durante una prueba de fuzzing.

**A7.3** — Pregúntese: *¿el dominio está haciendo algo legítimo sobre un objeto que lleva la etiqueta equivocada, o está haciendo algo que los autores de la política decidieron que no debería hacer?* Si el objeto está mal etiquetado — contenido en un directorio no estándar, un archivo creado por `mv`, una base de datos movida a un volumen nuevo — la solución correcta es un cambio de etiqueta (`semanage fcontext` + `restorecon`), porque la política provista ya contiene las reglas correctas para el tipo correcto y usted las gana todas gratis, para siempre, a través de las actualizaciones. Solo cuando el acceso requerido **no** tiene tipo provisto ni boolean correspondiente — una integración genuinamente novedosa entre dos servicios confinados — un módulo personalizado es lo correcto. En la práctica, bastante más del 90% de las denegaciones en producción son problemas de etiquetado.

**A7.4** — 400 es la **prioridad** del módulo. `semodule -i` instala en prioridad 400 por defecto; los módulos provistos por el paquete de política de la distribución viven en prioridad **100**. Cuando dos módulos comparten nombre, gana el de mayor prioridad. Para sobrescribir un módulo provisto, instale su versión modificada en cualquier prioridad superior a 100 — `sudo semodule -X 400 -i apache.pp` — y quítelo con la prioridad correspondiente (`semodule -X 400 -r apache`) para volver a la versión de la distribución. Por eso `semodule --list=full` es más útil que `semodule -l` a secas: solo el listado completo muestra prioridades y lenguaje (`pp` vs `cil`).

**A7.5** — (1) **Radio de impacto.** `setenforce 0` deshabilita el enforcement para todos los dominios de la máquina, así que durante la ventana de diagnóstico nada está confinado; un dominio permissive deja a los otros varios miles de dominios en enforcing, así que el compromiso de un servicio no relacionado sigue contenido. (2) **Relación señal/ruido.** Con permissive global usted recolecta AVC de todos los procesos de la máquina y debe filtrar; con un dominio permissive el log contiene esencialmente solo los registros que le interesan, cada uno marcado `permissive=1`. Una tercera: `semanage permissive` queda registrado en el almacén de políticas, así que `semanage permissive -l` le muestra a un auditor exactamente qué dominios están sin confinar y `semanage export` lo transporta — un `setenforce 0` interactivo no deja rastro alguno.

**A7.6** — Una regla `dontaudit` **suprime el registro de auditoría** de una denegación sin permitirla. La política incluye miles porque muchas aplicaciones sondean rutinariamente cosas que no necesitan — recorrer `/proc`, hacer stat de archivos para ver si existen, probar `ioctl`s sobre el tipo equivocado de descriptor — y registrar cada una sepultaría las denegaciones reales. El escenario en el que `semodule -DB` es la única salida: **una aplicación falla, pero `ausearch` no muestra ningún AVC.** La denegación existe; simplemente está siendo ocultada. `semodule -DB` reconstruye y recarga la política con todas las reglas dontaudit deshabilitadas, usted reproduce la falla, y el registro aparece. Después **debe** ejecutar `semodule -B` para restaurarlas — dejar dontaudit deshabilitado inunda el log de auditoría, puede llenar el disco, y en un host con carga degrada el rendimiento de forma medible.

**A7.7** — (1) **Ventana temporal**: `-ts today` barre toda denegación de todo dominio desde la medianoche, incluyendo servicios no relacionados y cualquier sondeo que haya hecho un atacante. El módulo contendrá reglas allow que el ingeniero nunca miró, concediendo acceso mucho más allá del incidente. Use `-ts recent` (últimos 10 minutos) o una marca de tiempo precisa, y siempre acote con `-c <comm>` o con el contexto de origen. (2) **Sin paso de revisión**: `&& semodule -i` instala sin que nadie lea el `.te`. `audit2allow` emitirá alegremente `allow httpd_t shadow_t:file read;` si esa denegación está en el log — que es precisamente el acceso que generaría un atacante. Ejecute siempre `audit2allow` sin `-M` primero, lea las reglas, y recién entonces empaquete. (3) **Herramienta equivocada para la causa**: el runbook no consulta `audit2why`, así que aplica reglas allow a problemas que son errores de etiquetado, ajustes de booleans, o violaciones de restricciones — degradando permanentemente la política para sortear algo que tenía una solución correcta de una línea, y en el caso de la restricción sin arreglar nada en absoluto. Una cuarta: repetido durante meses, esto produce una pila de módulos superpuestos sin nombre que nadie puede quitar con seguridad.

### Punto de control 8

**A8.1** —
- `.te` (+ `.if`, `.fc`) → `.mod`: **`checkmodule -M -m -o out.mod in.te`** compila la fuente de type enforcement a un módulo de política binario. `-m` selecciona modo módulo (no base); `-M` habilita soporte MLS/MCS, obligatorio en una política targeted.
- `.mod` + `.fc` → `.pp`: **`semodule_package -o out.pp -m out.mod -f out.fc`** empaqueta el módulo binario junto con la especificación de contextos de archivo en un **p**olicy **p**ackage.
- `.pp` → política cargada: **`semodule -i out.pp`** inserta el paquete en el almacén de políticas bajo `/var/lib/selinux/<policytype>/active/modules/<priority>/`, luego reconstruye la política binaria completa y la carga en el kernel.
`make -f /usr/share/selinux/devel/Makefile foo.pp` realiza los dos primeros pasos y además ejecuta la expansión de macros M4 que le da acceso a interfaces de la reference policy como `files_type()` y `apache_content_template()`.

**A8.2** — `require { }` declara los identificadores que el módulo **usa pero no define** — tipos, clases, permisos, roles, atributos y booleans que viven en la política base o en otros módulos. Es la declaración de importación del sistema de módulos: le dice al compilador que esos símbolos se resolverán al momento del enlazado. Referenciar `httpd_t` sin requerirlo falla en tiempo de compilación con `unknown type httpd_t` (o, peor en cadenas de herramientas antiguas, se interpreta como un intento de *declarar* un tipo nuevo con ese nombre, produciendo silenciosamente un módulo que concede acceso a un tipo que nada más usa). Note que `audit2allow` genera el bloque `require` por usted — una de sus fortalezas genuinas.

**A8.3** — El archivo `.fc` agrega una regla a la base de datos de contextos de archivo de la política diciendo "las rutas que coincidan con `/srv/lab333/spool(/.*)?` deberían etiquetarse `lab333_spool_t`". Instalar el módulo escribe esa regla en el almacén; no toca ningún inodo (la misma asimetría que en A3.5). `restorecon` es lo que lee la regla y aplica la etiqueta. Sin el reetiquetado, el directorio habría conservado `var_t`, el tipo nuevo `lab333_spool_t` existiría en la política sin etiquetar nada, y cada regla del módulo sería código muerto — la denegación sería idéntica a antes, lo cual es enloquecedor de depurar porque `semodule --list` confirma que el módulo está instalado.

**A8.4** — **CIL** (Common Intermediate Language) es el lenguaje de entrada nativo del compilador moderno de política SELinux. Desde la versión 2.4 del espacio de usuario, `semodule` compila los archivos `.pp` a CIL mediante un plugin de lenguaje de alto nivel (`/usr/libexec/selinux/hll/pp`) y luego compila CIL a la política binaria del kernel. Así que `.pp` es ahora un formato de front-end heredado, conservado por compatibilidad, y CIL es la interfaz real: puede instalarse directamente (`semodule -i foo.cil`), es lo que generan herramientas como `udica` y `container-selinux`, y expone funcionalidades que la cadena `.te`/`m4` no puede expresar (espacios de nombres, herencia, reglas `deny`). En la práctica: siga usando `.te` para política escrita a mano porque la biblioteca de interfaces de la reference policy es enorme y solo está disponible ahí, pero espere que la política generada y las herramientas futuras sean CIL, y sepa que `semodule -c -E <module>` le permite leer cualquier módulo instalado como CIL.

**A8.5** —
- **Tipo privado nuevo** — el dominio obtiene exactamente el acceso a exactamente estos datos, y nada más en el sistema comparte la etiqueta. Si Apache es comprometido, el atacante alcanza este spool y ningún otro contenido web. También hace la intención auditable: `sesearch -A -t lab333_spool_t` muestra la lista completa de quién puede tocarlo. Costo: usted es dueño del módulo para siempre, incluso a través de las actualizaciones de política.
- **Reutilizar `httpd_sys_rw_content_t`** — cero mantenimiento, ya es correcto, cada regla y boolean provistos que gobiernan contenido web escribible aplican automáticamente, y el siguiente ingeniero reconoce la etiqueta al instante. Costo: todo lo demás en la máquina etiquetado `httpd_sys_rw_content_t` — el directorio de subidas de cualquier otro vhost — queda ahora en la misma clase de equivalencia que sus datos.
Regla práctica: reutilice el tipo provisto salvo que tenga un requisito de aislamiento específico entre dos cosas que de otro modo compartirían etiqueta. Para separación multi-inquilino, las categorías MCS (Ejercicio 9) suelen ser mejor respuesta que un tipo nuevo.

**A8.6** — `files_type()` es una interfaz de la reference policy que asigna los atributos de archivo estándar (`file_type`, `non_security_file_type`, y relacionados) a su tipo nuevo. Una enorme cantidad de reglas provistas están escritas contra esos atributos y no contra tipos individuales — las reglas que permiten a los administradores reetiquetar el archivo, que permiten a los dominios de respaldo y de mantenimiento del sistema de archivos leerlo, que permiten a `restorecon` operar sobre él, que lo eximen de las restricciones de archivos de seguridad. Un `type lab333_spool_t;` pelado produce un tipo que no está en *ningún* atributo, así que no hereda *ninguna* regla: el directorio se vuelve ilegible para todos los dominios incluido `unconfined_t`, `restorecon` puede quedar incapaz de reetiquetarlo, y los respaldos fallan silenciosamente. Es el error clásico número uno de la política escrita a mano, y el síntoma — "ni root puede tocarlo y no puedo devolverle la etiqueta" — es alarmante en desproporción con la causa de una sola línea.

### Punto de control 9

**A9.1** — **MLS** (Multi-Level Security) implementa una jerarquía estilo Bell–LaPadula de *sensibilidades* (`s0` < `s1` < `s2` …) con reglas de dominancia — no leer hacia arriba, no escribir hacia abajo — y es lo que provee el tipo de política `mls` para entornos con niveles formales de clasificación. **MCS** (Multi-Category Security) usa solo la porción de *categorías* del mismo campo, sin jerarquía: las categorías son compartimentos planos y sin orden, y un sujeto puede acceder a un objeto solo si el conjunto de categorías del sujeto es un superconjunto del del objeto. `sestatus`/`seinfo` en `targeted` muestran **1 sensibilidad** y 1024 categorías — una política de una sola sensibilidad, por definición, no está haciendo seguridad multi-*nivel*. `targeted` usa la maquinaria de MLS puramente como MCS.

**A9.2** — Una **restricción** MLS/MCS (`mlsconstrain`), no una regla de tipo. Las restricciones son una construcción de política separada: son expresiones booleanas sobre campos del contexto (`l1 dom l2`, `u1 == u2`, `r1 == r2`) que deben cumplirse *además de* una regla allow. La arquitectura es: un acceso se permite solo si existe una regla allow **y** toda restricción aplicable se satisface. Las reglas de tipo son aditivas y cualquier módulo puede extenderlas; las restricciones son limitaciones declarativas sobre la política entera y solo pueden cambiarse en la política base. Por eso una denegación por restricción es un tipo de falla fundamentalmente distinto de una regla allow faltante.

**A9.3** — `audit2allow` lee el AVC y emite mecánicamente `allow unconfined_t var_t:file read;` — una regla que, en la política targeted, **ya existe**. El módulo generado compila, `semodule -i` tiene éxito, `semodule --list=full` lo muestra cargado, y el acceso sigue denegado, porque la denegación nunca vino de la dimensión de tipos. Esto produce la peor clase de falla de diagnóstico: cada acción informa éxito y nada cambia. La pista es `audit2why` informando "Constraint violation" y el AVC mostrando scontext y tcontext con *campos de nivel distintos pero tipos idénticos*. Las soluciones reales son cambiar las categorías del objeto (`chcat`), cambiar el rango del sujeto (`semanage login -r` / `semanage user -r`), o correr el sujeto a un nivel apropiado (`runcon -l`).

**A9.4** — **Dominancia**: un rango `low-high` domina un nivel si la sensibilidad del nivel está dentro de `[low, high]` **y** el conjunto de categorías del rango es un superconjunto del conjunto de categorías del nivel. Un sujeto puede leer un objeto solo si su habilitación domina el nivel del objeto.
- `s0` — sí (misma sensibilidad, el conjunto vacío de categorías es subconjunto de cualquiera).
- `s0:c5` — sí (`c5` ∈ `c0.c1023`).
- `s0:c1024` — no (las categorías van de `c0` a `c1023`; `c1024` está fuera del rango y de hecho es una categoría inválida en una política de 1024 categorías).
- `s1:c5` — no (`s1` excede la sensibilidad alta del rango, `s0`; además `s1` no existe en una política targeted de una sola sensibilidad).

**A9.5** — Ambos contenedores corren en el mismo tipo, `container_t`, así que Type Enforcement por sí solo permitiría que cualquiera tocara los archivos del otro. El runtime de contenedores asigna a cada contenedor un **par único y aleatorio de categorías** (`c214,c806` vs `c455,c1002`) y etiqueta la capa escribible de ese contenedor y sus volúmenes `:Z` con el mismo par. La restricción MCS exige entonces que el conjunto de categorías del proceso que accede sea un superconjunto del del objeto — y ningún par de un contenedor es superconjunto del otro, así que los accesos son denegados por restricción aunque los tipos coincidan perfectamente. Esto es MCS haciendo exactamente aquello para lo que fue diseñado: N instancias mutuamente aisladas de un tipo confinado sin escribir N políticas.
`--security-opt label=disable` corre el contenedor como `spc_t` (super-privileged container) sin par de categorías. El contenedor queda entonces sin confinar por SELinux: un escape de contenedor tiene el acceso que tenga `spc_t`, y el aislamiento MCS respecto de cualquier otro contenedor desaparece. Es el equivalente en contenedores de `setenforce 0` para esa única carga de trabajo.

**A9.6** —
- **`:z`** (minúscula) — reetiqueta el contenido del volumen con una etiqueta **compartida** (`container_file_t:s0`, sin categorías), de modo que *varios* contenedores puedan usarlo.
- **`:Z`** (mayúscula) — reetiqueta con la etiqueta **privada** de ese contenedor específico, incluyendo su par único de categorías, de modo que solo ese contenedor pueda usarlo.
Ambos realizan un **reetiquetado recursivo del directorio del host**. Apuntar `:Z` a un directorio que el host también usa — `/var/lib/mysql` perteneciente a un MariaDB del host, `/home`, o en el peor caso `/` o `/usr` — reescribe recursivamente las etiquetas de cada archivo debajo, rompiendo el servicio del host (que ahora no puede leer sus propios datos) y potencialmente exigiendo un `restorecon` completo o un `/.autorelabel` para recuperarse. Use `:Z` solo sobre directorios creados específicamente para el contenedor.

### Punto de control 10

**A10.1** — **SELinux media sobre etiquetas adjuntas a inodos; AppArmor media sobre rutas del sistema de archivos.**
- Ventaja de AppArmor: nunca se requiere reetiquetar el sistema de archivos. Los perfiles son texto legible que nombra rutas reales, así que usted puede desplegar una política de confinamiento en un sistema existente sin tocar los metadatos de un solo archivo, y un perfil puede ser revisado por alguien que nunca estudió el lenguaje de políticas. Nada está nunca "mal etiquetado".
- Ventaja de SELinux: la etiqueta viaja con el inodo, así que el confinamiento no puede eludirse llegando a los mismos datos por otro nombre — un bind mount, un enlace simbólico, un punto de montaje alternativo, o un enlace duro. También significa que SELinux puede etiquetar objetos que no tienen ruta alguna (sockets, puertos, IPC, claves, procesos), y por eso puede expresar cosas que AppArmor no puede, como "este dominio puede hacer bind solo a este puerto TCP".

**A10.2** —
- `ix` — **inherit execute**: el programa nuevo corre bajo el perfil *actual*. Correcto para helpers triviales (`cat`, `sed`) que usted quiere restringidos exactamente como el padre.
- `Px` — **discrete profile execute**: transiciona al perfil *propio* del helper; si no existe perfil, la ejecución es **denegada**. Esta es la respuesta correcta para un helper que tiene su propio perfil — es fail-closed.
- `Cx` — **child profile execute**: transiciona a un perfil hijo definido en línea dentro del perfil actual (`profile /usr/bin/helper { … }`). Úselo cuando el helper necesita un confinamiento distinto pero no amerita un perfil de nivel superior.
- `ux` — **unconfined execute**: el programa nuevo corre **sin** confinamiento alguno. Casi siempre incorrecto; es una válvula de escape y un hallazgo de auditoría.
(Las formas en minúscula `px`/`cx`/`ux` son las mismas transiciones pero *sin* limpiar el entorno; las formas en mayúscula sanean `LD_PRELOAD` y compañía y deberían preferirse. `pix`/`Pix` significan "usar el perfil si existe, si no heredar" — cómodo pero fail-open.)

**A10.3** — Las reglas de AppArmor coinciden con la ruta usada en la llamada `open()`. Si un archivo bajo `/srv/lab333/private/` también tuviera un enlace duro en `/srv/lab333/public/key.txt`, el proceso confinado podría abrirlo por la ruta permitida y leer el mismo inodo — la regla deny nombra una ruta, y el proceso no la usó. AppArmor mitiga esto con la **prueba de subconjunto de enlaces**: crear un enlace (permiso `l`) solo se permite si los permisos del nombre destino son un **subconjunto** de los del nombre origen, así que un proceso confinado no puede fabricar un alias más permisivo para un archivo que ya puede alcanzar. Eso protege contra que el proceso confinado cree el enlace, pero no contra un enlace que ya existe o que crea un proceso sin confinar. La defensa es auditar la disposición del sistema de archivos, mantener los datos sensibles en sistemas de archivos separados (los enlaces duros no pueden cruzarlos), y preferir calificadores `owner` y globs ajustados. SELinux es inmune a esta clase por construcción, ya que la etiqueta está en el inodo.

**A10.4** —
1. `aa-complain /etc/apparmor.d/<profile>` — inserta `flags=(complain)` en el archivo del perfil y lo recarga. **Persistente**, sobrevive a `apparmor_parser -r` y al reinicio, porque el flag está en la fuente.
2. Editar el perfil a mano para agregar `flags=(complain)` después del nombre del perfil, y luego `apparmor_parser -r`. Resultado idéntico; `aa-complain` es un wrapper de eso.
3. `aa-complain` sobre el nombre de un perfil *en ejecución* en lugar de una ruta de archivo (`aa-complain lab333-reader`) o escribir en `/sys/kernel/security/apparmor/.access` — cambia solo el perfil cargado. **No persistente**; una recarga desde el archivo en disco restaura el modo enforce.
Así que (1) y (2) — que son lo mismo — sobreviven a `apparmor_parser -r`; solo la forma en memoria no. Las operaciones inversas son `aa-enforce` y `aa-audit` (enforce más registrar todo acceso permitido, útil para auditar un perfil que usted cree correcto).

**A10.5** —
- **`aa-disable`** — descarga el perfil *y* crea un enlace simbólico en `/etc/apparmor.d/disable/`, que el script de init respeta, así que el perfil permanece descargado entre reinicios. Persistente, reversible con `aa-enforce` (que quita el enlace). Los procesos corren **sin confinar**. Esta es la forma soportada de apagar un perfil.
- **`apparmor_parser -R <file>`** — quita el perfil del kernel *ahora*. No persistente: la carga en el arranque lo reinstaura. Los procesos en ejecución que estaban confinados por él quedan sin confinar de inmediato.
- **Borrar el archivo del perfil** — persistente, pero destruye su trabajo y cualquier personalización local; el perfil no está en el próximo arranque, y si el archivo venía de un paquete, la próxima actualización del paquete lo restaura silenciosamente, reconfinando la aplicación en un momento impredecible. Nunca es la respuesta correcta.
En los tres casos, los procesos ya en ejecución pierden el confinamiento (AppArmor no los mata), lo cual importa si usted está deshabilitando un perfil en respuesta a un incidente.

**A10.6** —
- **`aa-genprof <program>`** — la herramienta de *arranque inicial*. Crea un perfil esqueleto (como `aa-autodep`), lo pone en modo complain, y luego le pide que ejecute el programa mientras observa el log, entrando al bucle interactivo de aprobación de reglas cuando usted presiona `S`. Úsela cuando no hay ningún perfil.
- **`aa-logprof`** — la herramienta de *refinamiento*. Escanea el log de auditoría en busca de entradas relativas a **cualquier** perfil cargado y lo guía por el mismo bucle interactivo para cada acceso no cubierto. Úsela después de que el perfil existe y la aplicación fue ejercitada — por ejemplo, tras una semana en modo complain en staging, o después de que una actualización de la aplicación agregó nuevos accesos a archivos.
Ambas dependen del modo complain porque en modo enforce los accesos son **denegados**, así que la aplicación toma una ruta de error y nunca revela qué habría hecho después. Usted aprende la primera denegación y nada más. En modo complain el acceso se permite y se registra, así que un único ejercicio completo de la aplicación produce el conjunto completo de accesos en una sola pasada. El flujo de trabajo estándar es: `aa-genprof` → complain → ejercitar a fondo en staging → `aa-logprof` → `aa-enforce` → monitorear `DENIED` en producción.

**A10.7** — `apparmor="ALLOWED"` es el **resultado**: el perfil está en modo complain, así que la syscall tuvo éxito. `denied_mask="r"` es la **decisión que produjeron las reglas del perfil**: el acceso de lectura no está concedido por ninguna regla, así que en modo enforce esto habría sido rechazado. El modo complain informa ambos — qué dice la política y qué ocurrió realmente — que es exactamente la información que `aa-logprof` necesita. El equivalente en SELinux es un AVC con `permissive=1`: la lista `denied { … }` sigue poblada, y el acceso igual tuvo éxito. En ambos sistemas, el "modo de aprendizaje" registra el contrafáctico.

**A10.8** —
- **`abstractions/`** — fragmentos de reglas reutilizables para patrones comunes (`base`, `bash`, `nameservice`, `ssl_certs`, `python`, `user-tmp`). Se incluyen con `include <abstractions/base>`. Existen para que cada perfil no tenga que rederivar las veinte reglas necesarias para cargar libc y leer `/etc/nsswitch.conf`.
- **`tunables/`** — definiciones de variables (`@{HOME}`, `@{PROC}`, `@{run}`, `@{multiarch}`) que los perfiles expanden. Se incluyen vía `include <tunables/global>` al principio de esencialmente todo perfil. Editar un tunable cambia el comportamiento de todos los perfiles a la vez — por ejemplo, agregar una ubicación no estándar de directorios personales a `@{HOMEDIRS}`.
- **`local/`** — un archivo por perfil, nombrado según él, e `include <local/usr.sbin.nginx>` aparece al **final** del perfil provisto. Acá es donde corresponden los agregados específicos del sitio, porque las actualizaciones de paquetes reemplazan el archivo principal del perfil y descartarán silenciosamente las ediciones hechas directamente en él, mientras que `/etc/apparmor.d/local/*` se preserva. Poner sus reglas ahí es la diferencia entre una personalización que sobrevive a `apt upgrade` y una que desaparece durante una ventana de parcheo rutinaria.

### Punto de control 11

**A11.1** — SELinux, AppArmor y Smack son todos LSM "mayores": cada uno mantiene su propia etiqueta de seguridad sobre los mismos objetos del kernel y engancha los mismos puntos de decisión, y el almacenamiento de etiquetas (xattrs `security.*`, `/proc/*/attr/current`) y la semántica de una denegación fueron históricamente exclusivos — un kernel estándar inicializa exactamente uno de ellos. (Los LSM menores — `capability`, `yama`, `lockdown`, `landlock`, `bpf`, `integrity` — se apilan desde Linux 5.1, y el apilamiento completo de LSM mayores lleva años en desarrollo pero no es el valor por defecto en ningún lado.) Para determinar cuál está activo: `cat /sys/kernel/security/lsm` lista los LSM inicializados en orden; `ls /sys/kernel/security/` muestra un directorio para el que esté activo; y las pruebas específicas son `sestatus`/`getenforce`, `aa-status`, y `mount | grep smackfs`. El selector en tiempo de arranque es el parámetro de kernel `lsm=` (kernels más viejos: `security=`).

**A11.2** — El kernel aplica estas en orden (de `Documentation/admin-guide/LSM/Smack.rst`):
1. Todo acceso solicitado por un sujeto etiquetado `*` es **denegado**. (`*` es la etiqueta de sujeto sin poder.)
2. Una lectura o ejecución solicitada por un sujeto etiquetado `^` es **permitida**. (`^`, el "hat", es el lector universal.)
3. Una lectura o ejecución solicitada sobre un objeto etiquetado `_` es **permitida**. (`_`, el "floor", es la etiqueta por defecto con la que todo comienza, y es universalmente legible.)
4. Todo acceso solicitado sobre un objeto etiquetado `*` es **permitido**. (`*` como etiqueta de *objeto* es universalmente accesible.)
5. Todo acceso donde las etiquetas de sujeto y objeto son **idénticas** está permitido.
6. Todo acceso explícitamente presente en el conjunto de reglas cargado está permitido.
7. Todo lo demás es **denegado**.
Así que `*` deja a un *sujeto* sin poder (regla 1) y a un *objeto* universalmente accesible (regla 4) — la misma etiqueta, significados opuestos según de qué lado del acceso se ubique.

**A11.3** — `SMACK64TRANSMUTE` fijado en un directorio significa que los objetos **creados dentro de él heredan la etiqueta del directorio** en lugar de la etiqueta del proceso creador — siempre que una regla conceda al sujeto acceso `t` (transmute). Sin él, el valor por defecto de Smack es que un archivo nuevo toma la etiqueta del proceso que lo creó, lo cual es incorrecto para directorios compartidos de spool y datos donde la *ubicación* debería determinar la etiqueta. Su análogo más cercano en SELinux es la **transición de tipo en la creación de archivos** (`type_transition domain_t dir_t:file new_t;`), que de igual manera hace que el directorio padre, y no el dominio creador, determine el tipo de un objeto nuevo — el mecanismo detrás de que `httpd_t` cree archivos como `httpd_sys_rw_content_t` en un directorio web escribible.

**A11.4** — El argumento de Smack para esa plataforma: la política es lo bastante pequeña como para leerla entera. Con ~15 procesos usted necesita quizá una docena de etiquetas y unas pocas decenas de reglas, todas expresables en un archivo de texto cargado en `/sys/fs/smackfs/load2` al arrancar — frente a la política provista de SELinux, con ~5.000 tipos y ~113.000 reglas allow, prácticamente ninguna de las cuales describe un dispositivo embebido. Smack tiene una huella mucho menor en el kernel y en el espacio de usuario (relevante con flash y RAM limitados), las etiquetas son cadenas con significado humano que usted elige en lugar de un vocabulario heredado, y un rootfs de solo lectura vuelve trivial el problema del etiquetado porque las etiquetas quedan horneadas en la imagen al momento de construirla. Por eso Tizen y Automotive Grade Linux lo eligieron.
Lo que pierden: **las herramientas y el ecosistema**. No hay `audit2allow`, ni `sealert`, ni `setroubleshoot`, ni reference policy, ni política por aplicación mantenida upstream, ni modo permissive para un despliegue progresivo, ni MLS/MCS. Cada regla se escribe a mano y cada regresión se diagnostica leyendo mensajes crudos del kernel. Ese intercambio está bien para 15 procesos conocidos e es insostenible para un servidor de propósito general.

**A11.5** — **AppArmor.** (1) *Basado en rutas, sin reetiquetar*: el perfil es un archivo de texto que nombra las rutas que el binario puede tocar, así que un equipo sin experiencia en MAC puede leerlo, revisarlo y razonarlo en una tarde — y desplegarlo no cambia metadatos de ningún archivo existente, con lo que el radio de impacto de un error es un perfil, no un sistema de archivos. (2) *Modo complain más `aa-genprof`/`aa-logprof`*: las herramientas generan un perfil funcional a partir del comportamiento observado, de forma interactiva, así que los dos días se invierten en ejercitar la aplicación en vez de en aprender un lenguaje de políticas. Sume que es el valor por defecto en Ubuntu, así que los perfiles se cargan al arrancar sin configuración y `aa-status` responde de inmediato a "¿está confinado?".
(La advertencia honesta que hay que enunciar junto con la recomendación: el perfil resultante confina las rutas que usted observó. Todo lo que la aplicación haga solo bajo condiciones que usted no ejercitó será denegado en producción, así que despliéguelo primero en modo complain y ejecute `aa-logprof` antes de pasar a enforce.)

**A11.6** — Le dice que los tres están implementados contra la **misma abstracción del kernel — el framework Linux Security Modules** — en vez de como parches independientes y ad hoc. LSM define un conjunto fijo de hooks en los puntos de decisión relevantes para la seguridad (verificaciones de permisos de inodos, creación de tareas, bind de sockets, verificaciones de capabilities, etcétera) y un blob de seguridad opaco por objeto y por tarea; cada módulo aporta su propia función de decisión y su propia interpretación del blob. `/proc/<pid>/attr/current` es parte de esa interfaz común: una forma genérica de leer y, donde el módulo lo permita, fijar el atributo de seguridad de la tarea que llama, signifique lo que signifique "atributo de seguridad" para el módulo activo. Las consecuencias prácticas para usted como administrador son que la *forma* de los sistemas es comparable — todos tienen una etiqueta de sujeto, una etiqueta de objeto, un conjunto de reglas, y un hook donde se toma una decisión — y que una herramienta escrita contra la interfaz genérica (auditoría, `ps -Z`, runtimes de contenedores) puede informar sobre cualquiera que sea el LSM activo. Lo que difiere es enteramente el modelo de política construido encima.

</details>

---

## Referencias

- LPI — [Exam 303 Objectives (303-300, version 3.0)](https://www.lpi.org/our-certifications/exam-303-objectives/)
- The SELinux Project — [Main page](https://selinuxproject.org/page/Main_Page), [Policy Languages](https://selinuxproject.org/page/PolicyLanguages), [CIL Reference Guide](https://github.com/SELinuxProject/selinux/tree/main/secilc/docs)
- Red Hat — [Using SELinux (RHEL 9)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/index)
- páginas de manual — [`selinux(8)`](https://man7.org/linux/man-pages/man8/selinux.8.html), [`semanage(8)`](https://man7.org/linux/man-pages/man8/semanage.8.html), [`semodule(8)`](https://man7.org/linux/man-pages/man8/semodule.8.html), [`restorecon(8)`](https://man7.org/linux/man-pages/man8/restorecon.8.html), [`setfiles(8)`](https://man7.org/linux/man-pages/man8/setfiles.8.html), [`fixfiles(8)`](https://man7.org/linux/man-pages/man8/fixfiles.8.html), [`runcon(1)`](https://man7.org/linux/man-pages/man1/runcon.1.html), [`newrole(1)`](https://man7.org/linux/man-pages/man1/newrole.1.html), [`audit2allow(1)`](https://man7.org/linux/man-pages/man1/audit2allow.1.html)
- SETools — [repositorio del proyecto](https://github.com/SELinuxProject/setools) (`seinfo`, `sesearch`, `apol`; note que `seaudit` fue removido en SETools 4.x, donde `ausearch` + `audit2why` cubren ese flujo de trabajo)
- AppArmor — [wiki upstream](https://gitlab.com/apparmor/apparmor/-/wikis/home), [referencia del lenguaje de perfiles](https://gitlab.com/apparmor/apparmor/-/wikis/AppArmor_Core_Policy_Reference), [documentación de Ubuntu Server](https://documentation.ubuntu.com/server/how-to/security/apparmor/)
- Kernel Linux — [LSM framework](https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html), [SELinux](https://www.kernel.org/doc/html/latest/admin-guide/LSM/SELinux.html), [AppArmor](https://www.kernel.org/doc/html/latest/admin-guide/LSM/apparmor.html), [Smack](https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html)
- Linux Audit — [documentación de `audit`](https://github.com/linux-audit/audit-documentation/wiki)