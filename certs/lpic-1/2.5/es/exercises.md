# Ejercicios Pr\u00e1cticos: 2.5 Networking Fundamentals

Estos ejercicios simulan un escenario de *troubleshooting* de conectividad a nivel de kernel, crucial para cualquier SRE que diagnostique fallos en cl\u00fasteres.

## Ejercicio 1: Interrogaci\u00f3n de Interfaces y Tablas de Ruteo (iproute2)

Un servidor no puede alcanzar una base de datos alojada en una red privada (10.0.0.0/8), pero s\u00ed puede salir a internet. Vamos a auditar su red.

### Pasos

1. Verifica todas las direcciones IP asignadas a tus interfaces f\u00edsicas y virtuales (como Docker o Kubernetes `cni0`), incluyendo las m\u00e1scaras CIDR:
   ```bash
   ip -c addr show
   ```
2. Inspecciona la tabla de ruteo del kernel. Presta atenci\u00f3n a la ruta `default` (por donde sale el tr\u00e1fico hacia internet, 0.0.0.0) y a las rutas directas de tus subredes locales:
   ```bash
   ip -c route show
   ```
3. Pide al kernel que simule exactamente por qu\u00e9 interfaz enviar\u00eda un paquete dirigido a una IP espec\u00edfica (\u00fatil si hay rutas en conflicto):
   ```bash
   ip route get 10.5.5.5
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** En la salida de `ip route show`, observas una l\u00ednea que dice `192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50`. \u00bfQu\u00e9 significa el t\u00e9rmino `scope link` en este contexto de ruteo?

---

## Ejercicio 2: Diagn\u00f3stico de Sockets (ss) vs. Network Tools (netstat)

Se reporta que el servicio de cach\u00e9 (Redis) se ha ca\u00eddo.

### Pasos

1. Utiliza el comando moderno `ss` para listar todos los sockets TCP en estado LISTEN, mostrando los procesos asociados y resolviendo num\u00e9ricamente (sin buscar nombres en DNS para no demorar la salida):
   ```bash
   sudo ss -tulnp
   ```
2. Imagina que descubres que Redis est\u00e1 escuchando, pero en la direcci\u00f3n IP incorrecta. Revisa r\u00e1pidamente las estad\u00edsticas globales de red del kernel para ver si hay errores (drop) de paquetes a nivel de socket:
   ```bash
   ss -s
   ```
3. Si un contenedor ef\u00edmero gener\u00f3 miles de conexiones que no se cerraron adecuadamente, el servidor podr\u00eda estar lleno de sockets en estado `TIME-WAIT`. Para contarlos:
   ```bash
   ss -tan | grep TIME-WAIT | wc -l
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** Un desarrollador te insiste en usar el comando legacy `netstat -an`. Como SRE, \u00bfcu\u00e1l es la raz\u00f3n t\u00e9cnica principal (a nivel de arquitectura del kernel) por la cual le exiges usar `ss` en servidores de producci\u00f3n de alto tr\u00e1fico?

---

## Ejercicio 3: Resoluci\u00f3n de DNS Nativa y Pruebas (dig)

Tu aplicaci\u00f3n arroja el error "No route to host" al intentar conectarse a `db.produccion.local`.

### Pasos

1. Interroga la configuraci\u00f3n actual del resolver (DNS local) del sistema operativo. Generalmente en Ubuntu moderno:
   ```bash
   resolvectl status
   ```
   *(Si no existe `resolvectl`, simplemente usa `cat /etc/resolv.conf`).*
2. Utiliza `dig` para rastrear la resoluci\u00f3n del dominio `google.com`, pero limitando la salida solo a las direcciones IP:
   ```bash
   dig +short google.com
   ```
3. Fuerza a `dig` a preguntar directamente al servidor de Google (8.8.8.8) para evadir cualquier cach\u00e9 o envenenamiento de tu DNS local:
   ```bash
   dig @8.8.8.8 google.com
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** Cuando ejecutas un simple `ping aplicacion.local`, el sistema operativo no solo consulta al DNS configurado (ej. 8.8.8.8). Explica brevemente el rol del archivo `/etc/hosts` en este proceso y qu\u00e9 tiene prioridad.

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** El `scope link` significa que esa subred (`192.168.1.0/24`) es directamente accesible en la Capa 2 (enlace de datos o switch f\u00edsico/virtual) a trav\u00e9s del cable conectado a la interfaz `eth0`. El host no necesita enviar esos paquetes a trav\u00e9s del router por defecto (Gateway), porque los dispositivos de destino est\u00e1n en su mismo dominio de broadcast.

**Respuesta 2.1:** La herramienta `netstat` (del paquete *net-tools*) funciona abriendo secuencialmente y leyendo archivos de texto en texto plano generados por el kernel en el sistema de archivos virtual `/proc/net/`. Cuando tienes 50,000 conexiones concurrentes, la lectura y parseo de estos archivos provoca una degradaci\u00f3n severa de CPU y un tiempo de ejecuci\u00f3n enorme. La herramienta `ss` (Socket Statistics), parte del paquete *iproute2*, se comunica directamente con el kernel a trav\u00e9s de una API binaria llamada **netlink**, obteniendo la tabla de sockets casi instant\u00e1neamente con m\u00ednima sobrecarga (overhead).

**Respuesta 3.1:** El archivo `/etc/hosts` act\u00faa como una tabla est\u00e1tica local de resoluci\u00f3n de nombres a IPs. Seg\u00fan la configuraci\u00f3n del Name Service Switch (archivo `/etc/nsswitch.conf`, l\u00ednea `hosts: files dns`), el sistema operativo (y por ende `ping` o navegadores) consultar\u00e1 **primero** el archivo local `/etc/hosts` (files) antes de enviar una consulta UDP de DNS a los servidores externos. Si el dominio est\u00e1 mapeado en `/etc/hosts`, esa IP tiene absoluta prioridad sobre lo que dicte el DNS de Internet.

</details>