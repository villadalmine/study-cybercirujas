# LPI DevOps Tools Engineer (Examen 701-100)
## Tema 704.2: Other Configuration Management Tools
**Ponderación del examen:** 2 (Ponderación relativa del tema: 3.34)  
**Audiencia objetivo:** SREs, DevOps Engineers y Platform Architects

---

### 1. Motivación arquitectónica y planteamiento del problema en producción

En infraestructuras empresariales a gran escala, la gestión del estado a través de miles de instancias de cómputo heterogéneas mediante scripts de shell imperativos introduce un severo drift de configuración, opacidad operacional y fallos de despliegue no deterministas. 

La gestión de configuración tradicional aborda esto a través de la **convergencia declarativa de estado** y la **idempotencia**:
* **Idempotencia:** Una operación ejecutada $N$ veces produce exactamente el mismo estado del sistema que una operación ejecutada una sola vez ($f(f(x)) = f(x)$).
* **Convergencia de estado:** El motor de configuración compara el *estado deseado* definido en el código de entrega continua frente al *estado actual* descubierto en el host de destino, ejecutando únicamente las operaciones de mutación delta necesarias para alinear el estado actual con el estado deseado.

#### Paradigmas arquitectónicos: Pull vs. Push y Agente vs. Agentless

```
[ Centralized Server ] <--- TLS Pull (30m Interval) --- [ Node Agent (Puppet/Chef) ]
     (Catalog/Cookbook)                                        (Local Evaluation Engine)

[ CI/CD Control Plane ] --- SSH/WinRM Push (Ad-hoc) ---> [ Target Node (Ansible) ]
     (Playbooks/Modules)                                       (Ephemeral Python Exec)
```

1. **Arquitectura Pull (Puppet / Chef-Client):**
   * **Mecánica:** Un daemon en segundo plano (`puppet-agent` o `chef-client`) se ejecuta periódicamente (por defecto: 30 minutos) en el host de destino. Recopila el estado del host ("facts" o "attributes"), los envía a un servidor centralizado (Puppet Server o Chef Server), recibe un plan de ejecución compilado (Catalog o Compiled Node Object) y aplica las mutaciones de estado localmente.
   * **Trade-offs en producción:** Alta escalabilidad autónoma (sin límites de conexiones SSH persistentes en el plano de control), remediación autorreparable de drift de configuración, pero requiere gestión del ciclo de vida del agente, infraestructura PKI para confianza de certificados mutual TLS, y huella de memoria en el servidor centralizado.

2. **Arquitectura Push (Ansible / Chef-Solo / Puppet Apply):**
   * **Mecánica:** Una máquina de orquestación empuja instrucciones de configuración sobre protocolos de gestión transitorios (SSH/WinRM) o ejecuta localmente (`puppet apply`, `chef-solo`).
   * **Trade-offs en producción:** Huella de agente nula (zero agent footprint) en los nodos de destino, fase de bootstrap más simple, pero sufre de cuellos de botella de escalabilidad al empujar a decenas de miles de instancias de forma concurrente sin sharding del orquestador.

---

### 2. Comparación técnica y matriz de trade-offs

| Eje arquitectónico | Puppet | Chef | Ansible |
| :--- | :--- | :--- | :--- |
| **Modelo de ejecución** | Declarative DSL (Puppet Code) | Imperative DSL (Ruby DSL) | Declarative / Procedural (YAML) |
| **Topología primaria** | Master/Agent (Pull) o Masterless (`puppet apply`) | Client/Server (Pull) o Local (`chef-solo`) | Control Node / Agentless (Push a través de SSH) |
| **Motor de resolución de estado** | DAG (Directed Acyclic Graph) basado en grafos | Recopilación y ejecución secuencial de recursos | Ejecución secuencial de tareas de Playbook |
| **Mecanismo de descubrimiento** | Facter (System Facts) | Ohai (System Attributes) | Ansible Facts (Gathers Facts) |
| **Unidad de abstracción central** | Classes, Manifests (`.pp`), Modules | Recipes (`.rb`), Cookbooks, Resources | Tasks, Roles, Playbooks (`.yml`) |
| **Compilación de estado** | El Master compila Manifests en un **Catalog** JSON | El Server combina Node Attributes y Recipes en un **Node Object** | El Control node renderiza plantillas Jinja2 en parámetros de módulo |
| **Garantía de orden** | Relaciones entre recursos (`before`, `require`, `notify`) | Orden de ejecución lineal por defecto | Lineal paso a paso de arriba a abajo |
| **Capa de PKI / Confianza** | Puppet CA integrado / Certificados de cliente X.509 | Claves de cliente de Chef Server / Autenticación por par de claves RSA | Infraestructura de clave pública SSH / Vault |

