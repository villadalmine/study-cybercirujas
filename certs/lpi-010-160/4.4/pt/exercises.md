# LPI Linux Essentials (010-160) — Tópico 4.4: Your Computer on the Network

> Exercícios guiados sobre configuração de rede em Linux: interfaces, IP addresses, routing, DNS e diagnóstico de conectividade.

---

## Exercício 1 — Identificando as network interfaces

1. Abra um terminal e liste todas as interfaces de rede disponíveis:
   ```
   ip link show
   ```
2. Observe o estado de cada interface (`UP` ou `DOWN`) e o nome (`lo`, `eth0`, `enp0s3`, `wlan0`, etc.).
3. Agora liste os endereços IP atribuídos a cada interface:
   ```
   ip addr show
   ```
4. Localize a interface `lo` (loopback) e anote o IP address associado a ela.

**Perguntas de verificação:**
- Qual é o IP address padrão da interface `lo`, e por que ela nunca aparece como `DOWN` em condições normais?
- Qual a diferença prática entre usar `ip addr` e o comando legado `ifconfig`?

---

## Exercício 2 — Endereço IP, netmask e default gateway

1. No output do Exercício 1, identifique uma interface conectada à rede (não `lo`) e anote seu IP address no formato CIDR (ex: `192.168.1.20/24`).
2. Calcule mentalmente a subnet mask correspondente ao prefixo `/24` (dica: quantos bits ficam em 1?).
3. Liste a routing table do sistema:
   ```
   ip route show
   ```
4. Identifique a linha que começa com `default via` — esse é o default gateway.

**Perguntas de verificação:**
- O que representa o default gateway e o que acontece se um pacote for destinado a um IP fora da subnet local?
- Se a interface tem `/24`, quantos hosts podem, em teoria, existir nessa subnet (incluindo network e broadcast address)?

---

## Exercício 3 — DHCP versus static IP configuration

1. Verifique se a interface de rede está usando DHCP consultando o gerenciador de conexões (em distribuições com NetworkManager):
   ```
   nmcli device show <interface>
   ```
2. Procure pelo campo `IP4.ADDRESS` e compare com o campo de configuração do método (`DHCP` ou `manual`).
3. Reflita: se você precisasse configurar um IP address fixo manualmente (sem DHCP), quais informações mínimas seriam necessárias? (IP address, netmask, gateway, DNS server)

**Perguntas de verificação:**
- Qual a principal vantagem de usar DHCP em vez de static IP em uma rede doméstica ou de escritório?
- Em que cenário faz mais sentido usar static IP (dê um exemplo prático, como um servidor)?

---

## Exercício 4 — DNS resolution

1. Verifique quais DNS servers seu sistema está usando:
   ```
   cat /etc/resolv.conf
   ```
   (Em sistemas com `systemd-resolved`, use `resolvectl status` como alternativa.)
2. Resolva um hostname para IP address usando o comando `host`:
   ```
   host www.lpi.org
   ```
3. Faça o mesmo com `dig`, observando a seção `ANSWER`:
   ```
   dig www.lpi.org
   ```
4. Consulte o arquivo local de resolução de nomes:
   ```
   cat /etc/hosts
   ```

**Perguntas de verificação:**
- Qual arquivo é consultado antes do DNS ser contatado, segundo a ordem definida em `/etc/nsswitch.conf`?
- Se você adicionasse a linha `127.0.0.1 meusite.local` em `/etc/hosts`, o que aconteceria ao digitar `ping meusite.local`?

---

## Exercício 5 — Testando conectividade

1. Teste a conectividade com o default gateway (use o IP anotado no Exercício 2):
   ```
   ping -c 4 <ip-do-gateway>
   ```
2. Teste a conectividade com um host externo:
   ```
   ping -c 4 www.lpi.org
   ```
3. Trace o caminho que os pacotes percorrem até um destino externo:
   ```
   traceroute www.lpi.org
   ```
   (ou `tracepath www.lpi.org` se `traceroute` não estiver instalado)
