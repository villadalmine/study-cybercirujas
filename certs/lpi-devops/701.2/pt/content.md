# 701.2 — Componentes e Plataformas Padrão para Software

**Certificação:** LPI DevOps Tools Engineer (exame 701-100, versão 2.0.0)
**Peso do tópico:** 5.0
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. O problema arquitetural: você está montando uma plataforma, não escrevendo uma

Todo serviço não trivial que você venha a rodar em produção é uma camada fina da sua própria lógica de negócio assentada sobre seis ou sete componentes que outra pessoa já escreveu: um substrato de computação, um armazenamento durável, um banco de dados transacional, um cache, um message broker, um object store e uma borda de ingress/CDN. A decisão de engenharia quase nunca é *"deveríamos ter um cache?"* — ela é **qual cache, operado por quem, com quais semânticas de falha, a que custo, e o que acontece com o resto da plataforma quando ele falha.**

Este objetivo existe porque a classe de incidente de produção mais cara não é um bug no código da aplicação. É um **descompasso entre as garantias que um componente padrão de fato oferece e as garantias que a aplicação supôs que ele oferecia.**

Três formatos concretos dessa falha, todos presentes no mapa conceitual do exame:

1. **Descompasso de semântica de entrega.** Uma equipe constrói um pipeline de pedidos sobre RabbitMQ com `autoAck` habilitado porque "ficou mais rápido no benchmark". Um pod consumidor sofre OOM-kill no meio de uma transação. O broker já havia removido a mensagem no momento da entrega. Pedidos desaparecem sem erro, sem alerta e sem rastro — o gráfico de profundidade da fila está plano e verde. O componente estava correto; a suposição ("o broker vai reentregar") não.

2. **Descompasso de fronteira de responsabilidade.** Uma equipe migra de PostgreSQL auto-hospedado para um DBaaS gerenciado e mantém um cron noturno de `pg_dump` num host bastion. Dezoito meses depois descobre-se que os backups automáticos do provedor têm retenção de 7 dias enquanto o requisito de compliance é de 35 dias, e que o bastion foi desativado numa rodada de corte de custos. Ninguém era dono da lacuna, porque cada lado supôs que o outro era.

3. **Descompasso de elasticidade.** Uma função serverless é posta na frente de um banco relacional de tamanho fixo. O tráfego triplica. A plataforma FaaS obedientemente escala para 900 invocações concorrentes, cada uma abrindo uma conexão. O `max_connections = 200` do PostgreSQL se esgota em quatro segundos; todo outro serviço que compartilha o banco — inclusive o caminho do healthcheck — começa a falhar. A camada elástica transformou a inelástica em arma.

A disciplina que evita as três é a mesma: **para cada componente padrão, conheça seu modelo de serviço, seu modelo de consistência, suas semânticas de entrega, seu eixo de escalabilidade e seu modelo de custo — e escreva tudo isso como um contrato explícito antes da primeira linha de código.**

---

## 2. Modelos de serviço e a fronteira de responsabilidade

A divisão clássica IaaS/PaaS/SaaS não é taxonomia de marketing; é um **mapa de quem é acordado às 03:00**. Leia a tabela como uma matriz de responsabilidade, não como uma lista de produtos.

| Camada | IaaS | CaaS | PaaS | FaaS | SaaS |
|---|---|---|---|---|---|
| Físico / DC | Provedor | Provedor | Provedor | Provedor | Provedor |
| Hypervisor | Provedor | Provedor | Provedor | Provedor | Provedor |
| SO convidado + CVEs de kernel | **Você** | Provedor | Provedor | Provedor | Provedor |
| Container runtime | **Você** | Provedor | Provedor | Provedor | Provedor |
| Orquestração / escalonamento | **Você** | Provedor* | Provedor | Provedor | Provedor |
| Runtime de linguagem + patches | **Você** | **Você** (imagem) | Provedor (buildpack) | Provedor | Provedor |
| Código da aplicação | **Você** | **Você** | **Você** | **Você** | Provedor |
| Dados / controle de acesso | **Você** | **Você** | **Você** | **Você** | **Você** |
| Política de escala | **Você** | **Você** | Declarativa | Automática | Provedor |
| Unidade de deploy | Imagem de VM | Imagem de container | Fonte / buildpack | Function handler | Nada |
| Lead time típico até o primeiro deploy | Dias | Horas | Minutos | Minutos | Zero |
| Superfície de lock-in | Baixa (imagens, cloud-init) | Baixa (OCI, API do Kubernetes) | Média (buildpacks, service brokers) | **Alta** (formatos de evento, IAM, runtime) | Total |

\* Control plane Kubernetes gerenciado; o node pool ainda é seu, a menos que seja um container runtime totalmente serverless.

**A regra que sobrevive a toda reorganização:** *dados e controle de acesso nunca passam para o provedor.* Criptografia em repouso ser "gerenciada pelo provedor" significa que o provedor gerencia a cifra, não a sua bucket policy.

### 2.1 O modelo de custo é parte da arquitetura

| Eixo de precificação | Onde dói | Magnitude típica (nuvem pública, 2026) | Consequência arquitetural |
|---|---|---|---|
| Computação on-demand | Serviços em regime estável | Linha de base 1,0× | Nunca é o preço certo para uma camada 24/7 |
| Reservado / uso comprometido | Compromisso de 1–3 anos | 0,4–0,65× | Exige previsão de capacidade, cria um piso |
| Spot / preemptível | Trabalho interrompível | 0,1–0,3× | Requer tratamento de drain e checkpointing |
| Egress para a Internet | Qualquer API tagarela ou mídia | US$ 0,05–0,12 / GiB | Domina a fatura de serviços de conteúdo; motiva CDN |
| Tráfego cross-AZ | Datastores replicados | US$ 0,01–0,02 / GiB em cada sentido | Um cluster Kafka em 3 AZ paga por cada salto de réplica |
| Por requisição | FaaS, object storage, API gateways | US$ 0,20–0,40 / milhão | Mata a conversa de granularidade fina; faça batch ou morra |
| IOPS provisionadas | Bancos de dados | US$ 0,05–0,65 / IOPS-mês | Muitas vezes excede o próprio custo de capacidade |
| Prêmio de serviço gerenciado | DBaaS vs auto-hospedado | 1,3–2,5× a infra bruta | Compare contra um salário de SRE carregado, não contra zero |

O cálculo honesto de auto-hospedado versus gerenciado é:

```
cost_managed  =  list_price
cost_selfhost =  infra + (engineer_fte_fraction * loaded_salary)
                 + expected_annual_downtime_hours * revenue_per_hour
                 + opportunity_cost_of_not_building_product
```

Um cluster PostgreSQL HA de três nós é aproximadamente 0,2–0,3 FTE depois que você conta patching, upgrades de versão maior, simulações de restauração de backup e testes de failover. A €120k carregados, isso são €24k–€36k/ano antes de um único euro de hardware — e é por isso que bancos relacionais gerenciados vencem para quase todo mundo abaixo de escala muito grande, e perdem acima dela.

---

## 3. Computação: máquinas virtuais, containers, funções

### 3.1 Matriz de trade-offs

| Propriedade | VM (KVM/Xen) | microVM (Firecracker/Cloud Hypervisor) | Container (runc) | Container em sandbox (gVisor/Kata) | FaaS |
|---|---|---|---|---|---|
| Cold start | 20–60 s | 125 ms – 1 s | 50–500 ms | 200 ms – 2 s | 100 ms – 10 s a frio, ~1 ms quente |
| Kernel | Próprio | Próprio (mínimo) | **Compartilhado com o host** | Próprio / em espaço de usuário | Do provedor |
| Fronteira de isolamento | Hypervisor | Hypervisor + modelo de dispositivo mínimo | namespaces, cgroups, seccomp, LSM | Interceptação de syscalls / hypervisor | microVM do provedor |
| Densidade por host | 10–40 | 100–1 000 | 100–300 | 50–200 | n/a |
| Tamanho da imagem | GiB | GiB | MiB | MiB | KiB–MiB |
| Estado local persistente | Nativo | Nativo | Só via volumes | Via volumes | **Nenhum** |
| Tempo máximo de execução | Ilimitado | Ilimitado | Ilimitado | Ilimitado | 15 min (AWS Lambda), 60 min (Cloud Run jobs) |
| Granularidade de cobrança | Por segundo, mínimo de 60 s | Por ms | Por node-segundo | Por node-segundo | Por ms + por requisição |
| Live migration | Sim | Limitada | Não | Não | n/a |
| Adequado para | Legado, módulos de kernel, isolamento rígido multi-tenant | Substrato serverless multi-tenant | Microsserviços stateless | Código não confiável em nós compartilhados | Trabalho curto, com picos, orientado a eventos |

**A ressalva sobre isolamento de containers que cai em entrevistas e em exames por igual:** um container é um *processo* com namespaces (`pid`, `net`, `mnt`, `uts`, `ipc`, `user`, `cgroup`), limites de cgroup, um filtro seccomp e um perfil LSM. Ele **não** é uma fronteira de segurança equivalente a uma VM — um LPE de kernel escapa dele. É exatamente por isso que Firecracker, gVisor e Kata existem: plataformas públicas de FaaS e CaaS não podem rodar tenants mutuamente desconfiados sobre um kernel compartilhado.

### 3.2 FaaS, de forma portável: Knative Serving

Knative é a resposta neutra de fornecedor para "Lambda, mas no meu Kubernetes". Ele dá scale-to-zero, autoscaling orientado a requisições e divisão de tráfego baseada em revisões. Manifesto completo e implantável:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: invoice-renderer
  namespace: functions
  labels:
    app.kubernetes.io/name: invoice-renderer
    app.kubernetes.io/part-of: billing-platform
spec:
  template:
    metadata:
      name: invoice-renderer-00007
      annotations:
        autoscaling.knative.dev/class: kpa.autoscaling.knative.dev
        autoscaling.knative.dev/metric: concurrency
        autoscaling.knative.dev/target: "20"
        autoscaling.knative.dev/min-scale: "2"
        autoscaling.knative.dev/max-scale: "60"
        autoscaling.knative.dev/window: "60s"
        autoscaling.knative.dev/scale-down-delay: "120s"
    spec:
      containerConcurrency: 25
      timeoutSeconds: 300
      responseStartTimeoutSeconds: 15
      serviceAccountName: invoice-renderer
      containers:
        - name: user-container
          image: registry.internal.example.com/billing/invoice-renderer@sha256:9f2c1d4b8a6e5037c2b1ae94d3f70c5d81ea2b46f0c9d7381ba5e6c0f4a21d38
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: PDF_ENGINE
              value: weasyprint
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: DB_DSN
              valueFrom:
                secretKeyRef:
                  name: invoice-renderer-db
                  key: dsn
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 10001
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: scratch
              mountPath: /tmp
      volumes:
        - name: scratch
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
  traffic:
    - revisionName: invoice-renderer-00006
      percent: 90
    - revisionName: invoice-renderer-00007
      percent: 10
      tag: canary
```

Faça o deploy e observe o comportamento de escala a partir do zero:

```
$ kubectl apply -f invoice-renderer.yaml
service.serving.knative.dev/invoice-renderer configured

$ kn service list -n functions
NAME               URL                                                      LATEST                   AGE   CONDITIONS   READY
invoice-renderer   http://invoice-renderer.functions.example.com             invoice-renderer-00007   12d   3 OK / 3     True

$ kn revision list -n functions
NAME                     SERVICE            TRAFFIC   TAGS     GENERATION   AGE   CONDITIONS   READY
invoice-renderer-00007   invoice-renderer        10%   canary            7   4m    3 OK / 3     True
invoice-renderer-00006   invoice-renderer        90%                     6   3d    3 OK / 3     True

$ hey -z 30s -c 200 http://invoice-renderer.functions.example.com/render
Summary:
  Total:        30.0041 secs
  Slowest:      2.9137 secs
  Fastest:      0.0193 secs
  Average:      0.1842 secs
  Requests/sec: 1083.4

