# 109.2 — Configuración de red persistente
## Ejercicios guiados (LPIC-1, exámenes 101-500 / 102-500, versión 5.0)

> **Requisitos del laboratorio.** Una VM descartable o una VM sin contenedores (KVM/libvirt, VirtualBox, o una instancia en la nube a la que puedas llegar por consola serial/VNC), `root` o `sudo`, y un **snapshot tomado antes de empezar**. Varios pasos recargan deliberadamente la pila de red; si tu único acceso es SSH, conseguí primero acceso por consola — `nmcli connection down` sobre tu interfaz de gestión te va a dejar afuera.
>
> Todo el direccionamiento usa rangos de documentación: `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` (RFC 5737) y `2001:db8::/32` (RFC 3849). Nada de esto toca tu enlace real, siempre que respetes la regla de "sin gateway en la interfaz de laboratorio" del Ejercicio 4.
>
> No todas las distribuciones traen todas las pilas. El Ejercicio 4 (NetworkManager), el Ejercicio 5 (ifupdown) y el Ejercicio 6 (systemd-networkd) están escritos para que puedas ejecutar los que tu sistema tenga y *leer* los que no — el examen espera que reconozcas los tres.

---

## Ejercicio 0 — Establecer la línea base: ¿quién es dueño de la red de esta máquina?

Antes de cambiar nada, tenés que saber qué demonio es el autoritativo. La configuración persistente escrita para una pila que no está corriendo se ignora en silencio — la falla más común de este objetivo.

1. Identificá la distribución y la generación de init:

   ```bash
   cat /etc/os-release | head -3
   pidof systemd >/dev/null && echo "systemd PID 1"
   ```

2. Preguntá qué gestores de red están instalados y cuáles están realmente activos:

   ```bash
   systemctl is-enabled NetworkManager systemd-networkd networking 2>&1
   systemctl is-active  NetworkManager systemd-networkd networking 2>&1
   ```

   Salida esperada en una instalación Debian 12 con sabor de escritorio:

   ```
   enabled
   disabled
   enabled
   active
   inactive
   active
   ```

3. Enumerá las fuentes de configuración en disco que existen ahora mismo:

   ```bash
   ls -l /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null
   ls -l /etc/NetworkManager/system-connections/ 2>/dev/null
   ls -l /etc/systemd/network/ 2>/dev/null
   ls -l /etc/netplan/ 2>/dev/null
   ```

4. Registrá el estado en vivo para poder diferenciarlo más tarde:

   ```bash
   ip -br addr show > /root/baseline-addr.txt
   ip -4 route show > /root/baseline-route4.txt
   ip -6 route show > /root/baseline-route6.txt
   cp -a /etc/resolv.conf /root/baseline-resolv.conf
   ip -br addr show
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   enp1s0           UP             192.168.122.61/24 fe80::5054:ff:fe12:3456/64
   ```

5. Demostrá que `ip(8)` **no** es persistencia:

   ```bash
   ip addr add 192.0.2.250/32 dev lo
   ip -br addr show lo
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 192.0.2.250/32 ::1/128
   ```

   ```bash
   ip addr del 192.0.2.250/32 dev lo
   ```

**Comprobá tu comprensión**

- **Q0.1** — Tanto `networking.service` (ifupdown) como `NetworkManager.service` reportan `active` en el mismo host. ¿Por qué eso no es automáticamente un bug, y qué única evidencia lo convertiría en uno?
- **Q0.2** — Agregás una dirección con `ip addr add` y funciona. Nombrá los dos eventos distintos que la van a destruir, y explicá por qué "sobrevivió a un `systemctl restart sshd`" no te dice nada sobre persistencia.
- **Q0.3** — `/etc/network/interfaces` existe y contiene una estrofa estática para `enp1s0`, pero `ip -br addr` muestra la interfaz con una dirección de estilo DHCP en una subred completamente distinta. Dá dos explicaciones plausibles, cada una comprobable con un solo comando.

---

## Ejercicio 1 — Hostname persistente: static, transient, pretty

1. Leé los tres sabores de hostname de una sola vez:

   ```bash
   hostnamectl status
   ```

   ```
    Static hostname: localhost
    Transient hostname: dhcp-192-168-122-61
          Icon name: computer-vm
            Chassis: vm 🖴
         Machine ID: 4f2e0d9a1c3b4f5e8a7d6c5b4a392817
            Boot ID: 9b1c7e2f5a4d43c1b8e6f0a2d3c4b5a6
     Virtualization: kvm
   Operating System: Debian GNU/Linux 12 (bookworm)
             Kernel: Linux 6.1.0-18-amd64
       Architecture: x86-64
   ```

2. Definí el hostname **static** (primero la sintaxis de systemd ≥ 249, después la más vieja — ambas son examinables):

   ```bash
   hostnamectl hostname lab-node01        # systemd >= 249
   # hostnamectl set-hostname lab-node01  # any systemd version
   hostnamectl set-hostname --pretty "LPIC-1 Lab Node 01"
   ```

3. Mostrá dónde aterrizó cada valor en disco:

   ```bash
   cat /etc/hostname
   grep PRETTY_HOSTNAME /etc/machine-info
   hostname
   ```

   ```
   lab-node01
   PRETTY_HOSTNAME=LPIC-1 Lab Node 01
   lab-node01
   ```

4. Pedí el nombre completamente calificado — y mirá cómo falla:

   ```bash
   hostname -f
   ```

   ```
   hostname: Name or service not known
   ```

5. Arreglalo en `/etc/hosts`. Editá el archivo para que contenga exactamente:

   ```
   127.0.0.1       localhost
   127.0.1.1       lab-node01.example.internal lab-node01
   ::1             localhost ip6-localhost ip6-loopback
   ff02::1         ip6-allnodes
   ff02::2         ip6-allrouters
   ```

6. Volvé a probar los nombres derivados:

   ```bash
   hostname -f; hostname -d; hostname -s; hostname -I
   ```

   ```
   lab-node01.example.internal
   example.internal
   lab-node01
   192.168.122.61
   ```

7. Confirmá que NetworkManager expone el mismo valor (si está corriendo):

   ```bash
   nmcli general hostname
   ```

   ```
   lab-node01
   ```

**Comprobá tu comprensión**

- **Q1.1** — ¿Cuál de los tres hostnames sobrevive a un reinicio, cuál se pierde, y qué archivo respalda a cada uno?
- **Q1.2** — `hostnamectl hostname lab-node01` tuvo éxito, y sin embargo `hostname -f` falló. Explicá el mecanismo: ¿qué hace realmente `hostname -f`, y qué subsistema respondió "Name or service not known"?
- **Q1.3** — Debian mapea el FQDN a `127.0.1.1` en lugar de `127.0.0.1`. ¿Qué se rompe si en cambio agregás el FQDN a la línea `127.0.0.1 localhost`, y por qué `127.0.1.1` (en lugar de la dirección real de LAN) es la opción más segura en un cliente DHCP?
- **Q1.4** — `nmcli general hostname lab-node02` — ¿qué archivo modifica en última instancia ese comando, y a través de qué servicio D-Bus?