4. Compare o número de *hops* (saltos) até o gateway local e até o destino externo.

**Perguntas de verificação:**
- Se o `ping` para o gateway funciona mas o `ping` para `www.lpi.org` falha, em que camada da comunicação (local vs. resolução/roteamento externo) está o problema?
- Qual protocolo o `ping` utiliza para enviar suas mensagens?

---

## Exercício 6 — Ports e serviços de rede

1. Liste as portas TCP e UDP em estado de escuta (*listening*) no sistema:
   ```
   ss -tuln
   ```
2. Identifique ao menos uma porta bem conhecida (*well-known port*) na saída, como `22` (SSH) ou `80` (HTTP).
3. Consulte a tabela de correspondência entre nomes de serviços e números de porta:
   ```
   less /etc/services
   ```

**Perguntas de verificação:**
- Qual a diferença fundamental entre TCP e UDP em termos de confiabilidade de entrega?
- Por que a porta 22 costuma aparecer associada ao serviço SSH, e o que isso tem a ver com o conceito de *well-known ports* (0–1023)?

---

## Referências

- LPI Learning Materials — Topic 4.4: Your Computer on the Network — https://learning.lpi.org/en/learning-materials/010-160/4/4.4/

---

<details>
<summary>Respostas</summary>

**Exercício 1**
- O IP address padrão da interface `lo` é `127.0.0.1/8` (IPv4) e `::1/128` (IPv6). Ela representa a própria máquina (loopback) e permanece `UP` porque não depende de nenhum hardware físico — é uma interface puramente de software usada para comunicação interna entre processos.
- `ip addr`/`ip link` fazem parte do pacote `iproute2`, são a ferramenta moderna e ativamente mantida, mostram mais informações (como múltiplos IPs por interface) e são o padrão em distribuições atuais. `ifconfig` vem do pacote `net-tools`, está obsoleto (*deprecated*) e pode nem estar instalado por padrão.

**Exercício 2**
- O default gateway é o roteador (*router*) para onde o sistema envia todo o tráfego destinado a IPs fora da sua subnet local. Sem ele, pacotes para redes externas simplesmente não têm para onde ir e são descartados.
- Com `/24`, existem 256 endereços no total (2^8), dos quais 254 são utilizáveis por hosts — o primeiro é reservado como network address e o último como broadcast address.

**Exercício 3**
- DHCP evita configuração manual em cada máquina, reduz erros humanos (como IPs duplicados) e facilita a administração de redes com muitos dispositivos, atribuindo endereços automaticamente a partir de um pool.
- Static IP faz sentido em servidores, impressoras de rede ou qualquer serviço que precise de um endereço previsível e estável, já que clientes (DNS, firewalls, outros serviços) dependem de sempre encontrá-lo no mesmo IP.

**Exercício 4**
- O arquivo `/etc/hosts` é consultado antes do DNS (na ordem típica definida em `/etc/nsswitch.conf`, geralmente `files` vem antes de `dns`).
- O comando `ping meusite.local` resolveria o hostname para `127.0.0.1` localmente, sem nunca consultar um DNS server externo, e faria ping na própria máquina.

**Exercício 5**
- O problema estaria na resolução de nomes (DNS) ou no roteamento além do gateway local — ou seja, fora da rede local —, já que a conectividade dentro da LAN está funcionando normalmente.
- O `ping` utiliza o protocolo ICMP (Internet Control Message Protocol), especificamente mensagens do tipo *echo request*/*echo reply*.

**Exercício 6**
- TCP é orientado a conexão (*connection-oriented*) e garante entrega confiável e ordenada dos dados, com confirmação (*acknowledgment*) e retransmissão. UDP é *connectionless*, mais rápido, mas não garante entrega, ordem ou ausência de duplicação.
- A porta 22 é reservada pela IANA como well-known port padrão para SSH. As portas 0–1023 são reservadas para serviços de sistema amplamente reconhecidos, permitindo que clientes se conectem a esses serviços sem precisar negociar previamente qual porta usar.

</details>