Latency distribution:
  50% in 0.0921 secs
  95% in 0.6110 secs
  99% in 2.4483 secs

$ kubectl get pods -n functions -l serving.knative.dev/service=invoice-renderer
NAME                                                     READY   STATUS    RESTARTS   AGE
invoice-renderer-00007-deployment-6b47c9f5d8-2xq4k       2/2     Running   0          31s
invoice-renderer-00007-deployment-6b47c9f5d8-7hjvn       2/2     Running   0          28s
invoice-renderer-00007-deployment-6b47c9f5d8-c9pmz       2/2     Running   0          25s
...
```

O `2/2` é o container do usuário mais o sidecar `queue-proxy` — o buffer de requisições por pod do Knative, o executor de concorrência e a fonte de métricas. Quando você depurar um problema de latência no Knative, **leia os logs do `queue-proxy` antes dos da aplicação**: é o componente que reporta o atraso de enfileiramento separadamente do tempo do handler.

> **A armadilha do pool de conexões, em um manifesto.** O serviço acima pode chegar a 60 réplicas × 25 de concorrência = 1 500 requisições em voo. Se cada uma abrir sua própria conexão PostgreSQL, você precisa de um connection pooler (PgBouncer em modo transação) entre elas, ou `max-scale` precisa ser limitado por `max_connections / conexões_por_pod`. Camadas elásticas nunca podem ter permissão de atropelar camadas inelásticas — esta é de longe a queda mais comum em serverless mais RDBMS.

---

## 4. Armazenamento: bloco, arquivo, objeto — e a borda da CDN

### 4.1 Os três formatos de persistência

| | Bloco | Arquivo | Objeto |
|---|---|---|---|
| Unidade | Blocos de tamanho fixo num dispositivo bruto | Arquivos numa hierarquia POSIX | Blobs imutáveis + metadados sob uma chave |
| Acesso | `/dev/nvme1n1`, formatado por você | `open()/read()/write()`, faixa de bytes | `GET`/`PUT`/`DELETE` HTTP de objetos inteiros |
| Mutação | In-place, no nível do byte | In-place, no nível do byte | **Substituir o objeto inteiro** (ou multipart) |
| Latência típica | 0,1–1 ms em NVMe local; 0,5–10 ms em rede | 0,5–5 ms | 20–200 ms de time-to-first-byte |
| Compartilhamento | Um escritor (`ReadWriteOnce`) | Muitos escritores (`ReadWriteMany`) | Leitores concorrentes ilimitados |
| Consistência | Forte | Close-to-open (NFS) | Leitura-após-escrita forte para PUT/DELETE (S3 desde dez/2020) |
| Teto de escala | Por volume (dezenas de TiB) | Por sistema de arquivos | Praticamente ilimitado |
| Custo / GiB-mês | US$ 0,08–0,12 (+ IOPS) | US$ 0,16–0,30 | US$ 0,004–0,023 |
| Adequado para | Bancos de dados, write-ahead logs | Ativos compartilhados, apps legadas, diretórios home | Backups, mídia, data lake, artefatos, logs |
| Produtos | EBS, Cinder, Ceph RBD, iSCSI/NVMe-oF | NFS, SMB, CephFS, EFS, Manila | S3, Swift, MinIO, Ceph RGW, GCS |

**A regra prática que custa menos dinheiro:** coloque bancos de dados em bloco, coloque tudo que é escrito uma vez e lido muitas em objeto, e use armazenamento de arquivos apenas quando uma aplicação que você não pode alterar exige um caminho POSIX compartilhado entre escritores. Volumes `ReadWriteMany` são os mais lentos, mais caros e mais frágeis dos três; cada um deles num desenho é uma pergunta a responder, não um padrão.

**APIs de object storage.** S3 é o protocolo de fio padrão de facto; OpenStack Swift é o outro grande, e o Ceph RADOS Gateway fala os dois. MinIO, Ceph RGW e o middleware S3 do Swift permitem rodar a API S3 on-premises — o que é a decisão anti-lock-in mais eficaz disponível na camada de armazenamento, porque ferramentas de backup, log shippers, repositórios de artefatos de CI e engines de data lake todos falam S3 e nada mais.

### 4.2 Consumindo armazenamento declarativamente no Kubernetes (CSI)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "500"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:eu-central-1:111122223333:key/6f1a2b3c-4d5e-6789-abcd-ef0123456789
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
  - matchLabelExpressions:
      - key: topology.ebs.csi.aws.com/zone
        values:
          - eu-central-1a
          - eu-central-1b
          - eu-central-1c
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: orders-db-data
  namespace: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 200Gi
```

Dois parâmetros desse manifesto são decisões arquiteturais disfarçadas de campos:

- `reclaimPolicy: Retain` — com `Delete`, remover um namespace destrói o volume subjacente. Em qualquer workload stateful isso é uma primitiva de perda de dados a uma tecla de distância.
- `volumeBindingMode: WaitForFirstConsumer` — com `Immediate`, o volume é provisionado numa zona escolhida antes de o scheduler ter posicionado o pod, e o pod pode ficar permanentemente `Pending` porque nenhum nó naquela zona tem capacidade.

Verificação:

```
$ kubectl get pvc -n data orders-db-data
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
orders-db-data   Bound    pvc-3f7a1e2c-9b04-4d61-8a7e-2c5d18f0b933   200Gi      RWO            fast-ssd       6d

$ kubectl get pv pvc-3f7a1e2c-9b04-4d61-8a7e-2c5d18f0b933 -o jsonpath='{.spec.nodeAffinity}' | jq .
{
  "required": {
    "nodeSelectorTerms": [
      {
        "matchExpressions": [
          {
            "key": "topology.ebs.csi.aws.com/zone",
            "operator": "In",
            "values": [
              "eu-central-1b"
            ]
          }
        ]
      }
    ]
  }
}
```

Essa saída é a resposta para "por que meu pod stateful nunca é reescalonado depois de uma falha de nó?" — o PV está fixado a uma zona, então o pod substituto só pode ser escalonado ali.

### 4.3 Conteúdo estático versus dinâmico, e a CDN

| | Conteúdo estático | Conteúdo dinâmico |
|---|---|---|
| Produzido por | Etapa de build, enviado uma vez | Aplicação, a cada requisição |
| Varia por | Só pela URL (mais `Accept-Encoding`) | Sessão, tenant, geografia, tempo |
| Cacheável na borda | Sim, por meses | Raramente; só com surrogate keys e purge |
| Origem ideal | Bucket de object storage | Camada de aplicação |
| Cabeçalhos corretos | `Cache-Control: public, max-age=31536000, immutable` | `Cache-Control: private, no-store` |
| Motor de custo | Egress (mitigado pela taxa de acerto da CDN) | CPU e IOPS de banco |

A CDN é o único componente desta lista que simultaneamente melhora a latência, reduz o custo e aumenta a disponibilidade, e faz isso **somente se o conteúdo for endereçado de forma imutável**. Coloque uma impressão digital no nome do arquivo (`app.7f3c91a2.js`) e faça cache para sempre; nunca faça cache de `app.js` para depois tentar purgá-lo globalmente sob a pressão de um incidente.

```
$ curl -sSI https://cdn.example.com/assets/app.7f3c91a2.js
HTTP/2 200
content-type: application/javascript; charset=utf-8
content-length: 284713
cache-control: public, max-age=31536000, immutable
etag: "7f3c91a2b4e6"
age: 84213
x-cache: HIT
x-cache-hits: 1842
server-timing: cdn-cache;desc=HIT, edge;dur=2

$ curl -sSI https://api.example.com/v1/orders/8812
HTTP/2 200
content-type: application/json
cache-control: private, no-store
x-cache: MISS
server-timing: origin;dur=41
```

`age`, `x-cache` e `server-timing` são os três cabeçalhos a verificar primeiro quando alguém reporta "o deploy não subiu" — um objeto obsoleto na borda explica isso muito mais vezes do que um pipeline quebrado.

---

## 5. Bancos de dados: relacionais e NoSQL

### 5.1 Escolhendo um modelo de dados

| Família | Exemplos | Modelo de dados | Consistência | Eixo de escala | Transações | Melhor encaixe | Modo de falha a prever |
|---|---|---|---|---|---|---|---|
| Relacional (OLTP) | PostgreSQL, MySQL/MariaDB, SQL Server | Tabelas, esquema imposto, joins | Forte, serializável disponível | Vertical + réplicas de leitura; sharding é manual | ACID completo, multi-linha | Qualquer coisa com invariantes entre entidades: dinheiro, estoque, identidade | Esgotamento de conexões; atraso de replicação em réplicas de leitura |
| Chave-valor | Redis, Memcached, DynamoDB, etcd | Valor opaco sob uma chave | Redis: forte por nó; DynamoDB: ajustável | Horizontal, trivialmente | Limitadas (Lua, item único) | Sessões, cache, contadores, feature flags | Hot key; crescimento ilimitado de memória |
| Documento | MongoDB, Couchbase, DocumentDB | Documentos tipo JSON, esquema flexível | Read/write concern ajustáveis | Horizontal via shard key | Multi-documento desde o MongoDB 4.0 | Agregados lidos por inteiro, esquema em evolução | Shard key errada = hotspot permanente |
| Wide-column | Cassandra, ScyllaDB, HBase, Bigtable | Partition key + clustering columns | Quórum ajustável (`ONE`…`ALL`) | Horizontal, linear | Apenas lightweight transactions | Séries temporais, volume de escrita muito alto | Tombstones; consultas que a partition key não suporta |
| Grafo | Neo4j, JanusGraph, Neptune | Nós e arestas com propriedades | Geralmente forte | Majoritariamente vertical | ACID (Neo4j) | Redes de fraude, permissões, recomendações | Supernós; explosão de travessia |
| Busca | Elasticsearch, OpenSearch, Solr | Índice invertido, documentos | **Quase em tempo real, não é sistema de registro** | Horizontal via shards | Nenhuma | Texto completo, análise de logs, facetas | Usado como store primário; split-brain em versões antigas |
| OLAP colunar | ClickHouse, Druid, BigQuery, Redshift | Orientado a colunas, comprimido | Inserções eventualmente consistentes | Horizontal | Limitadas | Agregações sobre bilhões de linhas | Buscas pontuais e `UPDATE`s |
| Série temporal | Prometheus, InfluxDB, TimescaleDB, VictoriaMetrics | Série = métrica + labels, com downsampling | Eventual | Horizontal (federação/sharding) | Nenhuma | Métricas, telemetria de IoT | Explosão de cardinalidade de labels |

### 5.2 CAP, e a parte que todo mundo esquece: PACELC

CAP diz que, durante uma **P**artição de rede, você precisa escolher entre **C**onsistência e **A**vailability (disponibilidade). É verdade e é quase inútil no dia a dia do design, porque partições são raras. **PACELC** é a versão que você de fato aplica:

> **se P**artição então (**A**vailability ou **C**onsistência) **e**lse (**L**atência ou **C**onsistência)

| Sistema | Durante partição | Operação normal |
|---|---|---|
| PostgreSQL (replicação síncrona) | PC — recusa escritas | EC — paga latência por durabilidade |
| PostgreSQL (replicação assíncrona) | PA — o primário segue aceitando | EL — réplicas podem servir leituras obsoletas |
| Cassandra `QUORUM` | PC | EC |
| Cassandra `ONE` | PA | EL |
| DynamoDB (leitura eventualmente consistente) | PA | EL |
| DynamoDB (leitura fortemente consistente) | PC | EC |
| MongoDB `w:majority` | PC | EC |
| etcd / ZooKeeper (Raft, ZAB) | **PC sempre** — o lado minoritário para | EC |

O ramo "else" é aquele com o qual você convive 99,99 % do tempo. Uma réplica de leitura dois segundos atrás do primário não é uma partição; é o trade-off cotidiano entre latência e consistência, e o bug que ele produz é *"eu salvei e a próxima página diz que não existe."* Corrija com roteamento read-your-writes (mande as leituras de uma sessão para o primário por N segundos após uma escrita), não tornando toda leitura fortemente consistente.

