# 4.4 Your Computer on the Network

## Introdução

Depois de entender os fundamentos de como a internet funciona (tópico 4.1), o próximo passo é saber como o **seu próprio computador** se enxerga e se apresenta dentro de uma rede local. Isso envolve saber identificar a interface de rede, o *hostname* da máquina, como o sistema resolve nomes para endereços IP (e vice-versa) e quais ferramentas de linha de comando usar para diagnosticar problemas básicos de conectividade.

Este tópico tem peso 2 no exame 010-160 (v1.6) e cobra conhecimento prático de arquivos de configuração e comandos, não teoria profunda de protocolos.

## 1. Identificando a interface de rede

Toda máquina Linux conectada a uma rede possui uma ou mais **interfaces de rede** (`eth0`, `enp0s3`, `wlan0`, `lo`, etc.). O comando moderno para consultá-las é `ip`, do pacote `iproute2` — o antigo `ifconfig` (`net-tools`) ainda aparece em provas e em sistemas legados, mas está deprecated na maioria das distribuições atuais.

```bash
$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:4a:3c:9e brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.42/24 brd 192.168.1.255 scope global dynamic enp0s3
       valid_lft 3542sec preferred_lft 3542sec
```

Pontos-chave desse output:

- `lo` é a interface **loopback** (`127.0.0.1`), sempre presente e usada para comunicação interna da própria máquina.
- `enp0s3` mostra o endereço `inet 192.168.1.42/24` (endereço IPv4 + máscara em notação CIDR) e a flag `dynamic`, indicando que o endereço foi obtido via **DHCP**.
- `UP` indica que a interface está ativa.

Comando equivalente, mais resumido:

```bash
$ ip -br addr
lo               UNKNOWN        127.0.0.1/8
enp0s3           UP             192.168.1.42/24
```

## 2. O hostname da máquina

O **hostname** é o nome pelo qual a máquina se identifica na rede. Existem três formas comuns de consultá-lo/defini-lo:

```bash
$ hostname
workstation01

$ cat /etc/hostname
workstation01
```

Em distribuições baseadas em `systemd`, a ferramenta recomendada é `hostnamectl`, que também mostra informações extras (kernel, arquitetura, virtualização):

```bash
$ hostnamectl
   Static hostname: workstation01
         Icon name: computer-vm
           Chassis: vm
        Machine ID: 8f3a9c1e2b4d4f8e9a1b2c3d4e5f6a7b
           Boot ID: 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d
    Virtualization: kvm
  Operating System: Debian GNU/Linux 12 (bookworm)
            Kernel: Linux 6.1.0-18-amd64
      Architecture: x86-64
```

Para alterar o hostname (requer privilégio de root):

```bash
# hostnamectl set-hostname novoservidor
```

## 3. Resolução de nomes local: `/etc/hosts`

Antes de consultar um servidor DNS externo, o Linux pode resolver nomes usando um arquivo estático local: `/etc/hosts`. Ele mapeia nomes de host para endereços IP, sendo útil em redes pequenas, para testes locais ou para forçar a resolução de um domínio sem depender do DNS.

```
$ cat /etc/hosts
127.0.0.1       localhost
127.0.1.1       workstation01
192.168.1.10    fileserver.local  fileserver
::1             localhost ip6-localhost ip6-loopback
```

Cada linha tem o formato: `<endereço IP> <hostname canônico> [aliases...]`. Note que a última linha mostra um endereço **IPv6** (`::1`), o equivalente ao loopback IPv4.

Um uso prático comum é adicionar entradas temporárias para testar um site antes de ele estar publicado no DNS público:

```
203.0.113.50    meusite.exemplo.com
```

## 4. Resolução de nomes via DNS: `/etc/resolv.conf`

Quando o nome não está em `/etc/hosts`, o sistema consulta um servidor **DNS**. Os servidores usados e o domínio de busca padrão ficam definidos em `/etc/resolv.conf`:

```
$ cat /etc/resolv.conf
search local
nameserver 192.168.1.1
nameserver 8.8.8.8
```

- `nameserver` — endereço IP de um servidor DNS a ser consultado (podem existir vários, em ordem de prioridade).
- `search` — domínio(s) anexado(s) automaticamente a nomes incompletos (ex.: `ping fileserver` tentaria `fileserver.local`).

> **Atenção:** em distribuições que usam `NetworkManager` ou `systemd-resolved`, esse arquivo costuma ser gerado/sobrescrito automaticamente (às vezes é até um symlink para `/run/systemd/resolve/stub-resolv.conf`). Editá-lo manualmente em sistemas assim pode não ter efeito permanente — mas para o exame, o importante é saber **o que o arquivo faz e sua sintaxe**.

## 5. Ordem de resolução: `/etc/nsswitch.conf`