---

## Ejercicio 2 — El orden del resolver: `/etc/nsswitch.conf` vs `/etc/resolv.conf`

1. Inspeccioná la política de resolución de nombres:

   ```bash
   grep -E '^(hosts|networks):' /etc/nsswitch.conf
   ```

   ```
   hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname
   networks:       files
   ```

2. Agregá un registro exclusivo del archivo de hosts:

   ```bash
   echo '198.51.100.77  lab-alias.lab.example.internal lab-alias' >> /etc/hosts
   ```

3. Consultalo de dos maneras distintas y compará:

   ```bash
   getent hosts lab-alias
   dig +short lab-alias.lab.example.internal
   ```

   ```
   198.51.100.77   lab-alias.lab.example.internal lab-alias
   
   ```

4. Deshabilitá temporalmente la fuente `files`. Cambiá la línea `hosts:` a:

   ```
   hosts:          dns myhostname
   ```

   después volvé a consultar — sin reiniciar demonios, sin vaciar cachés:

   ```bash
   getent hosts lab-alias
   echo "exit=$?"
   ```

   ```
   exit=2
   ```

5. Restaurá la línea `hosts:` original y verificá:

   ```bash
   getent hosts lab-alias >/dev/null && echo restored
   ```

6. Ejercitá la sintaxis de acciones. Poné:

   ```
   hosts:          files [SUCCESS=continue] dns myhostname
   ```

   ```bash
   getent hosts lab-alias
   ```

   ```
   198.51.100.77   lab-alias.lab.example.internal lab-alias
   ```

   Después volvé a restaurar la línea original.

7. Probá el módulo `myhostname` sin DNS en absoluto:

   ```bash
   getent hosts lab-node01
   getent hosts _gateway
   ```

**Comprobá tu comprensión**

- **Q2.1** — `getent hosts` encontró el alias y `dig` no. Explicá con precisión qué biblioteca usa cada herramienta y qué archivo de configuración gobierna a cada una.
- **Q2.2** — ¿Qué significa `[NOTFOUND=return]`, y qué cambiaría si fuera `[NOTFOUND=continue]`? Nombrá las cuatro claves de estado y las cuatro acciones disponibles en esa sintaxis de corchetes.
- **Q2.3** — Editar `/etc/nsswitch.conf` tuvo efecto inmediato para un `getent` nuevo, pero un demonio de larga duración siguió resolviendo del modo anterior. ¿Por qué — y cuál es la regla general sobre cuándo se lee la configuración NSS?
- **Q2.4** — `myhostname` aparece *después* de `dns` en Debian y *antes* en algunas otras distribuciones. Dá un modo de falla concreto causado por cada ordenamiento.

---

## Ejercicio 3 — ¿Quién escribe `/etc/resolv.conf`?

1. Determiná si el archivo es real, un symlink, o generado:

   ```bash
   ls -l /etc/resolv.conf
   head -5 /etc/resolv.conf
   ```

   Tres resultados comunes:

   ```
   # (a) systemd-resolved stub
   lrwxrwxrwx 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
   nameserver 127.0.0.53
   options edns0 trust-ad
   search lab.example.internal
   ```

   ```
   # (b) NetworkManager writing the file directly
   -rw-r--r-- 1 root root 112 Aug 12 09:14 /etc/resolv.conf
   # Generated by NetworkManager
   search lab.example.internal
   nameserver 192.168.122.1
   ```

   ```
   # (c) openresolv / resolvconf
   lrwxrwxrwx 1 root root 29 Aug 12 09:14 /etc/resolv.conf -> /run/resolvconf/resolv.conf
   ```

2. Si `systemd-resolved` está activo, inspeccioná los servidores upstream reales detrás del stub:

   ```bash
   resolvectl status
   ```

   ```
   Global
          Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
   resolv.conf mode: stub

   Link 2 (enp1s0)
       Current Scopes: DNS
            Protocols: +DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
   Current DNS Server: 192.168.122.1
          DNS Servers: 192.168.122.1
           DNS Domain: lab.example.internal
   ```

3. Demostrá el antipatrón. Editá el archivo a mano y después forzá al demonio dueño a reescribirlo:

   ```bash
   sed -i '1i nameserver 203.0.113.53' /etc/resolv.conf
   head -2 /etc/resolv.conf
   systemctl restart NetworkManager    # or: systemctl restart systemd-resolved
   sleep 2
   head -3 /etc/resolv.conf
   ```

   La línea agregada a mano desapareció.

4. Hacé que una opción del resolver sea persistente *de la manera soportada* (host con NetworkManager):

   ```bash
   nmcli connection modify "$(nmcli -g NAME connection show --active | head -1)" \
        ipv4.dns-options "timeout:2,attempts:2,rotate"
   nmcli connection up "$(nmcli -g NAME connection show --active | head -1)"
   grep ^options /etc/resolv.conf
   ```

   ```
   options timeout:2 attempts:2 rotate edns0 trust-ad
   ```

5. Inspeccioná la política de backend DNS de NetworkManager:

   ```bash
   grep -rE '^\s*dns\s*=' /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/ 2>/dev/null
   ```

**Comprobá tu comprensión**

- **Q3.1** — Tu línea `nameserver` editada a mano desapareció después de reiniciar un servicio. Enumerá los cuatro candidatos a dueño de `/etc/resolv.conf` cubiertos arriba y la prueba de un solo comando que identifica cuál manda en un host dado.
- **Q3.2** — `/etc/resolv.conf` contiene solamente `nameserver 127.0.0.53`, y sin embargo las consultas llegan a un servidor upstream en la LAN. Explicá el camino de los datos, y explicá por qué `dig @127.0.0.53` y `dig @192.168.122.1` pueden devolver respuestas distintas para el mismo nombre.
- **Q3.3** — ¿Cuál es la diferencia práctica entre `search` y `domain` en `resolv.conf`, y qué cambia `ndots:` respecto de cuándo se consulta la lista de búsqueda?
- **Q3.4** — Dá las dos maneras *legítimas* de fijar permanentemente un resolver estático en un host gestionado por NetworkManager, y enunciá el compromiso de cada una.

---

## Ejercicio 4 — NetworkManager: perfiles persistentes con `nmcli`

Usamos un dispositivo `dummy` para que nada de lo que hagas pueda dejarte varado en tu sesión.

1. Creá el perfil de conexión — NetworkManager crea el dispositivo por sí mismo:

   ```bash
   nmcli connection add type dummy ifname lpic0 con-name lab-dummy
   ```

   ```
   Connection 'lab-dummy' (3a5d1e2c-7b4f-4e2a-9c8d-1f0b6a3e5d94) successfully added.
   ```

2. Configurá direccionamiento estático de doble pila, DNS, una ruta estática y — crucialmente — **ninguna ruta por defecto**:

   ```bash
   nmcli connection modify lab-dummy \
        ipv4.method manual \
        ipv4.addresses 192.0.2.10/24 \
        ipv4.dns 192.0.2.53 \
        ipv4.dns-search lab.example.internal \
        ipv4.dns-priority 200 \
        ipv4.never-default yes \
        +ipv4.routes "198.51.100.0/24 192.0.2.1 100" \
        ipv6.method manual \
        ipv6.addresses 2001:db8:cafe::10/64 \
        ipv6.never-default yes \
        connection.autoconnect yes
   ```

