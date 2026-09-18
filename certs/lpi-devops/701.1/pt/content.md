# 701.1 — Desenvolvimento Moderno de Software

**Certificação:** LPI DevOps Tools Engineer · **Exame:** 701-100 (versão 2.0.0) · **Peso do tópico:** 10.0

> **Escopo deste objetivo.** Espera-se que você *projete* componentes de software que sobrevivam a ser distribuídos: decomposição baseada em serviços, contratos de API, tratamento de estado e configuração, conteinerização, modelos de implantação em nuvem, o perfil de risco da migração de um monólito legado e as classes comuns de falha de segurança de aplicações. Este é um objetivo de projeto, não de ferramentas — mas cada decisão de projeto abaixo está escrita junto com a falha de produção que ela previne, e com os comandos que você realmente vai digitar quando ela acontecer mesmo assim.

---

## 1. O problema arquitetural que este objetivo existe para resolver

### 1.1 O modo de falha do monólito acoplado à implantação

Uma única unidade implantável contendo todo o domínio de negócio não é, em si, um defeito. Monólitos são mais simples de raciocinar, não têm rede no meio de uma chamada de função e dão transações ACID reais de graça. O defeito aparece quando a *organização* escala e a *unidade de implantação* não.

Considere uma forma concreta de produção — uma plataforma de varejo: catálogo, carrinho, checkout, pagamentos, faturamento, busca, notificações. Um arquivo WAR, um esquema de banco de dados, 38 engenheiros, um trem de release a cada duas semanas.

As patologias mensuráveis:

| Sintoma | Mecanismo | Métrica que se degrada |
|---|---|---|
| A cadência de release colapsa | A alteração não mesclada de qualquer equipe bloqueia o trem; a branch de integração é um lock global | Frequência de implantação, lead time para mudança |
| O raio de impacto é total | Um vazamento de memória no renderizador de faturas em PDF causa OOM-kill no processo que serve o checkout | Disponibilidade, MTTR |
| A escalabilidade é indiferenciada | A busca precisa de 32 GB de heap; as notificações precisam de 256 MB. Você compra 32 GB × N réplicas | Custo por requisição, eficiência de recursos |
| A taxa de falha de mudança sobe | A superfície de regressão de um release é a união das alterações de 38 pessoas | Taxa de falha de mudança |
| A tecnologia fica congelada | O artefato inteiro precisa mudar de versão da JVM em conjunto | Tempo até adoção, contratação |

Essas quatro — frequência de implantação, lead time, taxa de falha de mudança, tempo até restauração — são as métricas DORA. O ponto do "desenvolvimento moderno de software" no sentido da LPI é que *a arquitetura é a alavanca primária sobre essas métricas*, e a arquitetura que as move é aquela em que **a unidade de implantação coincide com a unidade de propriedade**.

### 1.2 O custo com que você está pagando

A decomposição não elimina a complexidade; ela a realoca do compilador para a rede. A enumeração clássica (Deutsch/Gosling, "Fallacies of Distributed Computing") é a lista relevante para o exame das coisas que deixam de ser verdade no momento em que uma chamada de método vira uma chamada HTTP:

1. A rede é confiável — não é; toda chamada precisa de um timeout, uma política de retry e uma história de idempotência.
2. A latência é zero — uma chamada em processo de 200 µs vira um RPC de 2–20 ms; uma refatoração tagarela de um laço vira uma indisponibilidade.
3. A largura de banda é infinita — padrões de consulta N+1 atravessando uma fronteira de serviço saturam links.
4. A rede é segura — agora você precisa de mTLS, authN/authZ em cada salto e network policy.
5. A topologia não muda — pods são reagendados continuamente; nunca faça cache de um IP.
6. Há um único administrador — a propriedade é distribuída; o on-call também.
7. O custo de transporte é zero — serialização, handshakes TLS e bytes de egresso são dinheiro real.
8. A rede é homogênea — MTU, proxies, HTTP/2 vs HTTP/1.1 e middleboxes L7 diferem por salto.

**Regra de projeto:** toda chamada síncrona que atravessa uma fronteira de serviço deve declarar, em código, um timeout de conexão, um timeout de leitura, um orçamento de retry (com jitter) e um fallback. Uma chamada sem timeout é um bug de disponibilidade que ainda não disparou.

### 1.3 Acoplamento fraco é o objetivo real

"Microsserviços" é uma topologia de implantação. **Acoplamento fraco** é a propriedade que você quer, e você pode falhar em obtê-la em qualquer topologia. Um sistema tem acoplamento fraco quando uma mudança em um componente não força uma mudança coordenada em outro. Os acoplamentos a caçar:

| Tipo de acoplamento | Como se manifesta | Técnica de remoção |
|---|---|---|
| Acoplamento de implantação | Os serviços precisam ser liberados juntos em uma ordem fixa | Contratos compatíveis para trás/para frente, migrações expand-contract |
| Acoplamento de esquema | Dois serviços escrevem na mesma tabela | Banco por serviço; um escritor, os outros leem via API ou eventos |
| Acoplamento temporal | O chamador bloqueia até o chamado responder | Mensageria assíncrona, event-carried state transfer |
| Acoplamento de runtime | Chamado fora do ar ⇒ chamador fora do ar | Circuit breaker, bulkhead, fallback em cache/degradado |
| Acoplamento semântico | O modelo de domínio interno do chamado vaza para o chamador | Anti-corruption layer, contrato publicado ≠ modelo interno |
| Acoplamento tecnológico | Biblioteca compartilhada que fixa uma versão de linguagem/runtime | Contrato pela rede (HTTP/gRPC/AMQP), não binários compartilhados |

Um "microsserviço" que compartilha uma tabela de banco com três irmãos é um monólito distribuído: você pagou o custo integral da rede e não comprou nenhuma independência.

---

## 2. Granularidade de serviço: monólito → SOA → microsserviços

### 2.1 Tabela comparativa de trade-offs

| Dimensão | Monólito modular | SOA (clássica, centrada em ESB) | Microsserviços | Serverless / FaaS |
|---|---|---|---|---|
| Unidade de implantação | Um artefato | Poucos serviços grossos + ESB | Muitos serviços finos | Uma função |
| Comunicação | Chamada em processo | SOAP/XML sobre ESB, orquestração no barramento | REST/gRPC/eventos, dumb pipes, smart endpoints | Gatilhos de evento, gateway HTTP |
| Propriedade dos dados | Um esquema | Frequentemente um único banco corporativo compartilhado | Um armazenamento por serviço | Apenas armazenamentos externos |
| Transações | ACID | ACID internamente, XA entre serviços (frágil) | Saga / consistência eventual | Saga / consistência eventual |
| Isolamento de falhas | Nenhum (processo compartilhado) | Parcial (o ESB é um SPOF) | Alto, se houver bulkheads | Alto |
| Escalabilidade independente | Não | Grossa | Por serviço | Por invocação |
| Carga operacional | Baixa | Alta (o ESB é um produto de especialista) | Alta (exige plataforma: CI/CD, observabilidade, service discovery) | Baixa em infra, alto acoplamento ao fornecedor |
| Perfil de latência | Melhor | Ruim (salto no barramento + XML) | Médio, sensível à latência de cauda | Cold starts |
| Adequado para | <15 engenheiros, domínio único, produto não comprovado | Integração corporativa de sistemas legados heterogêneos | Múltiplas equipes autônomas, escalabilidade diferenciada | Cargas irregulares, orientadas a eventos, sem estado |
| Modo de falha primário | Congestionamento do trem de release | O ESB se torna o monólito | Monólito distribuído; dívida de observabilidade | Lock-in de fornecedor, surpresa de custo em carga constante |

**Distinção relevante para o exame entre SOA e microsserviços:** SOA coloca a inteligência na camada de integração (o Enterprise Service Bus realiza orquestração, transformação, roteamento); microsserviços empurram a inteligência para os endpoints e mantêm o transporte burro. A consequência é organizacional: um ESB exige uma equipe central de integração, o que recria o gargalo de coordenação que a decomposição deveria remover.

### 2.2 Escolhendo fronteiras

Fronteiras traçadas ao longo de camadas técnicas (um "serviço de controller", um "serviço de DAO") produzem acoplamento máximo — toda funcionalidade atravessa todos os serviços. Fronteiras traçadas ao longo de **capacidades de negócio** (Order, Payment, Inventory) produzem mudanças que aterrissam dentro de um único serviço.

Duas heurísticas que sobrevivem à produção:

- **Lei de Conway**: o sistema vai espelhar a estrutura de comunicação da organização. Se você quer três serviços independentes, precisa de três equipes com roadmaps independentes; caso contrário as fronteiras vão se erodir.
- **O teste das duas transações**: se uma única operação visível ao usuário exige uma escrita atômica em dois serviços candidatos, a fronteira provavelmente está errada. Ou junte-os, ou aceite uma saga com ações compensatórias explícitas e torne a consistência eventual visível na UX ("pagamento pendente").

### 2.3 Dados distribuídos: saga em vez de 2PC

O commit em duas fases entre serviços acopla a disponibilidade multiplicativamente (um serviço de 99,9 % vezes três ⇒ 99,7 %) e mantém locks através da rede. O padrão de produção é uma **saga**: uma sequência de transações locais, cada uma publicando um evento, com uma transação compensatória explícita por passo.

```
Order placed  ──▶ Payment authorised ──▶ Stock reserved ──▶ Shipment created
     │                    │                     │
     │                    │                     └─ compensate: release stock
     │                    └─ compensate: void authorisation
     └─ compensate: cancel order, notify customer
```

Os detalhes de implementação inegociáveis:

- **Idempotência**: todo consumidor precisa tolerar entrega duplicada. Message brokers oferecem at-least-once; exactly-once ponta a ponta não existe sem um sink idempotente. Persista uma tabela de mensagens processadas indexada por ID de mensagem, ou torne a escrita naturalmente idempotente (`UPDATE ... WHERE state = 'PENDING'`).
- **Transactional outbox**: escrever no banco de dados e publicar no broker são dois sistemas. Escreva o evento em uma tabela `outbox` *dentro da mesma transação local*, e retransmita-o assincronamente (change-data-capture ou um poller). Caso contrário, uma queda entre os dois produz um evento perdido ou fantasma.
- **Ordenação**: garantida apenas por partição/chave. Particione pelo ID do agregado (ID do pedido), nunca round-robin, se a ordem importa.

---

## 3. O Twelve-Factor App como contrato operacional

A metodologia twelve-factor é o checklist canônico para "software projetado para rodar em contêineres e ser implantado em um serviço de nuvem". Leia-a como um conjunto de *restrições que a plataforma exige*, não como conselho de estilo.

