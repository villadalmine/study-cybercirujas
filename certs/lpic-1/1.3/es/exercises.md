# Ejercicios Pr\u00e1cticos: 1.3 GNU and Unix Commands

Estos ejercicios est\u00e1n dise\u00f1ados para simular el procesamiento de datos y la gesti\u00f3n de flujos (streams) que un SRE debe dominar para depurar incidentes usando la terminal.

## Ejercicio 1: Extracci\u00f3n de Datos de Logs con Awk, Sort y Uniq

Simularemos que est\u00e1s bajo un ataque DDoS y necesitas analizar un archivo crudo para extraer las IPs atacantes.

### Pasos

1. Crea un archivo temporal simulando un log de Nginx:
   ```bash
   cat << 'EOF' > /tmp/access.log
   192.168.1.10 - - [10/Oct/2023:13:55:36 -0700] "GET / HTTP/1.1" 200 2326
   10.0.0.5 - - [10/Oct/2023:13:55:36 -0700] "GET /api HTTP/1.1" 503 102
   192.168.1.10 - - [10/Oct/2023:13:55:37 -0700] "GET / HTTP/1.1" 200 2326
   192.168.1.10 - - [10/Oct/2023:13:55:38 -0700] "GET / HTTP/1.1" 200 2326
   172.16.0.2 - - [10/Oct/2023:13:55:38 -0700] "GET / HTTP/1.1" 200 2326
   10.0.0.5 - - [10/Oct/2023:13:55:39 -0700] "GET /api HTTP/1.1" 503 102
   EOF
   ```
2. Utiliza `awk` para extraer solo la primera columna (las IPs):
   ```bash
   awk '{print $1}' /tmp/access.log
   ```
3. Ahora, ordena el resultado y cu\u00e9ntalo usando `uniq -c`:
   ```bash
   awk '{print $1}' /tmp/access.log | sort | uniq -c
   ```
4. Finalmente, ordena la salida num\u00e9rica en reversa para tener los mayores ofensores al principio:
   ```bash
   awk '{print $1}' /tmp/access.log | sort | uniq -c | sort -nr
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** \u00bfPor qu\u00e9 es obligatorio ejecutar `sort` *antes* de pasarlo por `uniq -c` en este tipo de pipelines?

---

## Ejercicio 2: Edici\u00f3n no interactiva con Sed

Necesitas deshabilitar la autenticaci\u00f3n por contrase\u00f1a en un servidor SSH, automatiz\u00e1ndolo sin abrir un editor visual como `vim` o `nano`.

### Pasos

1. Copia el archivo de configuraci\u00f3n SSH actual a tu directorio temporal para evitar romper tu sistema:
   ```bash
   cp /etc/ssh/sshd_config /tmp/sshd_config.test
   ```
2. Busca las l\u00edneas que mencionan `PasswordAuthentication` ignorando may\u00fasculas/min\u00fasculas:
   ```bash
   grep -i "passwordauthentication" /tmp/sshd_config.test
   ```
3. Utiliza `sed` para reemplazar `PasswordAuthentication yes` por `PasswordAuthentication no` *in-place* (es decir, sobrescribiendo el archivo):
   ```bash
   sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /tmp/sshd_config.test
   ```
4. Verifica que el reemplazo haya sido exitoso:
   ```bash
   grep -i "passwordauthentication" /tmp/sshd_config.test
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** \u00bfQu\u00e9 hace exactamente el flag `-i` en el comando `sed`? \u00bfCu\u00e1l es el riesgo de usarlo en producci\u00f3n sin un control de versiones?

---

## Ejercicio 3: Transformaci\u00f3n de texto con tr y variables

Como parte de un script de CI/CD, recibes un string con variables que debes normalizar a letras min\u00fasculas y reemplazar espacios por guiones bajos.

### Pasos

1. Define una variable con contenido que no est\u00e1 normalizado:
   ```bash
   CLUSTER_NAME="PROD US EAST 1"
   ```
2. Impr\u00edmela y p\u00e1sala por `tr` para convertir los espacios en guiones bajos:
   ```bash
   echo $CLUSTER_NAME | tr ' ' '_'
   ```
3. Ahora encadena otro comando `tr` para convertir todo el resultado a min\u00fasculas, guard\u00e1ndolo en una nueva variable:
   ```bash
   NORMALIZED_CLUSTER=$(echo $CLUSTER_NAME | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
   echo $NORMALIZED_CLUSTER
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** A diferencia de `sed` o `awk`, que operan procesando streams l\u00ednea por l\u00ednea o buscando patrones complejos, \u00bfc\u00f3mo opera internamente el comando `tr`?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** Porque el comando `uniq` solo compara l\u00edneas *adyacentes* (consecutivas). Si las IPs id\u00e9nticas est\u00e1n dispersas a lo largo del log (por el orden temporal), `uniq` no las sumar\u00e1; en su lugar, imprimir\u00e1 m\u00faltiples conteos separados para la misma IP. Agruparlas con `sort` garantiza que todas las ocurrencias id\u00e9nticas queden contiguas.

**Respuesta 2.1:** El flag `-i` significa *in-place*. En lugar de enviar el resultado modificado a la salida est\u00e1ndar (pantalla), `sed` crea un archivo temporal, escribe los cambios all\u00ed y luego reemplaza el archivo original. El riesgo principal es que, si la expresi\u00f3n regular es demasiado ambiciosa o err\u00f3nea (por ejemplo, vaciar el archivo por un `sed -i 'd'`), la p\u00e9rdida de la configuraci\u00f3n original es instant\u00e1nea e irrecuperable si no hay un backup o IaC. (Como buena pr\u00e1ctica, usar `sed -i.bak` crea un backup autom\u00e1tico).

**Respuesta 3.1:** El comando `tr` (translate) opera estrictamente car\u00e1cter por car\u00e1cter sobre la entrada est\u00e1ndar, mapeando conjuntos (sets). No entiende conceptos como "l\u00edneas", "palabras" o "expresiones regulares"; solo mapea cada byte o car\u00e1cter del conjunto de entrada con su correspondiente en el conjunto de salida. Por eso es extremadamente r\u00e1pido para normalizar min\u00fasculas/may\u00fasculas o caracteres individuales.

</details>