3. Activá y verificá el resultado en tiempo de ejecución:

   ```bash
   nmcli connection up lab-dummy
   ip -br addr show lpic0
   ip -4 route show dev lpic0
   ```

   ```
   Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/4)
   lpic0            UNKNOWN        192.0.2.10/24 2001:db8:cafe::10/64 fe80::9c4b:1eff:fe33:20a1/64
   192.0.2.0/24 proto kernel scope link src 192.0.2.10
   198.51.100.0/24 via 192.0.2.1 proto static metric 100
   ```

4. Leé el perfil de vuelta a través de la API, y después desde el disco:

   ```bash
   nmcli -f ipv4.addresses,ipv4.routes,ipv4.dns,connection.autoconnect connection show lab-dummy
   ls -l /etc/NetworkManager/system-connections/
   cat /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   ```

   ```
   -rw------- 1 root root 372 Aug 27 11:02 lab-dummy.nmconnection
   ```

   ```ini
   [connection]
   id=lab-dummy
   uuid=3a5d1e2c-7b4f-4e2a-9c8d-1f0b6a3e5d94
   type=dummy
   autoconnect=true
   interface-name=lpic0

   [dummy]

   [ipv4]
   address1=192.0.2.10/24
   dns=192.0.2.53;
   dns-priority=200
   dns-search=lab.example.internal;
   method=manual
   never-default=true
   route1=198.51.100.0/24,192.0.2.1,100

   [ipv6]
   addr-gen-mode=default
   address1=2001:db8:cafe::10/64
   method=manual
   never-default=true

   [proxy]
   ```

5. Editá el keyfile a mano y hacé que NetworkManager lo note:

   ```bash
   sed -i 's/^dns=192.0.2.53;/dns=192.0.2.53;198.51.100.53;/' \
       /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   nmcli -f ipv4.dns connection show lab-dummy      # still the OLD value
   nmcli connection reload
   nmcli -f ipv4.dns connection show lab-dummy      # now updated
   nmcli connection up lab-dummy
   ```

6. Demostrá la persistencia — reiniciá, después volvé a verificar:

   ```bash
   systemctl reboot
   # after login:
   ip -br addr show lpic0
   nmcli -f NAME,DEVICE,STATE connection show --active | grep lab-dummy
   ```

7. Contrastá un perfil *persistente* con una anulación *transitoria* a nivel de dispositivo:

   ```bash
   resolvectl dns lpic0 203.0.113.53      # runtime only, if systemd-resolved is the backend
   nmcli connection up lab-dummy          # profile reasserts itself
   ```

**Comprobá tu comprensión**

- **Q4.1** — ¿Por qué este laboratorio prohíbe configurar `ipv4.gateway` en la interfaz dummy, y qué previene exactamente `ipv4.never-default yes`?
- **Q4.2** — Después de editar el keyfile a mano, `nmcli connection show` seguía reportando el servidor DNS viejo. Explicá el modelo de dos capas (plugin en disco vs configuración en memoria) y nombrá el comando que las reconcilia. ¿Qué comando, en cambio, habría *sobrescrito* tu edición?
- **Q4.3** — ¿Cuál es la diferencia entre `nmcli connection modify ipv4.dns 1.1.1.1` y `nmcli connection modify +ipv4.dns 1.1.1.1`? ¿Qué hace el prefijo `-`?
- **Q4.4** — `connection.autoconnect` está en `yes` y el dispositivo existe, pero el perfil no levanta en el arranque. Dá tres causas independientes, y el comando que distingue cada una.
- **Q4.5** — `ipv4.dns-priority 200`: ¿qué significa un número *más bajo*, y en qué escenario decide esta opción qué servidor termina primero en `resolv.conf`?

---

## Ejercicio 5 — ifupdown de Debian: `/etc/network/interfaces`

Ejecutá este ejercicio en un sistema de la familia Debian con el paquete `ifupdown`. Primero, evitá que NetworkManager pelee por el dispositivo.

1. Marcá el dispositivo de laboratorio como no gestionado por NetworkManager:

   ```bash
   cat > /etc/NetworkManager/conf.d/99-lab-unmanaged.conf <<'EOF'
   [keyfile]
   unmanaged-devices=interface-name:lpic1
   EOF
   nmcli general reload
   ```

2. Confirmá que la directiva de inclusión está presente en el archivo principal:

   ```bash
   grep -n 'source' /etc/network/interfaces
   ```

   ```
   3:source /etc/network/interfaces.d/*
   ```

3. Creá una estrofa drop-in. **Notá que el nombre de archivo no tiene punto ni guion** — las reglas de inclusión al estilo `run-parts` ignoran archivos con extensiones en algunas configuraciones, así que usá un nombre simple:

   ```bash
   cat > /etc/network/interfaces.d/lpic1 <<'EOF'
   # Lab interface for LPIC-1 objective 109.2
   auto lpic1
   iface lpic1 inet static
       address 198.51.100.10/24
       dns-nameservers 198.51.100.53
       dns-search lab.example.internal
       pre-up  ip link show lpic1 >/dev/null 2>&1 || ip link add lpic1 type dummy
       post-up ip route add 203.0.113.0/24 via 198.51.100.1 dev lpic1
       pre-down ip route del 203.0.113.0/24 via 198.51.100.1 dev lpic1 || true
       post-down ip link del lpic1 || true

   iface lpic1 inet6 static
       address 2001:db8:beef::10/64
   EOF
   ```

4. Hacé una prueba en seco del parser antes de aplicarlo:

   ```bash
   ifquery lpic1
   ifquery --list --allow=auto
   ```

   ```
   address: 198.51.100.10/24
   dns-nameservers: 198.51.100.53
   dns-search: lab.example.internal
   ...
   ```

5. Levantala e inspeccioná:

   ```bash
   ifup lpic1
   ip -br addr show lpic1
   ip -4 route show dev lpic1
   ifquery --state lpic1
   cat /run/network/ifstate
   ```

   ```
   lpic1            UNKNOWN        198.51.100.10/24 2001:db8:beef::10/64 fe80::4c6a:5eff:fe91:11c3/64
   198.51.100.0/24 proto kernel scope link src 198.51.100.10
   203.0.113.0/24 via 198.51.100.1 dev lpic1
   lpic1=lpic1
   ```

6. Probá la idempotencia y el camino de bajada:

   ```bash
   ifup lpic1
   ```

   ```
   ifup: interface lpic1 already configured
   ```

   ```bash
   ifdown lpic1
   ip link show lpic1
   ```

   ```
   Device "lpic1" does not exist.
   ```

7. Reiniciá y confirmá que la interfaz vuelve sin ningún comando manual:

   ```bash
   systemctl reboot
   # after login:
   ip -br addr show lpic1
   ```