O arquivo `/etc/nsswitch.conf` (*Name Service Switch*) define, para vários serviços do sistema, **em que ordem** as fontes de informação devem ser consultadas. A linha relevante para nomes de host é `hosts`:

```
$ grep hosts /etc/nsswitch.conf
hosts:          files dns
```

Isso significa: primeiro consulte `/etc/hosts` (`files`), depois o `dns`. Se a ordem fosse invertida (`dns files`), o sistema consultaria o DNS antes do arquivo local.

## 6. Configuração de endereço: DHCP vs. estática

Um computador pode obter seu endereço IP de duas formas:

| Método | Como funciona | Onde se vê |
|---|---|---|
| **DHCP** (*Dynamic Host Configuration Protocol*) | Um servidor DHCP na rede atribui automaticamente IP, máscara, gateway e DNS | flag `dynamic` no `ip addr`; gerenciado por `NetworkManager`, `dhclient` ou `systemd-networkd` |
| **Estática** | O endereço é definido manualmente pelo administrador em um arquivo de configuração | sem a flag `dynamic`; configuração fixa em arquivos como `/etc/network/interfaces` (Debian) ou via `nmcli`/`netplan` |

Exemplo de definição de IP estático com `ip` (efeito temporário, até reboot):

```bash
# ip addr add 192.168.1.100/24 dev enp0s3
# ip route add default via 192.168.1.1
```

## 7. Testando conectividade e resolução

### `ping` — testar se um host responde

```bash
$ ping -c 3 fileserver.local
PING fileserver.local (192.168.1.10) 56(84) bytes of data.
64 bytes from fileserver.local (192.168.1.10): icmp_seq=1 ttl=64 time=0.412 ms
64 bytes from fileserver.local (192.168.1.10): icmp_seq=2 ttl=64 time=0.389 ms
64 bytes from fileserver.local (192.168.1.10): icmp_seq=3 ttl=64 time=0.401 ms

--- fileserver.local ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2038ms
```

A opção `-c 3` limita a três pacotes (sem ela, o `ping` roda indefinidamente até `Ctrl+C`).

### `host` e `dig` — consultar o DNS diretamente

```bash
$ host www.lpi.org
www.lpi.org has address 192.0.2.44

$ dig www.lpi.org +short
192.0.2.44
```

`dig` é mais completo e mostra detalhes da resposta DNS (TTL, tipo de registro, servidor consultado), enquanto `host` é mais direto e legível.

### `traceroute` — ver o caminho até o destino

```bash
$ traceroute lpi.org
traceroute to lpi.org (192.0.2.44), 30 hops max, 60 byte packets
 1  192.168.1.1 (192.168.1.1)  1.203 ms  1.150 ms  1.098 ms
 2  10.20.0.1 (10.20.0.1)  8.442 ms  8.390 ms  8.355 ms
 3  ...
```

Cada linha representa um **hop** (roteador) atravessado até o destino, útil para localizar onde uma conexão está lenta ou falhando.

### `netstat` / `ss` — ver conexões e portas ativas

```bash
$ ss -tulpn
Netid State  Local Address:Port   Peer Address:Port  Process
tcp   LISTEN 0.0.0.0:22           0.0.0.0:*          users:(("sshd",pid=812,fd=3))
tcp   LISTEN 127.0.0.1:631        0.0.0.0:*          users:(("cupsd",pid=930,fd=6))
```

`ss` é o substituto moderno do `netstat` (que também pode aparecer no exame): `-t` (TCP), `-u` (UDP), `-l` (listening), `-p` (processo), `-n` (não resolver nomes).

## Resumo dos arquivos e comandos deste tópico

| Item | Função |
|---|---|
| `/etc/hostname` | Nome fixo da máquina |
| `/etc/hosts` | Resolução estática de nomes para IP |
| `/etc/resolv.conf` | Servidores DNS e domínio de busca |
| `/etc/nsswitch.conf` | Ordem de consulta para resolução de nomes |
| `ip addr` / `ifconfig` | Mostrar/configurar interfaces e endereços |
| `hostname` / `hostnamectl` | Consultar/definir o hostname |
| `ping` | Testar alcance de um host |
| `host` / `dig` / `nslookup` | Consultar registros DNS |
| `traceroute` | Mostrar o caminho de rede até um destino |
| `netstat` / `ss` | Listar conexões e portas em uso |

## Referências

- LPI Learning Materials — 4.4 Your Computer on the Network: https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- `man hosts` — formato do arquivo `/etc/hosts`: https://man7.org/linux/man-pages/man5/hosts.5.html
- `man resolv.conf`: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `man nsswitch.conf`: https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `man ip`: https://man7.org/linux/man-pages/man8/ip.8.html
- `man ss`: https://man7.org/linux/man-pages/man8/ss.8.html
- `man dig`: https://man7.org/linux/man-pages/man1/dig.1.html
- `man hostnamectl`: https://man7.org/linux/man-pages/man1/hostnamectl.1.html