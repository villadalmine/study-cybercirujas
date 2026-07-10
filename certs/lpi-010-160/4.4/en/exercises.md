# Guided Exercises — Topic 4.4: Your Computer on the Network

**Certification:** LPI Linux Essentials (010-160, version 1.6) — Exam weight: 2
**Reference:** [LPI Learning Materials, Lesson 4.4](https://learning.lpi.org/en/learning-materials/010-160/4/4.4/)

Work through each block on a Linux machine with an internet connection (a VM or container is fine). You need the `iproute2` package (`ip`, `ss`) and the DNS client utilities from `bind-utils` / `dnsutils` (`host`, `dig`). Every command here only *queries* the system — nothing changes your network configuration.

---

## Exercise 1 — Network Interfaces and IP Addresses

A computer joins a network through a **network interface**. Each active interface normally carries at least one **IPv4** address and, on modern systems, one or more **IPv6** addresses.

**Steps:**

1. List every network interface the kernel knows about:

   ```bash
   ip link show
   ```

   Note the interface names. One is always `lo`; the others depend on your hardware (`eth0`, `enp1s0`, `wlan0`, `wlp2s0`, …).

2. Show the addresses assigned to each interface:

   ```bash
   ip addr show
   ```

   Look for lines starting with `inet` (IPv4) and `inet6` (IPv6).

3. Query only the loopback interface:

   ```bash
   ip addr show lo
   ```

4. Write down the IPv4 address of your main interface, including the prefix length (for example `192.168.1.42/24`). You will use it in Exercise 2.

5. If your system has the legacy tool installed, compare the output of the older command:

   ```bash
   ifconfig 2>/dev/null || echo "ifconfig not installed - ip addr is the modern replacement"
   ```

**Questions:**

**1.1** What is the purpose of the `lo` (loopback) interface, and which IPv4 and IPv6 addresses does it always have?

**1.2** In step 4 you noted something like `192.168.1.42/24`. What does the `/24` part mean?

**1.3** An IPv4 address is 32 bits long. How large is an IPv6 address, and what problem with IPv4 does IPv6 solve?

---

## Exercise 2 — The Routing Table and the Default Gateway

Your machine can reach hosts on its own network directly. To reach everything else — including the internet — it hands packets to a **router**, listed in the routing table as the **default gateway**.

**Steps:**

1. Display the IPv4 routing table:

   ```bash
   ip route show
   ```

   Identify the line beginning with `default via …`. The address after `via` is your default gateway; the name after `dev` is the interface used to reach it.

2. Display the IPv6 routing table as well:

   ```bash
   ip -6 route show
   ```

3. If installed, compare with the legacy command:

   ```bash
   route -n 2>/dev/null || echo "route not installed - ip route is the modern replacement"
   ```

4. Verify that the gateway answers:

   ```bash
   ping -c 3 <gateway-address>
   ```

   (Replace `<gateway-address>` with the address you found in step 1.)

5. Now verify that you can reach a host *beyond* your own network:

   ```bash
   ping -c 3 8.8.8.8
   ```

**Questions:**

**2.1** In your own words: what decision does the routing table let the kernel make for every outgoing packet?

**2.2** In step 1, besides the `default` line, you saw at least one route like `192.168.1.0/24 dev … scope link`. Why does traffic to those addresses *not* go through the gateway?

**2.3** Step 5 pinged `8.8.8.8` directly by IP address. Which network service did that test deliberately *avoid* using, and why is that a useful troubleshooting trick?

---

## Exercise 3 — DNS: From Names to Addresses

Humans use names like `www.lpi.org`; the network uses IP addresses. The **Domain Name System (DNS)** translates between them, and your machine must know which **DNS server** to ask.

**Steps:**

1. Check which DNS server(s) your system is configured to use:

   ```bash
   cat /etc/resolv.conf
   ```

   Look for `nameserver` lines. On systems running `systemd-resolved` you may see `127.0.0.53`; in that case also run `resolvectl status | head -20` to see the real upstream servers.

2. Resolve a name with `host`:

   ```bash
   host learning.lpi.org
   ```

3. Get more detail with `dig`:

   ```bash
   dig learning.lpi.org
   ```

   In the output, find the `ANSWER SECTION` and the `SERVER:` line near the bottom.

4. Do a reverse lookup — ask which name belongs to an IP address:

   ```bash
   host 8.8.8.8
   ```

5. Before asking any DNS server, the resolver checks a local file. Inspect it:

   ```bash
   cat /etc/hosts
   ```

6. Confirm that names in `/etc/hosts` resolve without DNS:

   ```bash
   ping -c 1 localhost
   ```

**Questions:**

**3.1** What is the role of the `nameserver` entries in `/etc/resolv.conf`?

**3.2** In step 3, what does the `SERVER:` line at the bottom of the `dig` output tell you, and where did that address come from?

**3.3** If the same hostname appears in `/etc/hosts` *and* in DNS with different addresses, which answer does your system normally use, and why?

**3.4** A colleague can `ping 8.8.8.8` successfully but `ping www.lpi.org` fails with "Name or service not known". Which part of the network configuration is broken?

---

## Exercise 4 — Who Is Talking? Sockets and Ports

Servers listen on **ports**; clients connect to them. The `ss` command (successor of `netstat`) shows the **sockets** currently open on your machine.

**Steps:**

1. List all listening TCP sockets, with numeric ports and the owning process (the process column needs root):

   ```bash
   sudo ss -tlnp
   ```

   Column `Local Address:Port` shows where each service is listening.

2. List listening UDP sockets too:

   ```bash
   ss -uln
   ```

3. Open a connection and watch it appear. In one terminal, fetch a web page (or just keep an SSH session open); in another, list *established* connections:

   ```bash
   ss -tn state established
   ```

4. If installed, compare with the legacy command:

   ```bash
   netstat -tln 2>/dev/null || echo "netstat not installed - ss is the modern replacement"
   ```

**Questions:**

**4.1** In step 1, what is the difference between a socket listening on `127.0.0.1:PORT` and one listening on `0.0.0.0:PORT`?

**4.2** Every established connection in step 3 shows *two* address:port pairs. What does each pair identify, and why are both needed?

**4.3** TCP and UDP both use port numbers. Name one practical difference between the two protocols.

---

## Exercise 5 — Putting It Together: A Connectivity Checklist

When "the internet doesn't work", these four questions — asked in order — locate the failure. Run the whole sequence on your machine.

**Steps:**

1. **Do I have an address?**

   ```bash
   ip addr show
   ```

2. **Can I reach my router?**

   ```bash
   ip route show
   ping -c 3 <gateway-address>
   ```

3. **Can I reach the internet by IP?**

   ```bash
   ping -c 3 8.8.8.8
   ```

4. **Does name resolution work?**

   ```bash
   host www.lpi.org
   ping -c 3 www.lpi.org
   ```

**Questions:**

**5.1** Step 1 succeeds but step 2 fails (the gateway does not answer). Where is the problem most likely located?

**5.2** Steps 1–3 succeed but step 4 fails. Which configuration file would you inspect first, and what would you look for?

**5.3** Why is it important to run these checks *in this order* rather than starting with `ping www.lpi.org`?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1** The loopback interface is a virtual interface the machine uses to talk to *itself* — network services on the same host can communicate through it without any physical network. It always has the IPv4 address `127.0.0.1` (network `127.0.0.0/8`) and the IPv6 address `::1`.

**1.2** The `/24` is the **prefix length** (CIDR notation): the first 24 bits of the address identify the *network*, the remaining 8 bits identify the *host*. So `192.168.1.42/24` belongs to network `192.168.1.0/24`, and any address from `192.168.1.1` to `192.168.1.254` is on the same local network.

**1.3** An IPv6 address is 128 bits long (written as eight groups of hexadecimal digits, e.g. `2001:db8::1`). It solves IPv4 **address exhaustion**: 32 bits allow only about 4.3 billion addresses, far too few for every device on the internet, while 128 bits provide a practically unlimited supply.

### Exercise 2

**2.1** For each outgoing packet, the routing table lets the kernel decide *where to send it next*: directly to the destination if it is on a locally connected network, or to a router (gateway) that will forward it further. The `default` route is the catch-all used when no more specific route matches.

**2.2** A route with `scope link` means those addresses are on the same local network segment as the interface itself. The machine can deliver those packets directly (using the link layer), so no router is needed. The gateway is only used for destinations *outside* the local network.

**2.3** It avoided **DNS**. By pinging a raw IP address, the test checks pure IP connectivity to the internet without depending on name resolution. If `ping 8.8.8.8` works but `ping www.example.com` fails, you know routing is fine and the problem is DNS — this separation is the core of network troubleshooting.

### Exercise 3

**3.1** Each `nameserver` line gives the IP address of a DNS server the local resolver will send its queries to. Whenever a program needs to turn a hostname into an IP address (and the answer is not in `/etc/hosts`), the query goes to one of these servers.

**3.2** The `SERVER:` line shows which DNS server actually answered the query, and on which port (normally 53). By default `dig` uses the first `nameserver` listed in `/etc/resolv.conf` — so this line confirms which configured server was consulted. (On `systemd-resolved` systems it shows the local stub `127.0.0.53`.)

**3.3** The `/etc/hosts` entry wins. The standard resolution order (configured in `/etc/nsswitch.conf`) checks local files *before* DNS, so a matching line in `/etc/hosts` short-circuits the DNS query entirely. This is handy for testing and for small networks, but a stale entry there can also cause confusing "wrong address" problems.

**3.4** Name resolution (DNS) is broken while IP connectivity works. The likely culprits: no reachable `nameserver` in `/etc/resolv.conf`, a wrong DNS server address, or the DNS server itself being down. Routing, addressing, and the gateway are all fine, since raw IP traffic gets through.

### Exercise 4

**4.1** A socket bound to `127.0.0.1:PORT` accepts connections only from the same machine (via loopback) — it is invisible to the network. A socket bound to `0.0.0.0:PORT` listens on *all* interfaces, so any host that can reach the machine may connect. The distinction matters for security: services that don't need remote access should bind to loopback only.

**4.2** One pair is the **local** address and port, the other is the **peer** (remote) address and port. Together the four values uniquely identify the connection: they tell the kernel which machine and which application on each end the traffic belongs to. Both are needed because one server port (e.g. 443) serves many simultaneous clients, distinguished by their remote address:port.

**4.3** TCP is connection-oriented and **reliable**: it establishes a connection, acknowledges data, retransmits lost segments, and preserves order — used by HTTP(S), SSH, email. UDP is connectionless and **unreliable but fast/lightweight**: packets are sent without guarantees — used by DNS queries, streaming, and other cases where low overhead matters more than delivery guarantees.

### Exercise 5

**5.1** On the local network: the machine's own link (cable unplugged, Wi-Fi down), the switch/access point, or the router itself. Since the machine has an address but cannot reach the first hop, the failure is *before* the internet is even involved.

**5.2** `/etc/resolv.conf`. Check that it contains at least one `nameserver` line, that the address is correct, and that the server responds (e.g. `dig @<that-address> www.lpi.org`). Since raw IP connectivity works (step 3), only the name-resolution layer can be at fault.

**5.3** Each step depends on the previous one: name resolution needs internet reachability, which needs a working gateway, which needs a valid local address. Testing in order isolates the *first* broken layer. Starting with `ping www.lpi.org` tests everything at once — if it fails, you still don't know whether the problem is the address, the gateway, the route, or DNS.

</details>