8. Examiná la plomería de `dns-nameservers`:

   ```bash
   ls /etc/resolvconf/ 2>/dev/null || echo "resolvconf not installed"
   grep -R 198.51.100.53 /etc/resolv.conf /run/resolvconf/ 2>/dev/null
   ```

**Comprobá tu comprensión**

- **Q5.1** — Distinguí `auto lpic1`, `allow-hotplug lpic1`, y una estrofa que no tenga ninguno de los dos. ¿Cuál levanta la interfaz cuando se enchufa una NIC USB después del arranque, y sobre cuál actúa `ifup -a`?
- **Q5.2** — Ordená los cinco tipos de hooks (`pre-up`, `up`/`post-up`, `down`/`pre-down`, `post-down`) en relación con la configuración de direcciones, y explicá por qué la ruta se agregó en `post-up` y no en `pre-up`.
- **Q5.3** — `dns-nameservers` está en la estrofa pero `/etc/resolv.conf` nunca cambia. ¿Qué componente falta, y cuál es la cadena exacta desde la estrofa hasta el archivo?
- **Q5.4** — `ifdown lpic1` devuelve "interface lpic1 not configured" aunque la dirección claramente está presente en `ip addr`. ¿Qué archivo consultó ifupdown para llegar a esa conclusión, y cómo recuperás la interfaz de forma limpia?
- **Q5.5** — La estrofa declara tanto `inet static` como `inet6 static` para la misma interfaz. ¿Cuántas familias de direcciones configura un solo `ifup lpic1`, y cómo levantarías solamente IPv6?

---

## Ejercicio 6 — systemd-networkd: `.netdev`, `.network`, y orden de coincidencia

1. Habilitá la pila (solo en un host donde NetworkManager *no* esté gestionando el dispositivo de laboratorio):

   ```bash
   systemctl enable --now systemd-networkd
   systemctl is-active systemd-networkd
   ```

2. Declará el dispositivo virtual:

   ```bash
   cat > /etc/systemd/network/10-lpic2.netdev <<'EOF'
   [NetDev]
   Name=lpic2
   Kind=dummy
   EOF
   ```

3. Declará su direccionamiento:

   ```bash
   cat > /etc/systemd/network/10-lpic2.network <<'EOF'
   [Match]
   Name=lpic2

   [Network]
   Address=203.0.113.10/24
   Address=2001:db8:f00d::10/64
   DNS=203.0.113.53
   Domains=~lab.example.internal
   IPv6AcceptRA=no
   LinkLocalAddressing=ipv6

   [Route]
   Destination=192.0.2.0/24
   Gateway=203.0.113.1
   Metric=200
   EOF
   chmod 0644 /etc/systemd/network/10-lpic2.netdev /etc/systemd/network/10-lpic2.network
   ```

4. Aplicá sin reiniciar el demonio (systemd ≥ 244):

   ```bash
   networkctl reload
   networkctl status lpic2
   ```

   ```
   ● 5: lpic2
                      Link File: /usr/lib/systemd/network/99-default.link
                   Network File: /etc/systemd/network/10-lpic2.network
                          State: routable (configured)
                   Online state: online
                           Type: ether
                          Kind: dummy
                        Address: 203.0.113.10
                                 2001:db8:f00d::10
                                 fe80::30c1:9aff:fe7d:4e02
                            DNS: 203.0.113.53
                 Search Domains: ~lab.example.internal
   ```

5. Verificá la ruta y el alcance del resolver:

   ```bash
   ip -4 route show dev lpic2
   resolvectl domain lpic2
   resolvectl dns lpic2
   ```

   ```
   203.0.113.0/24 proto kernel scope link src 203.0.113.10
   192.0.2.0/24 via 203.0.113.1 proto static metric 200
   Link 5 (lpic2): ~lab.example.internal
   Link 5 (lpic2): 203.0.113.53
   ```

6. Demostrá la precedencia léxica. Creá una segunda coincidencia, más amplia:

   ```bash
   cat > /etc/systemd/network/05-catchall.network <<'EOF'
   [Match]
   Name=lpic*

   [Network]
   Address=10.99.99.99/24
   EOF
   networkctl reload
   networkctl status lpic2 | grep 'Network File'
   ```

   ```
                   Network File: /etc/systemd/network/05-catchall.network
   ```

7. Eliminá el catch-all y restaurá el comportamiento correcto:

   ```bash
   rm /etc/systemd/network/05-catchall.network
   networkctl reload
   networkctl status lpic2 | grep 'Network File'
   ```

8. Listá cada enlace y su veredicto:

   ```bash
   networkctl list
   ```

   ```
   IDX LINK   TYPE     OPERATIONAL SETUP
     1 lo     loopback carrier     unmanaged
     2 enp1s0 ether    routable    unmanaged
     5 lpic2  ether    routable    configured
   ```

**Comprobá tu comprensión**

- **Q6.1** — Solo un archivo `.network` se aplica a un enlace dado. Enunciá la regla de selección exactamente, y explicá por qué `05-catchall.network` le ganó a `10-lpic2.network` aunque este último coincidía de forma más específica.
- **Q6.2** — ¿Qué significa `SETUP: unmanaged` para `enp1s0` en el paso 8, y por qué ese es el resultado *correcto* en un host donde NetworkManager es dueño de esa NIC?
- **Q6.3** — Nombrá los tres tipos de unidad que systemd-networkd lee de `/etc/systemd/network/` y enunciá la responsabilidad única de cada uno.
- **Q6.4** — ¿Cuál es la diferencia entre `Domains=lab.example.internal` y `Domains=~lab.example.internal` en el comportamiento del resolver?
- **Q6.5** — Compará `networkctl reload`, `networkctl reconfigure lpic2` y `systemctl restart systemd-networkd` en términos de radio de impacto. ¿Cuál ejecutarías en un host de producción al que llegás por SSH a través de la interfaz que estás cambiando?

---

## Ejercicio 7 — Coexistencia, conflictos y práctica de diagnóstico

Ahora tenés hasta tres pilas en un solo host. Este ejercicio inyecta tres fallas realistas y te pide aislar cada una a partir de la evidencia, no de la memoria.

### Falla A — el keyfile invisible

1. Rompé los permisos y recargá:

   ```bash
   chmod 0644 /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   nmcli connection reload
   nmcli -f NAME,DEVICE connection show | grep lab-dummy || echo "profile gone"
   ```

2. Leé el relato del propio demonio (el texto exacto varía según la versión de NetworkManager):

   ```bash
   journalctl -u NetworkManager -n 30 --no-pager | grep -i keyfile
   ```

   ```
   NetworkManager[812]: <warn>  [1756...] keyfile: load: "/etc/NetworkManager/system-connections/lab-dummy.nmconnection": file permissions (644) are insecure, ignoring file
   ```

3. Reparalo y confirmá la recuperación:

   ```bash
   chmod 0600 /etc/NetworkManager/system-connections/lab-dummy.nmconnection
   nmcli connection reload
   nmcli -f NAME,DEVICE connection show | grep lab-dummy
   ```

### Falla B — el error de tipeo en `[Match]`

