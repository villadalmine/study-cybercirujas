# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
## Topic 704.2: Other Configuration Management Tools
**Exam Weight:** 3.34 (Topic 704.2 Objective Weight: 2 out of 60 total exam weight)  
**Primary Reference:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

---

## 1. Architecture & Internal Mechanics

### 1.1 Puppet Architecture & Catalog Compilation Model

Puppet opera principalmente en un modelo pull **agent/server (master)** o en un modelo de **agent independiente (`puppet apply`)** utilizando un lenguaje específico del dominio (DSL) declarativo.

```
   +-------------------+                     +-------------------+
   |   Puppet Agent    |                     |   Puppet Server   |
   +-------------------+                     +-------------------+
             |                                         |
             | --- 1. Send System Facts (Facter) ----> |
             |                                         | --- 2. Parse Manifests (.pp)
             |                                         | --- 3. Evaluate Classes/Modules
             |                                         | --- 4. Build Resource DAG
             | <--- 5. Return Compiled JSON Catalog -- |
             |                                         |
             | --- 6. Enforce State (RAL) ------------ |
             | --- 7. Report Execution Summary ------> |
```

1. **Fact Collection (Facter):** El Puppet agent ejecuta `facter` para descubrir atributos del nodo (dirección IP, sistema operativo, versión del kernel, facts personalizados) y los envía al Puppet Server codificados en JSON.
2. **Manifest Parsing & AST Generation:** Puppet Server analiza (*parsea*) los manifests `.pp`, evalúa la lógica en función de los node facts entrantes y genera un Árbol de Sintaxis Abstracta (AST).
3. **Directed Acyclic Graph (DAG) & Catalog Compilation:** Puppet resuelve la herencia de clases, las relaciones (`before`, `require`, `notify`, `subscribe`) y las variables para compilar un **Catalog**: una representación JSON completa del grafo de configuración objetivo que contiene cada recurso y sus parámetros esperados.
4. **Resource Abstraction Layer (RAL):** El cliente recibe el catalog y traduce los recursos abstractos (por ejemplo, `package { 'nginx': ensure => installed }`) en llamadas a proveedores nativos del sistema (por ejemplo, `apt-get install`, `yum install` o `zypper install`) a través de su RAL interno.
5. **State Convergence & Idempotency:** El agent inspecciona el estado actual de cada recurso en comparación con el estado del catalog. Si se detecta una desviación (*drift*), Puppet aplica los cambios exactos requeridos para lograr la paridad y envía un informe al Puppet Server.

---

### 1.2 Chef Architecture & Two-Phase Execution Lifecycle

Chef utiliza un DSL imperativo/declarativo basado en Ruby que opera en un modelo **Chef Infra Server / Chef Client** o de ejecución independiente (`chef-apply` / `chef-client --local-mode`).

```
   +-------------------+                     +-------------------+
   |    Chef Client    |                     |    Chef Server    |
   +-------------------+                     +-------------------+
             |                                         |
             | --- 1. Authenticate & Fetch Node Object>|
             | --- 2. Run Ohai (Fact Discovery) -----> |
             | <--- 3. Download Cookbooks/Recipes ---- |
             |                                         |
   [ Phase 1: Compile Phase ]                          |
   - Evaluates Ruby code, attributes, & recipes        |
   - Constructs Resource Collection Array in memory    |
                                                       |
   [ Phase 2: Converge Phase ]                         |
   - Iterates sequentially through Resource Collection |
   - Checks provider state & executes resource updates |
   - Flushes delayed notifications (`notifies`)         |
             |                                         |
             | --- 4. Upload Updated Node Object -----> |
```

1. **Ohai Attribute Discovery:** `ohai` consulta el estado del sistema y construye una estructura JSON multicapa de atributos del sistema (`node['platform']`, `node['ipaddress']`).
2. **Two-Phase Lifecycle Execution:**
   - **Phase 1: Compile Phase:** Chef Client analiza las `recipes/*.rb` y evalúa construcciones estándar de Ruby (bucles, condicionales, métodos auxiliares). Instancia los objetos de recursos sin ejecutar cambios en el sistema y los agrega a un arreglo ordenado `Resource Collection`.
   - **Phase 2: Converge Phase:** Chef Client recorre el arreglo `Resource Collection` de forma secuencial y lineal. Para cada recurso, el Provider asignado verifica el estado actual contra los atributos objetivo, ejecuta comandos nativos del sistema si es necesario y encola notificaciones diferidas (por ejemplo, `notifies :restart, 'service[nginx]', :delayed`).