---

### 3. Manifiestos y configuraciones de infraestructura completos y sintácticamente válidos

#### 3.1 Manifiesto de Puppet Enterprise: Servidor Web Nginx de Producción

A continuación se presenta una estructura de módulo y manifiesto completos de Puppet que demuestran clases orientadas a objetos, integración de datos con Hiera, atributos de recursos y nodos de grafo con ordenamiento explícito de dependencias (`require`, `notify`).

##### Estructura de directorios:
```text
/etc/puppetlabs/code/environments/production/
├── manifests/
│   └── site.pp
└── modules/
    └── nginx_app/
        └── manifests/
            └── init.pp
```

##### Archivo: `/etc/puppetlabs/code/environments/production/modules/nginx_app/manifests/init.pp`
```puppet
# Class: nginx_app
# Manages the installation, configuration, and service state of Nginx web server.
class nginx_app (
  String $package_name              = 'nginx',
  String $service_name              = 'nginx',
  String $config_path               = '/etc/nginx/nginx.conf',
  String $doc_root                  = '/var/www/html',
  Enum['running', 'stopped'] $state = 'running',
  Boolean $enable_service           = true,
) {

  # Ensure the doc root directory exists prior to configuration
  file { $doc_root:
    ensure => 'directory',
    owner  => 'www-data',
    group  => 'www-data',
    mode   => '0755',
  }

  # Manage Package Installation
  package { 'nginx_package':
    ensure => 'present',
    name   => $package_name,
  }

  # Manage Configuration File with Notification to Service
  file { 'nginx_config':
    ensure  => 'file',
    path    => $config_path,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @(CONF),
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        root /var/www/html;
        index index.html index.htm;
        server_name _;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
| CONF
    require => Package['nginx_package'],
    notify  => Service['nginx_service'],
  }

  # Manage Application Index File
  file { "${doc_root}/index.html":
    ensure  => 'file',
    owner   => 'www-data',
    group   => 'www-data',
    mode    => '0644',
    content => "<html><body><h1>Deployed via Puppet Manifest</h1></body></html>\n",
    require => File[$doc_root],
  }

  # Service Control Engine
  service { 'nginx_service':
    ensure     => $state,
    name       => $service_name,
    enable     => $enable_service,
    hasrestart => true,
    hasstatus  => true,
    require    => Package['nginx_package'],
  }
}
```

##### Archivo: `/etc/puppetlabs/code/environments/production/manifests/site.pp`
```puppet
node default {
  include nginx_app
}
```

---

#### 3.2 Cookbook de Chef Standalone (Chef-Solo / Modo Local)

Chef utiliza DSL de Ruby para describir recursos del sistema secuencialmente dentro de recetas contenidas en cookbooks.

##### Estructura de directorios:
```text
/var/chef/cookbooks/
└── webserver/
    ├── attributes/
    │   └── default.rb
    ├── metadata.rb
    ├── recipes/
    │   └── default.rb
    └── templates/
        └── nginx.conf.erb
```

##### Archivo: `/var/chef/cookbooks/webserver/metadata.rb`
```ruby
name             'webserver'
maintainer       'SRE Platform Team'
maintainer_email 'sre@company.internal'
license          'Apache-2.0'
description      'Installs and configures production Nginx webserver'
version          '1.0.0'
chef_version     '>= 16.0'
supports         'ubuntu'
```