| # | Fator | Requisito de plataforma que satisfaz | Falha se violado |
|---|---|---|---|
| I | Base de código — um repositório, muitos deploys | Rastreabilidade de um artefato até um commit | Impossível responder "o que está rodando em produção?" |
| II | Dependências — declaradas explicitamente e isoladas | Builds reproduzíveis | "Funciona na minha máquina"; pacotes de sistema implícitos somem em uma imagem base slim |
| III | Configuração — no ambiente | A mesma imagem promovida de dev→stage→prod | Rebuild por ambiente; segredos embutidos na imagem |
| IV | Serviços de apoio — recursos acoplados | DB/cache/broker trocáveis por URL | Nomes de host fixos no código; sem failover, sem teste local |
| V | Build, release, run — estritamente separados | Releases imutáveis e re-implantáveis | Hot-patching de um contêiner em execução; drift |
| VI | Processos — sem estado, share-nothing | Qualquer réplica serve qualquer requisição | Sessões sticky obrigatórias; scale-in descarta dados de usuário |
| VII | Vinculação de portas — exportar via uma porta | A aplicação é autocontida, sem servidor de aplicação externo | Precisa de um runtime de contêiner/servlet pré-instalado |
| VIII | Concorrência — escalar horizontalmente via o modelo de processos | Autoescalonamento horizontal | Escalabilidade apenas vertical; gargalo de processo único |
| IX | Descartabilidade — início rápido, desligamento gracioso | Reagendamento, preempção, autoescalonamento, rolling updates | 502s em cada deploy; travas de 30 s no encerramento do pod |
| X | Paridade dev/prod | Os bugs aparecem antes da produção | SQLite em dev, PostgreSQL em prod ⇒ falhas exclusivas de produção |
| XI | Logs — fluxos de eventos para stdout | Coleta centralizada pela plataforma | Os logs morrem com o contêiner; sem rotação dentro da imagem |
| XII | Processos administrativos — pontuais, mesmo release | As migrações rodam com o código implantado | Drift de esquema entre código e banco |

### 3.1 Fator III na prática — configuração, não segredos, e nunca ambos na imagem

Três níveis, e eles precisam ser distinguidos:

| Nível | Exemplo | Mecanismo | Rotação |
|---|---|---|---|
| Constantes de build | Flags de compilador, imagem base | Dockerfile / build args | Nova imagem |
| Configuração de runtime | Nível de log, feature flags, URLs upstream, tamanhos de pool | Variáveis de ambiente / ConfigMap montado | Restart, ou hot-reload na mudança do arquivo |
| Segredos | Senha do banco, chaves de API, chaves privadas TLS | Cofre de segredos, montado como arquivo (preferencialmente projetado/de curta duração) | Rotacionar sem rebuild |

**Variáveis de ambiente vs arquivos montados** — isso aparece no exame e em toda revisão de incidente:

| Propriedade | Variável de ambiente | Arquivo montado |
|---|---|---|
| Visível em `/proc/<pid>/environ` | Sim | Não |
| Vaza em crash dumps, rastreadores de erro, `docker inspect` | Sim, frequentemente | Raramente |
| Atualização a quente sem restart | Não — o ambiente é fixado em `execve()` | Sim — o kubelet atualiza o volume (volumes de ConfigMap/Secret; não montagens com `subPath`) |
| Limite de tamanho | ~2 MB argv+env (ARG_MAX) | Praticamente ilimitado |
| Adequado para certificados / multilinha | Não | Sim |

**Regra:** configuração em variáveis de ambiente é aceitável; segredos pertencem a arquivos com modo `0400`, e idealmente credenciais de curta duração emitidas em tempo de execução em vez de strings de longa duração.

### 3.2 Fator IX — descartabilidade é código, não configuração

O runtime de contêineres envia `SIGTERM`, espera `terminationGracePeriodSeconds`, e então envia `SIGKILL`. Duas coisas quebram aqui na prática:

1. **O PID 1 não tem handlers de sinal padrão.** No kernel Linux, o PID 1 ignora sinais para os quais não instalou um handler. Se a sua aplicação é o PID 1 e nunca registra um handler de `SIGTERM`, o `SIGTERM` é descartado e todo desligamento leva o período de graça inteiro e depois um kill forçado — no meio de uma requisição.
2. **O `CMD` em forma de shell faz do `/bin/sh` o PID 1**, e o `sh` não encaminha sinais para seu filho. Use a forma exec: `CMD ["./server"]`, ou `ENTRYPOINT ["/usr/bin/tini", "--"]` quando você genuinamente precisar de um reaper para imagens multiprocesso.

Sequência correta de desligamento — a ordem importa:

```go
// main.go — graceful shutdown that actually drains
func main() {
	srv := &http.Server{Addr: ":8080", Handler: router()}

	// readiness flips to false first, so the endpoint controller
	// removes this pod from the Service before the listener closes.
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	ready.Store(false)                    // 1. fail the readiness probe
	time.Sleep(5 * time.Second)           // 2. let endpoint propagation catch up

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil { // 3. drain in-flight requests
		log.Printf("forced shutdown: %v", err)
	}
	db.Close()                            // 4. release backing services
	log.Print("exited cleanly")
}
```

O `time.Sleep` não é superstição: a exclusão do pod envia `SIGTERM` e remove o endpoint **concorrentemente**, e os data planes do kube-proxy/ingress convergem assincronamente. Fechar o listener no instante em que o `SIGTERM` chega produz erros de connection-refused por várias centenas de milissegundos a segundos de tráfego. A forma declarativa equivalente é um hook `preStop` com `sleep` (mostrado na §6.4).

### 3.3 Fator XI — logs como fluxo de eventos

Escreva em `stdout`/`stderr`, sem buffer, um evento por linha, estruturado. Não abra arquivos de log, não configure rotação dentro do contêiner, não envie logs da aplicação diretamente para o agregador (isso acopla a disponibilidade da sua aplicação ao backend de logging).

Estruturado é a palavra operativa: uma linha que o coletor consegue indexar sem regex.

```
{"ts":"2026-09-18T09:14:22.418Z","level":"error","service":"orders","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","event":"payment_authorise_failed","order_id":"ord_01J8X","upstream":"payments","status":502,"latency_ms":3021,"retry":2}
```

O `trace_id` deve ser propagado a partir do cabeçalho `traceparent` de entrada (W3C Trace Context) — sem ele, correlacionar um 500 visível ao usuário através de sete serviços é arqueologia manual. Logs, métricas e traces são os três sinais; o requisito de projeto é que os três carreguem o mesmo ID de correlação.

---

## 4. Conceitos e padrões de API

### 4.1 REST, e o que "RESTful" realmente restringe

REST é um estilo arquitetural (Fielding, 2000) com restrições concretas: cliente–servidor, **ausência de estado**, cacheabilidade, interface uniforme, sistema em camadas e code-on-demand opcional. A restrição que importa operacionalmente é a ausência de estado: *cada requisição contém toda a informação necessária para atendê-la*. É isso que permite a um balanceador de carga rotear qualquer requisição para qualquer réplica, o que é o que permite escalabilidade horizontal e rolling updates.

O Richardson Maturity Model é a escala usual:

| Nível | Característica | Nota prática |
|---|---|---|
| 0 | Uma URI, um verbo (POST), RPC sobre HTTP | Estilo SOAP; nenhuma semântica HTTP usada |
| 1 | Recursos — muitas URIs | `/orders/42`, `/customers/7` |
| 2 | Verbos e códigos de status HTTP | GET é seguro e cacheável, PUT/DELETE idempotentes, 201/404/409/422 usados corretamente |
| 3 | Controles de hipermídia (HATEOAS) | Raro na prática; valioso para APIs públicas de longa duração |

O nível 2 é o alvo realista de produção. A semântica com que tanto o exame quanto o CDN se importam:

| Método | Seguro | Idempotente | Cacheável | Uso típico |
|---|---|---|---|---|
| GET | Sim | Sim | Sim | Leitura |
| HEAD | Sim | Sim | Sim | Metadados / existência |
| PUT | Não | **Sim** | Não | Substituição completa em uma URI conhecida |
| DELETE | Não | **Sim** | Não | Remoção (repetir ⇒ 404 ou 204) |
| POST | Não | **Não** | Raramente | Criação em uma URI escolhida pelo servidor, ação não-CRUD |
| PATCH | Não | Não | Não | Atualização parcial (merge-patch RFC 7396 ou JSON Patch RFC 6902) |

**Como o POST não é idempotente, um retry após um timeout pode cobrar um cliente duas vezes.** A mitigação padrão é um cabeçalho de requisição `Idempotency-Key`: o servidor armazena a chave com a resposta por um TTL e reproduz a resposta armazenada em uma repetição. Qualquer API que movimente dinheiro ou crie recursos sobre uma rede não confiável precisa disso.

### 4.2 JSON e a disciplina de media type

JSON (RFC 8259) é a representação padrão: UTF-8, sem comentários, sem vírgulas finais, sem NaN/Infinity. Os perigos de produção:

- **Precisão numérica.** Números JSON são doubles IEEE-754 na maioria dos parsers; inteiros acima de 2^53 perdem precisão. Serialize IDs de 64 bits e valores monetários como strings, ou use unidades menores (centavos inteiros) — nunca floats para dinheiro.
- **Datas.** Sempre RFC 3339 / ISO 8601 com offset explícito (`2026-09-18T09:14:22Z`). Nunca uma string formatada por locale, nunca um epoch puro sem documentar a unidade.
- **Campos desconhecidos.** Os consumidores devem ignorar campos que não conhecem (tolerant reader). É isso que torna mudanças aditivas não quebradoras.
- **Erros.** Use `application/problem+json` (RFC 9457) em vez de inventar um envelope de erro por equipe.

Uma resposta de problema, que é um único documento JSON:

```json
{
  "type": "https://api.example.com/problems/insufficient-funds",
  "title": "Insufficient funds",
  "status": 409,
  "detail": "Account acc_8812 has a balance of 24.50 EUR; the authorisation requires 89.90 EUR.",
  "instance": "/orders/ord_01J8X/payments",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "balance_minor_units": 2450,
  "required_minor_units": 8990
}
```

### 4.3 O contrato é um arquivo, e é versionado

Uma API sem um contrato legível por máquina não pode ser validada em CI, não pode gerar clientes e não pode ser comparada em busca de mudanças quebradoras. OpenAPI é o padrão para APIs HTTP.