---

### 1.3 Technical Trade-Off Matrix

| Architectural Feature | Puppet | Chef | Ansible |
| :--- | :--- | :--- | :--- |
| **Execution Paradigm** | Pull (Daemon/Cron) o Push (`puppet apply`) | Pull (Daemon/Cron) o Push (`chef-apply`) | Push (SSH/WinRM Agentless) |
| **Language Paradigm** | Declarative DSL (HCL-like AST model) | Pure Ruby DSL (Imperativo + Declarativo) | YAML Declarative Playbooks |
| **Dependency Model** | Basado en grafos (resolución DAG vía metadatos) | Arreglo lineal secuencial (de arriba a abajo) | Ejecución lineal secuencial |
| **Fact Discovery Engine** | `facter` | `ohai` | Módulo `setup` (Gathers Facts) |
| **State Abstraction** | Resource Abstraction Layer (RAL) | Providers (`Chef::Provider`) | Modules (`ansible.builtin.*`) |

---

## 2. Complete Syntactically Valid Manifests & Recipes

### 2.1 Production Puppet Manifest (`/etc/puppetlabs/code/environments/production/manifests/site.pp`)

```puppet
# Class definition enforcing secure webserver state
class role::webserver (
  String $package_name = 'nginx',
  String $service_name = 'nginx',
  String $port         = '8080',
) {

  # Ensure package installation via platform RAL provider
  package { 'nginx_package':
    ensure => installed,
    name   => $package_name,
    before => File['nginx_config'],
  }

  # Manage configuration file state
  file { 'nginx_config':
    ensure  => file,
    path    => '/etc/nginx/conf.d/app.conf',
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "server {\n    listen ${port};\n    server_name _;\n    location / {\n        root /var/www/html;\n        index index.html;\n    }\n}\n",
    require => Package['nginx_package'],
    notify  => Service['nginx_service'],
  }

  # Manage web root directory
  file { '/var/www/html':
    ensure => directory,
    owner  => 'www-data',
    group  => 'www-data',
    mode   => '0755',
  }

  # Enforce running service state and register subscription
  service { 'nginx_service':
    ensure     => running,
    name       => $service_name,
    enable     => true,
    hasrestart => true,
    hasstatus  => true,
    subscribe  => File['nginx_config'],
  }
}

# Node mapping applying the class
node default {
  include role::webserver
}
```

---

### 2.2 Production Chef Recipe (`/var/chef/cookbooks/webserver/recipes/default.rb`)

```ruby
# frozen_string_literal: true

# Extract platform-specific parameters from node attributes
pkg_name = node['platform_family'] == 'rhel' ? 'httpd' : 'nginx'
svc_name = node['platform_family'] == 'rhel' ? 'httpd' : 'nginx'

# Install package during Converge Phase
package 'webserver_package' do
  package_name pkg_name
  action :install
end

# Create web root directory
directory '/var/www/html' do
  owner 'www-data'
  group 'www-data'
  mode '0755'
  recursive true
  action :create
end

# Render configuration file and signal delayed service restart
file '/etc/nginx/conf.d/app.conf' do
  owner 'root'
  group 'root'
  mode '0644'
  content lazy {
    port_num = node['webserver']['listen_port'] || '8080'
    "server {\n    listen #{port_num};\n    server_name _;\n    location / {\n        root /var/www/html;\n        index index.html;\n    }\n}\n"
  }
  action :create
  notifies :restart, "service[#{svc_name}]", :delayed
end

# Define service resource with explicit actions
service svc_name do
  supports status: true, restart: true
  action [:enable, :start]
end
```

---

## 3. Real CLI Commands & Output Signatures

### 3.1 Puppet Inspection and Dry-Run CLI