### 5.3 Um cluster PostgreSQL completo, em formato de produção (CloudNativePG)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orders-db
  namespace: data
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.2
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover
  enableSuperuserAccess: false

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: 4GB
      effective_cache_size: 12GB
      work_mem: 16MB
      maintenance_work_mem: 512MB
      wal_compression: "on"
      max_wal_size: 4GB
      min_wal_size: 1GB
      checkpoint_completion_target: "0.9"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      log_min_duration_statement: "500"
      log_checkpoints: "on"
      log_lock_waits: "on"
      log_autovacuum_min_duration: "0"
      shared_preload_libraries: pg_stat_statements
      track_io_timing: "on"
    pg_hba:
      - hostssl orders orders_app 10.42.0.0/16 scram-sha-256
      - hostssl all all 0.0.0.0/0 reject
    synchronous:
      method: any
      number: 1

  bootstrap:
    initdb:
      database: orders
      owner: orders_app
      secret:
        name: orders-db-app-credentials
      encoding: UTF8
      localeCollate: C
      localeCType: C
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_stat_statements
        - CREATE EXTENSION IF NOT EXISTS pgcrypto

  storage:
    size: 200Gi
    storageClass: fast-ssd
  walStorage:
    size: 50Gi
    storageClass: fast-ssd

  resources:
    requests:
      cpu: "2"
      memory: 8Gi
    limits:
      cpu: "4"
      memory: 16Gi

  affinity:
    enablePodAntiAffinity: true
    topologyKey: topology.kubernetes.io/zone
    podAntiAffinityType: required

  monitoring:
    enablePodMonitor: true

  backup:
    retentionPolicy: 35d
    barmanObjectStore:
      destinationPath: "s3://platform-backups/orders-db"
      endpointURL: "https://s3.eu-central-1.amazonaws.com"
      s3Credentials:
        accessKeyId:
          name: backup-object-store
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: backup-object-store
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 8
      data:
        compression: gzip
        immediateCheckpoint: false
        jobs: 4
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: orders-db-nightly
  namespace: data
spec:
  schedule: "0 30 2 * * *"
  backupOwnerReference: self
  cluster:
    name: orders-db
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: orders-db-rw-pool
  namespace: data
spec:
  cluster:
    name: orders-db
  instances: 3
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "2000"
      default_pool_size: "40"
      reserve_pool_size: "10"
      reserve_pool_timeout: "3"
      server_idle_timeout: "120"
```

Note o `schedule: "0 30 2 * * *"` — o CloudNativePG usa uma expressão cron de **seis campos** (segundos primeiro). Escrever ali uma expressão de cinco campos é um erro de configuração silencioso clássico: os backups rodam na hora errada ou não rodam.

Opere e verifique:

```
$ kubectl cnpg status orders-db -n data
Cluster Summary
Name:                orders-db
Namespace:           data
System ID:           7412908371445023745
PostgreSQL Image:    ghcr.io/cloudnative-pg/postgresql:17.2
Primary instance:    orders-db-1
Primary start time:  2026-09-11 08:14:02 +0000 UTC (uptime 7d04h)
Status:              Cluster in healthy state
Instances:           3
Ready instances:     3
Current Write LSN:   3F/6A1C4E80 (Timeline: 4 - WAL File: 0000000400000
                     03F00000006A)

Certificates Status
Certificate Name          Expiration Date                Days Left Until Expiration
----------------          ---------------                --------------------------
orders-db-ca              2027-06-08 08:11:41 +0000 UTC  263.00
orders-db-replication     2027-06-08 08:11:41 +0000 UTC  263.00
orders-db-server          2027-06-08 08:11:41 +0000 UTC  263.00

Continuous Backup status
First Point of Recoverability:  2026-08-14T02:31:07Z
Working WAL archiving:          OK
WALs waiting to be archived:    0
Last Archived WAL:              000000040000003F0000006A   @   2026-09-18T09:02:11Z

Streaming Replication status
Name         Sent LSN     Write LSN    Flush LSN    Replay LSN   Write Lag  Flush Lag  Replay Lag  State      Sync State  Sync Priority
----         --------     ---------    ---------    ----------   ---------  ---------  ----------  -----      ----------  -------------
orders-db-2  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  00:00:00   00:00:00   00:00:00    streaming  quorum      1
orders-db-3  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C1220  00:00:00   00:00:00   00:00:00.001 streaming  quorum      1

Instances status
Name         Database Size  Current LSN  Replication role  Status  QoS         Manager Version  Node
----         -------------  -----------  ----------------  ------  ---         ---------------  ----
orders-db-1  147 GB         3F/6A1C4E80  Primary           OK      Burstable   1.24.1           node-a-07
orders-db-2  147 GB         3F/6A1C4E80  Standby (sync)    OK      Burstable   1.24.1           node-b-03
orders-db-3  147 GB         3F/6A1C1220  Standby (sync)    OK      Burstable   1.24.1           node-c-11
```

Simulação deliberada de failover — a única maneira de saber que a HA funciona:

```
$ kubectl cnpg promote orders-db orders-db-2 -n data
Node orders-db-2 in cluster orders-db will be promoted

$ kubectl get pods -n data -l cnpg.io/cluster=orders-db -w
NAME          READY   STATUS    RESTARTS   AGE
orders-db-1   1/1     Running   0          7d4h
orders-db-2   1/1     Running   0          7d4h
orders-db-3   1/1     Running   0          7d4h
orders-db-1   0/1     Running   0          7d4h
orders-db-1   1/1     Running   0          7d4h

$ kubectl get endpoints -n data orders-db-rw
NAME           ENDPOINTS           AGE
orders-db-rw   10.42.3.117:5432    7d4h
```

A interrupção de serviço medida num cluster saudável de três nós é tipicamente de **2–8 segundos** — o tempo de fazer fencing do primário antigo, promover o standby e reapontar o Service `-rw`. Sua aplicação precisa reenviar escritas idempotentes ao longo dessa janela, ou o banco "HA" continua produzindo uma indisponibilidade visível ao usuário.

---

## 6. Caches

### 6.1 Redis versus Memcached

| | Redis (Valkey) | Memcached |
|---|---|---|
| Tipos de dados | Strings, listas, sets, sorted sets, hashes, streams, bitmaps, HyperLogLog, geo | Somente strings |
| Persistência | Snapshots RDB + AOF | Nenhuma |
| Replicação | Primário/réplica assíncrona; Redis Cluster faz shards | Nenhuma (sharding no cliente) |
| Threading | Loop de comandos single-threaded (+ threads de I/O) | Multi-threaded |
| Tamanho máximo de item | 512 MiB | 1 MiB por padrão |
| Evicção | 8 políticas (`allkeys-lru`, `volatile-ttl`, …) | LRU por slab class |
| Modo cluster | Nativo, 16 384 hash slots | Consistent hashing no cliente |
| Scripting / transações | Lua, `MULTI`/`EXEC`, functions | Não |
| Pub/Sub, streams, locks | Sim | Não |
| Eficiência de memória para valores minúsculos | Menor (estruturas mais ricas) | Maior (slab allocator) |
| Adequado para | Quase tudo: cache, fila, rate limiter, leaderboard, session store | Cache LRU puro, enorme e simples, com necessidade de throughput multi-core |

Redis é a escolha padrão em 2026; Memcached permanece genuinamente melhor apenas para caches muito grandes e muito simples, onde o throughput multi-threaded por nó domina e nada além de `GET`/`SET` é necessário.

### 6.2 Padrões de cache e seus modos de falha

| Padrão | Caminho de escrita | Caminho de leitura | Modo de falha |
|---|---|---|---|
| Cache-aside (lazy) | App escreve no DB, invalida a chave | Miss → DB → popula | Stampede na expiração de uma hot key; janela de dados obsoletos entre escrita e invalidação |
| Read-through | Igual | A biblioteca de cache carrega do DB | Mesmo stampede; esconde erros do DB atrás de erros de cache |
| Write-through | App escreve no cache, cache escreve no DB de forma síncrona | Sempre acerta | Latência de escrita = cache + DB; o cache vira caminho crítico |
| Write-behind | App escreve no cache, flush assíncrono para o DB | Sempre acerta | **Perda de dados em falha de cache** — só para dados toleráveis |
| Refresh-ahead | Atualização em segundo plano antes do TTL | Sempre acerta | Trabalho desperdiçado em chaves frias |

**Cache stampede** (thundering herd) é o incidente que você deveria conseguir descrever de memória: uma chave muito popular expira, dez mil requisições concorrentes dão miss simultaneamente, todas as dez mil consultam o banco, o banco satura, a latência sobe, mais requisições se acumulam. Três mitigações, aplicadas juntas:

1. **TTL com jitter** — `ttl = base + rand(0, base * 0.1)` para que as chaves nunca expirem em sincronia.
2. **Mutex por chave / single-flight** — o primeiro miss toma um lock curto (`SET key:lock 1 NX PX 5000`) e repopula; o restante espera brevemente ou serve dados obsoletos.
3. **Serve-stale-while-revalidate** — mantenha um TTL suave dentro do valor; passado o TTL suave, sirva o valor obsoleto e atualize em segundo plano.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: data
data:
  redis.conf: |
    bind 0.0.0.0
    protected-mode yes
    port 6379
    maxmemory 6gb
    maxmemory-policy allkeys-lru
    maxmemory-samples 10
    save ""
    appendonly no
    tcp-keepalive 60
    timeout 0
    lazyfree-lazy-eviction yes
    lazyfree-lazy-expire yes
    latency-monitor-threshold 100
    slowlog-log-slower-than 10000
    slowlog-max-len 256
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-cache
  namespace: data
spec:
  serviceName: redis-cache
  replicas: 1
  selector:
    matchLabels:
      app: redis-cache
  template:
    metadata:
      labels:
        app: redis-cache
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsNonRoot: true
      containers:
        - name: redis
          image: redis:7.4-alpine
          args:
            - /etc/redis/redis.conf
          ports:
            - name: redis
              containerPort: 6379
          resources:
            requests:
              cpu: "1"
              memory: 7Gi
            limits:
              cpu: "2"
              memory: 7Gi
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "redis-cli ping | grep -q PONG"
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "redis-cli ping | grep -q PONG"
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/redis
      volumes:
        - name: config
          configMap:
            name: redis-config
```

`maxmemory 6gb` contra um limite de container de 7 GiB é deliberado: o Redis contabiliza seu dataset, não o copy-on-write durante o `BGSAVE`, os buffers de réplica ou a fragmentação. Definir `maxmemory` igual ao limite do cgroup é como se consegue um OOM-kill em vez de uma evicção.

Sessão de diagnóstico:

```
$ kubectl exec -n data redis-cache-0 -- redis-cli info stats | head -20
# Stats
total_connections_received:184023
total_commands_processed:2914773219
instantaneous_ops_per_sec:41208
total_net_input_bytes:418273401923
total_net_output_bytes:1209374012883
rejected_connections:0
sync_full:0
expired_keys:18402711
evicted_keys:9127334
keyspace_hits:2610338211
keyspace_misses:203114882

$ kubectl exec -n data redis-cache-0 -- redis-cli info memory | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
used_memory_human:5.94G
maxmemory_human:6.00G
mem_fragmentation_ratio:1.31

$ kubectl exec -n data redis-cache-0 -- redis-cli --bigkeys --memkeys -i 0.01
[00.00%] Biggest string found so far '"session:d41d8cd98f00"' with 1284 bytes
[12.41%] Biggest hash   found so far '"cart:9928374"' with 214 fields
[63.02%] Biggest zset   found so far '"leaderboard:global"' with 1840223 members

-------- summary -------
Sampled 8241093 keys in the keyspace!
```

A taxa de acerto aqui é 2610338211 / (2610338211 + 203114882) = **92,8 %**. `evicted_keys` crescendo continuamente enquanto `used_memory` fica em `maxmemory` significa que o working set não cabe mais — ou aumente a memória ou encurte os TTLs. `mem_fragmentation_ratio` acima de ~1,5 justifica `activedefrag yes`; abaixo de 1,0 significa que o Redis está em swap, o que é uma emergência.