```yaml
openapi: 3.1.0
info:
  title: Orders API
  version: 2.3.0
  description: "Order lifecycle: creation, authorisation and cancellation."
  contact:
    name: Platform Team
    url: "https://internal.example.com/teams/platform"
servers:
  - url: "https://api.example.com/v2"
    description: Production
  - url: "https://api.staging.example.com/v2"
    description: Staging
security:
  - bearerAuth: []
paths:
  /orders:
    get:
      summary: List orders
      operationId: listOrders
      parameters:
        - name: cursor
          in: query
          required: false
          description: "Opaque cursor returned by the previous page."
          schema:
            type: string
        - name: limit
          in: query
          required: false
          schema:
            type: integer
            minimum: 1
            maximum: 200
            default: 50
      responses:
        "200":
          description: A page of orders
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/OrderPage"
        "429":
          $ref: "#/components/responses/RateLimited"
    post:
      summary: Create an order
      operationId: createOrder
      parameters:
        - name: Idempotency-Key
          in: header
          required: true
          description: "Client-generated UUIDv4; replays return the original response."
          schema:
            type: string
            format: uuid
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/OrderCreate"
      responses:
        "201":
          description: Created
          headers:
            Location:
              description: "URI of the created order."
              schema:
                type: string
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "409":
          description: Idempotency key reused with a different payload
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
  /orders/{orderId}:
    parameters:
      - name: orderId
        in: path
        required: true
        schema:
          type: string
    get:
      summary: Fetch a single order
      operationId: getOrder
      responses:
        "200":
          description: The order
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "404":
          description: No such order
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
  responses:
    RateLimited:
      description: Too many requests
      headers:
        Retry-After:
          description: "Seconds to wait before retrying."
          schema:
            type: integer
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
  schemas:
    OrderCreate:
      type: object
      required:
        - customerId
        - lines
      properties:
        customerId:
          type: string
        lines:
          type: array
          minItems: 1
          items:
            $ref: "#/components/schemas/OrderLine"
    OrderLine:
      type: object
      required:
        - sku
        - quantity
      properties:
        sku:
          type: string
        quantity:
          type: integer
          minimum: 1
        unitPriceMinor:
          type: integer
          description: "Price in minor units, for example cents. Never a float."
    Order:
      type: object
      required:
        - id
        - status
        - createdAt
      properties:
        id:
          type: string
        status:
          type: string
          enum:
            - pending
            - authorised
            - shipped
            - cancelled
        createdAt:
          type: string
          format: date-time
        totalMinor:
          type: integer
        currency:
          type: string
          example: EUR
    OrderPage:
      type: object
      required:
        - items
      properties:
        items:
          type: array
          items:
            $ref: "#/components/schemas/Order"
        nextCursor:
          type: string
          nullable: true
    Problem:
      type: object
      properties:
        type:
          type: string
        title:
          type: string
        status:
          type: integer
        detail:
          type: string
        instance:
          type: string
```

Valide-o em CI — um contrato que não é validado é documentação, e documentação sofre drift:

```
$ redocly lint openapi.yaml
validating openapi.yaml...
openapi.yaml: validated in 84ms

Woohoo! Your API description is valid. 🎉

$ oasdiff breaking https://api.example.com/v2/openapi.yaml ./openapi.yaml
1 breaking changes: 1 error, 0 warning
error   [response-property-removed] at ./openapi.yaml
        in API GET /orders/{orderId}
                removed the response property 'discountMinor' from the response with the '200' status
```

### 4.4 Estratégias de versionamento

| Estratégia | Exemplo | Prós | Contras |
|---|---|---|---|
| Caminho na URI | `/v2/orders` | Trivialmente visível, amigável a cache, roteamento fácil no gateway | Viola "um recurso, uma URI"; força mudanças no código do cliente |
| Media type | `Accept: application/vnd.example.order+json;version=2` | REST mais puro, evolução por recurso | Mais difícil de testar à mão; proxies/CDNs precisam variar em `Accept` |
| Parâmetro de consulta | `/orders?version=2` | Simples | Fácil de esquecer; polui as chaves de cache |
| Cabeçalho | `X-API-Version: 2` | URIs limpas | Invisível em logs/navegadores a menos que explicitamente registrado |
| **Sem versão — apenas aditivo** | — | Sem fan-out de implementações | Exige disciplina estrita: apenas adicionar campos opcionais, nunca remover ou mudar o tipo |

Orientação de produção: versione o contrato *major* no caminho para APIs públicas, e dentro da versão major permita apenas mudanças retrocompatíveis (adicionar campos opcionais, adicionar valores de enum apenas se estiver documentado que os clientes toleram valores desconhecidos, nunca mudar o tipo ou a semântica de um campo). Internamente, prefira nenhuma versão mais testes de contrato orientados ao consumidor.

### 4.5 REST vs as alternativas

| | REST/JSON sobre HTTP/1.1 | gRPC (HTTP/2 + protobuf) | GraphQL | Mensageria assíncrona (AMQP/Kafka) |
|---|---|---|---|---|
| Contrato | OpenAPI (opcional) | `.proto` (obrigatório, compilado) | Esquema SDL (obrigatório) | Schema registry (Avro/Protobuf/JSON Schema) |
| Payload | Texto, verboso, legível por humanos | Binário, compacto | JSON | Binário ou JSON |
| Sobrecarga típica de latência | Referência | 30–60 % menor; streams multiplexados | Referência + fan-out de resolvers | Desacoplado — não comparável |
| Suporte a navegador | Nativo | Precisa de grpc-web + proxy | Nativo | Via ponte WebSocket |
| Streaming | SSE / WebSocket acoplado | Bidirecional nativo | Subscriptions | Nativo |
| Cache | Cache HTTP (ETag, Cache-Control, CDN) | Nenhum padrão | Difícil (endpoint POST único) | N/A |
| Over/under-fetching | Comum | Comum | Resolvido por projeto | N/A |
| Acoplamento temporal | Síncrono | Síncrono | Síncrono | **Removido** |
| Depurabilidade | `curl` | `grpcurl`, precisa de reflexão | GraphiQL | CLI do broker + inspeção da DLQ |
| Melhor uso | APIs públicas, CRUD, qualquer coisa que um navegador chame | Leste-oeste interno, alto QPS, poliglota | Agregação para clientes heterogêneos (mobile/web) | Eventos, filas de trabalho, fan-out, buffering |
| Principal perigo | N+1 tagarela atravessando fronteiras | Opaco na rede; skew de versão nos stubs gerados | Uma única query pode causar DoS no backend (precisa de limites de profundidade/complexidade) | Duplicatas at-least-once; ordenação apenas por partição |

**Regra prática de projeto:** requisição/resposta síncrona para consultas em que um usuário está esperando; eventos assíncronos para propagação de estado entre serviços. Se o serviço A chama B que chama C que chama D sincronamente para atender uma requisição, sua disponibilidade é o produto de quatro serviços e seu p99 é a soma de quatro p99s.

### 4.6 CORS — a política de mesma origem e seu relaxamento controlado

Os navegadores impõem a **política de mesma origem** (same-origin policy): um documento da origem `https://app.example.com` não pode ler uma resposta de `https://api.example.com`. Uma origem é a tripla *(esquema, host, porta)* — `https://app.example.com` e `https://app.example.com:8443` são origens diferentes, assim como as variantes `http://` e `https://`.

**CORS (Cross-Origin Resource Sharing)** é o mecanismo pelo qual o *servidor* diz ao navegador para relaxar essa restrição. Três pontos que são constantemente mal compreendidos:

1. CORS é imposto **pelo navegador**, não pelo servidor. O `curl` o ignora completamente — uma requisição que falha no Chrome e tem sucesso no `curl` é um problema de CORS, sempre.
2. CORS **não** é um controle de segurança do lado do servidor. Ele não protege a API; ele protege a sessão de navegador do *usuário* de ser lida por uma página hostil. Sua API ainda precisa de autenticação e autorização.
3. Uma verificação de CORS que falha não impede a requisição de chegar ao servidor em uma requisição simples — ela impede que a *resposta seja lida*. Efeitos colaterais podem já ter acontecido, e é por isso que a proteção contra CSRF continua sendo necessária.

**Requisições simples vs com preflight.** Uma requisição é "simples" (sem preflight) apenas se o método for `GET`, `HEAD` ou `POST`, os cabeçalhos estiverem limitados ao conjunto CORS-safelisted, e o `Content-Type` for um entre `application/x-www-form-urlencoded`, `multipart/form-data` ou `text/plain`. **`Content-Type: application/json` portanto sempre dispara um preflight** — e é por isso que praticamente toda API REST precisa tratar `OPTIONS`.

A troca de preflight, observada:

```
$ curl -i -X OPTIONS https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,authorization,idempotency-key'
HTTP/2 204
access-control-allow-origin: https://app.example.com
access-control-allow-methods: GET, POST, PUT, DELETE, PATCH, OPTIONS
access-control-allow-headers: content-type,authorization,idempotency-key
access-control-allow-credentials: true
access-control-max-age: 600
vary: Origin
date: Fri, 18 Sep 2026 09:22:41 GMT
```

Então a requisição de fato:

```
$ curl -i -X POST https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer eyJhbGciOi...' \
    -H 'Idempotency-Key: 6f1c2a3e-9b4d-4f2a-8c11-77d0f5a1b2c3' \
    -d '{"customerId":"cus_7","lines":[{"sku":"SKU-1","quantity":2}]}'
HTTP/2 201
location: /v2/orders/ord_01J8X
access-control-allow-origin: https://app.example.com
access-control-expose-headers: Location, X-Request-Id
access-control-allow-credentials: true
vary: Origin
content-type: application/json
```

Referência de cabeçalhos:

| Cabeçalho | Direção | Significado |
|---|---|---|
| `Origin` | Requisição | A origem do documento solicitante; definida pelo navegador, não forjável pelo JS da página |
| `Access-Control-Request-Method` | Preflight | Método que a requisição real vai usar |
| `Access-Control-Request-Headers` | Preflight | Cabeçalhos não-safelisted que a requisição real vai enviar |
| `Access-Control-Allow-Origin` | Resposta | Origem permitida, ou `*` |
| `Access-Control-Allow-Methods` | Resposta de preflight | Métodos permitidos |
| `Access-Control-Allow-Headers` | Resposta de preflight | Cabeçalhos de requisição permitidos |
| `Access-Control-Allow-Credentials` | Resposta | `true` permite cookies/certificados de cliente TLS; **incompatível com `*`** |
| `Access-Control-Expose-Headers` | Resposta | Cabeçalhos de resposta que o JS pode ler (por padrão apenas os seis safelisted) |
| `Access-Control-Max-Age` | Resposta de preflight | Segundos que o navegador pode cachear o preflight |
| `Vary: Origin` | Resposta | **Obrigatório** quando a origem permitida é calculada — caso contrário um cache compartilhado serve os cabeçalhos da origem A para a origem B |

Os quatro bugs de CORS que você vai realmente encontrar:

1. `Access-Control-Allow-Origin: *` junto com `Access-Control-Allow-Credentials: true` — o navegador rejeita a combinação de imediato. Com credenciais você precisa ecoar a origem exata (a partir de uma allowlist) e emitir `Vary: Origin`.
2. Refletir o `Origin` sem validá-lo — isso permite que qualquer site leia respostas autenticadas. Sempre confronte com uma allowlist explícita.
3. A rota `OPTIONS` exige autenticação — o navegador não envia credenciais em um preflight, então recebe 401 e a requisição real nunca acontece. O preflight deve ser respondido antes do middleware de autenticação.
4. Um `Vary: Origin` ausente atrás de um CDN — falhas intermitentes e dependentes de origem que "só acontecem com alguns usuários".

---

## 5. Armazenamento de dados, estado e configuração

### 5.1 Sem estado é uma propriedade do processo, não do sistema

O estado não desaparece; ele se move para um serviço de apoio construído para esse fim. O alvo de projeto é que **qualquer réplica possa atender qualquer requisição**, e que matar uma réplica não perca nada além do trabalho em andamento.

| Categoria de estado | Lar errado | Lar certo |
|---|---|---|
| Sessão de usuário | Memória do processo | Redis/Memcached, ou um token assinado mantido pelo cliente |
| Arquivos enviados | Sistema de arquivos do contêiner | Armazenamento de objetos (compatível com S3) |
| Cache | Mapa por réplica (inconsistente entre réplicas) | Cache compartilhado, ou por réplica com TTL curto e inconsistência aceita |
| Jobs agendados / líder | "O primeiro pod" | Eleição de líder pela plataforma (objeto Lease), ou uma fila |
| Trabalho em andamento | Fila local em memória | Broker durável com visibility timeout |
| Dados de negócio | SQLite local no contêiner | Banco de dados gerenciado/operado por operator com backups |

### 5.2 Tratamento de sessão: sessões sticky vs estado externalizado vs tokens

| Abordagem | Como funciona | Comportamento no scale-in | Modo de falha |
|---|---|---|---|
| **Em memória + sessões sticky** | O LB fixa um cliente a uma réplica por cookie ou hash de IP de origem | Usuários na réplica encerrada perdem a sessão | Carga desigual; rolling updates deslogam todo mundo; bloqueia o autoescalonamento |
| **Armazenamento externo de sessão** | Cookie com ID de sessão; estado no Redis com TTL | Transparente | O Redis passa a estar no caminho crítico — precisa de HA e de um orçamento de latência |
| **Token no cliente (JWT)** | Claims assinados no cookie/cabeçalho; o servidor verifica a assinatura | Transparente, sem estado no servidor | **A revogação é difícil**; o tamanho do token cresce; os claims ficam obsoletos até expirar |
| **Híbrido** | Access token de curta duração (5–15 min) + refresh token no servidor | Transparente | O melhor trade-off prático; revogue invalidando o refresh token |

Sessões sticky no Kubernetes são `service.spec.sessionAffinity: ClientIP` (L4, grosseiro, quebra atrás de NAT) ou uma anotação de cookie no ingress (L7). Trate ambos como uma muleta de migração para aplicações legadas, não como um projeto.

**Especificidades de JWT que causam incidentes:** valide o `alg` contra uma allowlist (rejeite `none` e rejeite confusão de algoritmo entre HMAC e RSA), valide `iss`, `aud`, `exp` e `nbf`, mantenha a expiração curta, e nunca coloque nada secreto no payload — um JWT é assinado, não criptografado, e é trivialmente decodificado em base64 por qualquer um que o possua.

### 5.3 Escolhendo um armazenamento de dados

| Tipo de armazenamento | Modelo | Consistência | Escala por | Use para | Não use para |
|---|---|---|---|---|---|
| Relacional (PostgreSQL, MySQL) | Tabelas, joins, restrições | Forte, ACID | Vertical + réplicas de leitura; o sharding é manual | Dados transacionais de negócio, qualquer coisa com invariantes | Blobs; throughput de escrita ilimitado |
| Chave-valor (Redis, Memcached) | `key → value` | Tipicamente last-write-wins | Horizontal (sharding) | Cache, sessões, rate limiters, locks | Sistema de registro (a menos que a persistência esteja configurada e compreendida) |
| Documento (MongoDB, CouchDB) | Documentos JSON | Atômico por documento; ajustável | Horizontal | Agregados lidos por inteiro, esquemas flexíveis | Invariantes transacionais entre documentos |
| Wide-column (Cassandra, ScyllaDB) | Chaves de partição + clustering | Ajustável (quórum) | Horizontal, linear | Throughput de escrita massivo, séries temporais | Consultas ad-hoc; a forma da consulta precisa ser conhecida antes |
| Busca (OpenSearch, Elasticsearch) | Índice invertido | Quase em tempo real | Horizontal | Texto completo, agregações | Sistema de registro |
| Armazenamento de objetos (compatível com S3) | Bucket/chave → blob | Read-after-write para objetos novos | Efetivamente ilimitado | Arquivos, backups, artefatos, ativos estáticos | Qualquer coisa que precise de um motor de consulta |
| Message broker (Kafka, RabbitMQ) | Log / fila | At-least-once | Partições / filas | Desacoplamento, buffering, fluxos de eventos | Armazenamento de acesso aleatório |
| Série temporal (Prometheus, VictoriaMetrics) | Séries rotuladas | Eventualmente consistente | Sharding/federação | Métricas | Eventos que precisam de retenção/auditoria exatas |

**CAP e PACELC em um parágrafo.** Sob uma **P**artição de rede você precisa escolher **C**onsistência ou **A**vailability (disponibilidade); partições não são opcionais, então CAP é na verdade uma escolha CP/AP. PACELC acrescenta o resto do tempo: **E**lse (caso contrário), escolha **L**atência ou **C**onsistência. Um banco de dados replicado sincronamente compra consistência com latência de escrita; uma réplica assíncrona compra latência com uma janela de desatualização e possível perda de dados no failover. Faça essa escolha explicitamente por conjunto de dados — um livro-razão de pedidos e uma lista de "vistos recentemente" não precisam da mesma garantia.

---

## 6. Projetando software para rodar em contêineres

### 6.1 Regras de projeto de contêineres

1. **Uma preocupação por contêiner.** Não "um processo" — um servidor web com um pool de workers está ok — mas uma razão para ser reiniciado, um ciclo de vida, uma dimensão de escalabilidade. Sidecars (proxy, log shipper) pertencem ao mesmo pod, não ao mesmo contêiner.
2. **A imagem é imutável e agnóstica de ambiente.** Exatamente uma imagem é construída por commit e promovida pelos ambientes. Se você constrói `myapp:prod`, você não testou o que implanta.
3. **Fixe por digest em produção.** Tags são mutáveis: `image: registry/orders@sha256:…` é reproduzível; `orders:v2.3.0` é uma promessa que alguém pode quebrar.
4. **Base pequena, não-root, rootfs somente leitura.** Cada binário na imagem é superfície de ataque e ruído em varredura de CVEs.
5. **O PID 1 trata sinais** (§3.2).
6. **Sem segredos nas camadas.** Um `RUN` que faz curl com um token deixa o token na camada para sempre, mesmo que uma camada posterior apague o arquivo. Use montagens de build secrets.
7. **Exponha endpoints de saúde** que sejam baratos e honestos (§6.3).

### 6.2 Um build multi-stage completo, com forma de produção

```dockerfile
# syntax=docker/dockerfile:1.7

########## Stage 1 — build ##########
FROM golang:1.23-bookworm AS build
WORKDIR /src

# Dependency layer: cached unless go.mod/go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
ARG VERSION=dev
ARG COMMIT=unknown
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/orders ./cmd/orders

########## Stage 2 — test (fails the build, not the pipeline afterwards) ##########
FROM build AS test
RUN CGO_ENABLED=0 go vet ./... && go test -count=1 ./...

########## Stage 3 — runtime ##########
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# distroless/static:nonroot runs as UID/GID 65532 and ships CA certificates
# and /etc/passwd, but no shell, no package manager, no busybox.
COPY --from=build /out/orders /usr/local/bin/orders

USER 65532:65532
EXPOSE 8080
ENV GOMAXPROCS=0 \
    OTEL_SERVICE_NAME=orders

# Exec form: the binary is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/usr/local/bin/orders"]
```

Construir e inspecionar:

```
$ docker buildx build \
    --build-arg VERSION=2.3.0 \
    --build-arg COMMIT=$(git rev-parse --short HEAD) \
    --target runtime \
    --provenance=true --sbom=true \
    -t registry.example.com/orders:2.3.0 --push .
[+] Building 41.7s (18/18) FINISHED
 => [build 5/6] RUN --mount=type=cache ... go build                     28.4s
 => [test 1/1] RUN go vet ./... && go test -count=1 ./...                9.1s
 => exporting to image                                                   1.2s
 => => pushing manifest for registry.example.com/orders:2.3.0@sha256:9f2c...

$ docker image ls registry.example.com/orders:2.3.0
REPOSITORY                         TAG     IMAGE ID       CREATED          SIZE
registry.example.com/orders        2.3.0   3b1f8e0c7a55   12 seconds ago   14.8MB

$ docker run --rm registry.example.com/orders:2.3.0 --version
orders 2.3.0 (commit 8c41d0a, go1.23.4)
```

Verifique que o processo é realmente o PID 1 e realmente morre com `SIGTERM`:

```
$ docker run -d --name orders-t registry.example.com/orders:2.3.0
c81f2a44e19b
$ docker top orders-t
UID    PID    PPID   C   STIME   TTY   TIME       CMD
65532  41207  41185  0   09:31   ?     00:00:00   /usr/local/bin/orders
$ time docker stop orders-t
orders-t

real    0m0.412s
```

`real 0m0.4s` prova que o handler rodou. Um `real 0m10.0s` aqui significa que o `SIGTERM` foi ignorado e o runtime recorreu ao `SIGKILL` — o defeito de conteinerização mais comum de todos.

### 6.3 Endpoints de saúde: três perguntas distintas

| Probe | Pergunta | Ação em caso de falha | NÃO deve verificar |
|---|---|---|---|
| **Startup** | A inicialização terminou? | Mantém liveness/readiness suspensas até passar | — |
| **Liveness** | Este processo está travado além de recuperação? | **Reiniciar o contêiner** | Dependências. Uma liveness probe que verifica o banco de dados reinicia todos os pods quando o DB oscila — uma indisponibilidade autoinfligida |
| **Readiness** | Esta réplica consegue servir tráfego *agora*? | Remover dos endpoints do Service (sem restart) | Qualquer coisa lenta ou cara |

`/livez` deve ser uma resposta de tempo constante a partir do handler HTTP — se ele responde, o event loop está vivo. `/readyz` pode verificar o pool de conexões e os caches sem os quais não consegue servir, e deve passar a falhar no `SIGTERM`. Ambos devem ser excluídos da autenticação e dos logs de acesso, e nenhum deles deve ser exposto através do ingress.

