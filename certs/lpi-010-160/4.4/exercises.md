# Ejercicios guiados — Tema 4.4: Your Computer on the Network

**Certificación:** LPI Linux Essentials (examen 010-160, versión 1.6) · **Peso:** 2
**Referencia:** [learning.lpi.org — Lección 4.4](https://learning.lpi.org/en/learning-materials/010-160/4/4.4/)

Estos ejercicios se ejecutan en una terminal de cualquier distribución Linux moderna. Necesitás los paquetes `iproute2` (comando `ip`, `ss`) y `bind-utils` / `dnsutils` (comandos `host` y `dig`). Ninguno de los pasos modifica la configuración del sistema: todos son comandos de consulta.

---

## Ejercicio 1 — Identificar las interfaces de red y sus direcciones IP

El primer paso para entender cómo tu computadora se conecta a la red es saber qué **network interfaces** tiene y qué direcciones tienen asignadas.

1. Listá todas las interfaces de red del sistema:

   ```bash
   ip link show
   ```

   Observá los nombres de las interfaces. Siempre vas a encontrar una llamada `lo` (la interfaz de **loopback**); las demás pueden llamarse `eth0`, `enp3s0`, `wlan0`, `wlp2s0`, etc., según sean cableadas o inalámbricas.

2. Ahora mostrá las direcciones IP asignadas a cada interfaz:

   ```bash
   ip addr show
   ```

   Buscá las líneas que empiezan con `inet` (direcciones **IPv4**) e `inet6` (direcciones **IPv6**).

3. Repetí la consulta pero solo para la interfaz de loopback:

   ```bash
   ip addr show lo
   ```

   Verificá que su dirección IPv4 es `127.0.0.1/8` y su dirección IPv6 es `::1/128`.

4. Anotá la dirección IPv4 de tu interfaz principal (la que usás para salir a internet), incluyendo el prefijo de red (por ejemplo `192.168.1.42/24`).

**Preguntas de comprensión:**

**1.1.** ¿Para qué sirve la interfaz `lo` y por qué existe aunque la máquina no tenga ninguna placa de red física?

**1.2.** En la salida de `ip addr show`, una interfaz muestra `inet 192.168.1.42/24`. ¿Qué indica el `/24`?

**1.3.** ¿Cuál es la diferencia principal entre una dirección IPv4 y una IPv6 en cuanto a formato y tamaño?

**1.4.** Tu interfaz muestra una dirección `inet6` que empieza con `fe80::`. ¿Ese tipo de dirección sirve para comunicarse con hosts de internet? ¿Por qué?

---

## Ejercicio 2 — Consultar la tabla de rutas y encontrar el default gateway

Para que los paquetes salgan de tu red local hacia internet, tienen que pasar por un **router**. Tu sistema sabe a cuál enviárselos gracias a la **routing table**.

1. Mostrá la tabla de rutas IPv4:

   ```bash
   ip route show
   ```

   Identificá la línea que empieza con `default via ...`. La dirección IP que aparece ahí es tu **default gateway**.

2. Mostrá también la tabla de rutas IPv6:

   ```bash
   ip -6 route show
   ```

3. Compará la dirección del default gateway con la dirección IPv4 de tu interfaz (anotada en el Ejercicio 1). Verificá que ambas pertenecen a la misma red (por ejemplo, ambas empiezan con `192.168.1.`).

4. Buscá en la salida de `ip route show` la línea que describe tu red local (algo como `192.168.1.0/24 dev enp3s0 ...`). Esta ruta le dice al sistema que los hosts de esa red se alcanzan directamente, sin pasar por el router.

**Preguntas de comprensión:**

**2.1.** ¿Qué significa la ruta `default` y cuándo la usa el sistema?

**2.2.** Si tu computadora quiere enviar un paquete a otra máquina de tu misma red local, ¿lo envía a través del default gateway? Justificá con lo que viste en la tabla de rutas.

**2.3.** ¿Qué rangos de direcciones IPv4 están reservados para redes privadas (los que típicamente ves en una red hogareña)?

**2.4.** Tu red hogareña usa direcciones privadas, pero igual podés navegar por internet. ¿Qué mecanismo del router lo hace posible?

---

## Ejercicio 3 — Verificar conectividad con `ping`

`ping` envía paquetes **ICMP echo request** a un host y espera las respuestas (**echo reply**). Es la herramienta básica para diagnosticar conectividad, y conviene usarla "de adentro hacia afuera": primero el gateway, después internet por IP, después internet por nombre.

1. Hacé ping a tu default gateway (reemplazá la IP por la que encontraste en el Ejercicio 2), limitando el envío a 3 paquetes con la opción `-c`:

   ```bash
   ping -c 3 192.168.1.1
   ```

   Observá el tiempo de respuesta (`time=...`) y el resumen final (`0% packet loss`).

2. Hacé ping a un host de internet usando directamente su dirección IP (por ejemplo, el DNS público de Google):

   ```bash
   ping -c 3 8.8.8.8
   ```

3. Ahora hacé ping usando un nombre de dominio:

   ```bash
   ping -c 3 www.lpi.org
   ```

   Fijate que la primera línea de salida muestra la dirección IP a la que se resolvió el nombre.

4. Compará los tiempos de respuesta del paso 1 (red local) con los de los pasos 2 y 3 (internet). Deberían ser notablemente menores en la red local.

**Preguntas de comprensión:**

**3.1.** ¿Qué protocolo utiliza `ping` para comprobar la conectividad?

**3.2.** Supongamos que el paso 2 (`ping 8.8.8.8`) funciona, pero el paso 3 (`ping www.lpi.org`) falla con un error de resolución de nombre. ¿Dónde está el problema: en la conectividad a internet o en otro servicio? ¿En cuál?

**3.3.** ¿Para qué sirve la opción `-c 3`? ¿Qué pasa en Linux si ejecutás `ping` sin ella?

**3.4.** Le hacés `ping` a un servidor y no responde, pero podés abrir su sitio web en el navegador. ¿Cómo se explica?

---

## Ejercicio 4 — Resolución de nombres: DNS, `host` y `dig`

Los humanos usamos nombres (`www.lpi.org`); las redes usan direcciones IP. El **DNS (Domain Name System)** traduce unos en otras. En este ejercicio consultás qué servidores DNS usa tu sistema y hacés resoluciones manuales.

1. Mirá qué servidores DNS tiene configurados tu sistema:

   ```bash
   cat /etc/resolv.conf
   ```

   Las líneas `nameserver` indican las direcciones IP de los servidores DNS que el sistema consulta. (Nota: en sistemas con `systemd-resolved` podés ver `nameserver 127.0.0.53`, que es un servicio local que reenvía las consultas a los DNS reales.)

2. Resolvé un nombre de dominio con `host`:

   ```bash
   host www.lpi.org
   ```

   Anotá las direcciones IPv4 (registros **A**) e IPv6 (registros **AAAA**) que devuelve.

3. Hacé la misma consulta con `dig`, que muestra información más detallada:

   ```bash
   dig www.lpi.org
   ```

   Buscá la sección `ANSWER SECTION` y compará con la salida de `host`.

4. Consultá un servidor DNS distinto del configurado en tu sistema, indicándolo con `@`:

   ```bash
   host www.lpi.org 8.8.8.8
   dig @8.8.8.8 www.lpi.org
   ```

5. Por último, mirá el archivo de resolución local de nombres:

   ```bash
   cat /etc/hosts
   ```

   Verificá que contiene al menos una entrada que asocia `localhost` con `127.0.0.1`.

**Preguntas de comprensión:**

**4.1.** ¿Qué rol cumple el archivo `/etc/resolv.conf`?

**4.2.** ¿Qué diferencia hay entre `/etc/hosts` y el DNS? ¿Cuál se consulta habitualmente primero?

**4.3.** ¿Qué tipo de registro DNS asocia un nombre con una dirección IPv4? ¿Y con una IPv6?

**4.4.** Un compañero cambió los `nameserver` de `/etc/resolv.conf` por direcciones inexistentes. ¿Qué síntomas vas a observar al usar la red? ¿`ping 8.8.8.8` seguiría funcionando?

---

## Ejercicio 5 — Ver conexiones y puertos con `ss`

El comando `ss` (socket statistics) muestra las conexiones de red activas y los puertos en escucha. Es el reemplazo moderno de `netstat`.

1. Mostrá todos los puertos **TCP** en estado de escucha (*listening*), sin resolver nombres:

   ```bash
   ss -tln
   ```

   Las opciones significan: `-t` TCP, `-l` listening, `-n` numérico (no traduce puertos ni direcciones a nombres).

2. Repetí para **UDP**:

   ```bash
   ss -uln
   ```

3. Ahora mostrá las conexiones TCP establecidas (sin `-l`):

   ```bash
   ss -tn
   ```

   Si tenés un navegador abierto, deberías ver conexiones hacia puertos remotos `443` (HTTPS) en estado `ESTAB`.

4. Ejecutá la misma consulta agregando `-p` para ver qué proceso posee cada socket (necesita privilegios para ver procesos de otros usuarios):

   ```bash
   sudo ss -tlnp
   ```

**Preguntas de comprensión:**

**5.1.** ¿Qué diferencia hay entre un socket en estado `LISTEN` y uno en estado `ESTAB`?

**5.2.** En la salida de `ss -tln` ves `127.0.0.1:631`. ¿Desde qué máquinas se puede acceder a ese servicio? ¿Y si en cambio mostrara `0.0.0.0:631`?

**5.3.** ¿Qué diferencia conceptual hay entre **TCP** y **UDP**?

**5.4.** Nombrá el puerto estándar de: SSH, HTTP, HTTPS y DNS.

---

## Ejercicio 6 — Diagnóstico integrado (desafío)

Este ejercicio junta todo lo anterior en una rutina de diagnóstico, la misma secuencia lógica que usarías (y que el examen espera que conozcas) cuando "no anda internet".

1. Ejecutá en orden y anotá el resultado de cada paso:

   ```bash
   ip addr show            # ¿tengo dirección IP?
   ip route show           # ¿tengo default gateway?
   ping -c 3 <gateway>     # ¿llego al router?
   ping -c 3 8.8.8.8       # ¿llego a internet por IP?
   host www.lpi.org        # ¿funciona la resolución DNS?
   ```

2. Escribí en una hoja qué conclusión sacarías si la secuencia falla exactamente en cada punto (falla en el paso 1, falla en el 3, falla en el 4, falla en el 5).

**Preguntas de comprensión:**

**6.1.** La interfaz tiene la dirección `169.254.12.7`. ¿Qué te dice eso sobre la configuración de red de la máquina?

**6.2.** El ping al gateway funciona, el ping a `8.8.8.8` falla. ¿Dónde ubicarías el problema?

**6.3.** ¿Qué servicio suele asignar automáticamente la dirección IP, el default gateway y los servidores DNS en una red hogareña?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1.1.** La interfaz `lo` (loopback) permite que la máquina se comunique consigo misma a través de la pila de red, usando la dirección `127.0.0.1` (IPv4) o `::1` (IPv6). Existe siempre, incluso sin hardware de red, porque muchos servicios locales (bases de datos, servidores de desarrollo, `systemd-resolved`, etc.) se comunican entre sí mediante sockets de red locales.

**1.2.** El `/24` es la notación **CIDR** del prefijo de red: indica que los primeros 24 bits de la dirección identifican la red (`192.168.1.0`) y los 8 bits restantes identifican al host dentro de esa red. Equivale a la máscara `255.255.255.0`.

**1.3.** IPv4 usa direcciones de **32 bits** escritas como cuatro números decimales separados por puntos (por ejemplo `192.168.1.42`). IPv6 usa direcciones de **128 bits** escritas como ocho grupos hexadecimales separados por dos puntos (por ejemplo `2001:db8::1`), lo que da un espacio de direcciones enormemente mayor.

**1.4.** No. Las direcciones que empiezan con `fe80::` son **link-local**: solo son válidas dentro del enlace local (el segmento de red físico) y los routers no las reenvían. Para comunicarse con internet por IPv6 se necesita una dirección global.

### Ejercicio 2

**2.1.** La ruta `default` es la "ruta de último recurso": se usa para todo destino que no coincida con ninguna otra ruta más específica de la tabla. En la práctica, cubre todo el tráfico hacia internet, que se envía al **default gateway** (el router).

**2.2.** No. La tabla de rutas contiene una entrada específica para la red local (por ejemplo `192.168.1.0/24 dev enp3s0`), que indica entrega directa por la interfaz, sin intermediarios. El gateway solo se usa para destinos fuera de la red local.

**2.3.** Los rangos privados definidos en RFC 1918: `10.0.0.0/8`, `172.16.0.0/12` (de `172.16.0.0` a `172.31.255.255`) y `192.168.0.0/16`. Estas direcciones no son enrutables en internet.

**2.4.** **NAT (Network Address Translation)**: el router reemplaza la dirección privada de origen por su propia dirección pública al reenviar los paquetes hacia internet, y hace la traducción inversa con las respuestas.

### Ejercicio 3

**3.1.** **ICMP** (Internet Control Message Protocol), concretamente los mensajes *echo request* y *echo reply*. Para IPv6 se usa ICMPv6 (comando `ping` moderno o `ping6`).

**3.2.** La conectividad a internet está bien (el ping por IP funciona); el problema está en la **resolución de nombres (DNS)**: el sistema no puede traducir `www.lpi.org` a una dirección IP. Habría que revisar `/etc/resolv.conf` o el servidor DNS configurado.

**3.3.** `-c 3` (*count*) limita el envío a 3 paquetes y termina. Sin esa opción, en Linux `ping` envía paquetes indefinidamente hasta que lo interrumpís con `Ctrl+C`.

**3.4.** Muchos servidores y firewalls bloquean o descartan los paquetes ICMP por política de seguridad, pero siguen aceptando tráfico TCP en los puertos 80/443. Por eso la falta de respuesta a `ping` no prueba que un host esté caído.

### Ejercicio 4

**4.1.** `/etc/resolv.conf` le indica al sistema qué servidores DNS usar para resolver nombres, mediante líneas `nameserver` con las IPs de esos servidores (y opcionalmente `search`/`domain` para dominios de búsqueda).

**4.2.** `/etc/hosts` es un archivo local con asociaciones estáticas nombre → IP, definidas a mano en cada máquina. El DNS es un servicio distribuido de red que resuelve nombres para todo internet. Por defecto (según `/etc/nsswitch.conf`), el sistema consulta primero `/etc/hosts` y, si el nombre no está ahí, recurre al DNS.

**4.3.** El registro **A** asocia un nombre con una dirección IPv4; el registro **AAAA** lo asocia con una dirección IPv6.

**4.4.** Todo lo que dependa de nombres de dominio fallaría: la navegación web, `ping www.lpi.org`, `host`, etc., con errores de resolución o timeouts. En cambio, `ping 8.8.8.8` seguiría funcionando, porque usa una IP directa y no necesita DNS. Este contraste es justamente la prueba clásica para diagnosticar un problema de DNS.

### Ejercicio 5

**5.1.** `LISTEN` significa que un proceso local está esperando conexiones entrantes en ese puerto (es un servidor). `ESTAB` (*established*) es una conexión ya establecida entre dos extremos, con tráfico posible en ambos sentidos.

**5.2.** `127.0.0.1:631` significa que el servicio escucha solo en la interfaz de loopback: únicamente procesos de **la misma máquina** pueden conectarse. `0.0.0.0:631` significa que escucha en **todas las interfaces**, por lo que también sería accesible desde otras máquinas de la red (salvo que un firewall lo impida).

**5.3.** **TCP** es orientado a conexión: garantiza entrega, orden y retransmisión de los datos, a costa de más overhead. **UDP** es sin conexión: envía datagramas sin garantía de entrega ni de orden, lo que lo hace más liviano y rápido (usado por DNS, streaming, juegos, etc.).

**5.4.** SSH: **22/TCP** · HTTP: **80/TCP** · HTTPS: **443/TCP** · DNS: **53** (UDP para la mayoría de las consultas, y también TCP).

### Ejercicio 6

**6.1.** `169.254.0.0/16` es el rango **link-local** de IPv4 (APIPA). El sistema se autoasignó esa dirección porque **no consiguió respuesta de un servidor DHCP**: hay un problema con el DHCP de la red o con el enlace hacia él.

**6.2.** La red local funciona (llegás al router), así que el problema está **más allá del gateway**: la conexión del router hacia el proveedor (ISP), la configuración de NAT/rutas del router, o un corte del servicio de internet.

**6.3.** **DHCP** (Dynamic Host Configuration Protocol), normalmente ejecutado por el propio router hogareño. En una sola negociación entrega la dirección IP, la máscara/prefijo, el default gateway y los servidores DNS.

</details>

---

*Material original elaborado sobre la base de los objetivos del examen LPI Linux Essentials 010-160 v1.6, tema 4.4. Fuente de referencia: [https://learning.lpi.org/en/learning-materials/010-160/4/4.4/](https://learning.lpi.org/en/learning-materials/010-160/4/4.4/)*