1. Inyectala:

   ```bash
   sed -i 's/^Name=lpic2$/Name=lpci2/' /etc/systemd/network/10-lpic2.network
   networkctl reload
   networkctl status lpic2 | grep -E 'Network File|State'
   ```

   ```
                   Network File: n/a
                          State: off (unmanaged)
   ```

2. Diagnosticá, después reparalo:

   ```bash
   grep -rn '^Name=' /etc/systemd/network/
   sed -i 's/^Name=lpci2$/Name=lpic2/' /etc/systemd/network/10-lpic2.network
   networkctl reload
   networkctl status lpic2 | grep State
   ```

### Falla C — dos dueños, una interfaz

1. Devolvé el dispositivo gestionado por ifupdown a NetworkManager y observá la contienda:

   ```bash
   rm /etc/NetworkManager/conf.d/99-lab-unmanaged.conf
   nmcli general reload
   ifup lpic1
   nmcli device status | grep lpic1
   ip -br addr show lpic1
   ```

   ```
   lpic1   ethernet  connected  Wired connection 2
   lpic1            UNKNOWN        198.51.100.10/24 169.254.x.x/16 ...
   ```

2. Restaurá la propiedad única:

   ```bash
   nmcli device set lpic1 managed no
   cat > /etc/NetworkManager/conf.d/99-lab-unmanaged.conf <<'EOF'
   [keyfile]
   unmanaged-devices=interface-name:lpic1
   EOF
   nmcli general reload
   nmcli device status | grep lpic1
   ```

   ```
   lpic1   ethernet  unmanaged  --
   ```

**Comprobá tu comprensión**

- **Q7.1** — La Falla A no produjo *ningún error* de `nmcli connection reload`; el perfil simplemente dejó de existir. ¿Cuál es la justificación de seguridad de ese comportamiento, y qué fuente de logs es autoritativa cuando `nmcli` calla?
- **Q7.2** — En la Falla B, `networkctl status` reportó `Network File: n/a`. ¿Por qué ese mensaje es estrictamente más útil que "interfaz caída", y qué prueba acerca de dónde *no* está la falla?
- **Q7.3** — En la Falla C, la interfaz terminó con una dirección estática y además una dirección link-local `169.254.0.0/16`. Reconstruí la secuencia de eventos que produce esa combinación específica.
- **Q7.4** — Compará los tres mecanismos para excluir un dispositivo de NetworkManager: `nmcli device set <dev> managed no`, `unmanaged-devices=` en `conf.d`, y `NM_CONTROLLED=no` en un archivo ifcfg heredado. ¿Cuáles sobreviven un reinicio, y cuáles sobreviven un reinicio de NetworkManager?
- **Q7.5** — Escribí la regla de una línea que pondrías en un runbook para decidir qué pila es dueña de una interfaz dada en un host desconocido.

---

## Ejercicio 8 — Limpieza y verificación final

1. Eliminá todo lo creado arriba:

   ```bash
   nmcli connection delete lab-dummy
   rm -f /etc/systemd/network/10-lpic2.netdev /etc/systemd/network/10-lpic2.network
   networkctl reload
   ifdown lpic1 2>/dev/null
   rm -f /etc/network/interfaces.d/lpic1
   rm -f /etc/NetworkManager/conf.d/99-lab-unmanaged.conf
   nmcli general reload
   sed -i '/lab-alias/d' /etc/hosts
   ```

2. Diferenciá el estado en vivo contra la línea base que capturaste en el Ejercicio 0:

   ```bash
   ip -br addr show | diff /root/baseline-addr.txt - && echo "addresses restored"
   ip -4 route show | diff /root/baseline-route4.txt - && echo "IPv4 routes restored"
   ip -6 route show | diff /root/baseline-route6.txt - && echo "IPv6 routes restored"
   ```

3. Reiniciá y diferenciá una vez más — un diff limpio *antes* del reinicio pero sucio *después* significa que se pasó por alto un artefacto persistente:

   ```bash
   systemctl reboot
   # after login:
   ip -br addr show | diff /root/baseline-addr.txt -
   ```

**Comprobá tu comprensión**

- **Q8.1** — ¿Por qué el diff posterior al reinicio es el único que realmente prueba que la limpieza tuvo éxito?
- **Q8.2** — Borraste `10-lpic2.netdev` pero el dispositivo `lpic2` sigue presente hasta el reinicio. Explicá por qué, y dá el comando que lo elimina inmediatamente.
- **Q8.3** — Escribí la lista de verificación de cuatro archivos que inspeccionarías, en orden, para documentar por completo la configuración de red persistente de un host Linux desconocido en una auditoría.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1** — En Debian, `networking.service` (ifupdown) y `NetworkManager.service` coexisten habitualmente: ifupdown maneja las interfaces declaradas en `/etc/network/interfaces` y NetworkManager maneja todo lo demás, precisamente porque el plugin ifupdown de NetworkManager por defecto deja esos dispositivos en paz. Se convierte en un bug en el momento en que **ambas pilas reclaman la misma interfaz** — evidencia: una interfaz listada en `/etc/network/interfaces` que además aparece como `connected` (no `unmanaged`) en `nmcli device status`.

**A0.2** — (1) Un reinicio — la tabla de direcciones del kernel está enteramente en memoria. (2) Cualquier acción que vacíe o vuelva a ejecutar la configuración de ese enlace: `ip addr flush`, `ifdown`/`ifup`, `nmcli connection up`, `networkctl reconfigure`, una renovación de lease DHCP que reemplace la dirección, o un reinicio del demonio gestor. `systemctl restart sshd` no toca nada de eso — reinicia un demonio de espacio de usuario no relacionado y nunca habla con la tabla de direcciones de netlink, así que sobrevivirlo no demuestra nada.

**A0.3** — (1) A la estrofa le falta `auto`/`allow-hotplug`, así que `ifup -a` nunca la levantó y NetworkManager configuró el dispositivo en su lugar — prueba: `ifquery --list --allow=auto` (la interfaz va a estar ausente) más `nmcli device status`. (2) `networking.service` está deshabilitado o falló, así que el archivo nunca se lee — prueba: `systemctl status networking`. Una tercera posibilidad que vale la pena revisar: la estrofa nombra un nombre de interfaz predecible (`enp1s0`) que ya no coincide con el nombre real del kernel — prueba: `ip -br link`.

### Ejercicio 1

**A1.1** — El **static** sobrevive al reinicio, guardado en `/etc/hostname`. El **transient** (valor `CONFIG_HOSTNAME` del kernel, típicamente puesto por un cliente DHCP o por `hostname(1)`) se pierde al reiniciar y solo se usa cuando el hostname static no está definido o es `localhost`. El **pretty** — una etiqueta UTF-8 de forma libre — sobrevive al reinicio en `/etc/machine-info` como `PRETTY_HOSTNAME=` y nunca se usa para networking.

**A1.2** — `hostname -f` no lee ningún archivo de hostname. Toma el nombre de nodo actual y lo resuelve a través de la base de datos `hosts` de NSS (llamada de la familia `gethostbyname`), devolviendo el nombre canónico del primer resultado. La falla vino de NSS: ninguna entrada de `files` coincidió con `lab-node01` y DNS tampoco tenía registro para él, así que la búsqueda devolvió "no encontrado". Definir el hostname static cambia lo que se *pregunta*, no lo que *responde*.