---

## 7. Filas de mensagens e brokers

### 7.1 A comparação que importa

| | Apache Kafka | RabbitMQ | NATS JetStream | ActiveMQ Artemis | Redis Streams | AWS SQS | ZeroMQ |
|---|---|---|---|---|---|---|---|
| Modelo | **Commit log** distribuído | **Broker** com exchanges + filas | Mensageria por subject + armazenamento de stream | Broker JMS | Log em memória/AOF | Fila gerenciada | **Biblioteca**, sem broker |
| Consumo | Pull, o consumer group é dono das partições | Push (prefetch), consumidores concorrentes | Pull ou push | Push | Pull (`XREADGROUP`) | Pull (long poll) | Socket direto |
| Mensagem retida após leitura | **Sim** (por tempo/tamanho) | Não (o ack remove) | Sim (configurável) | Não | Sim (até `XTRIM`) | Não | n/a |
| Replay | Nativo (seek para o offset) | Requer republicação | Nativo | Não | Nativo | Não | Não |
| Ordenação | Por partição | Por fila (consumidor único) | Por subject/stream | Por fila | Por stream | Só em filas FIFO | n/a |
| Semânticas de entrega | At-least-once; exactly-once dentro do Kafka via produtor idempotente + transações | At-least-once (ack manual) | At-least-once, janela de exactly-once | At-least-once | At-least-once | At-least-once (padrão) / exactly-once (FIFO) | At-most-once por padrão |
| Inteligência de roteamento | **Broker burro, consumidor esperto** | **Broker esperto** (direct/topic/fanout/headers) | Curingas de subject | Seletores JMS | Nenhuma | Nenhuma | n/a |
| Throughput/nó | Muito alto (100 k–1 M msg/s) | Moderado (20–50 k msg/s) | Muito alto | Moderado | Alto | Gerenciado | O mais alto (sem broker) |
| Latência | ms (batching ajustável) | sub-ms possível | **µs–ms** | ms | sub-ms | 10–100 ms | µs |
| Protocolo | Binário próprio | AMQP 0-9-1, MQTT, STOMP | Protocolo NATS | AMQP 1.0, MQTT, STOMP, OpenWire | RESP | API HTTPS | TCP/IPC bruto |
| Peso operacional | Alto (KRaft/ZK, rebalanceamentos, partições) | Médio | Baixo (binário único) | Médio | Baixo | **Zero** | Zero (mas você constrói tudo) |
| Adequado para | Event streaming, agregação de logs, CDC, pipelines com replay | Filas de tarefas com roteamento complexo, RPC, prioridades | Edge/IoT, RPC entre microsserviços, baixa latência | Parques Java/JMS | Já tem Redis, volume modesto | Desacoplamento nativo na AWS | Padrões in-process/intra-DC sem necessidade de durabilidade |

**A distinção mais importante desta tabela** é *broker esperto / consumidor burro* (RabbitMQ) versus *broker burro / consumidor esperto* (Kafka). O RabbitMQ decide para onde vai uma mensagem, rastreia o reconhecimento por mensagem e a esquece assim que é confirmada — excelente para distribuição de trabalho. O Kafka acrescenta a um log particionado, não lembra nada sobre consumidores individuais exceto um offset commitado, e mantém os dados por dias — excelente para muitos consumidores independentes lendo os mesmos eventos no próprio ritmo, e para reprocessar o histórico depois de um bug.

**ZeroMQ não é um broker.** É uma biblioteca de sockets que oferece os padrões PUB/SUB, REQ/REP, PUSH/PULL e DEALER/ROUTER sem servidor, sem persistência e sem garantia de entrega. Saber que ele pertence a uma categoria diferente dos outros seis é exatamente o tipo de distinção que este objetivo cobra.

### 7.2 Um deployment completo de Kafka (Strimzi, modo KRaft)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 20Gi
        class: fast-ssd
        deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 1000Gi
        class: fast-ssd
        deleteClaim: false
  resources:
    requests:
      cpu: "2"
      memory: 16Gi
    limits:
      cpu: "4"
      memory: 16Gi
  jvmOptions:
    -Xms: 6g
    -Xmx: 6g
  template:
    pod:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              strimzi.io/cluster: platform-events
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: platform-events
  namespace: messaging
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.9.0
    metadataVersion: "3.9-IV0"
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
      - name: external
        port: 9094
        type: loadbalancer
        tls: true
        authentication:
          type: scram-sha-512
        configuration:
          bootstrap:
            annotations:
              external-dns.alpha.kubernetes.io/hostname: kafka.example.com
    authorization:
      type: simple
      superUsers:
        - CN=platform-admin
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      auto.create.topics.enable: false
      unclean.leader.election.enable: false
      log.retention.hours: 168
      log.segment.bytes: 1073741824
      num.replica.fetchers: 4
      replica.lag.time.max.ms: 30000
      compression.type: producer
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics
          key: kafka-metrics-config.yml
  entityOperator:
    topicOperator: {}
    userOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders.created.v1
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: "604800000"
    segment.bytes: "1073741824"
    min.insync.replicas: "2"
    cleanup.policy: delete
    max.message.bytes: "1048576"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: customers.state.v1
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  partitions: 12
  replicas: 3
  config:
    cleanup.policy: compact
    min.cleanable.dirty.ratio: "0.1"
    delete.retention.ms: "86400000"
    min.insync.replicas: "2"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: orders-service
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: orders.created.v1
          patternType: literal
        operations:
          - Describe
          - Write
        host: "*"
      - resource:
          type: group
          name: orders-consumer
          patternType: prefix
        operations:
          - Read
        host: "*"
```

Note o `host: "*"` — entre aspas, porque um `*` sem aspas é um token de alias do YAML e o documento falharia ao ser analisado.

Os dois valores de `cleanup.policy` codificam uma distinção arquitetural real: `delete` para **streams de eventos** (fatos que aconteceram, retidos por uma janela), `compact` para **tópicos de estado** (o último valor por chave, retido para sempre). Um tópico compactado é um store chave-valor distribuído e reprocessável — a base do padrão "banco de dados do avesso" e dos state stores do Kafka Streams.

Verificação e diagnóstico de lag:

```
$ kubectl -n messaging exec -it platform-events-broker-0 -- bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --describe --topic orders.created.v1
Topic: orders.created.v1  TopicId: 8Kx2mQ1nTx-PqW0dRf7ZxA  PartitionCount: 12  ReplicationFactor: 3  Configs: min.insync.replicas=2,segment.bytes=1073741824,retention.ms=604800000,cleanup.policy=delete
    Topic: orders.created.v1  Partition: 0  Leader: 3  Replicas: 3,4,5  Isr: 3,4,5  Elr:   LastKnownElr:
    Topic: orders.created.v1  Partition: 1  Leader: 4  Replicas: 4,5,3  Isr: 4,5,3  Elr:   LastKnownElr:
    Topic: orders.created.v1  Partition: 2  Leader: 5  Replicas: 5,3,4  Isr: 5,3      Elr:   LastKnownElr:
    ...

$ kubectl -n messaging exec -it platform-events-broker-0 -- bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --describe --group orders-consumer

GROUP            TOPIC              PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG      CONSUMER-ID                                     HOST           CLIENT-ID
orders-consumer  orders.created.v1  0          48210394        48210401        7        consumer-orders-1-9a1c...-0  /10.42.2.31    consumer-orders-1
orders-consumer  orders.created.v1  1          48198221        48198230        9        consumer-orders-2-4f70...-0  /10.42.3.19    consumer-orders-2
orders-consumer  orders.created.v1  2          47110882        48203994        1093112  consumer-orders-3-1b2e...-0  /10.42.1.44    consumer-orders-3
orders-consumer  orders.created.v1  3          48204118        48204118        0        consumer-orders-4-7c93...-0  /10.42.2.88    consumer-orders-4
...
```

Dois achados numa só tela:

- **A partição 2 tem `Isr: 5,3` enquanto `Replicas: 5,3,4`** — o broker 4 caiu fora do conjunto de réplicas in-sync. Com `min.insync.replicas=2` a partição ainda aceita escritas `acks=all`, mas agora está a uma falha de rejeitar todas as escritas. Este é o estado sobre o qual alertar, *antes* de virar uma indisponibilidade.
- **A partição 2 tem 1 093 112 mensagens de lag enquanto suas irmãs têm dígitos únicos** — lag concentrado numa partição nunca é "os consumidores estão lentos". É uma **partição quente** causada por uma partition key enviesada (por exemplo, o ID de um tenant grande hasheando para a partição 2), ou por uma mensagem envenenada que o consumidor continua falhando em processar e relendo. Lag uniforme em todas as partições é um problema de capacidade; lag enviesado é um problema de chaveamento, e acrescentar consumidores não vai resolver — um consumer group não pode ter mais consumidores ativos do que partições.

### 7.3 RabbitMQ: quorum queues, DLX e a visão operacional

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: tasks
  namespace: messaging
spec:
  replicas: 3
  image: rabbitmq:4.0-management
  resources:
    requests:
      cpu: "1"
      memory: 4Gi
    limits:
      cpu: "2"
      memory: 4Gi
  persistence:
    storageClassName: fast-ssd
    storage: 100Gi
  rabbitmq:
    additionalConfig: |
      cluster_partition_handling = pause_minority
      vm_memory_high_watermark.relative = 0.6
      disk_free_limit.absolute = 10GB
      channel_max = 512
      management.rates_mode = basic
    additionalPlugins:
      - rabbitmq_prometheus
      - rabbitmq_shovel
  override:
    statefulSet:
      spec:
        template:
          spec:
            topologySpreadConstraints:
              - maxSkew: 1
                topologyKey: topology.kubernetes.io/zone
                whenUnsatisfiable: DoNotSchedule
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: invoices-work
  namespace: messaging
spec:
  name: invoices.work
  vhost: "/"
  type: quorum
  durable: true
  rabbitmqClusterReference:
    name: tasks
  arguments:
    x-queue-type: quorum
    x-delivery-limit: 5
    x-dead-letter-exchange: invoices.dlx
    x-dead-letter-routing-key: invoices.failed
---
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: invoices-dead
  namespace: messaging
spec:
  name: invoices.dead
  vhost: "/"
  type: quorum
  durable: true
  rabbitmqClusterReference:
    name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Exchange
metadata:
  name: invoices-dlx
  namespace: messaging
spec:
  name: invoices.dlx
  vhost: "/"
  type: direct
  durable: true
  rabbitmqClusterReference:
    name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Binding
metadata:
  name: invoices-dead-binding
  namespace: messaging
spec:
  vhost: "/"
  source: invoices.dlx
  destination: invoices.dead
  destinationType: queue
  routingKey: invoices.failed
  rabbitmqClusterReference:
    name: tasks
```

`x-delivery-limit: 5` mais uma dead-letter exchange é o **disjuntor de mensagens envenenadas**. Sem isso, uma mensagem que o consumidor não consegue processar é reentregue para sempre, queimando CPU e bloqueando a fila — uma indisponibilidade de produção genuína causada por um único payload malformado.

```
$ kubectl exec -n messaging tasks-server-0 -- rabbitmqctl list_queues \
    name type messages messages_ready messages_unacknowledged consumers memory
Timeout: 60.0 seconds ...
Listing queues for vhost / ...
name             type    messages  messages_ready  messages_unacknowledged  consumers  memory
invoices.work    quorum  18432     18420           12                       6          78123456
invoices.dead    quorum  41        41              0                        0          212992
notifications    quorum  0         0               0                        12         98304

$ kubectl exec -n messaging tasks-server-0 -- rabbitmqctl cluster_status
Cluster status of node rabbit@tasks-server-0.tasks-nodes.messaging ...
Basics
Cluster name: tasks

Disk Nodes
rabbit@tasks-server-0.tasks-nodes.messaging
rabbit@tasks-server-1.tasks-nodes.messaging
rabbit@tasks-server-2.tasks-nodes.messaging

Running Nodes
rabbit@tasks-server-0.tasks-nodes.messaging
rabbit@tasks-server-1.tasks-nodes.messaging
rabbit@tasks-server-2.tasks-nodes.messaging

Feature flags
Flag: quorum_queue, state: enabled
Flag: stream_queue, state: enabled
Flag: message_containers, state: enabled
```