### 6.4 Conjunto completo de manifestos Kubernetes

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders
  namespace: shop
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: orders-config
  namespace: shop
data:
  LOG_LEVEL: info
  LOG_FORMAT: json
  HTTP_PORT: "8080"
  PAYMENTS_BASE_URL: "http://payments.shop.svc.cluster.local:8080"
  PAYMENTS_TIMEOUT: 2s
  PAYMENTS_RETRIES: "2"
  DB_POOL_MAX_CONNS: "20"
  DB_POOL_MAX_CONN_LIFETIME: 30m
  CORS_ALLOWED_ORIGINS: "https://app.example.com,https://admin.example.com"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
---
apiVersion: v1
kind: Secret
metadata:
  name: orders-secrets
  namespace: shop
type: Opaque
stringData:
  DATABASE_URL: "postgres://orders_app:S3cr3t-Pa55@postgres-rw.shop.svc.cluster.local:5432/orders?sslmode=verify-full"
  JWT_PUBLIC_KEY_PEM: |
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0vx7agoebGcQSuuPiLJX
    ZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tS
    oc_TRUNCATED_FOR_BREVITY_REPLACE_WITH_REAL_KEY
    -----END PUBLIC KEY-----
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
  namespace: shop
  labels:
    app.kubernetes.io/name: orders
    app.kubernetes.io/version: 2.3.0
    app.kubernetes.io/part-of: shop
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders
        app.kubernetes.io/version: 2.3.0
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: orders
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders
      containers:
        - name: orders
          image: "registry.example.com/orders@sha256:9f2c4d1b8ae0a7c3f5d69b21c0e4a7f8d3b6c19e25aa70fd1c8b4e39a6d2f701"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          envFrom:
            - configMapRef:
                name: orders-config
            - secretRef:
                name: orders-secrets
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: NODE_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['topology.kubernetes.io/zone']
            - name: GOMEMLIMIT
              valueFrom:
                resourceFieldRef:
                  resource: limits.memory
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /startupz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command:
                  - /usr/local/bin/orders
                  - drain
                  - --wait=10s
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: orders
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: orders
  ports:
    - name: http
      port: 8080
      targetPort: http
    - name: metrics
      port: 9090
      targetPort: metrics
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orders
  namespace: shop
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: orders
  namespace: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: orders
  minReplicas: 4
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
    - type: Pods
      pods:
        metric:
          name: http_requests_inflight
        target:
          type: AverageValue
          averageValue: "25"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 8
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: orders
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: orders
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: payments
      ports:
        - protocol: TCP
          port: 8080
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: postgres
      ports:
        - protocol: TCP
          port: 5432
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: orders
  namespace: shop
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.example.com"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-headers: "Content-Type, Authorization, Idempotency-Key, traceparent"
    nginx.ingress.kubernetes.io/cors-expose-headers: "Location, X-Request-Id"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
    nginx.ingress.kubernetes.io/cors-max-age: "600"
    nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: api-example-com-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v2/orders
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  name: http
```

Notas que um arquiteto deveria saber defender em uma revisão:

- **`maxUnavailable: 0`** — durante um rolling update a capacidade nunca cai abaixo de `replicas`; o pod de surge precisa ser agendável, então deixe folga.
- **Sem limite de CPU, com limite de memória definido** — limites de CPU causam throttling do CFS e precipícios de latência p99; a memória é incompressível, então precisa de um limite para proteger o nó. `GOMEMLIMIT` derivado do limite mantém o GC do Go abaixo do teto do cgroup em vez de sofrer OOMKill.
- **`terminationGracePeriodSeconds: 45` > drain do preStop (10 s) + timeout de shutdown (25 s)** — se o período de graça for menor que o drain, o kernel mata o processo no meio de uma requisição.
- **`topologySpreadConstraints` em zonas com `DoNotSchedule`** — é isso que torna "multi-AZ" real em vez de aspiracional; sem isso o scheduler pode colocar as quatro réplicas em uma única zona.
- **`automountServiceAccountToken: false`** — uma aplicação que não chama a API do Kubernetes não tem por que segurar um token que pode chamá-la.
- **Egresso default-deny** — a NetworkPolicy acima é uma allowlist completa; note que o DNS precisa ser explicitamente permitido ou toda resolução de nomes falha, o que se apresenta como erros de conexão aleatórios, não como um erro de política.

---

## 7. Modelos de implantação em nuvem, elasticidade e imutabilidade

### 7.1 Divisão de responsabilidades

| Modelo | Você gerencia | O provedor gerencia | Unidade de escala | Lock-in típico |
|---|---|---|---|---|
| **On-premises** | Tudo | Nada | Rack | Nenhum |
| **IaaS** | SO, runtime, aplicação, dados | Virtualização, hardware, malha de rede | VM | Baixo (imagens, rede) |
| **CaaS** (Kubernetes gerenciado) | Imagem de contêiner, manifestos, aplicação, dados | Control plane, ciclo de vida dos nós | Pod | Médio (portável via a API do Kubernetes) |
| **PaaS** | Código da aplicação + configuração | SO, runtime, escalabilidade, patching | Instância da aplicação | Alto (buildpacks, serviços proprietários) |
| **FaaS** | Código da função | Todo o resto | Invocação | Muito alto (modelo de eventos, limites de runtime) |
| **SaaS** | Dados e configuração | A aplicação inteira | Assento/uso | Muito alto (exportar dados é a única saída) |

O enquadramento do exame: IaaS ⇒ você ainda aplica patches no SO; PaaS ⇒ você envia código, não máquinas; SaaS ⇒ você consome, você não implanta.

### 7.2 Regiões, zonas de disponibilidade, e contra o que elas realmente protegem

- **Zona de disponibilidade**: um domínio de falha independente dentro de uma região — energia, refrigeração e rede separadas, mas interconexão de baixa latência (tipicamente <2 ms). Protege contra uma falha em nível de datacenter. Barata de usar: replicação síncrona entre AZs é viável.
- **Região**: uma localização geograficamente distinta. Protege contra uma indisponibilidade regional e satisfaz requisitos de residência de dados. A replicação entre regiões é assíncrona na prática (velocidade da luz), então vem com um RPO > 0.

| Falha a sobreviver | Topologia mínima | Custo | Consistência de dados |
|---|---|---|---|
| Nó/VM único | ≥2 réplicas, antiafinidade | Desprezível | Não afetada |
| Rack / domínio de energia | Distribuir entre hosts | Desprezível | Não afetada |
| Zona de disponibilidade | ≥3 réplicas em ≥3 AZs; datastore baseado em quórum | Cobranças de tráfego entre AZs | Forte, síncrona |
| Região | Ativo/passivo ou ativo/ativo multirregião | Alto (footprint dobrado, egresso) | Eventual; defina RPO/RTO explicitamente |

**Elasticidade vs escalabilidade** — escalabilidade é a capacidade de lidar com mais carga adicionando recursos; elasticidade é fazer isso *automaticamente e nos dois sentidos* em resposta à demanda. Elasticidade exige ausência de estado (§5.1), inicialização rápida (fator IX) e uma métrica que anteceda a demanda em vez de ficar atrás dela. A utilização de CPU fica atrás; a profundidade da fila e as requisições em andamento antecedem — e é por isso que o HPA acima usa ambas.

### 7.3 Infraestrutura imutável

| | Servidores mutáveis ("pets") | Servidores imutáveis ("gado") |
|---|---|---|
| Mecanismo de mudança | SSH, execução de gerência de configuração no local | Construir uma nova imagem, substituir a instância |
| Drift | Acumula silenciosamente; servidores floco-de-neve | Estruturalmente impossível |
| Rollback | Reexecutar uma configuração antiga e torcer | Reimplantar a imagem/digest anterior |
| Depurar um incidente ao vivo | Logar e fuçar | Reproduzir a partir da mesma imagem localmente |
| Tempo de provisionamento | Minutos (execução da configuração) | Minutos (bake da imagem) + segundos (boot) |
| Evidência de conformidade | Varreduras de inventário | O digest da imagem *é* a evidência |
| Ponto fraco | "Funcionou na última vez que rodamos o Ansible" | Exige um pipeline de build real e um repositório de artefatos |

Contêineres tornam a imutabilidade o padrão. Em VMs, o equivalente é o image baking (Packer) mais uma implantação de substituir-em-vez-de-corrigir. Em ambos os casos a disciplina é a mesma: **nenhuma mudança interativa em infraestrutura em execução** — se você faz `kubectl exec` e edita um arquivo, o próximo reagendamento o reverte silenciosamente, e você inventou um bug que só reproduz às vezes.

Infraestrutura como código, declarada e revisável:

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {
    bucket         = "example-tfstate-prod"
    key            = "shop/orders/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

variable "image_digest" {
  description = "Immutable image reference promoted from staging."
  type        = string
}

resource "aws_db_instance" "orders" {
  identifier                   = "orders-prod"
  engine                       = "postgres"
  engine_version               = "16.4"
  instance_class               = "db.r6g.xlarge"
  allocated_storage            = 200
  storage_encrypted            = true
  multi_az                     = true # synchronous standby in a second AZ
  backup_retention_period      = 14
  performance_insights_enabled = true
  deletion_protection          = true
  apply_immediately            = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Service     = "orders"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

```
$ terraform plan -out=orders.tfplan
Terraform used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  ~ update in-place

