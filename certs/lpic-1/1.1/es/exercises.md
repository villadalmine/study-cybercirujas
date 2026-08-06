# Ejercicios Pr\u00e1cticos: 1.1 System Architecture

Estos ejercicios guiados est\u00e1n dise\u00f1ados para simular tareas reales de un Site Reliability Engineer (SRE) en un entorno de producci\u00f3n, interactuando con el hardware, el bootloader y el init system.

## Ejercicio 1: Interrogaci\u00f3n del Hardware y Topolog\u00eda PCI

Como parte de un capacity planning para un nuevo nodo Kubernetes, necesitas verificar qu\u00e9 dispositivos de red y almacenamiento de alto rendimiento est\u00e1n expuestos al sistema operativo.

### Pasos

1. Lista de manera jer\u00e1rquica todos los dispositivos conectados al bus PCI:
   ```bash
   lspci -tv
   ```
2. Identifica el ID de subsistema de tu controlador Ethernet o de red principal (por ejemplo, buscar "Ethernet" o "Network"). 
   ```bash
   lspci | grep -i net
   ```
3. Suponiendo que el dispositivo de red est\u00e1 en el bus `00:03.0`, obt\u00e9n informaci\u00f3n detallada del m\u00f3dulo del kernel que est\u00e1 utilizando:
   ```bash
   lspci -nnk -s 00:03.0
   ```
4. Busca informaci\u00f3n sobre ese m\u00f3dulo del kernel espec\u00edfico (reemplaza `virtio_net` con el m\u00f3dulo que obtuviste en el paso anterior):
   ```bash
   modinfo virtio_net
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** \u00bfPor qu\u00e9 es importante utilizar el flag `-nnk` en `lspci` cuando estamos depurando problemas de conectividad de red a bajo nivel?

**Pregunta 1.2:** Si `modinfo` muestra que un m\u00f3dulo est\u00e1 firmado (signature), \u00bfqu\u00e9 caracter\u00edstica de seguridad del firmware a nivel boot est\u00e1 siendo reforzada por el kernel?

---

## Ejercicio 2: Monitoreo de Eventos udev (Hot-plug)

Se ha reportado que un nuevo disco SSD conectado en caliente a veces no recibe los permisos correctos. Vamos a interceptar el evento del kernel.

### Pasos

1. Inicia el monitor de `udev` para capturar eventos del kernel (`uevent`) y del subsistema `udev`:
   ```bash
   sudo udevadm monitor --environment
   ```
2. En otra terminal, simula la creaci\u00f3n o el cambio de estado de un dispositivo de bloque, o si puedes, conecta un pendrive USB al equipo (si es f\u00edsico). Para simularlo (trigger):
   ```bash
   sudo udevadm trigger --subsystem-match=block --action=change
   ```
3. Vuelve a la primera terminal, observa los eventos registrados, presiona `Ctrl+C` para detener la captura y analiza las variables de entorno de los eventos.

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** \u00bfCu\u00e1l es la diferencia entre los eventos etiquetados como `KERNEL` y los eventos etiquetados como `UDEV` en la salida de `udevadm monitor`?

---

## Ejercicio 3: Manipulaci\u00f3n de Systemd Targets (Runlevels)

El sistema ha arrancado pero un servicio de base de datos cr\u00edtico falla repetidamente, causando un loop de reinicios. Debes intervenir entrando en un target equivalente a "single user mode" para repararlo sin levantar la red ni los servicios secundarios.

### Pasos

1. Verifica cu\u00e1l es tu target de booteo por defecto actual:
   ```bash
   systemctl get-default
   ```
2. Cambia temporalmente la ejecuci\u00f3n del sistema actual al modo de rescate:
   ```bash
   sudo systemctl isolate rescue.target
   ```
   *(Nota: Si ejecutas esto en SSH perder\u00e1s la conexi\u00f3n. En entornos virtuales o laboratorios locales puedes hacerlo libremente; de lo contrario, solo revisa el comando).*
3. Una vez en el modo de rescate (o simulando), revisa c\u00f3mo configurar para que el siguiente reinicio vaya directamente al modo multiusuario sin interfaz gr\u00e1fica:
   ```bash
   sudo systemctl set-default multi-user.target
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** \u00bfCu\u00e1l es la diferencia fundamental en `systemd` entre utilizar `systemctl isolate <target>` y `systemctl set-default <target>`?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** El flag `-nnk` muestra tanto los IDs hexadecimales del Vendor y el Device (\u00fatil para buscar en bases de datos de hardware o escribir reglas `udev` precisas), como el driver del kernel asociado que est\u00e1 cargando para controlar el dispositivo. Sin esto, es dif\u00edcil saber si el kernel detect\u00f3 el hardware pero le falta el firmware/m\u00f3dulo adecuado.

**Respuesta 1.2:** Secure Boot. Si UEFI Secure Boot est\u00e1 habilitado, el kernel de Linux puede estar configurado en modo *lockdown*, requiriendo que cualquier m\u00f3dulo cargado est\u00e9 firmado criptogr\u00e1ficamente por una llave confiable; de lo contrario, el m\u00f3dulo es rechazado para evitar rootkits.

**Respuesta 2.1:** Los eventos `KERNEL` (`uevents`) son generados directamente por el kernel en el momento exacto en que detecta el hardware. Los eventos `UDEV` son emitidos despu\u00e9s de que el demonio de espacio de usuario (`systemd-udevd`) ha procesado el evento del kernel y ha aplicado todas las reglas configuradas en `/etc/udev/rules.d/` o `/usr/lib/udev/rules.d/` (ej. creando symlinks, ajustando permisos).

**Respuesta 3.1:** `systemctl isolate` cambia inmediatamente el estado actual del sistema en ejecuci\u00f3n al target especificado (deteniendo los servicios que no pertenecen a dicho target). Por otro lado, `systemctl set-default` modifica el enlace simb\u00f3lico en `/etc/systemd/system/default.target` y no afecta el sistema que ya est\u00e1 corriendo; el cambio tomar\u00e1 efecto en el pr\u00f3ximo booteo del sistema.

</details>