#### Command 1: Fact Inspection via `facter`
```bash
facter os.family os.name architecture ipaddress
```
**Expected Output:**
```json
{
  "architecture": "x86_64",
  "ipaddress": "192.168.122.45",
  "os": {
    "family": "Debian",
    "name": "Ubuntu"
  }
}
```

#### Command 2: Resource Inspection via `puppet resource`
```bash
puppet resource service nginx
```
**Expected Output:**
```puppet
service { 'nginx':
  ensure => 'running',
  enable => 'true',
}
```

#### Command 3: Dry-run Manifest Evaluation (`puppet apply --noop`)
```bash
puppet apply --noop --verbose /etc/puppetlabs/code/environments/production/manifests/site.pp
```
**Expected Output:**
```text
Info: Loading facts
Info: Applying configuration version '1723032400'
Notice: /Stage[main]/Role::Webserver/File[nginx_config]/ensure: current_value 'absent', should be 'file' (noop)
Notice: /Stage[main]/Role::Webserver/Service[nginx_service]: Would have triggered 'refresh' from 1 event
Notice: Class[Role::Webserver]: Would have triggered 'refresh' from 1 event
Notice: Stage[main]: Would have triggered 'refresh' from 1 event
Notice: Applied catalog in 0.14 seconds
```

---

### 3.2 Chef Inspection and Execution CLI

#### Command 1: Attribute Discovery via `ohai`
```bash
ohai platform platform_version ipaddress
```
**Expected Output:**
```json
{
  "platform": "ubuntu",
  "platform_version": "22.04",
  "ipaddress": "192.168.122.45"
}
```

#### Command 2: Standalone Recipe Execution via `chef-apply`
```bash
chef-apply -e "package 'curl' do action :install end"
```
**Expected Output:**
```text
Recipe: (checksum file)
  * package[curl] action install
    - install version 7.81.0-1ubuntu1.16 of package curl
```

#### Command 3: Local Mode Execution via `chef-client --local-mode`
```bash
chef-client --local-mode --override-runlist 'recipe[webserver]'
```
**Expected Output:**
```text
[2026-08-07T08:24:44+00:00] INFO: Started chef-client in local mode
[2026-08-07T08:24:44+00:00] INFO: Processing package[webserver_package] action install
[2026-08-07T08:24:45+00:00] INFO: package[webserver_package] installed nginx version 1.18.0-0ubuntu1.4
[2026-08-07T08:24:45+00:00] INFO: Processing file[/etc/nginx/conf.d/app.conf] action create
[2026-08-07T08:24:45+00:00] INFO: file[/etc/nginx/conf.d/app.conf] updated file content
[2026-08-07T08:24:45+00:00] INFO: file[/etc/nginx/conf.d/app.conf] sending restart action to service[nginx] (delayed)
[2026-08-07T08:24:45+00:00] INFO: Processing service[nginx] action enable
[2026-08-07T08:24:45+00:00] INFO: Processing service[nginx] action start
[2026-08-07T08:24:45+00:00] INFO: Processing service[nginx] action restart
[2026-08-07T08:24:45+00:00] INFO: service[nginx] restarted
[2026-08-07T08:24:45+00:00] INFO: Chef Infra Client Run complete
```

---

## 4. Guided Hands-On Lab Exercises

### Exercise 1: Puppet Catalog Inspection, Dependency Graphing, and Dry-Run Validation

En este ejercicio, crearás un Puppet manifest independiente que contiene una sintaxis explícita de cadena de dependencias, consultarás el estado del sistema local con `facter` y `puppet resource`, y ejecutarás una evaluación no destructiva del catalog en modo dry-run.

#### Step 1: Create a Puppet manifest workspace
Crea un directorio llamado `/tmp/puppet_lab` y abre un archivo llamado `/tmp/puppet_lab/check_sshd.pp`.

```bash
mkdir -p /tmp/puppet_lab
cat << 'EOF' > /tmp/puppet_lab/check_sshd.pp
package { 'openssh-server':
  ensure => installed,
  before => File['/tmp/puppet_lab/sshd_banner'],
}

file { '/tmp/puppet_lab/sshd_banner':
  ensure  => file,
  content => "Authorized Access Only\n",
  owner   => 'root',
  mode    => '0644',
  notify  => Service['ssh_service'],
}

service { 'ssh_service':
  ensure     => running,
  name       => $facts['os']['family'] ? {
    'RedHat' => 'sshd',
    default  => 'ssh',
  },
  enable     => true,
  hasstatus  => true,
  hasrestart => true,
}
EOF
```

