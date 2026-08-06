# Ejercicios Pr\u00e1cticos: 2.1 Shells and Shell Scripting

Estos ejercicios te ayudar\u00e1n a dominar las caracter\u00edsticas avanzadas de Bash para crear scripts robustos y resilientes en entornos de producci\u00f3n o CI/CD.

## Ejercicio 1: Variables de Entorno, Locales y Exportaci\u00f3n

Al escribir un script de despliegue, necesitas manejar tokens de manera segura y entender c\u00f3mo el *Scope* (alcance) de las variables afecta a los procesos hijos.

### Pasos

1. Define una variable global y una local dentro de un script simulado en tu terminal:
   ```bash
   API_TOKEN="secret123"
   ```
2. Ejecuta un sub-shell (un proceso hijo) y trata de leer la variable:
   ```bash
   bash -c 'echo "El token es: $API_TOKEN"'
   ```
   *(Notar\u00e1s que est\u00e1 vac\u00edo).*
3. Ahora, exporta la variable en tu shell actual y vuelve a ejecutar el sub-shell:
   ```bash
   export API_TOKEN
   bash -c 'echo "El token es: $API_TOKEN"'
   ```
4. Utiliza la sintaxis de *Variable Expansion* para proveer un valor por defecto en caso de que una variable no est\u00e9 definida. Imprime una variable `DB_HOST`, pero si no existe, que por defecto sea `localhost`:
   ```bash
   echo "Conectando a: ${DB_HOST:-localhost}"
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** \u00bfPor qu\u00e9 un script de bash que es llamado desde otro script no puede acceder a las variables del primero a menos que se use el comando `export`?

---

## Ejercicio 2: Modo Defensivo (set -e y set -u)

Vas a escribir un script peque\u00f1o que ilustra por qu\u00e9 un script normal es peligroso en producci\u00f3n.

### Pasos

1. Crea un script llamado `peligro.sh` usando un *heredoc*:
   ```bash
   cat << 'EOF' > peligro.sh
   #!/bin/bash
   echo "Paso 1: Iniciando..."
   # Este comando fallar\u00e1 porque el directorio no existe
   cd /directorio/inexistente/de/base_de_datos
   echo "Paso 2: Borrando archivos antiguos..."
   # Si estuviera ejecutando rm -rf *, borrar\u00eda donde sea que est\u00e9 parado.
   echo "[rm -rf *] (Simulado)"
   EOF
   chmod +x peligro.sh
   ```
2. Ejec\u00fatalo. Observa c\u00f3mo el script contin\u00faa ejecutando el Paso 2 a pesar de que fall\u00f3 el `cd`:
   ```bash
   ./peligro.sh
   ```
3. Ahora, crea una versi\u00f3n segura `seguro.sh` utilizando banderas defensivas:
   ```bash
   cat << 'EOF' > seguro.sh
   #!/bin/bash
   set -euo pipefail
   echo "Paso 1: Iniciando..."
   cd /directorio/inexistente/de/base_de_datos
   echo "Paso 2: Borrando archivos antiguos..."
   EOF
   chmod +x seguro.sh
   ```
4. Ejec\u00fatalo y observa la diferencia:
   ```bash
   ./seguro.sh
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** Explica brevemente qu\u00e9 protecciones individuales habilitan los flags `-e`, `-u` y `-o pipefail` en Bash.

---

## Ejercicio 3: Control de Flujo Avanzado y Loops (Polling)

Los SREs a menudo necesitan esperar a que un servicio externo est\u00e9 listo antes de continuar un pipeline.

### Pasos

1. Crea un script de *polling* simple usando un loop `while`. Este script iterar\u00e1 3 veces esperando (simuladamente) por un servicio:
   ```bash
   cat << 'EOF' > wait_service.sh
   #!/bin/bash
   MAX_RETRIES=3
   COUNT=0
   
   while [[ $COUNT -lt $MAX_RETRIES ]]; do
       echo "Verificando servicio... (Intento $((COUNT+1)))"
       # Aqu\u00ed ir\u00eda un curl o nc (netcat) real
       sleep 1
       ((COUNT++))
   done
   echo "Timeout alcanzado. Fallando pipeline."
   exit 1
   EOF
   chmod +x wait_service.sh
   ```
2. Ejec\u00fatalo:
   ```bash
   ./wait_service.sh
   ```
3. Imprime el *Exit Code* del script (que deber\u00eda ser 1, indicando error):
   ```bash
   echo $?
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** \u00bfPor qu\u00e9 es recomendable utilizar corchetes dobles `[[ ]]` en lugar de corchetes simples `[ ]` (el comando `test` nativo) cuando evaluamos condiciones (como en el loop `while`) en Bash moderno?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** Porque en sistemas UNIX/Linux, un nuevo script invocado se ejecuta en un proceso hijo (sub-shell). Por dise\u00f1o y seguridad, los procesos hijos heredan copias de las variables de entorno de su proceso padre, pero NO heredan las variables locales. El comando `export` promueve una variable local a una variable de entorno.

**Respuesta 2.1:** 
* `-e` (errexit): Detiene la ejecuci\u00f3n del script si cualquier comando falla (sale con un c\u00f3digo distinto de 0).
* `-u` (nounset): Detiene el script inmediatamente si se intenta expandir una variable que no ha sido definida, protegiendo contra errores tipogr\u00e1ficos o estados vac\u00edos.
* `-o pipefail`: Fuerza a que el c\u00f3digo de salida de un *pipeline* completo (ej. `cmd1 | cmd2`) sea el del \u00faltimo comando que fall\u00f3 (distinto de 0) en lugar del c\u00f3digo de salida del \u00faltimo comando de la cadena, evitando falsos positivos.

**Respuesta 3.1:** Los corchetes dobles `[[ ]]` son una extensi\u00f3n nativa construida directamente en Bash (built-in keyword). A diferencia de `[ ]`, que es esencialmente un alias al binario `/usr/bin/test` o un *built-in* m\u00e1s primitivo, `[[ ]]` previene autom\u00e1ticamente errores de *Word Splitting* y *Pathname Expansion* si las variables contienen espacios, soporta comparaciones de Expresiones Regulares con el operador `=~`, y permite el uso de operadores l\u00f3gicos `&&` y `||` internamente en lugar de `-a` y `-o`.

</details>