`messages_ready` subindo com `consumers` diferente de zero significa que os consumidores estão lentos demais ou que o `prefetch` está baixo demais. `messages_unacknowledged` grande e estático significa que os consumidores pegaram mensagens e pararam de confirmar — procure um deadlock ou uma chamada de I/O bloqueada no handler. Um `invoices.dead` crescendo é seu sinal de mensagem envenenada e deve gerar alerta: ele é silencioso por construção.

### 7.4 Escolhendo semânticas de entrega deliberadamente

| Garantia | Como é obtida | Custo | Quando é adequada |
|---|---|---|---|
| At-most-once | Auto-ack / fire-and-forget | Mais barata, menor latência | Métricas, amostras de telemetria, qualquer coisa onde a perda é invisível |
| At-least-once | Ack manual após processar; produtor com retries | Duplicatas **vão** acontecer | O padrão para quase todos os eventos de negócio |
| Effectively-once | At-least-once + consumidor idempotente (chave de dedup, upsert, tabela de idempotência) | Uma consulta extra ao store por mensagem | Pagamentos, pedidos, qualquer coisa com efeito colateral em forma de dinheiro |
| Exactly-once (nativa do broker) | Produtor idempotente do Kafka + transações, isolamento read-committed | ~10–20 % do throughput, acoplamento ao broker | Somente processamento de stream Kafka-para-Kafka |

A regra prática: **assuma at-least-once e torne o consumidor idempotente.** "Exactly-once" atravessando um broker e um sistema externo (um banco de dados, um gateway de pagamento, um provedor de e-mail) não existe sem uma transação distribuída que o sistema externo quase certamente não oferece. Uma chave de idempotência armazenada junto com a escrita de negócio é o desenho que de fato se sustenta.

---

## 8. Plataformas de big data e analytics

| Engine | Paradigma | Classe de latência | Armazenamento que lê | Unidade de escala | Adequado para | Modo de falha |
|---|---|---|---|---|---|---|
| Hadoop MapReduce | Batch, limitado por disco | Minutos–horas | HDFS | Nó | ETL legado; amplamente superado | Problema de arquivos pequenos no NameNode do HDFS |
| Apache Spark | Batch + micro-batch, DAG em memória | Segundos–horas | HDFS, S3, JDBC, Delta/Iceberg | Executor | ETL geral, pipelines de ML, joins grandes | OOM de executor por data skew; spill de shuffle |
| Apache Flink | Streaming verdadeiro, event time, com estado | Milissegundos | Kafka, S3 | Task slot | Processamento contínuo, agregação por janela, CEP | Crescimento do checkpoint/state backend |
| Trino / Presto | SQL MPP distribuído, federado | Segundos | S3, Hive, Iceberg, RDBMS | Worker | SQL interativo ad-hoc entre fontes | Memória do coordenador; consultas ilimitadas |
| Elasticsearch / OpenSearch | Índice invertido, quase em tempo real | Milissegundos | Shards próprios | Nó de dados | Texto completo, busca em logs, observabilidade | Explosão de shards; explosão de mapeamento de campos; **não é sistema de registro** |
| ClickHouse | OLAP colunar, vetorizado | Milissegundos–segundos | MergeTree próprio, S3 | Shard/réplica | Analytics de alta cardinalidade, métricas de produto | `INSERT`s pequenos demais em excesso → tempestade de merges |
| Apache Druid | OLAP colunar em tempo real | Sub-segundo | Deep storage + segmentos | Historical/MiddleManager | Dashboards fatiados no tempo | Complexidade operacional |

### 8.1 Batch versus streaming, arquiteturalmente

| | Arquitetura Lambda | Arquitetura Kappa |
|---|---|---|
| Caminhos | Dois: batch (preciso) + speed (rápido) | Um: só stream |
| Reprocessamento | Rodar de novo o job batch | Reproduzir o log a partir do offset 0 |
| Duplicação de código | **Sim** — duas implementações da mesma lógica | Não |
| Reconciliação de corretude | A camada batch sobrescreve a camada speed | Fonte única da verdade |
| Pré-requisito | Nenhum | Um log durável e reproduzível (Kafka com retenção longa) |
| Carga operacional | Alta | Moderada |

Kappa é o padrão moderno precisamente porque um tópico Kafka com 30 dias de retenção transforma "reprocesse tudo com o código corrigido" num replay em vez de numa segunda base de código.

### 8.2 Spark no Kubernetes

```
$ spark-submit \
    --master k8s://https://k8s-api.internal.example.com:6443 \
    --deploy-mode cluster \
    --name orders-daily-rollup \
    --class com.example.analytics.OrdersRollup \
    --conf spark.kubernetes.namespace=analytics \
    --conf spark.kubernetes.container.image=registry.internal.example.com/analytics/spark:3.5.4 \
    --conf spark.kubernetes.authenticate.driver.serviceAccountName=spark \
    --conf spark.executor.instances=20 \
    --conf spark.executor.cores=4 \
    --conf spark.executor.memory=12g \
    --conf spark.executor.memoryOverhead=2g \
    --conf spark.driver.memory=4g \
    --conf spark.sql.shuffle.partitions=400 \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.adaptive.skewJoin.enabled=true \
    --conf spark.hadoop.fs.s3a.endpoint=s3.eu-central-1.amazonaws.com \
    --conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.WebIdentityTokenCredentialsProvider \
    --conf spark.kubernetes.executor.deleteOnTermination=true \
    s3a://platform-artifacts/analytics/orders-rollup-2.1.0.jar \
    --date 2026-09-17

26/09/18 09:41:02 INFO SparkKubernetesClientFactory: Auto-configuring K8S client using current context
26/09/18 09:41:04 INFO KubernetesClientUtils: Spark configuration files loaded from Some(/opt/spark/conf)
26/09/18 09:41:06 INFO LoggingPodStatusWatcherImpl: State changed, new state:
     pod name: orders-daily-rollup-b41f7c93f2a10d84-driver
     namespace: analytics
     phase: Pending
26/09/18 09:41:19 INFO LoggingPodStatusWatcherImpl: State changed, new state:
     phase: Running
26/09/18 09:48:37 INFO LoggingPodStatusWatcherImpl: Container final statuses:
     container name: spark-kubernetes-driver
     exit code: 0
26/09/18 09:48:37 INFO LoggingPodStatusWatcherImpl: Application orders-daily-rollup finished.
```

`spark.sql.adaptive.skewJoin.enabled=true` é o ajuste que transforma a maioria dos incidentes de "um executor roda por três horas enquanto dezenove ficam ociosos" numa execução normal. Data skew é o modo de falha dominante do Spark, e o AQE divide partições superdimensionadas em tempo de execução.

---

## 9. Runtimes de aplicação e Platform as a Service

### 9.1 Comparação de PaaS

| | Cloud Foundry | OpenShift | Heroku | Knative | Dokku |
|---|---|---|---|---|---|
| Unidade de deploy | Fonte ou droplet (`cf push`) | Fonte (S2I), Dockerfile, imagem | Fonte (git push) | Imagem de container | Fonte (git push) |
| Mecanismo de build | Buildpacks | S2I / Dockerfile / Cloud Native Buildpacks | Buildpacks | Externo (você constrói) | Buildpacks |
| Orquestrador subjacente | Diego, ou Kubernetes (Korifi) | Kubernetes | Dyno manager | Kubernetes | Docker em um host |
| Serviços de apoio | Service broker (OSB API) | Operators / Service Binding | Marketplace de add-ons | Traga o seu | Plugins |
| Roteamento | Gorouter | Router (HAProxy) / Gateway API | Router | Kourier / Istio / Contour | nginx |
| Escala até zero | Não | Não (add-on Serverless: sim) | Eco dynos hibernam | **Sim** | Não |
| Multi-tenancy | Orgs / spaces | Projects + SCC | Times | Namespaces | Nenhuma |
| Auto-hospedável | Sim | Sim | Não | Sim | Sim |
| Adequado para | Grandes empresas com mandato 12-factor | Empresas já em Kubernetes que precisam de autosserviço para devs | Times pequenos, caminho mais rápido até produção | Workloads orientados a eventos em Kubernetes existente | Um único host, projetos pessoais |

### 9.2 Cloud Foundry: a interação canônica de PaaS

```yaml
---
applications:
  - name: orders-api
    memory: 1G
    disk_quota: 1G
    instances: 4
    stack: cflinuxfs4
    buildpacks:
      - java_buildpack_offline
    path: build/libs/orders-api-2.4.1.jar
    health-check-type: http
    health-check-http-endpoint: /actuator/health/readiness
    health-check-invocation-timeout: 5
    timeout: 120
    routes:
      - route: orders.apps.example.com
      - route: orders-internal.apps.internal
    services:
      - orders-postgres
      - orders-redis
      - orders-kafka
    env:
      SPRING_PROFILES_ACTIVE: production
      JAVA_OPTS: "-XX:MaxRAMPercentage=75"
      JBP_CONFIG_OPEN_JDK_JRE: "{ jre: { version: 21.+ } }"
      OTEL_SERVICE_NAME: orders-api
```

`JBP_CONFIG_OPEN_JDK_JRE` precisa estar entre aspas: um valor sem aspas começando com `{` é interpretado pelo YAML como um flow mapping, e o buildpack receberia um mapa renderizado em vez da string literal que ele espera.

```
$ cf push -f manifest.yml
Pushing app orders-api to org platform / space production as ci@example.com...
Applying manifest file /workspace/manifest.yml...
Uploading files...
 3.41 MiB / 3.41 MiB [=========================================] 100.00% 2s

Staging app and tracing logs...
   Downloading java_buildpack_offline...
   Downloaded java_buildpack_offline (242.1M)
   Cell 6b8a2f1c creating container for instance 0f3a...
   Downloading build artifacts cache...
   -----> Java Buildpack v4.68 | https://github.com/cloudfoundry/java-buildpack.git
   -----> Downloading Jvmkill Agent 1.17.0 from https://java-buildpack.cloudfoundry.org/...
   -----> Downloading Open Jdk JRE 21.0.5_11 from https://java-buildpack.cloudfoundry.org/...
          Expanding Open Jdk JRE to .java-buildpack/open_jdk_jre (1.4s)
   -----> Downloading Spring Auto Reconfiguration 2.15.0 ...
          Uploading droplet (118.2M)

Waiting for app orders-api to start...

name:              orders-api
requested state:   started
routes:            orders.apps.example.com, orders-internal.apps.internal
last uploaded:     Thu 18 Sep 09:52:14 UTC 2026
stack:             cflinuxfs4
buildpacks:        java_buildpack_offline

type:            web
sidecars:
instances:       4/4
memory usage:    1024M
     state     since                  cpu    memory         disk           logging
#0   running   2026-09-18T09:53:02Z   3.1%   412.9M of 1G   198.4M of 1G   0/s of unlimited
#1   running   2026-09-18T09:53:04Z   2.8%   408.1M of 1G   198.4M of 1G   0/s of unlimited
#2   running   2026-09-18T09:53:07Z   3.4%   417.2M of 1G   198.4M of 1G   0/s of unlimited
#3   running   2026-09-18T09:53:09Z   2.9%   404.6M of 1G   198.4M of 1G   0/s of unlimited

$ cf env orders-api | head -30
Getting env variables for app orders-api in org platform / space production...

System-Provided:
VCAP_SERVICES
{
  "postgresql": [
    {
      "label": "postgresql",
      "name": "orders-postgres",
      "plan": "ha-200",
      "credentials": {
        "host": "pg-7841.service.internal",
        "port": 5432,
        "database": "orders",
        "username": "u_a91f",
        "uri": "postgresql://u_a91f:REDACTED@pg-7841.service.internal:5432/orders"
      }
    }
  ]
}
```