##### Archivo: `/var/chef/cookbooks/webserver/attributes/default.rb`
```ruby
default['webserver']['package_name']  = 'nginx'
default['webserver']['service_name']  = 'nginx'
default['webserver']['config_path']   = '/etc/nginx/nginx.conf'
default['webserver']['doc_root']      = '/var/www/html'
default['webserver']['port']          = 80
default['webserver']['worker_conns']  = 1024
```

##### Archivo: `/var/chef/cookbooks/webserver/templates/nginx.conf.erb`
```erb
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections <%= node['webserver']['worker_conns'] %>;
}

http {
    sendfile on;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen <%= node['webserver']['port'] %> default_server;
        root <%= node['webserver']['doc_root'] %>;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
```

##### Archivo: `/var/chef/cookbooks/webserver/recipes/default.rb`
```ruby
# Update package repositories on Debian/Ubuntu systems
apt_update 'update_sources' do
  action :update
end

# Install Package Resource
package node['webserver']['package_name'] do
  action :install
end

# Create Web Root Directory
directory node['webserver']['doc_root'] do
  owner 'www-data'
  group 'www-data'
  mode '0755'
  recursive true
  action :create
end

# Deploy Template Resource with Service Notification
template node['webserver']['config_path'] do
  source 'nginx.conf.erb'
  owner 'root'
  group 'root'
  mode '0644'
  notifies :reload, "service[#{node['webserver']['service_name']}]", :immediately
end

# Deploy Index HTML Document
file "#{node['webserver']['doc_root']}/index.html" do
  content '<html><body><h1>Deployed via Chef Recipe</h1></body></html>'
  owner 'www-data'
  group 'www-data'
  mode '0644'
  action :create
end

# Enable and Start Service Resource
service node['webserver']['service_name'] do
  supports status: true, restart: true, reload: true
  action [:enable, :start]
end
```

##### Archivo: `/var/chef/solo.rb`
```ruby
file_cache_path "/var/chef/cache"
cookbook_path   ["/var/chef/cookbooks"]
log_level       :info
log_location    STDOUT
```

##### Archivo: `/var/chef/solo.json`
```json
{
  "run_list": [
    "recipe[webserver::default]"
  ]
}
```

---

### 4. Comandos reales de CLI y salidas de terminal esperadas

#### 4.1 Diagnóstico y ejecución de Puppet CLI

##### Aplicación de catálogo en modo Dry-run (`puppet apply --noop`)
Valida la sintaxis y muestra las modificaciones intencionadas sin mutar el estado del sistema:

```bash
$ puppet apply --noop --environment=production /etc/puppetlabs/code/environments/production/manifests/site.pp
```
```text
Notice: Compiled catalog for node01.production.internal in environment production in 0.18 seconds
Notice: /Stage[main]/Nginx_app/File[/var/www/html]/ensure: current_value 'absent', should be 'directory' (noop)
Notice: /Stage[main]/Nginx_app/Package[nginx_package]/ensure: current_value 'purged', should be 'present' (noop)
Notice: /Stage[main]/Nginx_app/File[nginx_config]/ensure: current_value 'absent', should be 'file' (noop)
Notice: /Stage[main]/Nginx_app/File[/var/www/html/index.html]/ensure: current_value 'absent', should be 'file' (noop)
Notice: /Stage[main]/Nginx_app/Service[nginx_service]/ensure: current_value 'stopped', should be 'running' (noop)
Notice: Class[Nginx_app]: Would have triggered 'refresh' from 1 event
Notice: Stage[main]: Would have triggered 'refresh' from 1 event
Notice: Applied catalog in 0.05 seconds
```

##### Ejecución completa de Puppet (`puppet apply`)

```bash
$ puppet apply /etc/puppetlabs/code/environments/production/manifests/site.pp
```
```text
Notice: Compiled catalog for node01.production.internal in environment production in 0.22 seconds
Notice: /Stage[main]/Nginx_app/File[/var/www/html]/ensure: created
Notice: /Stage[main]/Nginx_app/Package[nginx_package]/ensure: created
Notice: /Stage[main]/Nginx_app/File[nginx_config]/ensure: defined content as '{sha256}a289063c5a176bfb8db1726a8d67ec7e4663806f0e6530663c0a256a06df5c76'
Notice: /Stage[main]/Nginx_app/File[/var/www/html/index.html]/ensure: created
Notice: /Stage[main]/Nginx_app/Service[nginx_service]/ensure: change from 'stopped' to 'running'
Notice: /Stage[main]/Nginx_app/Service[nginx_service]: Triggered 'refresh' from 1 event
Notice: Applied catalog in 3.41 seconds
```

