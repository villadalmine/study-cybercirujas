# LPI Web Development Essentials (Exam 030-100, Version 1.0)
## Topic 2.4: HTML Forms (Weight: 5)

**Official Reference**: [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)

---

### Visión General de la Arquitectura Ejecutiva y Mecánica HTTP

Los formularios HTML sirven como el puente interactivo principal entre el navegador cliente (DOM) y los servicios web del backend. Cuando se envía un formulario HTML, el navegador serializa las entradas del usuario desde los elementos de control (`<input>`, `<select>`, `<textarea>`) en pares clave-valor y construye una HTTP Request dirigida a la URL especificada en el atributo `action` del formulario utilizando el método HTTP declarado en el atributo `method`.

#### 1. HTTP Methods in Form Submissions
* **`GET`**: Los datos de control del formulario se codifican en la URL (URL-encoded) y se añaden directamente al URI `action` como una query string (ej., `/search?query=sre&page=1`).
  * *Trade-offs*: Idempotente, guardable en marcadores y almacenable en caché por capas de proxys HTTP/CDN. Sin embargo, los parámetros de consulta se almacenan en los access logs del servidor web, en el historial del navegador y en los encabezados HTTP `Referer`. Nunca use `GET` para credenciales sensibles o mutaciones de payload.
* **`POST`**: Los datos de control del formulario se colocan dentro del cuerpo (body) de la HTTP request.
  * *Trade-offs*: No idempotente, previene la fuga de credenciales mediante el registro en logs de URL y soporta tamaños de payload arbitrarios (ej., subida de archivos).

#### 2. Media Encoding Types (`enctype`)
* **`application/x-www-form-urlencoded`** *(Por defecto)*: Las claves y valores se codifican en tuplas de clave-valor separadas por `&`, con los caracteres especiales escapados en la URL (ej., `user=john+doe&role=admin`). Eficiente para pares clave-valor de texto pequeño.
* **`multipart/form-data`**: El payload se divide en partes individuales del cuerpo delimitadas por una cadena boundary única (ej., `---------------------------974767299852498929531610575`). Requerido al enviar archivos binarios (`<input type="file">`).
* **`text/plain`**: Envía pares clave-valor sin codificar en bruto separados por saltos de línea. Se utiliza principalmente para depuración heredada (legacy debugging); no apto para parsing en producción.

---

### Ejercicio Guiado 1: Construcción de Formularios Accesibles e Inspección de Payloads HTTP en Bruto

#### Objetivo
Construir un formulario HTML5 compatible con entornos de producción que cuente con asociaciones de etiquetas precisas, agrupación estructural y restricciones de entrada personalizadas. Ejecutar un depurador de endpoint HTTP local para inspeccionar los formatos wire `GET` y `POST` en bruto.

#### Pasos de Ejecución

1. Crear un directorio de trabajo local y navegar dentro de él:
```bash
mkdir -p ~/lpi-form-lab && cd ~/lpi-form-lab
```

2. Crear un archivo HTML llamado `index.html` con controles de formulario explícitos, fieldsets, labels y atributos de validación:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Production System Registration</title>
</head>
<body>
  <h1>Cluster User Registration</h1>
  <form action="http://localhost:8080/register" method="POST" enctype="application/x-www-form-urlencoded">
    <fieldset>
      <legend>Identity & Credentials</legend>
      
      <p>
        <label for="username">Username (Required):</label>
        <input type="text" id="username" name="username" required maxlength="30" placeholder="e.g. sysadmin">
      </p>

      <p>
        <label for="email">Work Email:</label>
        <input type="email" id="email" name="email" required placeholder="admin@example.com">
      </p>

      <p>
        <label for="environment">Target Environment:</label>
        <select id="environment" name="environment">
          <optgroup label="Non-Production">
            <option value="dev">Development</option>
            <option value="staging" selected>Staging</option>
          </optgroup>
          <optgroup label="Production">
            <option value="prod-us">Production (US-East)</option>
            <option value="prod-eu">Production (EU-Central)</option>
          </optgroup>
        </select>
      </p>
    </fieldset>

    <fieldset>
      <legend>Access Level & Policies</legend>
      
      <p>
        <label>Account Role:</label><br>
        <input type="radio" id="role-viewer" name="role" value="viewer" checked>
        <label for="role-viewer">Viewer</label>
        
        <input type="radio" id="role-operator" name="role" value="operator">
        <label for="role-operator">Operator</label>
      </p>

      <p>
        <input type="checkbox" id="terms" name="accept_terms" value="yes" required>
        <label for="terms">I accept the Production Access SLA Policy</label>
      </p>
      
      <input type="hidden" name="client_version" value="2.4.0-sre">
    </fieldset>

    <p>
      <button type="submit">Submit Registration</button>
      <button type="reset">Reset Form</button>
    </p>
  </form>