`VCAP_SERVICES` é a implementação concreta do **fator III do twelve-factor (configuração no ambiente) e do fator IV (serviços de apoio como recursos anexados)**. A aplicação nunca fixa em código o host do banco; ela lê o binding que a plataforma injetou. O equivalente no Kubernetes é um `Secret` projetado como variáveis de ambiente ou como arquivo, produzido por um Service Binding ou por um operator — mesmo contrato, mecanismo diferente.

### 9.3 Buildpacks versus Dockerfiles

| | Cloud Native Buildpacks | Dockerfile |
|---|---|---|
| Entrada | Código-fonte | Instruções explícitas |
| Atualizações da imagem base | **Rebase sem rebuild** (`pack rebase`) | Rebuild completo obrigatório |
| Patching de segurança em escala | Uma atualização do builder faz rebase de milhares de apps | Cada repositório precisa ser tocado |
| Reprodutibilidade | Alta (builder fixo, SBOM emitido) | Depende inteiramente de disciplina |
| Flexibilidade | Limitada às linguagens detectadas | Total |
| Otimização de camadas | Automática (dependências vs código da app) | Manual |
| Adequado para | Muitos serviços parecidos, equipe central de plataforma | Runtimes incomuns, pacotes de sistema, controle preciso |

```
$ pack build registry.internal.example.com/billing/orders-api:2.4.1 \
    --builder paketobuildpacks/builder-jammy-base \
    --env BP_JVM_VERSION=21 \
    --publish
jammy-base: Pulling from paketobuildpacks/builder-jammy-base
Digest: sha256:fd1e9a2c8b4737f0e51c2a9d8c4e71b03fa62d5c9e1a7b48d0a3f2c65e91b774
===> DETECTING
5 of 18 buildpacks participating
paketo-buildpacks/ca-certificates   3.8.5
paketo-buildpacks/bellsoft-liberica 10.7.2
paketo-buildpacks/syft              1.45.0
paketo-buildpacks/gradle            7.6.1
paketo-buildpacks/spring-boot       5.29.1
===> BUILDING
Paketo Buildpack for BellSoft Liberica 10.7.2
  https://github.com/paketo-buildpacks/bellsoft-liberica
  Build Configuration:
    $BP_JVM_VERSION 21  the Java version
  Launch Configuration:
    $BPL_JVM_HEAD_ROOM  0   the headroom in memory calculation
===> EXPORTING
Adding layer 'paketo-buildpacks/ca-certificates:helper'
Adding layer 'paketo-buildpacks/bellsoft-liberica:helper'
Adding 1/1 app layer(s)
Adding layer 'launcher'
Adding layer 'config'
Adding label 'io.buildpacks.lifecycle.metadata'
Adding label 'io.buildpacks.project.metadata'
Setting default process type 'web'
Saving registry.internal.example.com/billing/orders-api:2.4.1...
*** Images (sha256:3b7f0d91ac):
      registry.internal.example.com/billing/orders-api:2.4.1
Successfully built image registry.internal.example.com/billing/orders-api:2.4.1

$ pack rebase registry.internal.example.com/billing/orders-api:2.4.1 --publish
Rebasing registry.internal.example.com/billing/orders-api:2.4.1 on run image paketobuildpacks/run-jammy-base
Saving registry.internal.example.com/billing/orders-api:2.4.1...
*** Images (sha256:91c4e7fa02):
      registry.internal.example.com/billing/orders-api:2.4.1
Rebased Image: sha256:91c4e7fa02...
```

O `pack rebase` terminou em cerca de dois segundos e não reexecutou o build: ele trocou as camadas do SO abaixo das camadas inalteradas da aplicação. Corrigir uma CVE de imagem base em 400 serviços vira um laço sobre 400 rebases em vez de 400 pipelines de CI — o argumento isolado mais forte a favor de buildpacks em escala de plataforma.

---

## 10. OpenStack: o IaaS open-source de referência

O OpenStack importa para este objetivo porque é a decomposição canônica de "uma nuvem" em serviços nomeados com APIs documentadas. Aprenda o mapa de componentes e você consegue raciocinar sobre qualquer nuvem, porque todo provedor tem as mesmas peças sob nomes de marca diferentes.

| Projeto | Papel | Serviço AWS análogo | Conceito-chave a saber |
|---|---|---|---|
| **Keystone** | Identidade, autenticação/autorização, catálogo de serviços | IAM + STS | Todos os outros serviços consultam endpoints aqui; emite tokens com escopo |
| **Nova** | Computação — ciclo de vida de VMs | EC2 | O scheduler coloca instâncias nos nós de computação por flavor + filtros |
| **Neutron** | Rede — SDN, L2/L3, security groups, FIPs | VPC | Drivers ML2 plugáveis (OVS, OVN, Linux bridge) |
| **Glance** | Registro de imagens | Catálogo de AMIs | Imagens são a entrada imutável do Nova |
| **Cinder** | Armazenamento em bloco | EBS | Volumes se anexam a uma instância; snapshots |
| **Swift** | Armazenamento de objetos | S3 | Eventualmente consistente, baseado em ring, API própria (+ middleware S3) |
| **Placement** | Inventário e alocação de recursos | — | O Nova pergunta a ele qual host tem VCPU/MEMORY_MB/DISK_GB livres |
| **Heat** | Orquestração — stacks declarativas | CloudFormation | Templates HOT; o ponto de entrada de IaC |
| **Horizon** | Dashboard web | Console | Cliente fino sobre as mesmas APIs |
| **Ironic** | Provisionamento bare-metal | Instâncias Bare Metal | O Nova pode escalonar em hosts físicos |
| **Octavia** | Balanceamento de carga como serviço | ELB/NLB | VMs Amphora rodando HAProxy |
| **Designate** | DNS como serviço | Route 53 | Registros criados junto com as instâncias |
| **Barbican** | Gerenciamento de chaves e segredos | KMS / Secrets Manager | Dá suporte à criptografia do Cinder/Octavia |
| **Magnum** | Provisionamento de engines de orquestração de containers | EKS | Cria clusters Kubernetes sobre Nova/Heat |
| **Manila** | Sistemas de arquivos compartilhados | EFS | Compartilhamentos NFS/CIFS |
| **Ceilometer / Gnocchi / Aodh** | Telemetria, armazenamento de métricas, alarmes | CloudWatch | Alimenta o autoscaling |

### 10.1 Um Heat Orchestration Template completo

```yaml
heat_template_version: 2021-04-16

description: >
  Two-tier reference stack for the orders platform: a private tenant network
  routed to the external provider network, a security group per tier, an
  autoscaled application tier behind an Octavia load balancer, and a Cinder
  volume for the application's local cache.

parameters:
  image:
    type: string
    label: Glance image
    default: ubuntu-24.04-server-cloudimg-amd64
    constraints:
      - custom_constraint: glance.image
  flavor:
    type: string
    label: Nova flavor
    default: m1.large
    constraints:
      - custom_constraint: nova.flavor
  key_name:
    type: string
    label: SSH keypair name
    default: platform-ops
  external_network:
    type: string
    label: Provider network for floating IPs
    default: public
  app_image_ref:
    type: string
    label: OCI image reference deployed on each instance
    default: "registry.example.com/billing/orders-api:2.4.1"
  min_instances:
    type: number
    default: 2
  max_instances:
    type: number
    default: 8

resources:

  app_network:
    type: OS::Neutron::Net
    properties:
      name: orders-app-net

  app_subnet:
    type: OS::Neutron::Subnet
    properties:
      name: orders-app-subnet
      network:
        get_resource: app_network
      cidr: 10.30.10.0/24
      gateway_ip: 10.30.10.1
      enable_dhcp: true
      dns_nameservers:
        - 10.30.0.10
        - 10.30.0.11
      allocation_pools:
        - start: 10.30.10.50
          end: 10.30.10.250

  app_router:
    type: OS::Neutron::Router
    properties:
      name: orders-app-router
      external_gateway_info:
        network:
          get_param: external_network

  app_router_interface:
    type: OS::Neutron::RouterInterface
    properties:
      router:
        get_resource: app_router
      subnet:
        get_resource: app_subnet

  app_security_group:
    type: OS::Neutron::SecurityGroup
    properties:
      name: orders-app-sg
      description: Application tier - HTTP from the load balancer, SSH from bastion
      rules:
        - protocol: tcp
          port_range_min: 8080
          port_range_max: 8080
          remote_ip_prefix: 10.30.10.0/24
        - protocol: tcp
          port_range_min: 22
          port_range_max: 22
          remote_ip_prefix: 10.30.0.0/24
        - protocol: icmp
          remote_ip_prefix: 10.30.0.0/16

  app_cache_volume:
    type: OS::Cinder::Volume
    properties:
      name: orders-app-cache
      size: 50
      volume_type: ssd

  app_server:
    type: OS::Nova::Server
    properties:
      name: orders-app-01
      image:
        get_param: image
      flavor:
        get_param: flavor
      key_name:
        get_param: key_name
      security_groups:
        - get_resource: app_security_group
      networks:
        - subnet:
            get_resource: app_subnet
      metadata:
        stack_id:
          get_param: "OS::stack_id"
        tier: application
      user_data_format: RAW
      user_data:
        str_replace:
          template: |
            #!/bin/bash
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y podman
            mkdir -p /var/cache/orders
            systemctl enable --now podman.socket
            podman run -d --name orders-api --restart=always \
              --publish 8080:8080 \
              --volume /var/cache/orders:/cache:Z \
              --env SPRING_PROFILES_ACTIVE=production \
              $APP_IMAGE
          params:
            $APP_IMAGE:
              get_param: app_image_ref

  app_volume_attachment:
    type: OS::Cinder::VolumeAttachment
    properties:
      volume_id:
        get_resource: app_cache_volume
      instance_uuid:
        get_resource: app_server
      mountpoint: /dev/vdb

  app_floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network:
        get_param: external_network

  app_floating_ip_association:
    type: OS::Nova::FloatingIPAssociation
    properties:
      floating_ip:
        get_resource: app_floating_ip
      server_id:
        get_resource: app_server

  app_loadbalancer:
    type: OS::Octavia::LoadBalancer
    properties:
      name: orders-lb
      vip_subnet:
        get_resource: app_subnet

  app_listener:
    type: OS::Octavia::Listener
    properties:
      name: orders-lb-http
      loadbalancer:
        get_resource: app_loadbalancer
      protocol: HTTP
      protocol_port: 80

  app_pool:
    type: OS::Octavia::Pool
    properties:
      name: orders-lb-pool
      listener:
        get_resource: app_listener
      protocol: HTTP
      lb_algorithm: LEAST_CONNECTIONS
      session_persistence:
        type: APP_COOKIE
        cookie_name: ORDERSSESSION

  app_health_monitor:
    type: OS::Octavia::HealthMonitor
    properties:
      pool:
        get_resource: app_pool
      type: HTTP
      url_path: /healthz
      expected_codes: "200"
      delay: 5
      timeout: 3
      max_retries: 3

outputs:
  load_balancer_vip:
    description: VIP address of the Octavia load balancer
    value:
      get_attr:
        - app_loadbalancer
        - vip_address
  app_public_ip:
    description: Floating IP attached to the first application instance
    value:
      get_attr:
        - app_floating_ip
        - floating_ip_address
  app_private_ip:
    description: Fixed IP of the first application instance
    value:
      get_attr:
        - app_server
        - first_address
```

Faça o deploy e inspecione:

```
$ openstack stack create -t orders-stack.yaml \
    --parameter flavor=m1.xlarge \
    --parameter app_image_ref=registry.example.com/billing/orders-api:2.4.1 \
    --wait orders-production
2026-09-18 10:04:11Z [orders-production]: CREATE_IN_PROGRESS  Stack CREATE started
2026-09-18 10:04:13Z [orders-production.app_network]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:16Z [orders-production.app_network]: CREATE_COMPLETE  state changed
2026-09-18 10:04:17Z [orders-production.app_subnet]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:21Z [orders-production.app_subnet]: CREATE_COMPLETE  state changed
2026-09-18 10:04:22Z [orders-production.app_router]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:39Z [orders-production.app_router]: CREATE_COMPLETE  state changed
2026-09-18 10:05:02Z [orders-production.app_server]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:06:48Z [orders-production.app_server]: CREATE_COMPLETE  state changed
2026-09-18 10:08:31Z [orders-production.app_loadbalancer]: CREATE_COMPLETE  state changed
2026-09-18 10:08:55Z [orders-production]: CREATE_COMPLETE  Stack CREATE completed successfully

+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| id                  | 4d81b2f0-5a1e-49c7-9f2b-7a3e1c084b62 |
| stack_name          | orders-production                    |
| stack_status        | CREATE_COMPLETE                      |
| creation_time       | 2026-09-18T10:04:11Z                 |
+---------------------+--------------------------------------+

$ openstack stack output show orders-production --all
+---------------------+------------------------------------------------------------+
| Field               | Value                                                      |
+---------------------+------------------------------------------------------------+
| load_balancer_vip   | 10.30.10.72                                                |
| app_public_ip       | 203.0.113.184                                              |
| app_private_ip      | 10.30.10.113                                               |
+---------------------+------------------------------------------------------------+

$ openstack service list
+----------------------------------+------------+----------------+
| ID                               | Name       | Type           |
+----------------------------------+------------+----------------+
| 0a1f3c5e7b9d2f4a6c8e0b2d4f6a8c0e | keystone   | identity       |
| 1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e | nova       | compute        |
| 2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f | neutron    | network        |
| 3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f80 | glance     | image          |
| 4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091 | cinderv3   | block-storage  |
| 5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2 | swift      | object-store   |
| 6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3 | heat       | orchestration  |
| 7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4 | placement  | placement      |
| 8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5 | octavia    | load-balancer  |
| 9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6 | barbican   | key-manager    |
+----------------------------------+------------+----------------+

$ openstack server show orders-app-01 -f value -c status -c OS-EXT-SRV-ATTR:host -c addresses
ACTIVE
compute-node-07.dc1.example.com
orders-app-net=10.30.10.113, 203.0.113.184
```

### 10.2 Diagnosticando uma instância OpenStack travada

```
$ openstack server list --status ERROR
+--------------------------------------+---------------+--------+----------+
| ID                                   | Name          | Status | Networks |
+--------------------------------------+---------------+--------+----------+
| 9f2a1c84-73b1-4e20-9d5c-08a2f61b4e37 | orders-app-04 | ERROR  |          |
+--------------------------------------+---------------+--------+----------+

$ openstack server show orders-app-04 -f value -c fault
{'code': 500, 'created': '2026-09-18T10:22:04Z', 'message': 'No valid host was found. There are not enough hosts available.', 'details': 'Traceback (most recent call last):\n  File "/usr/lib/python3/dist-packages/nova/conductor/manager.py", line 1548, in schedule_and_build_instances\n    host_lists = self._schedule_instances(context, request_specs[0], ...'}

$ openstack hypervisor list --long
+----+----------------------------------+-----------------+---------------+-------+------------+---------+
| ID | Hypervisor Hostname              | Hypervisor Type | Host IP       | State | vCPUs Used | vCPUs   |
+----+----------------------------------+-----------------+---------------+-------+------------+---------+
|  1 | compute-node-07.dc1.example.com  | QEMU            | 10.30.0.107   | up    |         62 |      64 |
|  2 | compute-node-08.dc1.example.com  | QEMU            | 10.30.0.108   | up    |         64 |      64 |
|  3 | compute-node-09.dc1.example.com  | QEMU            | 10.30.0.109   | down  |          0 |      64 |
+----+----------------------------------+-----------------+---------------+-------+------------+---------+

$ openstack quota show --detail $(openstack project show platform -f value -c id) | grep -E 'cores|ram|instances'
| cores     | {'in_use': 126, 'limit': 128, 'reserved': 0} |
| instances | {'in_use': 31, 'limit': 64, 'reserved': 0}   |
| ram       | {'in_use': 507904, 'limit': 524288, 'reserved': 0} |
```

**"No valid host was found" tem exatamente três causas**, e os três comandos acima as distinguem: (1) esgotamento genuíno de capacidade — visível em `hypervisor list`; (2) esgotamento da quota do projeto — visível em `quota show`, e aqui `cores` está em 126/128, que é a causa real; (3) um filtro do scheduler que nenhum host satisfaz (aggregate, zona de disponibilidade, PCI passthrough, topologia NUMA) — visível apenas nos logs do `nova-scheduler`. Verifique a quota antes da capacidade: é a resposta mais comum e a consulta mais barata.

---

## 11. Equivalentes gerenciados como código (Terraform)

O mesmo conjunto de componentes, contratado em vez de operado. Este é o artefato que torna revisável a decisão de construir versus comprar.

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

resource "aws_db_instance" "orders" {
  identifier     = "orders-production"
  engine         = "postgres"
  engine_version = "17.2"
  instance_class = "db.r7g.2xlarge"

  allocated_storage     = 200
  max_allocated_storage = 1000
  storage_type          = "gp3"
  iops                  = 12000
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  multi_az                     = true
  backup_retention_period      = 35
  backup_window                = "02:30-03:30"
  maintenance_window           = "sun:04:00-sun:05:00"
  performance_insights_enabled = true
  monitoring_interval          = 30
  deletion_protection          = true
  auto_minor_version_upgrade   = true

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.orders_db.id]

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Service     = "orders"
    Tier        = "data"
    Environment = "production"
  }
}

resource "aws_elasticache_replication_group" "orders_cache" {
  replication_group_id = "orders-cache"
  description          = "Session and read-through cache for the orders service"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.r7g.large"

  num_node_groups         = 2
  replicas_per_node_group = 1

  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  parameter_group_name = aws_elasticache_parameter_group.lru.name
  subnet_group_name    = aws_elasticache_subnet_group.data.name
  security_group_ids   = [aws_security_group.orders_cache.id]

  snapshot_retention_limit = 0
}