**A1.3** — Si agregás el FQDN a la línea `127.0.0.1 localhost`, el nombre canónico de `127.0.0.1` pasa a ser el FQDN, así que el software que resuelve inversamente el loopback (servidores de correo, algunos demonios RPC y de clúster) ve el nombre público del host adosado a `localhost`, lo que rompe las verificaciones de HELO/identidad y confunde a los consumidores de `hostname -f`. `127.0.1.1` le da al FQDN una dirección de loopback dedicada sin perturbar `localhost`. Usar la dirección real de LAN es incorrecto en un cliente DHCP porque la dirección cambia y la línea obsoleta de `/etc/hosts` entonces resuelve el propio nombre de la máquina a una dirección que ya no le pertenece — una fuente difícil de rastrear de fallas de auto-conexión.

**A1.4** — Escribe `/etc/hostname`, indirectamente: `nmcli` envía una solicitud D-Bus a NetworkManager, que la reenvía a `systemd-hostnamed` (`org.freedesktop.hostname1`), y ese servicio es el único escritor del archivo. Es el mismo camino que usa `hostnamectl`.

### Ejercicio 2

**A2.1** — `getent hosts` llama al resolver NSS de glibc (módulos `libnss_*`), guiado por `/etc/nsswitch.conf`; como `files` está listado ahí, se consulta `/etc/hosts`. `dig` es una herramienta del protocolo DNS de las utilidades BIND: evita NSS por completo, lee solo `/etc/resolv.conf` para su servidor por defecto y envía una consulta DNS real. `/etc/hosts` le es invisible por diseño. (`host` y `nslookup` se comportan igual; `ping` y `curl` usan NSS.)

**A2.2** — `[NOTFOUND=return]` significa: si la fuente anterior respondió autoritativamente "este nombre no existe", detené la búsqueda y devolvé ese resultado en lugar de probar fuentes posteriores. Con `continue`, el resolver caería a la siguiente fuente (por ejemplo `dns`) tras una respuesta negativa. Claves de estado: `SUCCESS`, `NOTFOUND`, `UNAVAIL`, `TRYAGAIN` (cada una puede negarse con `!`). Acciones: `return`, `continue`, `merge` (glibc ≥ 2.24, válida para `SUCCESS`), y el valor por defecto implícito según el estado.

**A2.3** — glibc lee `/etc/nsswitch.conf` cuando la maquinaria NSS se inicializa por primera vez en un proceso y cachea la configuración parseada por toda la vida de ese proceso; `getent` es un proceso nuevo cada vez, así que ve el cambio de inmediato. Un demonio de larga duración conserva su configuración cacheada (y, si hay cacheo de `nscd`/`systemd-resolved` en juego, también las respuestas cacheadas) hasta que se reinicia. Regla general: los cambios de configuración NSS se aplican a procesos recién iniciados; los existentes deben reiniciarse.

**A2.4** — `myhostname` **después** de `dns`: si una zona DNS contiene un registro obsoleto para el hostname local, la máquina resuelve su propio nombre a la dirección equivocada — el fallback local nunca se consulta. `myhostname` **antes** de `dns`: un registro DNS legítimo para el propio nombre del host (por ejemplo su dirección pública de servicio en una zona de horizonte dividido) queda tapado por la respuesta sintética del módulo, así que el host se alcanza a sí mismo por loopback/link-local cuando debería haber usado la dirección ruteada.

### Ejercicio 3

**A3.1** — Candidatos: (a) `systemd-resolved`, (b) NetworkManager escribiendo el archivo directamente, (c) `resolvconf`/`openresolv`, (d) un archivo estático mantenido a mano. Prueba de identificación: `ls -l /etc/resolv.conf` — un symlink hacia `/run/systemd/resolve/` significa resolved, un symlink hacia `/run/resolvconf/` o `/run/NetworkManager/` nombra al dueño directamente, y un archivo regular cuya primera línea es `# Generated by NetworkManager` identifica a NetworkManager. Si es un archivo plano sin encabezado de generador, contrastá con `grep -rE '^\s*dns\s*=' /etc/NetworkManager/` buscando `dns=none`.

**A3.2** — `127.0.0.53:53` es el **stub listener** de `systemd-resolved`. Las aplicaciones envían consultas DNS ordinarias ahí a través de NSS o de la biblioteca del resolver; resolved aplica su configuración por enlace (dominios de búsqueda, dominios de ruteo, política DNSSEC/DoT, caché) y las reenvía al servidor upstream que aprendió de la configuración del enlace. Por lo tanto `dig @127.0.0.53` ejercita toda la pila de políticas de resolved incluyendo su caché y el cacheo negativo, mientras que `dig @192.168.122.1` la evita y le pregunta al upstream directamente — respuestas distintas revelan una caché obsoleta, una regla de dominio de ruteo que manda la consulta al servidor de otro enlace, o una falla de validación DNSSEC dentro de resolved.

**A3.3** — `domain` define un **único** dominio por defecto que se agrega a los nombres no calificados; `search` define una **lista** ordenada (hasta 6 entradas, 256 caracteres en total en glibc) que se prueba en secuencia. Son mutuamente excluyentes — gana la última que aparezca en el archivo. `ndots:N` fija el umbral: una consulta que contenga **menos de N** puntos se prueba primero contra la lista de búsqueda; con N o más se prueba primero como nombre absoluto. El valor por defecto es `ndots:1`, que es la razón por la cual `host.lab` (un punto) se envía como absoluto antes de usar la lista de búsqueda.

**A3.4** — (1) Poner los servidores en el perfil de conexión: `nmcli connection modify <name> ipv4.dns <ip>` más `ipv4.ignore-auto-dns yes` — compromiso: correcto y por enlace, pero hay que repetirlo para cada perfil que pueda estar activo. (2) Definir `dns=none` en `/etc/NetworkManager/NetworkManager.conf` y mantener `/etc/resolv.conf` vos mismo (o apuntarlo a tu propio archivo) — compromiso: un único lugar autoritativo, pero perdés el DNS por enlace por completo, incluido el split-DNS de VPN, y los servidores provistos por DHCP se ignoran en todas las interfaces.

### Ejercicio 4

**A4.1** — Un gateway en la conexión instala una **ruta por defecto** a través de un dispositivo que descarta todos los paquetes; según la métrica puede ganarle a tu ruta por defecto real y hacer un agujero negro con todo el tráfico, incluida la sesión SSH desde la que estás trabajando. `ipv4.never-default yes` le dice a NetworkManager que nunca instale una ruta por defecto desde este perfil, aunque la ofrezca DHCP o esté configurada — las rutas on-link y estáticas de la interfaz siguen aplicándose.