##### Inspección de atributos del sistema con Facter

```bash
$ facter os.family networking.ip
```
```json
{
  "networking.ip": "192.168.1.50",
  "os.family": "Debian"
}
```

##### Ejecución Cliente-Servidor de Puppet Agent

```bash
$ puppet agent --test --debug
```
```text
Debug: Retrieving pluginfacts
Debug: Retrieving plugin
Debug: Loading facts from /var/puppet/lib/facter/custom_fact.rb
Info: Caching catalog for node01.production.internal
Info: Applying configuration version '1723015482'
Notice: Applied catalog in 0.48 seconds
```

---

#### 4.2 Diagnóstico y ejecución de Chef CLI

##### Ejecución local mediante `chef-solo`

```bash
$ chef-solo -c /var/chef/solo.rb -j /var/chef/solo.json
```
```text
[2026-08-07T08:30:10+00:00] INFO: Started chef-zero at http://127.0.0.1:8889 with pid 14205
[2026-08-07T08:30:10+00:00] INFO: *** Chef Infra Client 17.10.3 ***
[2026-08-07T08:30:10+00:00] INFO: Platform: x86_64-linux
[2026-08-07T08:30:10+00:00] INFO: Run List expands to [recipe[webserver::default]]
[2026-08-07T08:30:10+00:00] INFO: Starting Chef Infra Client Run for node01.production.internal
[2026-08-07T08:30:12+00:00] INFO: Processing apt_update[update_sources] action update (webserver::default line 2)
[2026-08-07T08:30:13+00:00] INFO: Processing package[nginx] action install (webserver::default line 7)
[2026-08-07T08:30:15+00:00] INFO: Processing directory[/var/www/html] action create (webserver::default line 12)
[2026-08-07T08:30:15+00:00] INFO: Processing template[/etc/nginx/nginx.conf] action create (webserver::default line 20)
[2026-08-07T08:30:15+00:00] INFO: template[/etc/nginx/nginx.conf] updated file content
[2026-08-07T08:30:15+00:00] INFO: template[/etc/nginx/nginx.conf] sending reload action to service[nginx] (immediately)
[2026-08-07T08:30:15+00:00] INFO: Processing service[nginx] action reload (webserver::default line 37)
[2026-08-07T08:30:15+00:00] INFO: service[nginx] reloaded
[2026-08-07T08:30:15+00:00] INFO: Processing file[/var/www/html/index.html] action create (webserver::default line 29)
[2026-08-07T08:30:15+00:00] INFO: Processing service[nginx] action enable (webserver::default line 37)
[2026-08-07T08:30:15+00:00] INFO: Processing service[nginx] action start (webserver::default line 37)
[2026-08-07T08:30:15+00:00] INFO: Chef Infra Client Run complete 6/7 resources updated in 05 seconds
```

##### Ejecución local mediante `chef-client --local-mode`

```bash
$ chef-client --local-mode --override-runlist 'recipe[webserver::default]'
```
```text
[2026-08-07T08:32:00+00:00] INFO: Starting Chef Infra Client, version 17.10.3 in local mode
[2026-08-07T08:32:01+00:00] INFO: Converging 6 resources
[2026-08-07T08:32:01+00:00] INFO: Chef Infra Client Run complete 0/6 resources updated in 01 seconds
```

##### Descubrimiento de atributos del sistema con Ohai

```bash
$ ohai platform platform_version ipaddress
```
```json
[
  "ubuntu",
  "22.04",
  "192.168.1.50"
]
```

---

### 5. Guía de verificación, resolución de problemas y diagnóstico de fallos

#### 5.1 Diagrama de flujo de diagnóstico de Puppet y errores comunes