</body>
</html>
```

3. Iniciar un socket listener en bruto en el puerto `8080` usando `netcat` (o `nc`) para inspeccionar los payloads HTTP entrantes enviados por el navegador o cURL:
```bash
nc -l 8080
```

4. En una sesión de terminal separada, ejecutar un comando `curl` que simule el envío POST de un formulario de navegador usando `application/x-www-form-urlencoded`:
```bash
curl -i -X POST http://localhost:8080/register \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=sysadmin&email=admin%40example.com&environment=staging&role=operator&accept_terms=yes&client_version=2.4.0-sre"
```

5. Observar la HTTP request en bruto esperada capturada por `netcat`:

```http
POST /register HTTP/1.1
Host: localhost:8080
User-Agent: curl/7.81.0
Accept: */*
Content-Type: application/x-www-form-urlencoded
Content-Length: 111

username=sysadmin&email=admin%40example.com&environment=staging&role=operator&accept_terms=yes&client_version=2.4.0-sre
```

---

#### Preguntas de Verificación (Ejercicio 1)

1. ¿Qué sucede con los elementos de entrada del formulario que carecen de un atributo `name` cuando el formulario se envía al servidor?
2. ¿Por qué la vinculación explícita entre `<label for="element_id">` e `<input id="element_id">` es esencial para la accesibilidad y la UX?
3. ¿Cómo determina el navegador qué opción se selecciona por defecto en un control desplegable `<select>` si no se especifica el atributo `selected`?
4. ¿Cuál es la diferencia funcional entre `<button type="submit">`, `<button type="reset">` y `<button type="button">`?

---

### Ejercicio Guiado 2: Subida de Archivos, Mecanismos de Codificación y Validación de Patrones

#### Objetivo
Implementar un formulario HTML multipart configurado para la subida de archivos binarios y validación de restricciones avanzada en el lado del cliente. Usar cURL para emular la codificación `multipart/form-data` y verificar los boundaries HTTP.

#### Pasos de Ejecución

1. Crear `upload.html` dentro de `~/lpi-form-lab` con soporte para archivos adjuntos, textareas y validación de restricciones regex:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Kubeconfig & Artifact Submission</title>
</head>
<body>
  <h1>Upload Cluster Configuration</h1>
  <form action="http://localhost:8080/upload" method="POST" enctype="multipart/form-data">
    <p>
      <label for="node-id">Node Identifier (Format: node-XXXX):</label>
      <input type="text" id="node-id" name="node_id" required pattern="node-[0-9]{4}" title="Must start with 'node-' followed by 4 digits">
    </p>

    <p>
      <label for="config-file">Upload Manifest (YAML/JSON):</label>
      <input type="file" id="config-file" name="config_file" accept=".yaml,.yml,.json" required>
    </p>

    <p>
      <label for="notes">Deployment Notes:</label><br>
      <textarea id="notes" name="notes" rows="5" cols="40" placeholder="Add optional deployment context..."></textarea>
    </p>

    <p>
      <button type="submit">Upload Config</button>
    </p>
  </form>
</body>
</html>
```

2. Crear un archivo de configuración de prueba:
```bash
echo "apiVersion: v1\nkind: Config" > test-manifest.yaml
```

3. Iniciar `netcat` en el puerto `8080` para escuchar el payload de subida multipart:
```bash
nc -l 8080
```

4. Emular una subida de formulario multipart usando `curl -F`:
```bash
curl -i -X POST http://localhost:8080/upload \
  -F "node_id=node-1042" \
  -F "config_file=@test-manifest.yaml;type=application/x-yaml" \
  -F "notes=Deploying patch v1.2"
```

5. Revisar el payload wire multipart en bruto capturado por `netcat`:

```http
POST /upload HTTP/1.1
Host: localhost:8080
User-Agent: curl/7.81.0
Accept: */*
Content-Length: 428
Content-Type: multipart/form-data; boundary=------------------------a7d83f4b50c1e892

--------------------------a7d83f4b50c1e892
Content-Disposition: form-data; name="node_id"

node-1042
--------------------------a7d83f4b50c1e892
Content-Disposition: form-data; name="config_file"; filename="test-manifest.yaml"
Content-Type: application/x-yaml

apiVersion: v1
kind: Config

--------------------------a7d83f4b50c1e892
Content-Disposition: form-data; name="notes"