**A4.2** — NetworkManager mantiene la configuración de las conexiones en memoria, poblada por los plugins de settings (`keyfile` leyendo `/etc/NetworkManager/system-connections/`, más `ifcfg-rh`/`ifupdown` en algunas distribuciones) al arrancar. `nmcli` lee y escribe la copia en memoria por D-Bus; NetworkManager la escribe de vuelta al disco. Editar el archivo directamente cambia solo la copia en disco, así que las dos divergen hasta que `nmcli connection reload` (o `nmcli connection load <file>`) la vuelve a leer. A la inversa, cualquier `nmcli connection modify` antes de recargar habría serializado la configuración obsoleta en memoria de vuelta al disco y **destruido tu edición**.

**A4.3** — `ipv4.dns 1.1.1.1` a secas **reemplaza** todo el valor de la propiedad por esa única entrada. `+ipv4.dns 1.1.1.1` **agrega** a la propiedad multivaluada existente. `-ipv4.dns 1.1.1.1` elimina un valor específico (se puede dar un índice numérico en lugar del valor). Las formas `+`/`-` solo son válidas para propiedades multivaluadas como `ipv4.dns`, `ipv4.addresses`, `ipv4.routes`.

**A4.4** — (1) El perfil está ligado a un dispositivo que no existe en el momento del arranque o cuyo nombre/MAC no coincide con `connection.interface-name` / `802-3-ethernet.mac-address` — distinguilo con `nmcli -f connection.interface-name connection show <name>` contra `ip -br link`. (2) Otro perfil con mayor `connection.autoconnect-priority` reclamó el dispositivo — distinguilo con `nmcli -f NAME,AUTOCONNECT,AUTOCONNECT-PRIORITY,DEVICE connection show`. (3) El dispositivo está no gestionado (`unmanaged-devices=` en `conf.d`, `nmcli device set … managed no`, o el plugin ifupdown) — distinguilo con `nmcli device status`. Una cuarta: la activación falló y `may-fail=false` en una familia que nunca levantó — visible en `journalctl -u NetworkManager -b`.

**A4.5** — Valor numérico más bajo = prioridad **más alta**: los servidores de la conexión con el `dns-priority` más bajo se colocan primero en la configuración del resolver generada. Decide el ordenamiento cada vez que hay más de una conexión activa simultáneamente y cada una aporta servidores DNS — el caso clásico es un perfil de VPN (que normalmente pone una prioridad baja/negativa) frente al perfil de LAN. Un valor negativo además hace que los servidores de esa conexión sean *exclusivos*, suprimiendo por completo a los demás.

### Ejercicio 5

**A5.1** — `auto lpic1` marca la interfaz para ser configurada por `ifup -a`, que es lo que ejecuta `networking.service` en el arranque — se aplica incondicionalmente en ese momento, exista o no el dispositivo todavía. `allow-hotplug lpic1` la marca para ser configurada por `ifup --allow=hotplug` disparado desde una regla de udev, es decir cuando el kernel anuncia el dispositivo — este es el que maneja una NIC USB enchufada después del arranque. Una estrofa sin ninguno de los dos se configura solo con un `ifup lpic1` manual explícito. `ifup -a` actúa solo sobre la clase `auto`.

**A5.2** — Orden: `pre-up` → configuración de direcciones/rutas de la estrofa → `up`/`post-up` (sinónimos), y en el desmontaje `pre-down`/`down` (sinónimos) → desconfiguración de direcciones → `post-down`. La ruta estática se agregó en `post-up` porque requiere que `198.51.100.10/24` ya esté en el enlace — un next hop `via 198.51.100.1` solo es alcanzable una vez que existe la ruta de prefijo on-link, así que el mismo comando en `pre-up` falla con `Error: Nexthop has invalid gateway`. Simétricamente, la ruta se elimina en `pre-down`, antes de que la dirección desaparezca.

**A5.3** — El componente faltante es el paquete `resolvconf` (u `openresolv`). Cadena: `ifup` ejecuta los scripts de hook en `/etc/network/if-up.d/`, uno de los cuales es `000resolvconf`; este canaliza los valores `dns-nameservers`/`dns-search` de la estrofa hacia `resolvconf -a lpic1.inet`; resolvconf fusiona todas las fuentes registradas por orden de interfaz en `/run/resolvconf/resolv.conf`, al cual `/etc/resolv.conf` es un symlink. Sin el paquete, `dns-nameservers` se parsea y luego se descarta en silencio.

**A5.4** — ifupdown consulta su archivo de estado, `/run/network/ifstate` — una interfaz está "configurada" solo si figura ahí, sin importar la tabla de direcciones real del kernel. Un reinicio, un `ip addr add` manual, o un `ifup` que se cayó desincronizan a los dos. Recuperación: `ifup --force lpic1` para volver a marcarla y reconfigurarla, o bajarla explícitamente con `ifdown --force lpic1` primero; en el peor caso, quitá la entrada obsoleta de `/run/network/ifstate` y volvé a ejecutar `ifup`.

**A5.5** — Un `ifup lpic1` configura **ambas** familias: el ifupdown de Debian moderno procesa cada estrofa `iface` que coincida con el nombre y las familias de direcciones solicitadas. Para actuar sobre una sola familia, usá `ifup -6 lpic1` / `ifdown -6 lpic1` (equivalentemente `ifup lpic1=lpic1 --family inet6` en versiones más viejas), o nombrá la estrofa explícitamente con la forma `iface lpic1 inet6` y el selector `--family`.

### Ejercicio 6

**A6.1** — systemd-networkd ordena todos los archivos `*.network` de `/etc/systemd/network/`, `/run/systemd/network/` y `/usr/lib/systemd/network/` por **nombre de archivo en orden léxico** y aplica el **primer archivo cuya sección `[Match]` coincida** con el enlace; todos los archivos restantes se ignoran para ese enlace. La especificidad de la coincidencia es irrelevante. `05-catchall.network` ordena antes que `10-lpic2.network`, coincidió con `lpic*`, y por eso ganó. Exactamente por esto la convención es numerar los archivos con un prefijo de dos dígitos, del más específico al menos.

**A6.2** — `unmanaged` significa que ningún archivo `.network` coincidió con ese enlace, así que systemd-networkd no lo va a tocar — ni lo configura ni lo desconfigura. Ese es el resultado correcto cuando NetworkManager es dueño de `enp1s0`: los dos demonios pueden correr en el mismo host mientras sus conjuntos de coincidencias sean disjuntos. Un `SETUP: configured` en una interfaz que NetworkManager además tiene `connected` es la firma del conflicto.

**A6.3** — `.netdev` — **crea** dispositivos virtuales (dummy, bridge, bond, vlan, veth, wireguard, …); define la existencia, no el direccionamiento. `.network` — **configura** un enlace existente: direcciones, rutas, DHCP, DNS, comportamiento de RA, membresía de bridge/bond. `.link` — **propiedades de capa de enlace aplicadas por udev** cuando aparece el dispositivo: política de nombrado de la interfaz, dirección MAC, MTU, offloads, ajustes de ring/queue. Los archivos `.link` los lee `systemd-udevd`, no networkd, que es la razón por la cual cambiar uno puede requerir regenerar el initramfs para que tenga efecto en el arranque.