```
                      [ Run Puppet Command ]
                                |
                   Did Catalog Compilation Succeed?
                             /        \
                          (No)        (Yes)
                           /            \
          [ Check Syntax/Graph ]      Does Execution Converge?
          - puppet parser validate       /             \
          - Check Circular Dependency  (No)           (Yes)
                                        /               \
                       [ Trace OS/Resource Error ]  [ State Verified ]
                       - Check /var/log/syslog
                       - Verify file permissions
```

##### Error 1: Fallo de compilación del catálogo (Dependency Cycle)
* **Síntoma:**
  ```text
  Error: Could not compile catalog for node node01.production.internal: Found 1 dependency cycle:
  (File[/var/www/html] => Package[nginx_package] => File[/var/www/html])
  Cycle graph written to /var/puppet/state/graphs/cycles.dot.
  ```
* **Causa raíz:** Bucle de dependencia entre recursos creado mediante metarámetros `require` o `before` referenciados mutuamente.
* **Resolución:** Inspeccionar las relaciones utilizando `puppet parser validate` y una herramienta de visualización de grafos:
  ```bash
  $ dot -Tpng /var/puppet/state/graphs/cycles.dot -o cycle.png
  ```
  Eliminar la lógica de dependencia circular de los archivos de manifiesto.

##### Error 2: Fallo de verificación del certificado TLS (Master-Agent Pull)
* **Síntoma:**
  ```text
  Error: Could not request certificate from CA server: SSL_connect returned=1 errno=0 state=error: certificate verify failed: [certificate revoked for puppet-master.internal]
  ```
* **Causa raíz:** Desviación de tiempo (time drift) entre el agente y el master, o certificado de cliente obsoleto en la Puppet CA.
* **Resolución:**
  1. Sincronizar los relojes del sistema mediante NTP/chrony: `$ chronyc tracking`
  2. Limpiar el estado SSL del cliente local en el nodo: `$ rm -rf /etc/puppetlabs/puppet/ssl`
  3. Limpiar el certificado en el Puppet Server: `$ puppetserver ca clean --certname node01.production.internal`
  4. Reemitir la solicitud de certificado: `$ puppet agent -t`

---

#### 5.2 Diagnóstico de Chef y errores comunes

##### Error 1: Fallo de compilación de receta (Ruby Syntax Error)
* **Síntoma:**
  ```text
  ================================================================================
  Recipe Compile Error in /var/chef/cookbooks/webserver/recipes/default.rb
  ================================================================================
  SyntaxError
  -----------
  /var/chef/cookbooks/webserver/recipes/default.rb:22: syntax error, unexpected end-of-input, expecting `end'
  ```
* **Causa raíz:** Bloque Ruby sin cerrar (`do ... end`) dentro de la lógica de la receta.
* **Resolución:** Ejecutar análisis con Ruby linter / Foodcritic / Cookstyle:
  ```bash
  $ cookstyle /var/chef/cookbooks/webserver
  ```

##### Error 2: Fallo de ejecución en la convergencia de recursos
* **Síntoma:**
  ```text
  ================================================================================
  Error Executing Resource Block
  ================================================================================
  Mixlib::ShellOut::ShellCommandFailed
  ------------------------------------
  template[/etc/nginx/nginx.conf] (webserver::default line 20) had an error:
  Errno::ENOENT: No such file or directory @ rb_sysopen - /etc/nginx/nginx.conf.tmp2026-8712
  ```
* **Causa raíz:** El directorio padre `/etc/nginx` no existe antes de escribir la plantilla porque el recurso de paquete se omitió o falló durante la ejecución.
* **Resolución:** Asegurar un orden de ejecución explícito en la receta o verificar el acceso al repositorio para la instalación del paquete.

---

### 6. Referencias

* **Visión general y objetivos oficiales de LPI DevOps Tools Engineer:**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Objetivos en la Wiki de LPI V1 (Tema 704.2):**  
  [https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1](https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1)
* **Especificación del lenguaje y documentación de arquitectura de Puppet:**  
  [https://www.puppet.com/docs/puppet/7/architecture.html](https://www.puppet.com/docs/puppet/7/architecture.html)
* **Documentación y recursos de Chef Infra:**  
  [https://docs.chef.io/chef_overview/](https://docs.chef.io/chef_overview/)