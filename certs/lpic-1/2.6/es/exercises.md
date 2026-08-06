# Ejercicios Pr\u00e1cticos: 2.6 Security

Estos ejercicios abordan los controles de acceso privilegiado y el cifrado de datos, tareas cr\u00edticas para un SRE enfocado en la seguridad operativa y el cumplimiento.

## Ejercicio 1: Restricci\u00f3n del Escalamiento de Privilegios (sudo)

Un desarrollador junior necesita poder reiniciar el servicio `nginx` sin tener acceso completo de superusuario en el servidor de *staging*.

### Pasos

1. Inicia sesi\u00f3n como un usuario no privilegiado e intenta reiniciar el servicio. Recibir\u00e1s un error de autenticaci\u00f3n:
   ```bash
   systemctl restart nginx.service
   ```
2. *(Simulaci\u00f3n mental)* Para otorgar este permiso espec\u00edfico sin dar acceso a `root`, debes usar el editor de configuraci\u00f3n seguro para sudoers:
   ```bash
   # NUNCA uses vim o nano. Siempre usa esto:
   sudo visudo
   ```
3. La l\u00ednea que agregar\u00edas al archivo (o preferiblemente en `/etc/sudoers.d/devs`) ser\u00eda:
   ```text
   usuario_junior ALL=(root) /bin/systemctl restart nginx.service
   ```
   *Nota:* Es crucial especificar la ruta absoluta del binario (`/bin/systemctl`) para evitar que el usuario enga\u00f1e al sistema alterando su variable `$PATH`.

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** Si configuras un usuario para que pueda ejecutar el editor de texto `vi` o `vim` como root mediante sudo (ej. `juan ALL=(root) /usr/bin/vim`), \u00bfpor qu\u00e9 esto equivale en la pr\u00e1ctica a darle acceso root total (irrestricto) al servidor?

---

## Ejercicio 2: Cifrado y Descifrado Asim\u00e9trico con GPG

Como SRE, debes enviarle a un colega un archivo con las credenciales de la base de datos de producci\u00f3n a trav\u00e9s de Slack o Email. Para que sea seguro, cifrar\u00e1s el archivo usando su clave p\u00fablica.

### Pasos

1. Primero, crea un archivo de texto simple simulando el secreto:
   ```bash
   echo "DB_PASS=SuperSecreto123" > db_credenciales.txt
   ```
2. *(Mental)* Si ya hubieras importado la clave p\u00fablica de tu colega (con email `alice@empresa.com`), cifrar\u00edas el archivo de la siguiente manera. El flag `--armor` (o `-a`) asegura que el resultado sea texto ASCII (f\u00e1cil de copiar/pegar) en lugar de datos binarios ilegibles:
   ```bash
   gpg --encrypt --armor --recipient alice@empresa.com db_credenciales.txt
   ```
3. El comando anterior genera un archivo `db_credenciales.txt.asc`. Puedes leer su contenido (ver\u00e1s un bloque cifrado PGP) usando:
   ```bash
   cat db_credenciales.txt.asc
   ```
4. Solo tu colega, utilizando su **clave privada**, podr\u00e1 ejecutar el descifrado:
   ```bash
   # Comando que ejecutar\u00eda tu colega
   gpg --decrypt db_credenciales.txt.asc
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** En la criptograf\u00eda asim\u00e9trica utilizada por GPG (y SSH), \u00bfcu\u00e1l de las dos claves (P\u00fablica o Privada) debe ser compartida libremente y distribuida a los servidores, y cu\u00e1l **jam\u00e1s** debe abandonar la computadora del ingeniero?

---

## Ejercicio 3: Auditor\u00eda y Desactivaci\u00f3n de SUID

El bit SUID (Set Owner User ID) es \u00fatil para que comandos como `passwd` funcionen, pero es un vector cr\u00edtico de ataque si est\u00e1 configurado en binarios equivocados (como `/bin/bash` o `nmap`).

### Pasos

1. Inspecciona los permisos del comando `ping`. Ver\u00e1s que pertenece a `root` y que la `x` (ejecuci\u00f3n) del due\u00f1o ha sido reemplazada por una `s` min\u00fascula. Esto permite que un usuario normal pueda enviar paquetes ICMP (que requieren privilegios de red del kernel):
   ```bash
   ls -l $(which ping)
   # Salida esperada: -rwsr-xr-x 1 root root ...
   ```
2. Utiliza `find` para listar todos los ejecutables del sistema operativo que tienen el bit SUID activo. Un atacante siempre ejecuta este comando al entrar a un servidor para buscar un binario vulnerable:
   ```bash
   sudo find / -type f -perm -4000 -exec ls -l {} + 2>/dev/null
   ```
3. *(Simulaci\u00f3n)* Si descubrieras un binario de terceros o compilado localmente con el bit SUID que no deber\u00eda tenerlo, le quitar\u00edas ese privilegio especial inmediatamente con el comando `chmod` utilizando el valor octal adecuado o su representaci\u00f3n simb\u00f3lica:
   ```bash
   sudo chmod u-s /ruta/al/binario_peligroso
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** Un desarrollador crea un script en bash (`/opt/script.sh`) y le asigna permisos `chmod 4755` (a\u00f1adiendo el bit SUID). Sin embargo, cuando un usuario no privilegiado ejecuta el script, este falla porque los comandos internos del script dicen "Permission denied" en lugar de ejecutarse como root. \u00bfPor qu\u00e9 el kernel de Linux ignora intencionalmente el bit SUID en los *scripts* (archivos de texto interpretados)?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** Porque editores como `vim` (as\u00ed como `less`, `more`, o `awk`) tienen funciones integradas para ejecutar sub-comandos del sistema operativo desde dentro del propio programa (conocido como *Shell Escape*). En `vim`, si escribes `:!/bin/bash`, el editor lanzar\u00e1 un nuevo shell de bash. Y dado que `vim` fue invocado mediante `sudo` (con privilegios de root), el shell resultante tambi\u00e9n ser\u00e1 un shell de root absoluto, sorteando completamente cualquier restricci\u00f3n impuesta en el archivo `sudoers`.

**Respuesta 2.1:** La clave **P\u00fablica** est\u00e1 dise\u00f1ada para ser compartida con el mundo (es p\u00fablica). Se utiliza para que otros cifren mensajes dirigidos hacia ti, o para que los servidores verifiquen tu identidad. La clave **Privada** es el secreto absoluto; **jam\u00e1s** debe transmitirse, copiarse a servidores ajenos ni salir del dispositivo seguro del ingeniero (idealmente almacenada en un hardware token como YubiKey). Solo la clave Privada puede descifrar los mensajes que fueron cifrados con la clave P\u00fablica correspondiente.

**Respuesta 3.1:** Hist\u00f3ricamente, permitir el bit SUID en scripts de shell es una de las vulnerabilidades m\u00e1s catastr\u00f3ficas y dif\u00edciles de prevenir, debido a las *Race Conditions* y a la facilidad de manipular el entorno (`$PATH`, `$IFS`) justo antes de que el int\u00e9rprete (ej. `/bin/bash`) empiece a leer el archivo de texto. Por seguridad, el kernel de Linux moderno ignora completamente el bit SUID si el archivo a ejecutar es un script (determinado por el *shebang* `#!`). El bit SUID solo tiene efecto en binarios compilados reales (ELF).

</details>