**A6.4** — `Domains=lab.example.internal` es un **dominio de búsqueda**: se agrega a los nombres no calificados, *y además* rutea implícitamente las consultas de ese dominio a los servidores de este enlace. `Domains=~lab.example.internal` (prefijo de tilde) es un **dominio solo de ruteo**: nunca se agrega a los nombres no calificados, solo le dice a `systemd-resolved` "mandá las consultas bajo este dominio a los servidores DNS de este enlace". La forma con tilde es la que hace que el split-DNS sobre una VPN funcione sin contaminar la lista de búsqueda; `Domains=~.` rutea *todas* las consultas a ese enlace.

**A6.5** — `networkctl reload` vuelve a leer los archivos de configuración y aplica cambios solo a los enlaces cuya configuración realmente cambió — el menor radio de impacto. `networkctl reconfigure lpic2` reaplica forzosamente la configuración a un enlace nombrado, desconfigurándolo brevemente — acotado, pero disruptivo para ese enlace. `systemctl restart systemd-networkd` reinicia el demonio y reconfigura cada enlace gestionado — el mayor radio de impacto y el que puede tirarte la sesión. En un host de producción alcanzado a través de la interfaz que estás cambiando: `networkctl reload`.

### Ejercicio 7

**A7.1** — Un keyfile puede contener secretos (PSKs, contraseñas 802.1X, credenciales de VPN). NetworkManager se niega a cargar un archivo en `system-connections/` cuyos permisos lo expongan más allá de root, porque cargarlo sería un aval implícito de un archivo que el sistema ya filtró. Saltea el archivo en lugar de fallar ruidosamente para que un único archivo malo no impida cargar el resto de la configuración — que es exactamente por lo que la falla es invisible en la capa de `nmcli`. La fuente autoritativa es el log del demonio: `journalctl -u NetworkManager -b`. Los permisos correctos son `0600`, dueño `root:root`.

**A7.2** — `Network File: n/a` afirma que networkd evaluó su conjunto de archivos y **no encontró configuración coincidente**, lo que localiza la falla en la sección `[Match]` o en la ubicación/nombrado del archivo — y simultáneamente prueba que la falla *no* está en el direccionamiento, en las rutas, en el dispositivo mismo, ni en la salud del demonio. "Interfaz caída" sería consistente con una docena de causas no relacionadas; este mensaje las elimina a todas.

**A7.3** — `ifup lpic1` creó el dispositivo dummy en su hook `pre-up` y le asignó `198.51.100.10/24`. Como la regla `unmanaged-devices` había sido eliminada y NetworkManager había sido recargado, NetworkManager vio un dispositivo nuevo, gestionado, con portadora y sin perfil coincidente, así que aplicó su comportamiento por defecto: auto-crear un perfil `Wired connection N` con `ipv4.method auto`, correr DHCP, no obtener respuesta en un enlace dummy aislado, y caer a la autoconfiguración link-local IPv4 (`169.254.0.0/16`). El resultado es la dirección estática de ifupdown más la dirección link-local de NetworkManager en el mismo enlace — dos dueños, dos direcciones.

**A7.4** — `nmcli device set <dev> managed no` es **solo en tiempo de ejecución**: se pierde al reiniciar y al reiniciar NetworkManager. `unmanaged-devices=` en `/etc/NetworkManager/conf.d/*.conf` (o `NetworkManager.conf`) es **persistente**: sobrevive tanto al reinicio del sistema como al del servicio, y es el mecanismo correcto. `NM_CONTROLLED=no` en un archivo `ifcfg-*` es persistente pero solo en distribuciones que todavía compilan el plugin `ifcfg-rh` (familia RHEL/CentOS, deprecado en RHEL 9+ en favor de los keyfiles) — no tiene efecto en sistemas de la familia Debian.

**A7.5** — "Para la interfaz *X*: ejecutá `nmcli device status`, `networkctl list` e `ifquery --list --allow=auto`; exactamente uno de ellos debe reclamar *X*. El que lo haga es el dueño, y su archivo de configuración es el único lugar donde hacer cambios persistentes; si dos lo reclaman, excluila de todos menos uno antes de cambiar nada."

### Ejercicio 8

**A8.1** — Antes del reinicio las interfaces pueden verse limpias simplemente porque las bajaste en tiempo de ejecución; eso no dice nada sobre lo que queda en disco. Los artefactos persistentes — un `.netdev` remanente, una estrofa `auto` en un drop-in de `interfaces.d`, un perfil con autoconnect — solo vuelven a imponerse cuando el camino de configuración de arranque se ejecuta otra vez. Un diff limpio posterior al reinicio es la única evidencia de que no quedó ningún archivo de configuración atrás.

**A8.2** — Los archivos `.netdev` solo se consultan al crear dispositivos; eliminar el archivo más `networkctl reload` impide que el dispositivo se *recree* en el próximo arranque pero no borra un dispositivo del kernel ya existente, porque networkd no destruye dispositivos virtuales para los que ya no tiene configuración. Eliminalo de inmediato con `ip link del lpic2`.

**A8.3** — En orden: (1) `/etc/hostname` y `/etc/hosts` — identidad del nodo y mapeos estáticos. (2) `/etc/nsswitch.conf` y `/etc/resolv.conf` (incluyendo `ls -l` para identificar a su dueño) — política de resolución y servidores. (3) La configuración de direccionamiento de la pila que sea autoritativa: `/etc/NetworkManager/system-connections/*.nmconnection` + `/etc/NetworkManager/conf.d/`, `/etc/network/interfaces` + `/etc/network/interfaces.d/`, y `/etc/systemd/network/*.{link,netdev,network}`. (4) El estado de los servicios que decide cuál de esos archivos se lee realmente: `systemctl is-enabled NetworkManager systemd-networkd networking`.

</details>

---

## Fuentes

- LPI — Objetivos del examen 101-500 (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Objetivos del examen 102-500, Tema 109 "Networking Fundamentals": <https://www.lpi.org/our-certifications/exam-102-objectives/>
- `hostnamectl(1)` / `hostname(5)` / `machine-info(5)`: <https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html>
- `nsswitch.conf(5)`, NSS de la biblioteca GNU C: <https://www.gnu.org/software/libc/manual/html_node/Name-Service-Switch.html>
- `resolv.conf(5)` — proyecto man-pages: <https://man7.org/linux/man-pages/man5/resolv.conf.5.html>
- `systemd-resolved.service(8)` y `resolvectl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html>
- NetworkManager — `nmcli(1)`, `nm-settings-keyfile(5)`, `NetworkManager.conf(5)`: <https://networkmanager.dev/docs/api/latest/>
- Debian — `interfaces(5)` (ifupdown): <https://manpages.debian.org/stable/ifupdown/interfaces.5.en.html>
- `systemd.network(5)`, `systemd.netdev(5)`, `systemd.link(5)`, `networkctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- RFC 5737 (prefijos IPv4 de documentación) y RFC 3849 (prefijo IPv6 de documentación): <https://www.rfc-editor.org/rfc/rfc5737> · <https://www.rfc-editor.org/rfc/rfc3849>