resource "aws_elasticache_parameter_group" "lru" {
  name   = "orders-cache-lru"
  family = "valkey8"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_msk_cluster" "events" {
  cluster_name           = "platform-events"
  kafka_version          = "3.9.0"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.m7g.large"
    client_subnets  = aws_subnet.data[*].id
    security_groups = [aws_security_group.kafka.id]

    storage_info {
      ebs_storage_info {
        volume_size = 1000
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
    encryption_at_rest_kms_key_arn = aws_kms_key.data.arn
  }

  configuration_info {
    arn      = aws_msk_configuration.events.arn
    revision = aws_msk_configuration.events.latest_revision
  }
}

resource "aws_msk_configuration" "events" {
  name           = "platform-events-config"
  kafka_versions = ["3.9.0"]

  server_properties = <<-PROPERTIES
    auto.create.topics.enable=false
    default.replication.factor=3
    min.insync.replicas=2
    unclean.leader.election.enable=false
    log.retention.hours=168
  PROPERTIES
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "platform-artifacts-eu-central-1"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Dois ajustes merecem ser nomeados porque são a diferença entre um desenho HA e um em formato de HA: `unclean.leader.election.enable=false` (o Kafka vai recusar eleger uma réplica fora de sincronia como líder, escolhendo indisponibilidade em vez de perda silenciosa de dados) e `deletion_protection = true` no banco (um `terraform destroy` contra o workspace errado é um erro humano rotineiro). `snapshot_retention_limit = 0` no cache é deliberado no sentido oposto: um cache não é sistema de registro, e pagar para fazer backup dele é pagar para restaurar dados obsoletos.

---

## 12. Verificação e diagnóstico de falhas

### 12.1 O método genérico

Quando um serviço apoiado em componentes degrada, trabalhe **de fora para dentro** ao longo do caminho da requisição e faça uma pergunta em cada salto: *este salto está adicionando latência, adicionando erros ou enfileirando?*

```
client → DNS → CDN/edge → LB → ingress → app pod → pool → { DB | cache | broker } → downstream
```

As três famílias de sintomas e sua assinatura:

| Sintoma | Assinatura | Componente mais provável | Primeiro comando |
|---|---|---|---|
| Latência sobe, taxa de erro estável | p99 sobe antes do p50 | Enfileiramento: esgotamento de pool, GC, disco | `pg_stat_activity` / `redis-cli --latency` |
| Taxa de erro sobe, latência cai | Falhas rápidas | Circuit breaker, connection refused, autenticação | `kubectl logs`, `ss -s` |
| Latência sobe **e** erros sobem | Saturação | Limite de CPU/memória/IOPS atingido | `kubectl top`, `iostat -x 1` |
| Throughput estável sob mais carga | Teto rígido | Limite de conexões, partição única, thread única | `kafka-consumer-groups.sh`, `SHOW max_connections` |
| Tudo bem, dados errados | Nenhum sinal | Semânticas de entrega, atraso de replicação, cache obsoleto | Comparar contagens de origem e destino |

### 12.2 Um runbook concreto de triagem

**Sintoma: a API de pedidos está retornando HTTP 503 em 12 % das requisições.**

```
$ kubectl get pods -n orders -l app=orders-api
NAME                          READY   STATUS      RESTARTS      AGE
orders-api-6f9d4c7b8d-2k4xq   1/1     Running     0             3h
orders-api-6f9d4c7b8d-7vnzl   0/1     CrashLoopBackOff  6 (42s ago)   3h
orders-api-6f9d4c7b8d-9wqrt   1/1     Running     0             3h
orders-api-6f9d4c7b8d-pm8zc   1/1     Running     2 (11m ago)   3h

$ kubectl logs -n orders orders-api-6f9d4c7b8d-7vnzl --previous --tail=20
2026-09-18T11:02:14.882Z ERROR [HikariPool-1] Connection is not available, request timed out after 30001ms
2026-09-18T11:02:14.884Z ERROR o.s.b.w.s.ErrorPageFilter  org.springframework.jdbc.CannotGetJdbcConnectionException
2026-09-18T11:02:44.901Z ERROR [HikariPool-1] Connection is not available, request timed out after 30002ms

$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT state, wait_event_type, count(*)
    FROM pg_stat_activity
    WHERE datname = 'orders'
    GROUP BY 1, 2 ORDER BY 3 DESC;"
      state       | wait_event_type | count
------------------+-----------------+-------
 idle in transaction | Client        |   147
 active           | Lock            |    31
 idle             | Client          |    14
 active           |                 |     6
(4 rows)

$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT pid, now() - xact_start AS xact_age, left(query, 60) AS query
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
    ORDER BY xact_start LIMIT 5;"
  pid  |    xact_age     |                    query
-------+-----------------+----------------------------------------------
 28471 | 00:41:12.882713 | SELECT * FROM orders WHERE customer_id = $1
 28492 | 00:40:57.114029 | SELECT * FROM orders WHERE customer_id = $1
 28503 | 00:40:44.900112 | UPDATE inventory SET reserved = reserved + $1
```

**Diagnóstico.** 147 sessões estão `idle in transaction` com idades de transação acima de quarenta minutos. A aplicação abriu transações e nunca fez commit nem rollback — quase sempre um caminho de exceção que pula o `close()`, ou uma transação que abrange uma chamada HTTP de saída. Essas sessões seguram locks (os 31 que esperam por `Lock`) e consomem `max_connections`, então o pool não consegue entregar conexões e a readiness probe falha, tirando pods da lista de endpoints → 503.

**Mitigação imediata, depois a correção de verdade:**

```
$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'orders'
      AND state = 'idle in transaction'
      AND now() - xact_start > interval '5 minutes';"
 pg_terminate_backend
----------------------
 t
 t
... (147 rows)
```

As correções duráveis, em ordem de valor: definir `idle_in_transaction_session_timeout = '60s'` no banco para que isso nunca mais esgote conexões; colocar o PgBouncer em modo de pooling por transação entre a aplicação e o banco, de forma que 1 500 conexões do lado da aplicação mapeiem para 40 do lado do servidor; e remover a chamada de rede de dentro da transação na aplicação.

### 12.3 Checklist de verificação por componente

| Componente | Liveness | Corretude | Saturação | Comando |
|---|---|---|---|---|
| Banco relacional | Aceita conexões | LSN da réplica == LSN do primário | Contagem de `pg_stat_activity` vs `max_connections`; checkpoints de `pg_stat_bgwriter` | `kubectl cnpg status`, `pg_isready` |
| Cache | `PING` → `PONG` | Taxa de acerto estável | Taxa de `evicted_keys`; `used_memory` vs `maxmemory` | `redis-cli info`, `--bigkeys` |
| Kafka | Broker no ISR de todas as partições | Tamanho de `Isr` == tamanho de `Replicas` | Taxa de variação do lag do consumidor, % de disco | `kafka-topics.sh --describe --under-replicated-partitions` |
| RabbitMQ | Todos os nós em `cluster_status` | Profundidade da DLQ == 0 | Tendência de `messages_ready`, alarme de memória | `rabbitmqctl list_queues`, `status` |
| Object storage | `HEAD` no bucket | Checksum na restauração | Taxa de requisições vs limites por prefixo | `aws s3api head-bucket` |
| Knative/FaaS | Revisão `Ready` | Divisão de tráfego corresponde à intenção | Tempo de enfileiramento do `queue-proxy`, throttling | `kn revision list` |
| CDN | 200 num asset conhecido | Proporção de `x-cache: HIT` | Taxa de requisições à origem | `curl -I`, analytics do provedor |
| OpenStack | `openstack service list` com todos presentes | Stack em `CREATE_COMPLETE` | Quota vs em uso, vCPUs do hypervisor | `openstack quota show --detail` |

### 12.4 Regras de alerta que codificam o acima

```yaml
groups:
  - name: platform-standard-components
    interval: 30s
    rules:
      - alert: KafkaUnderReplicatedPartitions
        expr: |
          sum by (cluster) (kafka_server_replicamanager_underreplicatedpartitions) > 0
        for: 5m
        labels:
          severity: critical
          component: kafka
        annotations:
          summary: "Under-replicated partitions on {{ $labels.cluster }}"
          description: "min.insync.replicas is at risk; one more broker loss stops writes."
          runbook_url: "https://runbooks.example.com/kafka/under-replicated"

      - alert: KafkaConsumerLagGrowing
        expr: |
          sum by (consumergroup, topic) (kafka_consumergroup_lag) > 100000
          and
          deriv(sum by (consumergroup, topic) (kafka_consumergroup_lag)[15m:1m]) > 0
        for: 15m
        labels:
          severity: warning
          component: kafka
        annotations:
          summary: "Lag above 100k and still growing for {{ $labels.consumergroup }}"

      - alert: PostgresReplicationLagHigh
        expr: |
          max by (cluster) (cnpg_pg_replication_lag) > 30
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Replica more than 30s behind on {{ $labels.cluster }}"

      - alert: PostgresConnectionsNearLimit
        expr: |
          sum by (cluster) (cnpg_backends_total)
          /
          max by (cluster) (cnpg_pg_settings_setting{name="max_connections"})
          > 0.85
        for: 10m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "Connection usage above 85% of max_connections"

      - alert: RedisCacheHitRatioDegraded
        expr: |
          sum(rate(redis_keyspace_hits_total[10m]))
          /
          (sum(rate(redis_keyspace_hits_total[10m])) + sum(rate(redis_keyspace_misses_total[10m])))
          < 0.80
        for: 20m
        labels:
          severity: warning
          component: redis
        annotations:
          summary: "Cache hit ratio below 80% - working set may exceed maxmemory"

      - alert: RabbitDeadLetterQueueNotEmpty
        expr: |
          rabbitmq_queue_messages{queue=~".*\\.dead"} > 0
        for: 5m
        labels:
          severity: warning
          component: rabbitmq
        annotations:
          summary: "Messages in {{ $labels.queue }} - poison messages are being discarded"

      - alert: ObjectStorageBackupStale
        expr: |
          time() - cnpg_collector_last_available_backup_timestamp > 90000
        for: 30m
        labels:
          severity: critical
          component: backup
        annotations:
          summary: "No successful backup in over 25 hours"
```

Cada `expr` acima é um block scalar cujas linhas carregam indentação idêntica, incluindo os operadores isolados `/` e `and` — uma única linha com indentação menor encerra silenciosamente o escalar e o Prometheus se recusa a carregar o arquivo de regras inteiro.

---

## 13. Resumo de decisão

| Se o requisito for… | Escolha | Porque |
|---|---|---|
| Invariantes entre entidades, dinheiro | Relacional (PostgreSQL) | ACID entre linhas não é emulável barato |
| Último valor por chave, reproduzível | Tópico compactado no Kafka | O log é o estado, o replay é grátis |
| Distribuição de trabalho com roteamento e prioridades | Quorum queues do RabbitMQ | Broker esperto, ack por mensagem, DLX |
| Event streaming com muitos leitores independentes | Kafka | Retenção desacoplada do consumo |
| Sub-milissegundo, sem necessidade de durabilidade | Redis / NATS | Em memória, um único salto |
| Volume de escrita muito alto, ordenado no tempo | Cassandra / ClickHouse | Engine de armazenamento otimizada para escrita |
| Busca de texto completo | OpenSearch, **com um sistema de registro por trás** | O índice é uma projeção derivada e reconstruível |
| Trabalho curto, com picos, stateless | FaaS / Knative | Escala a zero, cobrança por ms |
| Serviço estável 24/7 | Container em capacidade reservada | Custo fixo bate o por requisição em alto ciclo de trabalho |
| Artefatos imutáveis, lidos muitas vezes | Object storage + CDN | O mais barato por GiB, ilimitado, cacheável |
| Autosserviço para devs sem letramento em Kubernetes | PaaS (Cloud Foundry / OpenShift) | Buildpacks e service brokers removem a superfície da plataforma |
| Uma nuvem on-premises com API | OpenStack | A decomposição de referência, todas as peças endereçáveis |

**E as quatro perguntas a fazer sobre todo componente antes que ele entre num desenho:**

1. **O que ele garante?** Modelo de consistência, semânticas de entrega, durabilidade no `fsync` ou não.
2. **Quem o opera?** Desenhe a linha de responsabilidade explicitamente, incluindo backups, patching e simulações de restauração.
3. **Como ele escala, e qual é o teto rígido?** Partições, conexões, memória, IOPS — todo componente tem um.
4. **O que o resto da plataforma faz quando ele falha?** Se a resposta for "tudo para", você não desenhou uma dependência; você desenhou um ponto único de falha com etapas extras.

---

## Referências

**Objetivos do exame**
- LPI DevOps Tools Engineer, objetivos do exame 701 — https://www.lpi.org/our-certifications/exam-701-objectives/

**Plataformas de nuvem e modelos de serviço**
- Documentação do OpenStack (índice de componentes) — https://docs.openstack.org/
- Especificação do OpenStack Heat Orchestration Template — https://docs.openstack.org/heat/latest/template_guide/hot_spec.html
- OpenStack Nova (computação) — https://docs.openstack.org/nova/latest/
- OpenStack Neutron (rede) — https://docs.openstack.org/neutron/latest/
- OpenStack Cinder (armazenamento em bloco) — https://docs.openstack.org/cinder/latest/
- OpenStack Swift (armazenamento de objetos) — https://docs.openstack.org/swift/latest/
- OpenStack Keystone (identidade) — https://docs.openstack.org/keystone/latest/
- OpenStack Octavia (balanceamento de carga) — https://docs.openstack.org/octavia/latest/
- NIST SP 800-145, The NIST Definition of Cloud Computing — https://csrc.nist.gov/publications/detail/sp/800-145/final

**Computação e containers**
- Documentação do Kubernetes — https://kubernetes.io/docs/home/
- Storage Classes do Kubernetes — https://kubernetes.io/docs/concepts/storage/storage-classes/
- Knative Serving — https://knative.dev/docs/serving/
- Referência de autoscaling do Knative — https://knative.dev/docs/serving/autoscaling/
- Firecracker microVM — https://firecracker-microvm.github.io/
- gVisor — https://gvisor.dev/docs/
- Especificações da Open Container Initiative — https://opencontainers.org/

**PaaS e sistemas de build**
- Documentação do Cloud Foundry — https://docs.cloudfoundry.org/
- Referência do manifesto de aplicação do Cloud Foundry — https://docs.cloudfoundry.org/devguide/deploy-apps/manifest-attributes.html
- Open Service Broker API — https://www.openservicebrokerapi.org/
- Cloud Native Buildpacks — https://buildpacks.io/docs/
- Paketo Buildpacks — https://paketo.io/docs/
- Documentação do Red Hat OpenShift — https://docs.openshift.com/
- The Twelve-Factor App — https://12factor.net/

**Bancos de dados**
- Documentação do PostgreSQL — https://www.postgresql.org/docs/current/
- Alta disponibilidade e replicação no PostgreSQL — https://www.postgresql.org/docs/current/high-availability.html
- Manual de referência do MySQL — https://dev.mysql.com/doc/refman/8.4/en/
- Base de conhecimento do MariaDB — https://mariadb.com/kb/en/documentation/
- Manual do MongoDB — https://www.mongodb.com/docs/manual/
- Documentação do Apache Cassandra — https://cassandra.apache.org/doc/latest/
- Documentação do CloudNativePG — https://cloudnative-pg.io/documentation/current/
- Guia do usuário do Amazon RDS — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html

**Caching**
- Documentação do Redis — https://redis.io/docs/latest/
- Políticas de evicção do Redis — https://redis.io/docs/latest/develop/reference/eviction/
- Documentação do Valkey — https://valkey.io/docs/
- Wiki do Memcached — https://github.com/memcached/memcached/wiki

**Mensageria**
- Documentação do Apache Kafka — https://kafka.apache.org/documentation/
- Design e semânticas de entrega do Kafka — https://kafka.apache.org/documentation/#semantics
- Documentação do Strimzi — https://strimzi.io/docs/operators/latest/overview
- Documentação do RabbitMQ — https://www.rabbitmq.com/docs
- Quorum queues do RabbitMQ — https://www.rabbitmq.com/docs/quorum-queues
- Especificação do protocolo AMQP 0-9-1 — https://www.rabbitmq.com/tutorials/amqp-concepts
- Especificação OASIS AMQP 1.0 — https://www.amqp.org/resources/specifications
- Apache ActiveMQ Artemis — https://activemq.apache.org/components/artemis/documentation/
- Documentação do NATS — https://docs.nats.io/
- Guia do ZeroMQ — https://zguide.zeromq.org/
- Guia do desenvolvedor do Amazon SQS — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html

**Big data e analytics**
- Documentação do Apache Hadoop — https://hadoop.apache.org/docs/stable/
- Documentação do Apache Spark — https://spark.apache.org/docs/latest/
- Executando Spark no Kubernetes — https://spark.apache.org/docs/latest/running-on-kubernetes.html
- Documentação do Apache Flink — https://nightlies.apache.org/flink/flink-docs-stable/
- Documentação do OpenSearch — https://opensearch.org/docs/latest/
- Referência do Elasticsearch — https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
- Documentação do ClickHouse — https://clickhouse.com/docs
- Documentação do Trino — https://trino.io/docs/current/

**Armazenamento, entrega e observabilidade**
- Guia do usuário do Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- Modelo de consistência do Amazon S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
- Documentação do MinIO — https://min.io/docs/minio/linux/index.html
- Documentação do Ceph — https://docs.ceph.com/en/latest/
- Documentação de desenvolvedor do CSI do Kubernetes — https://kubernetes-csi.github.io/docs/
- RFC 9111, HTTP Caching — https://www.rfc-editor.org/rfc/rfc9111.html
- Documentação do Prometheus — https://prometheus.io/docs/introduction/overview/
- Regras de alerta do Prometheus — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

**Infraestrutura como código**
- Documentação do Terraform — https://developer.hashicorp.com/terraform/docs
- Provider AWS do Terraform — https://registry.terraform.io/providers/hashicorp/aws/latest/docs