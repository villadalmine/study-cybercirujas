# Ejercicios Pr\u00e1cticos: 1.2 Linux Installation and Package Management

Estos ejercicios te guiar\u00e1n en el diagn\u00f3stico del Dynamic Linker (`ld.so`) y en la auditor\u00eda de gestores de paquetes, habilidades cr\u00edticas para un SRE lidiando con "dependency hell".

## Ejercicio 1: Auditor\u00eda de Librer\u00edas Compartidas (Shared Libraries)

Imagina que despliegas un binario custom de una aplicaci\u00f3n y al ejecutarlo falla silenciosamente o reporta una librer\u00eda faltante. Debes verificar qu\u00e9 librer\u00edas est\u00e1 intentando cargar el sistema.

### Pasos

1. Verifica las librer\u00edas din\u00e1micas requeridas por una utilidad com\u00fan, por ejemplo, `curl`:
   ```bash
   ldd /usr/bin/curl
   ```
2. Observa la salida. Deber\u00edas ver referencias como `libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1`. Ahora, verifica en la cach\u00e9 del dynamic linker d\u00f3nde est\u00e1 configurado el sistema para buscar librer\u00edas:
   ```bash
   cat /etc/ld.so.conf
   ls /etc/ld.so.conf.d/
   ```
3. Ejecuta el comando para reconstruir la cach\u00e9 de `ld.so`. (Nota: en sistemas de producci\u00f3n reales, haces esto tras compilar e instalar librer\u00edas C/C++ manualmente en `/usr/local/lib`).
   ```bash
   sudo ldconfig -v | head -n 15
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** Al correr `ldd`, si ves que una librer\u00eda dice `not found`, \u00bfc\u00f3mo puedes instruir al linker temporalmente para que busque en un directorio espec\u00edfico (por ejemplo, `/opt/mi_app/lib`) sin modificar la configuraci\u00f3n global del sistema?

---

## Ejercicio 2: Gesti\u00f3n e Interrogaci\u00f3n de Paquetes (Debian/Ubuntu)

Un compa\u00f1ero SRE ha configurado un servidor temporal y modific\u00f3 la configuraci\u00f3n de SSH, pero no document\u00f3 qu\u00e9 paquete exacto instal\u00f3. Quieres auditar un archivo para ver de qu\u00e9 paquete proviene.

*(Nota: Si usas RHEL/CentOS, los comandos equivalentes se muestran en el Ejercicio 3).*

### Pasos

1. Averigua qu\u00e9 paquete instal\u00f3 el binario `/usr/bin/sshd` o su archivo de configuraci\u00f3n:
   ```bash
   dpkg -S /etc/ssh/sshd_config
   ```
2. Consulta el estado de instalaci\u00f3n de dicho paquete en la base de datos de `dpkg`:
   ```bash
   dpkg -s openssh-server
   ```
3. Ahora, averigua las dependencias estrictas (`Depends`) del paquete antes de siquiera instalarlo o actualizarlo, utilizando el frontend `apt-cache`:
   ```bash
   apt-cache depends openssh-server
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** Seg\u00fan tu conocimiento de `dpkg`, \u00bfen qu\u00e9 archivo de texto plano se guarda el registro principal (estado, dependencias, descripciones) de todos los paquetes instalados en un sistema Debian/Ubuntu?

---

## Ejercicio 3: Gesti\u00f3n Avanzada de Paquetes (RHEL/CentOS/Fedora)

Est\u00e1s administrando un cluster basado en RHEL. Una actualizaci\u00f3n reciente rompi\u00f3 un servicio web (Nginx). Quieres revisar los scripts de pre/post instalaci\u00f3n del paquete RPM para ver qu\u00e9 se ejecut\u00f3 detr\u00e1s de escena.

### Pasos

1. Averigua qu\u00e9 paquete RPM provee un comando espec\u00edfico, por ejemplo, `semanage` (muy \u00fatil cuando te falta una utilidad CLI):
   ```bash
   dnf provides "*/semanage"
   ```
2. Consulta los scripts pre y post instalaci\u00f3n de un paquete instalado (por ejemplo, `nginx` o `bash`):
   ```bash
   rpm -q --scripts bash
   ```
3. Revisa el historial de transacciones de DNF para auditar qu\u00e9 hizo el equipo en las \u00faltimas horas:
   ```bash
   dnf history list
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** Si al hacer `dnf history list` identificas que la transacci\u00f3n con ID `45` corrompi\u00f3 el sistema, \u00bfcu\u00e1l es el comando exacto para revertir (undo) esa transacci\u00f3n espec\u00edfica y devolver los paquetes a su estado anterior?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** Utilizando la variable de entorno `LD_LIBRARY_PATH`. Al prependerla a la ejecuci\u00f3n del comando, fuerzas a `ld.so` a buscar en esos directorios primero. Ejemplo: `LD_LIBRARY_PATH=/opt/mi_app/lib ./mibinario`.

**Respuesta 2.1:** La base de datos principal de `dpkg` reside en el archivo de texto `/var/lib/dpkg/status`. Es com\u00fan que los SRE hagan backups o analicen este archivo con herramientas como `grep` y `awk` cuando el frontend de `apt` est\u00e1 roto.

**Respuesta 3.1:** El comando es `sudo dnf history undo 45`. Esto calcular\u00e1 las dependencias inversas y har\u00e1 un downgrade o remover\u00e1 los paquetes instalados en esa transacci\u00f3n, simulando un "rollback".

</details>