Deploying patch v1.2
--------------------------a7d83f4b50c1e892--
```

---

#### Preguntas de Verificación (Ejercicio 2)

1. ¿Qué sucede si un usuario envía un formulario que contiene un elemento `<input type="file">` mientras la etiqueta `<form>` tiene `enctype="application/x-www-form-urlencoded"`?
2. ¿Cómo hace cumplir el navegador el atributo `pattern` durante la validación en el lado del cliente y acaso la validación en el lado del cliente reemplaza la validación del payload en el lado del servidor?
3. ¿Cuáles son las implicaciones de seguridad de utilizar elementos `<input type="hidden">` para identificadores de sesión o gestión de estado?
4. ¿Qué rol desempeña el parámetro de cadena `boundary` en el encabezado HTTP `Content-Type: multipart/form-data`?

---

### Soluciones y Respuestas de Verificación de Comprensión

<details>
<summary>Haga clic aquí para ver las soluciones detalladas de todas las preguntas de los ejercicios</summary>

#### Soluciones del Ejercicio 1

1. **Atributo `name` faltante**: Los elementos de entrada del formulario sin un atributo `name` se ignoran por completo durante la serialización del formulario. El navegador no incluirá sus valores ni en la query string de la URL (`GET`) ni en el cuerpo de la HTTP request (`POST`). El atributo `id` se utiliza para la manipulación del DOM y la vinculación de etiquetas, mientras que el atributo `name` define la clave del parámetro en el payload HTTP.

2. **Vinculación explícita de `<label for="...">`**: Vincular una etiqueta mediante el atributo `for` (coincidiendo con el `id` del elemento de destino) aumenta el área de clic objetivo para dispositivos de escritorio y táctiles; hacer clic en el texto enfoca o activa/desactiva la entrada. De manera crucial, los lectores de pantalla anuncian el texto de la etiqueta cuando el elemento de entrada recibe el foco, cumpliendo con los mandatos de accesibilidad (WCAG).

3. **Elemento `<select>` por defecto**: Si ningún `<option>` contiene el atributo `selected`, el navegador selecciona por defecto el primer `<option>` renderizado en la lista del DOM.

4. **Tipos de botones**:
   * `type="submit"`: Serializa los datos del formulario padre y envía una HTTP request a la URL asignada en `action`. (Comportamiento por defecto si se omite `type` dentro de un `<form>`).
   * `type="reset"`: Revierte todos los campos de entrada hijos dentro del formulario padre a sus valores por defecto iniciales definidos en el marcado HTML.
   * `type="button"`: No tiene un comportamiento por defecto en el navegador. Se utiliza exclusivamente para vincular la ejecución de JavaScript personalizado en el lado del cliente a través de event listeners (`addEventListener`).

---

#### Soluciones del Ejercicio 2

1. **Subida de archivos con enctype `urlencoded`**: El navegador solo transmitirá el nombre del archivo (como una cadena de texto plano) en el payload clave-valor del cuerpo HTTP (ej., `config_file=test-manifest.yaml`). El contenido binario real del archivo **no** se subirá al servidor.

2. **Aplicación del `pattern` de regex**: El atributo `pattern` acepta una expresión regular de JavaScript. Antes de enviar el formulario, el navegador prueba el valor del campo contra el patrón regex. Si falla, el envío del formulario se bloquea, la interfaz de usuario de validación nativa de HTML alerta al usuario y se aplican las pseudoclases CSS `:invalid`. **Nota de Seguridad**: La validación en el lado del cliente mejora la experiencia del usuario, pero se puede omitir fácilmente usando `cURL`, Postman o herramientas proxy (Burp Suite). Toda la validación de entrada debe reejecutarse en el lado del servidor.

3. **Riesgos de seguridad de `<input type="hidden">`**: Las entradas ocultas se almacenan en texto plano dentro del DOM de HTML. Los usuarios pueden inspeccionar, editar o manipular los valores de entrada ocultos a través de las Developer Tools del navegador o solicitudes cURL directas. Nunca almacene credenciales sensibles, cálculos de precios, niveles de acceso o tokens de sesión no confiables en entradas ocultas sin verificación de firma/MAC en el lado del servidor.

4. **Cadena `boundary` multipart**: El parámetro `boundary` establece una secuencia de bytes única que actúa como un delimitador entre campos de formulario separados en el cuerpo de la HTTP request. Permite que el parser del servidor aísle los encabezados individuales (`Content-Disposition`, `Content-Type`) y los segmentos de datos de payload para cada campo y subida de archivo binario.

</details>