Terraform will perform the following actions:

  # aws_db_instance.orders will be updated in-place
  ~ resource "aws_db_instance" "orders" {
        id                      = "orders-prod"
      ~ backup_retention_period = 7 -> 14
        # (48 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

### 7.4 Estratégias de implantação

| Estratégia | Mecanismo | Indisponibilidade | Capacidade extra | Velocidade de rollback | Detecta releases ruins por |
|---|---|---|---|---|---|
| **Recreate** | Parar tudo, iniciar o novo | Sim | Nenhuma | Reimplantar (lento) | Usuários reclamando |
| **Rolling** | Substituir N por vez | Não | `maxSurge` | Rollback = outro rolling update | Probes + métricas a posteriori |
| **Blue-green** | Dois ambientes completos, chavear o roteador | Não | **100 %** | Instantâneo (voltar o chaveamento) | Smoke tests no green antes do chaveamento |
| **Canary** | Pequena % do tráfego real para a nova versão, aumentar gradualmente | Não | Pequena | Rápido (devolver o tráfego) | Métricas reais de produção em tráfego real |
| **Testes A/B** | Rotear por atributo do usuário (cabeçalho/cookie) | Não | Pequena | Rápido | Métricas de negócio, não só erros |
| **Shadow / mirror** | Duplicar o tráfego para a nova versão, descartar as respostas | Não | Duplicata completa da nova versão | N/A (nunca serve usuários) | Comparação, com zero risco para o usuário |

Blue-green e canary ambos exigem **dados retrocompatíveis**: durante a transição, duas versões de código leem e escrevem no mesmo banco de dados. Este é o padrão expand-contract (parallel change):

1. **Expand** — adicione a nova coluna/tabela anulável; implante código que escreve tanto no antigo quanto no novo e lê do antigo.
2. **Migrate** — preencha retroativamente a nova coluna; implante código que escreve em ambos e lê do novo.
3. **Contract** — implante código que escreve e lê apenas do novo; remova a coluna antiga em um release posterior.

Nunca combine uma mudança de esquema e uma mudança de código que dependa dela na mesma implantação. É isso que torna o rollback impossível, e o rollback é a única mitigação confiável de incidentes.

Um canary com análise automatizada, para que a decisão de rollback não seja um humano encarando um dashboard às 03:00:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: orders
  namespace: shop
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders
    spec:
      containers:
        - name: orders
          image: "registry.example.com/orders@sha256:9f2c4d1b8ae0a7c3f5d69b21c0e4a7f8d3b6c19e25aa70fd1c8b4e39a6d2f701"
          ports:
            - name: http
              containerPort: 8080
  strategy:
    canary:
      canaryService: orders-canary
      stableService: orders-stable
      trafficRouting:
        nginx:
          stableIngress: orders
      analysis:
        templates:
          - templateName: orders-success-rate
        startingStep: 2
        args:
          - name: service-name
            value: orders-canary
      steps:
        - setWeight: 5
        - pause:
            duration: 5m
        - setWeight: 20
        - pause:
            duration: 10m
        - setWeight: 50
        - pause:
            duration: 10m
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: orders-success-rate
  namespace: shop
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 60s
      count: 20
      successCondition: "result[0] >= 0.995"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            sum(rate(http_requests_total{service="{{args.service-name}}",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{service="{{args.service-name}}"}[2m]))
    - name: latency-p99
      interval: 60s
      count: 20
      successCondition: "result[0] <= 0.750"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            histogram_quantile(
              0.99,
              sum by (le) (
                rate(http_request_duration_seconds_bucket{service="{{args.service-name}}"}[2m])
              )
            )
```

Observado durante um rollout:

```
$ kubectl argo rollouts get rollout orders -n shop --watch
Name:            orders
Namespace:       shop
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/7
  SetWeight:     20
  ActualWeight:  20
Images:          registry.example.com/orders@sha256:9f2c... (canary)
                 registry.example.com/orders@sha256:1a7e... (stable)
Replicas:
  Desired:       10
  Current:       10
  Updated:       2
  Ready:         10
  Available:     10

NAME                                 KIND         STATUS     AGE   INFO
⟳ orders                             Rollout      ॥ Paused   6d
├──# revision:12
│  └──⧉ orders-7c9f6d4bb8            ReplicaSet   ✔ Healthy  4m    canary
│     ├──□ orders-7c9f6d4bb8-2xk9d   Pod          ✔ Running  4m    ready:1/1
│     └──□ orders-7c9f6d4bb8-9wq4p   Pod          ✔ Running  4m    ready:1/1
│  └──α orders-7c9f6d4bb8-2          AnalysisRun  ✔ Success  4m    ✔ 4
└──# revision:11
   └──⧉ orders-6b4d7c9f55            ReplicaSet   ✔ Healthy  6d    stable
```

E um canary falhando e se abortando:

```
$ kubectl argo rollouts status orders -n shop
Error: The rollout is in a degraded state with message: RolloutAborted: Rollout aborted update to revision 13

$ kubectl describe analysisrun orders-8f6c2a1dd9-4 -n shop | tail -12
Status:
  Phase:  Failed
  Metric Results:
    Name:   success-rate
    Phase:  Failed
    Measurements:
      Value:  0.9713   Phase: Failed
      Value:  0.9688   Phase: Failed
      Value:  0.9702   Phase: Failed
Events:
  Type     Reason         Age   From                 Message
  Warning  MetricFailed   90s   rollouts-controller  metric 'success-rate' failure limit exceeded (2)
```

---

## 8. Migrando e integrando um sistema legado monolítico

### 8.1 Registro de riscos

| Risco | Por que dói | Controle |
|---|---|---|
| Reescrita big-bang | Dois sistemas para manter, congelamento de funcionalidades por 18 meses, nenhum valor incremental | Strangler fig — incremental, sempre entregável |
| O banco compartilhado persiste | O serviço extraído ainda escreve nas tabelas do monólito ⇒ monólito distribuído | Um escritor por tabela; leitura via API ou eventos replicados |
| Garantias transacionais perdidas | Uma operação que era um único `COMMIT` agora abrange dois serviços | Saga + compensação, ou mantenha-a dentro de uma única fronteira |
| O modelo de domínio legado vaza | Os novos serviços herdam 15 anos de semântica acidental | Anti-corruption layer traduzindo na fronteira |
| Comportamento não documentado | Os bugs do monólito são estruturais para os consumidores downstream | Tráfego shadow / execução paralela e comparação das saídas |
| Sem testes | A refatoração é inverificável | Testes de caracterização: capture o comportamento atual antes de mudá-lo |
| Regressão de latência | Uma chamada em processo vira uma chamada de rede em um laço quente | Meça primeiro; engrosse a API; faça batching |
| Suposições com estado | Sessão em memória, escritas em arquivos locais, agendadores singleton | Externalize o estado antes de conteinerizar (§5) |
| Risco de cutover big-bang | Sem caminho de rollback | Execução dupla com uma feature flag; roteie uma % do tráfego; mantenha o caminho antigo aquecido |

### 8.2 O strangler fig, concretamente

Coloque uma fachada (ingress, API gateway, proxy reverso) na frente do monólito no primeiro dia. Ela inicialmente roteia 100 % para o monólito. Cada capacidade extraída vira uma nova rota.

```
            ┌───────────────┐
  client ──▶│  API gateway  │
            └───┬───────┬───┘
   /v2/orders   │       │   everything else
                ▼       ▼
        ┌─────────────┐  ┌────────────────────┐
        │   orders    │  │  legacy monolith   │
        │  (new svc)  │  │                    │
        └──────┬──────┘  └─────────┬──────────┘
               │                   │
               ▼                   ▼
        ┌─────────────┐  ┌────────────────────┐
        │ orders DB   │  │   legacy schema    │
        └─────────────┘  └────────────────────┘
                ▲                  │
                └── CDC / events ◀──┘  (one-way, during transition)
```

Roteamento no nível do ingress tornando a extração invisível para os clientes:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-facade
  namespace: shop
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  ingressClassName: nginx
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v2/orders
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  name: http
          - path: /
            pathType: Prefix
            backend:
              service:
                name: legacy-monolith
                port:
                  number: 8080
```

**Branch by abstraction** é o análogo em código quando a costura não é uma rota HTTP: introduza uma interface no monólito, implemente-a duas vezes (caminho legado e caminho de chamada remota), selecione em tempo de execução por feature flag, aumente gradualmente, depois apague a implementação legada. Isso mantém o trunk sempre liberável, que é o pré-requisito para entrega contínua.

---

## 9. Riscos de segurança de aplicações e mitigações

### 9.1 OWASP Top 10 (edição 2021) em um contexto cloud-native

> O OWASP Top 10 é revisado periodicamente; a edição de 2021 é a mais comumente referenciada pelos objetivos de exame e pelas ferramentas. Verifique `https://owasp.org/www-project-top-ten/` para a edição publicada atualmente antes de citar números de categoria em uma auditoria.

| ID | Categoria | Manifestação cloud-native | Mitigação que você pode implementar |
|---|---|---|---|
| A01 | Broken Access Control | IDOR (`GET /orders/{id}` sem verificação de propriedade); chamadas serviço-a-serviço confiadas porque "estão dentro do cluster" | Autorize em cada requisição contra o sujeito, não a localização de rede; negue por padrão; NetworkPolicy + mTLS como defesa em profundidade, nunca como o controle |
| A02 | Cryptographic Failures | TLS terminado no ingress e texto claro dentro do mesh; segredos no Git; backups não criptografados | TLS em todo lugar (mTLS dentro do mesh), criptografia em repouso, HSTS, nada de criptografia caseira |
| A03 | Injection | Injeção de SQL/NoSQL/comando/LDAP; injeção de template | Apenas consultas parametrizadas; nunca construa SQL por concatenação; valide/use allowlist na entrada; evite execução no estilo `shell=True` |
| A04 | Insecure Design | Sem modelagem de ameaças; sem rate limiting; consultas ilimitadas | Modele ameaças a cada nova fronteira; projete casos de abuso; cotas e limites como requisitos |
| A05 | Security Misconfiguration | `privileged: true`, contêineres root, endpoints de debug expostos, credenciais padrão, CORS permissivo | Pod Security Admission `restricted`; política de admissão em CI; varredura de configuração (`kubescape`, `trivy config`) |
| A06 | Vulnerable and Outdated Components | Uma imagem base com 180 CVEs; uma dependência transitiva com um RCE conhecido | SBOM por build, varredura em CI *e* continuamente no registry, atualizações de dependências automatizadas |
| A07 | Identification and Authentication Failures | Tokens de longa duração, sem MFA, `alg: none` aceito, fixação de sessão | Tokens de curta duração, validação estrita de JWT, rotação na mudança de privilégio, MFA para caminhos administrativos |
| A08 | Software and Data Integrity Failures | Imagens não assinadas, CI puxando `latest` de um registry não fixado, desserialização insegura | Assine artefatos (Sigstore/cosign), verifique assinaturas em um admission controller, fixe por digest, atestados de proveniência (SLSA) |
| A09 | Security Logging and Monitoring Failures | Falhas de autenticação não registradas; sem alerta em um pico de 401/403; logs sem IDs de correlação | Registre eventos de segurança de forma estruturada; alerte sobre anomalias; retenha conforme a política; nunca registre segredos ou tokens |
| A10 | Server-Side Request Forgery | Um serviço que busca uma URL fornecida pelo usuário alcança o endpoint de metadados da nuvem e rouba credenciais da instância | Use allowlist de destinos de saída; bloqueie o link-local `169.254.169.254` por NetworkPolicy; force IMDSv2; valide a URL após a resolução DNS |

### 9.2 Segredos: a resposta em camadas

| Camada | Prática | Antipadrão que substitui |
|---|---|---|
| Fonte | Segredos nunca no Git; varredura de pre-commit (`gitleaks`) | `config/prod.yaml` com uma senha |
| Build | Montagens de secret do BuildKit (`--mount=type=secret`) | `ARG TOKEN` — visível no histórico da imagem para sempre |
| Armazenamento | Gerenciador externo (Vault, cofre apoiado por KMS de nuvem), ou no mínimo criptografia do etcd em repouso | Base64 em um manifesto — base64 é codificação, não criptografia |
| Entrega | Arquivos montados, TTL curto, rotação automática (CSI Secrets Store / External Secrets Operator) | Um `Secret` criado à mão dois anos atrás |
| Runtime | Ler na inicialização ou na mudança do arquivo; nunca registrar em log; censurar nos handlers de erro | Imprimir a struct de configuração no boot |
| Rotação | Automatizada, testada, sem exigir redeploy | "Nós rotacionamos no desligamento de contas" |

```
$ gitleaks detect --source . --redact --no-banner
Finding:     DATABASE_URL="postgres://orders:REDACTED@db.internal:5432/orders"
Secret:      REDACTED
RuleID:      generic-api-key
File:        deploy/overlays/prod/env.properties
Line:        12
Commit:      8c41d0aa9f1e2b3c4d5e6f708192a3b4c5d6e7f8

1 leak found
```

### 9.3 Cadeia de suprimentos: SBOM, varredura, assinatura, verificação

```
$ syft registry.example.com/orders:2.3.0 -o spdx-json > sbom.spdx.json
 ✔ Parsed image      sha256:9f2c4d1b8ae0
 ✔ Cataloged contents
   ├── ✔ Packages           [37 packages]
   └── ✔ Executables        [1 executables]

$ grype sbom:sbom.spdx.json --fail-on high
NAME                  INSTALLED  FIXED-IN  TYPE    VULNERABILITY   SEVERITY
golang.org/x/net      v0.28.0    v0.33.0   go-mod  GHSA-w32m-9786  Medium
stdlib                go1.23.2   go1.23.5  go-mod  CVE-2024-45341  Medium

2 vulnerabilities found (0 critical, 0 high, 2 medium, 0 low)

$ cosign sign --yes registry.example.com/orders@sha256:9f2c4d1b8ae0...
tlog entry created with index: 148820417

$ cosign verify \
    --certificate-identity-regexp 'https://github.com/example/orders/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/orders@sha256:9f2c4d1b8ae0... | jq '.[0].optional.Subject'
Verification for registry.example.com/orders@sha256:9f2c4d1b8ae0... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
"https://github.com/example/orders/.github/workflows/release.yml@refs/tags/v2.3.0"
```

---

## 10. Automação de build e o pipeline de CI/CD

Ferramentas de automação de build (Maven, Gradle, npm/pnpm, Make, Bazel, Cargo, Go modules) existem para tornar o build **declarativo, reproduzível e ciente de dependências**. Sua contribuição operacional:

| Propriedade | Por que importa em produção |
|---|---|
| Dependências declaradas com um lockfile | O build é reproduzível seis meses depois e em outra máquina (fator II) |
| Resolução determinística de dependências | `npm ci` a partir do `package-lock.json`, não `npm install` — caso contrário CI e produção divergem |
| Um grafo de dependências | Builds incrementais; só o que mudou é reconstruído e retestado |
| Fases de ciclo de vida padronizadas | `compile → test → package → verify` é o mesmo verbo em todo repositório |
| Publicação de artefatos com coordenadas | Um artefato imutável e endereçável (GAV, semver + digest) é o que é promovido |

Um pipeline que impõe as regras de projeto acima, de ponta a ponta:

```yaml
name: release
on:
  push:
    tags:
      - "v*"

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Secret scan
        run: |
          docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
            detect --source /repo --redact --no-banner

      - name: Contract lint and breaking-change gate
        run: |
          npx @redocly/cli@latest lint openapi.yaml
          docker run --rm -v "$PWD:/w" -w /w tufin/oasdiff:latest \
            breaking "https://api.example.com/v2/openapi.yaml" openapi.yaml

      - name: Build, test and push
        id: build
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          IMAGE="registry.example.com/orders"
          docker buildx build \
            --build-arg "VERSION=${VERSION}" \
            --build-arg "COMMIT=${GITHUB_SHA::7}" \
            --target runtime \
            --provenance=true --sbom=true \
            --tag "${IMAGE}:${VERSION}" \
            --push .
          DIGEST=$(docker buildx imagetools inspect "${IMAGE}:${VERSION}" \
            --format '{{ "{{" }}.Manifest.Digest{{ "}}" }}')
          echo "ref=${IMAGE}@${DIGEST}" >> "$GITHUB_OUTPUT"

      - name: Vulnerability gate
        run: |
          docker run --rm aquasec/trivy:latest image \
            --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed \
            "${{ steps.build.outputs.ref }}"

      - name: Sign
        run: cosign sign --yes "${{ steps.build.outputs.ref }}"

      - name: Promote by digest
        run: |
          yq -i '.spec.template.spec.containers[0].image = strenv(REF)' \
            deploy/overlays/prod/deployment.yaml
        env:
          REF: ${{ steps.build.outputs.ref }}
```

Os princípios de projeto codificados aqui: construa uma vez e promova o **digest**; faça gate na compatibilidade de contrato antes que qualquer coisa chegue a um ambiente; falhe o build em segredos e em CVEs de alta severidade corrigíveis; e assine o artefato para que o cluster possa recusar qualquer coisa não assinada.

---

## 11. Verificação e diagnóstico de falhas

### 11.1 Escada de verificação pré-implantação

| Pergunta | Comando | Custo |
|---|---|---|
| O YAML é válido e correto quanto ao esquema? | `kubeconform -strict -summary -kubernetes-version 1.31.0 deploy/` | Grátis |
| Viola a política de segurança? | `trivy config deploy/` · `kubescape scan framework nsa deploy/` | Grátis |
| O contêiner roda como não-root com um root FS somente leitura? | `docker run --rm --read-only <img> id` | Grátis |
| O PID 1 trata SIGTERM? | `time docker stop <container>` (espere < 1 s) | Grátis |
| O contrato da API é retrocompatível? | `oasdiff breaking <old> <new>` | Grátis |
| As probes respondem corretamente? | `curl -sf localhost:8080/readyz` | Grátis |
| A aplicação inicia apenas com a configuração declarada? | `docker run --env-file env.prod.example <img>` | Grátis |
| Ela sobrevive a uma dependência fora do ar? | Caos: escale a dependência para 0, observe a taxa de erro e o fallback | Barato |

```
$ kubeconform -strict -summary -kubernetes-version 1.31.0 deploy/base/
Summary: 8 resources found parsing 8 files - Valid: 8, Invalid: 0, Errors: 0, Skipped: 0

$ trivy config --severity HIGH,CRITICAL deploy/base/
deploy/base/deployment.yaml (kubernetes)
Tests: 128 (SUCCESSES: 127, FAILURES: 1)
Failures: 1 (HIGH: 1, CRITICAL: 0)

HIGH: Container 'orders' of Deployment 'orders' should set 'resources.limits.cpu'
════════════════════════════════════════════════════════════════════════════════
Enforcing a CPU limit prevents DoS by a runaway container.
See https://avd.aquasec.com/misconfig/ksv011
```

*(Esse achado específico é um a ser sobrescrito deliberadamente — veja a §6.4 sobre throttling do CFS. Documente a exceção em vez de silenciar o scanner globalmente.)*

### 11.2 Catálogo de falhas

#### A. `CrashLoopBackOff` imediatamente após o deploy

```
$ kubectl get pods -n shop -l app.kubernetes.io/name=orders
NAME                      READY   STATUS             RESTARTS      AGE
orders-7c9f6d4bb8-2xk9d   0/1     CrashLoopBackOff   4 (38s ago)   2m14s

$ kubectl logs -n shop orders-7c9f6d4bb8-2xk9d --previous
{"ts":"2026-09-18T09:41:02.117Z","level":"fatal","event":"config_invalid","error":"required environment variable DATABASE_URL is not set"}

$ kubectl get deploy orders -n shop -o jsonpath='{.spec.template.spec.containers[0].envFrom}' | jq .
[
  {
    "configMapRef": {
      "name": "orders-config"
    }
  }
]
```

Causa raiz: a entrada `secretRef` foi descartada em um merge. **Valor diagnóstico do projeto:** a aplicação falha rápido e ruidosamente com configuração ausente no boot em vez de na primeira requisição — valide a configuração em `main()`, antes de vincular a porta.

#### B. Rolling update produz 502s

```
$ kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=5
10.244.2.9 - - [18/Sep/2026:09:52:11 +0000] "POST /v2/orders HTTP/2.0" 502 150 "-" 0.002 [shop-orders-http] 10.244.3.41:8080 - - 502

$ kubectl get events -n shop --sort-by=.lastTimestamp | tail -5
2m    Normal   Killing   pod/orders-6b4d7c9f55-kk29x   Stopping container orders
2m    Normal   Started   pod/orders-7c9f6d4bb8-2xk9d   Started container orders

$ kubectl get deploy orders -n shop -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
30
$ kubectl exec -n shop orders-7c9f6d4bb8-2xk9d -- sh -c 'echo $SHUTDOWN_TIMEOUT'
60s
```

Causa raiz: o timeout de desligamento da própria aplicação (60 s) excede o `terminationGracePeriodSeconds` (30 s), então o kubelet dá `SIGKILL` no meio do drain; e não há atraso `preStop`, então o listener fecha antes de o endpoint ser retirado de cada data plane. Corrija ambos: período de graça > preStop + timeout de shutdown, e adicione o drain preStop (§6.4).

#### C. "Funciona no `curl` mas não no navegador"

```
$ curl -s -o /dev/null -w '%{http_code}\n' https://api.example.com/v2/orders
200

$ curl -i -X OPTIONS https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type' | head -8
HTTP/2 401
www-authenticate: Bearer realm="api"
content-type: application/problem+json
```

Causa raiz: o middleware de autenticação roda antes do tratamento de CORS, então o preflight — que por projeto não carrega credenciais — é rejeitado com 401 e o navegador nunca emite a requisição real. O handler de `OPTIONS` deve ser registrado antes do middleware de autenticação. Segunda variante da mesma classe:

```
$ curl -sI https://api.example.com/v2/orders -H 'Origin: https://app.example.com' \
  | grep -i -E 'access-control|vary'
access-control-allow-origin: *
access-control-allow-credentials: true
```

Causa raiz: `*` com credenciais é rejeitado de imediato por todo navegador. Ecoe a origem validada e adicione `Vary: Origin`.

#### D. Perda de sessão após scale-in

```
$ kubectl get hpa orders -n shop
NAME     REFERENCE           TARGETS            MINPODS   MAXPODS   REPLICAS   AGE
orders   Deployment/orders   31%/65%, 4/25      4         40        4          19d

$ kubectl logs -n shop -l app.kubernetes.io/name=orders --tail=200 \
  | jq -r 'select(.event=="session_not_found") | .session_id' | wc -l
1184

$ kubectl exec -n shop orders-7c9f6d4bb8-2xk9d -- sh -c 'echo $SESSION_STORE'
memory
```

Causa raiz: violação do fator VI — estado de sessão na memória do processo. O HPA fez scale-in de 12 para 4 e despejou o equivalente a oito réplicas de sessões. Correção: externalize para um armazenamento compartilhado, ou mude para tokens assinados de curta duração (§5.2). Sessões sticky mascarariam o sintoma e mutilariam permanentemente a elasticidade.

#### E. `OOMKilled` sob carga

```
$ kubectl get pod orders-7c9f6d4bb8-9wq4p -n shop -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq .
{
  "exitCode": 137,
  "finishedAt": "2026-09-18T10:04:51Z",
  "reason": "OOMKilled",
  "startedAt": "2026-09-18T09:58:12Z"
}

$ kubectl top pod -n shop -l app.kubernetes.io/name=orders
NAME                      CPU(cores)   MEMORY(bytes)
orders-7c9f6d4bb8-2xk9d   243m         498Mi
orders-7c9f6d4bb8-9wq4p   251m         511Mi
```

Código de saída 137 = 128 + 9 (`SIGKILL`), motivo `OOMKilled`: o limite de memória do cgroup foi atingido. Distinga duas causas raiz antes de aumentar o limite — um vazamento genuíno (a memória cresce monotonicamente ao longo de horas independentemente da carga) versus um limite subdimensionado (a memória acompanha a taxa de requisições e estabiliza). Para um runtime com seu próprio GC, verifique também se o teto do heap é derivado do limite do cgroup (`GOMEMLIMIT`, `-XX:MaxRAMPercentage`); caso contrário o coletor nunca sente pressão e o kernel mata o processo antes.

#### F. `connection refused` intermitente para um serviço irmão

```
$ kubectl exec -n shop deploy/orders -- nslookup payments.shop.svc.cluster.local
;; connection timed out; no servers could be reached

$ kubectl get networkpolicy orders -n shop -o jsonpath='{.spec.egress[*].ports[*].port}'
8080 5432
```

Causa raiz: uma política de egresso default-deny sem uma permissão explícita para DNS (UDP/TCP 53 para o `kube-dns`). O sintoma não é "política negou" — é a resolução DNS dando timeout, o que aparece como erros de conexão com latência de vários segundos. Toda política de egresso default-deny precisa da regra de DNS mostrada na §6.4.

#### G. Retries em avalanche amplificam uma indisponibilidade parcial

```
$ kubectl logs -n shop -l app.kubernetes.io/name=payments --tail=3
{"level":"warn","event":"pool_exhausted","waiters":412,"max_conns":20}

$ curl -s "http://prometheus.monitoring.svc:9090/api/v1/query" \
    --data-urlencode 'query=sum(rate(http_client_requests_total{service="orders",upstream="payments"}[1m]))' \
  | jq -r '.data.result[0].value[1]'
3184.6
```

Causa raiz: amplificação de retry. Três retries sem jitter e sem orçamento transformaram uma oscilação de 1 000 rps no upstream em 3 000+ rps. Controles, em ordem de eficácia: um **orçamento de retry** (limite os retries a ~10 % do tráfego base), **backoff exponencial com full jitter**, um **circuit breaker** que falha rápido enquanto o upstream está insalubre, e **nunca faça retry de operações não idempotentes sem uma chave de idempotência**.

### 11.3 Uma auditoria twelve-factor que você pode rodar em qualquer serviço

```
$ kubectl get deploy orders -n shop -o yaml > /tmp/d.yaml

# III  — config from the environment, not baked in
$ yq '.spec.template.spec.containers[0].envFrom' /tmp/d.yaml
# VI   — no persistent volumes, no local state
$ yq '.spec.template.spec.volumes' /tmp/d.yaml
# VII  — port binding
$ yq '.spec.template.spec.containers[0].ports' /tmp/d.yaml
# IX   — disposability: grace period and preStop present
$ yq '.spec.template.spec | {"grace": .terminationGracePeriodSeconds, "preStop": .containers[0].lifecycle.preStop}' /tmp/d.yaml
# V    — immutable release: image pinned by digest
$ yq '.spec.template.spec.containers[0].image' /tmp/d.yaml | grep -q '@sha256:' \
    && echo "pinned by digest" || echo "MUTABLE TAG — not a reproducible release"
# XI   — logs go to stdout only
$ kubectl exec -n shop deploy/orders -- ls -l /proc/1/fd/1 /proc/1/fd/2
```

```
pinned by digest
l-wx------ 1 65532 65532 64 Sep 18 10:11 /proc/1/fd/1 -> pipe:[418822]
l-wx------ 1 65532 65532 64 Sep 18 10:11 /proc/1/fd/2 -> pipe:[418823]
```

---

## 12. Resumo focado no exame

- **Acoplamento fraco** é o objetivo; microsserviços são um meio. Um serviço que compartilha uma tabela de banco com outro serviço não tem acoplamento fraco.
- **SOA** coloca a orquestração no barramento; **microsserviços** a colocam nos endpoints e mantêm os canos burros.
- **Restrições REST** que importam: ausência de estado, interface uniforme, cacheabilidade. GET/PUT/DELETE são idempotentes; **POST não é**.
- **JSON**: UTF-8, sem comentários, datas RFC 3339, dinheiro em unidades menores inteiras.
- **CORS** é imposto pelo navegador e relaxa a política de mesma origem; `Content-Type: application/json` sempre dispara um preflight `OPTIONS`; `Allow-Origin: *` é incompatível com `Allow-Credentials: true`; sempre envie `Vary: Origin`.
- **Twelve-factor**: configuração no ambiente, processos sem estado, logs para stdout, inicialização rápida e desligamento gracioso, separação estrita de build/release/run.
- **Contêineres**: uma preocupação, não-root, rootfs somente leitura, PID 1 trata `SIGTERM`, `CMD` em forma exec, fixado por digest, sem segredos nas camadas.
- **Probes**: liveness reinicia e não deve testar dependências; readiness controla o tráfego e deve falhar no desligamento; startup cobre inicialização lenta.
- **O estado** vive em serviços de apoio (fator IV), acoplados por URL; sessões sticky são uma muleta legada que bloqueia a elasticidade.
- **IaaS/PaaS/SaaS**: quem aplica patches no SO é a pergunta que distingue. **AZ** protege contra um datacenter; **região** contra uma geografia.
- **Servidores imutáveis**: substituir, nunca corrigir. Rollback é reimplantar o digest anterior.
- **Blue-green** precisa de capacidade dobrada e dá um chaveamento instantâneo; **canary** aumenta gradualmente o tráfego real e detecta problemas com sinais de produção. Ambos precisam de esquemas retrocompatíveis (expand–contract).
- **Migração de legado**: strangler fig atrás de uma fachada, anti-corruption layer na fronteira, testes de caracterização primeiro, nunca uma reescrita big-bang.
- **Segurança**: OWASP Top 10 como taxonomia de risco; segredos nunca no Git nem em camadas de imagem; assine e verifique artefatos; SSRF alcança o endpoint de metadados a menos que você o bloqueie.

---

## 13. Referências

**Objetivos oficiais do exame**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, 701-100): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Arquitetura e metodologia**
- The Twelve-Factor App: https://12factor.net/
- Fielding, R. T., *Architectural Styles and the Design of Network-based Software Architectures*, Cap. 5 (REST): https://ics.uci.edu/~fielding/pubs/dissertation/rest_arch_style.htm
- CNCF Cloud Native Definition v1.1: https://github.com/cncf/toc/blob/main/DEFINITION.md
- CNCF Cloud Native Landscape: https://landscape.cncf.io/
- NIST SP 800-145, *The NIST Definition of Cloud Computing* (IaaS/PaaS/SaaS): https://csrc.nist.gov/pubs/sp/800/145/final
- NIST SP 800-190, *Application Container Security Guide*: https://csrc.nist.gov/pubs/sp/800/190/final

**APIs e padrões web**
- RFC 9110 — HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110.html
- RFC 8259 — The JavaScript Object Notation (JSON) Data Interchange Format: https://www.rfc-editor.org/rfc/rfc8259.html
- RFC 9457 — Problem Details for HTTP APIs: https://www.rfc-editor.org/rfc/rfc9457.html
- RFC 3339 — Date and Time on the Internet: https://www.rfc-editor.org/rfc/rfc3339.html
- RFC 7396 — JSON Merge Patch: https://www.rfc-editor.org/rfc/rfc7396.html
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://www.rfc-editor.org/rfc/rfc6902.html
- RFC 7519 — JSON Web Token (JWT): https://www.rfc-editor.org/rfc/rfc7519.html
- WHATWG Fetch Standard (protocolo CORS): https://fetch.spec.whatwg.org/#http-cors-protocol
- MDN — Cross-Origin Resource Sharing (CORS): https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
- MDN — Same-origin policy: https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy
- OpenAPI Specification 3.1.0: https://spec.openapis.org/oas/v3.1.0.html
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- gRPC documentation: https://grpc.io/docs/
- GraphQL specification: https://spec.graphql.org/

**Contêineres e orquestração**
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Runtime Specification: https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- Dockerfile reference: https://docs.docker.com/reference/dockerfile/
- Docker — Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Docker — Build secrets: https://docs.docker.com/build/building/secrets/
- Kubernetes — Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Lifecycle (termination): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Configure a Pod to Use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- Kubernetes — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Argo Rollouts — Canary strategy: https://argo-rollouts.readthedocs.io/en/stable/features/canary/
- Argo Rollouts — Analysis and progressive delivery: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/

**Segurança e cadeia de suprimentos**
- OWASP Top 10: https://owasp.org/www-project-top-ten/
- OWASP Application Security Verification Standard (ASVS): https://owasp.org/www-project-application-security-verification-standard/
- OWASP Cheat Sheet Series: https://cheatsheetseries.owasp.org/
- OWASP Kubernetes Top Ten: https://owasp.org/www-project-kubernetes-top-ten/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/spec/v1.0/
- Sigstore / cosign documentation: https://docs.sigstore.dev/
- SPDX specification: https://spdx.dev/use/specifications/
- CycloneDX specification: https://cyclonedx.org/specification/overview/

**Infraestrutura como código e automação de build**
- Terraform documentation: https://developer.hashicorp.com/terraform/docs
- HashiCorp Packer documentation: https://developer.hashicorp.com/packer/docs
- Apache Maven — Build lifecycle reference: https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html
- Gradle user manual: https://docs.gradle.org/current/userguide/userguide.html
- npm CLI — `npm ci`: https://docs.npmjs.com/cli/v10/commands/npm-ci
- GitHub Actions documentation: https://docs.github.com/en/actions
- GitLab CI/CD documentation: https://docs.gitlab.com/ee/ci/