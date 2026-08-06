# Exercises: Networking Fundamentals (Topic 2.5)

## Exercise 1: Inspecting Network Interfaces and Routes

Understanding the current state of your network stack is the first step in troubleshooting any connectivity issue.

1. List all network interfaces along with their IP addresses (both IPv4 and IPv6) in a brief, readable format:
   ```bash
   ip -brief address show
   ```
2. Display the current IPv4 routing table to determine the default gateway:
   ```bash
   ip route show
   ```
3. Use `ping` to test connectivity to the default gateway you found in step 2:
   ```bash
   ping -c 4 <gateway_ip>
   ```

**Question 1.1:** What does the `lo` interface represent in the output of `ip address show`?
**Question 1.2:** In the routing table, what does `default via` mean?

---

## Exercise 2: Tracing and Socket Inspection

When a service is unreachable, you must determine if the packets are dropping on the network (Layer 3) or if the application isn't listening (Layer 4).

1. Trace the route to an external server (like `8.8.8.8`) to see the network hops:
   ```bash
   tracepath 8.8.8.8
   ```
2. Check if a local SSH daemon is actively listening for incoming TCP connections:
   ```bash
   sudo ss -tlnp | grep ssh
   ```
3. Test if you can establish a TCP connection to an external HTTPS server without sending any HTTP payload:
   ```bash
   nc -vz 8.8.8.8 443
   ```

**Question 2.1:** What is the primary difference between `tracepath` (or `traceroute`) and `ping` in terms of the information they provide?
**Question 2.2:** In the output of `ss -tlnp`, what do the `t`, `l`, `n`, and `p` flags stand for?

---

## Exercise 3: DNS Resolution

Most modern Linux systems use a local stub resolver. Let's verify how names are being resolved.

1. View the contents of the resolver configuration file:
   ```bash
   cat /etc/resolv.conf
   ```
2. Query the status of the `systemd-resolved` daemon to see the actual upstream DNS servers:
   ```bash
   resolvectl status
   ```

**Question 3.1:** If `/etc/resolv.conf` shows `nameserver 127.0.0.53`, what does this IP address represent?
**Question 3.2:** What is the purpose of the `search` directive in `/etc/resolv.conf`?

---

<details>
<summary><strong>Answers</strong></summary>

**Answer 1.1:** `lo` represents the loopback interface (`127.0.0.1` / `::1`). It is a virtual network interface used by the system to communicate with itself without sending packets onto the physical network hardware.

**Answer 1.2:** `default via` specifies the default gateway (often the local router). If the system needs to send a packet to an IP address that doesn't match any specific subnet in the routing table, it sends the packet to this default gateway.

**Answer 2.1:** `ping` only tells you if the destination is reachable and the round-trip time. `tracepath`/`traceroute` shows every router (hop) the packet passes through to reach the destination, which is crucial for identifying exactly where a connection is dropping.

**Answer 2.2:** 
- `t`: TCP sockets only.
- `l`: Listening sockets only (waiting for incoming connections).
- `n`: Numeric output (do not resolve IP addresses or port numbers to hostnames/service names, making it much faster).
- `p`: Show the process using the socket (requires root privileges).

**Answer 3.1:** `127.0.0.53` is a local loopback address specifically used by `systemd-resolved` as a local DNS stub resolver. It intercepts DNS queries from local applications and forwards them to the actual upstream DNS servers configured on the network interfaces.

**Answer 3.2:** The `search` directive appends specified domain names to any short hostname queries. For example, if `search internal.example.com` is set, pinging `db-server` will automatically try to resolve `db-server.internal.example.com`.
</details>