#### Step 2: Query system facts using Facter
Ejecuta `facter` para evaluar la ruta de decisión dinámica utilizada por la búsqueda `$facts['os']['family']` en el manifest:

```bash
facter os.family
```

#### Step 3: Inspect the live system service resource via Puppet RAL
Consulta el estado de configuración actual en vivo del servicio SSH directamente a través del Resource Abstraction Layer de Puppet sin escribir código:

```bash
puppet resource service ssh || puppet resource service sshd
```

#### Step 4: Run a dry-run evaluation using `--noop`
Ejecuta `puppet apply` en modo dry-run para compilar el Catalog JSON y simular el orden de dependencias sin modificar el estado del sistema:

```bash
puppet apply --noop --verbose /tmp/puppet_lab/check_sshd.pp
```

---

#### Question 1.1
Durante la compilación del catalog en el Paso 4, ¿qué componente traduce la declaración genérica `package { 'openssh-server': ensure => installed }` en comandos operacionales nativos como `apt-get install` o `yum install`?
- A) Puppet Server AST Engine
- B) Facter Provider Core
- C) Resource Abstraction Layer (RAL)
- D) Directed Acyclic Graph (DAG) Compiler

#### Question 1.2
Si el recurso file `/tmp/puppet_lab/sshd_banner` se actualiza en un nodo, ¿cómo aplica Puppet el orden definido por `notify => Service['ssh_service']`?
- A) Puppet recompila el catalog desde cero y reinicia todos los recursos definidos.
- B) Puppet ejecuta el recurso Service después del recurso File y envía un evento de actualización (*refresh event*) para activar el reinicio del servicio.
- C) Puppet detiene el recurso Service antes de modificar el recurso File, y luego lo vuelve a iniciar.
- D) Puppet activa inmediatamente una llamada HTTP POST sincrónica a Puppet Server para verificar el cumplimiento de la licencia.

---

### Exercise 2: Chef Two-Phase Execution Lifecycle and Lazy Evaluation Debugging

En este ejercicio, analizarás la distinción entre la Compile Phase y la Converge Phase de Chef escribiendo una recipe con mutaciones de variables y evaluación perezosa (*lazy property evaluation*).

#### Step 1: Create a Chef workspace directory
Crea `/tmp/chef_lab` y abre un archivo de recipe llamado `/tmp/chef_lab/lifecycle.rb`.

```bash
mkdir -p /tmp/chef_lab
cat << 'EOF' > /tmp/chef_lab/lifecycle.rb
target_file = '/tmp/chef_lab/dynamic_config.txt'
run_state_var = 'INITIAL_COMPILE_VALUE'

puts "=== [COMPILE PHASE] Evaluating Ruby code. run_state_var = #{run_state_var} ==="

ruby_block 'mutate_variable_at_converge' do
  block do
    run_state_var = 'MUTATED_IN_CONVERGE_PHASE'
    puts "=== [CONVERGE PHASE] Executed ruby_block. run_state_var is now = #{run_state_var} ==="
  end
  action :run
end

file target_file do
  owner 'root'
  mode '0644'
  content lazy { "Final state: #{run_state_var}\n" }
  action :create
end
EOF
```

#### Step 2: Query system facts using Ohai
Ejecuta `ohai` para verificar las propiedades del sistema operativo del nodo utilizadas por las recipes de Chef:

```bash
ohai platform platform_family
```

#### Step 3: Execute the recipe using `chef-apply`
Ejecuta `chef-apply` para observar los registros de consola emitidos a lo largo de las dos fases diferenciadas:

```bash
chef-apply /tmp/chef_lab/lifecycle.rb
```

#### Step 4: Verify generated file content
Verifica que el bloque de evaluación `lazy` haya capturado con éxito el valor mutado durante la Converge Phase:

```bash
cat /tmp/chef_lab/dynamic_config.txt
```

---

#### Question 2.1
¿Qué se escribiría en `/tmp/chef_lab/dynamic_config.txt` si la propiedad `content` en el Ejercicio 2, Paso 1 **NO** utilizara el envoltura de bloque `lazy { ... }`?
- A) `Final state: MUTATED_IN_CONVERGE_PHASE`
- B) `Final state: INITIAL_COMPILE_VALUE`
- C) La ejecución fallaría con un error de sintaxis durante la Compile Phase.
- D) El archivo se crearía completamente vacío (0 bytes).

#### Question 2.2
¿Qué afirmación describe con precisión el comportamiento de ejecución de Chef al evaluar una recipe estándar que contiene recursos `package`, `template` y `service`?
- A) Chef ejecuta comandos de shell del sistema línea por línea tan pronto como cada bloque de recurso es analizado en Ruby.
- B) Chef analiza todos los recursos en un Árbol Acíclico Dirigido (DAG) y los ejecuta de forma concurrente utilizando grupos de hilos (*thread pools*).
- C) Chef construye un arreglo ordenado `Resource Collection` durante la Compile Phase, y luego evalúa secuencialmente el estado del sistema y aplica actualizaciones durante la Converge Phase.
- D) Chef carga la recipe en el Chef Server, el cual compila una carga útil binaria inmutable y la envía de vuelta vía SSH.

---

## 5. Official References

- **Linux Professional Institute (LPI):** [LPI DevOps Tools Engineer Exam 701-100 Objectives Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **Puppet Architecture & Catalog Compilation Documentation:** [Puppet Core Architecture & Catalog Compilation](https://www.puppet.com/docs/puppet/7/architecture.html)
- **Chef Infra Execution & Two-Phase Lifecycle Documentation:** [Chef Infra Client Overview & Lifecycle](https://docs.chef.io/chef_overview/)

---

<details>
<summary><strong>Respuestas y soluciones</strong></summary>

### Exercise 1 Answer Key

#### Question 1.1
- **Respuesta correcta:** **C) Resource Abstraction Layer (RAL)**
- **Explicación:** El Resource Abstraction Layer (RAL) desacopla la sintaxis declarativa de alto nivel de Puppet (`package`) de los gestores de paquetes dependientes de la plataforma. Utiliza los facts del sistema para seleccionar el **Provider** adecuado (como `apt`, `yum` o `zypper`) para ejecutar comandos nativos de gestión de paquetes en el host objetivo.

#### Question 1.2
- **Respuesta correcta:** **B) Puppet executes the Service resource after the File resource and sends a refresh event to trigger a service restart.**
- **Explicación:** En Puppet, `notify` establece tanto una dependencia de ejecución (el recurso objetivo se ejecuta después del recurso notificador) como el envío de un evento de actualización (*refresh event*). Cuando el recurso service recibe este evento, su provider ejecuta su comando de reinicio (si `hasrestart => true`).

---

### Exercise 2 Answer Key

#### Question 2.1
- **Respuesta correcta:** **B) Final state: INITIAL_COMPILE_VALUE**
- **Explicación:** Sin `lazy { ... }`, Chef evalúa la variable Ruby `run_state_var` durante la **Compile Phase** cuando el recurso file se instancia por primera vez en memoria. En ese punto del tiempo, `run_state_var` contiene `'INITIAL_COMPILE_VALUE'`. Envolver el contenido dentro de `lazy` pospone la evaluación hasta la **Converge Phase**, después de que `ruby_block` se haya ejecutado y mutado la variable a `'MUTATED_IN_CONVERGE_PHASE'`.

#### Question 2.2
- **Respuesta correcta:** **C) Chef builds an ordered Resource Collection array during the Compile Phase, then sequentially evaluates system state and applies updates during the Converge Phase.**
- **Explicación:** Chef utiliza strictly un ciclo de vida de ejecución en dos fases. En la Fase 1 (Compile Phase), el código Ruby se evalúa para poblar el arreglo `Resource Collection`. En la Fase 2 (Converge Phase), Chef itera secuencialmente a través del arreglo, invocando providers para inspeccionar y alinear el estado del sistema de manera idempotente.
</details>