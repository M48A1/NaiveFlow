# LAN proxy sharing

Open **About → Advanced Settings → LAN Proxy**. Set a TCP port (default 8080),
enable sharing, save, and reconnect
the VPN. Configure the other device to use the displayed Wi-Fi address and port.

The port supports **SOCKS5 CONNECT** only. It relays TCP
through the VPN's current default node or proxy chain. New connections use the
current selection; established connections retain their original outbound.
This ingress does not evaluate per-destination routing rules or run MITM.
HTTP CONNECT, plain HTTP forward-proxy requests, SOCKS BIND, SOCKS UDP ASSOCIATE and IPv6
inbound clients/targets are not supported.

Sharing is off by default. There is no address allowlist or username/password
authentication. When enabled, the first three distinct private Wi-Fi client IPv4
addresses with active connections can use the proxy. A fourth address is rejected
even when connection slots remain. An address keeps its slot while any of its
connections (including handshakes) remain; the last close or timeout frees it.
Devices are counted by source IPv4, not by hardware identity: clients behind one
address share a slot. Only RFC 1918 peers are eligible; public, loopback,
link-local, IPv6 and hostname peers are rejected. Legacy saved `allowedClients`
fields are ignored on load and removed on the next save.

The listener binds a specific private IPv4 address on the primary Wi-Fi
interface (`en0`) and requires a Wi-Fi path. It does not bind `0.0.0.0`, loopback,
cellular, Ethernet or a VPN interface. Wi-Fi path changes close old listeners
and clients and rebind when a private address is available. If there is no such
address, nothing listens. Sharing stops with the VPN. LAN settings are local to
the device and take effect at the next VPN start.

Resource limits are scoped to LAN sharing:

- 3 concurrent client IPv4 addresses and 12 total TCP connections, including handshakes.
- 4 connections per client IPv4 address and 4 simultaneous handshakes overall.
- Excess connections close immediately; there is no waiting queue.
- 15-second handshake/dial deadline; non-SOCKS5 traffic is rejected on its first byte.
- At most 16 KiB per read from an inbound client, with sequential sends providing
  backpressure. Outbound protocol buffers retain their separate budgets; this
  read limit is not a cap on total session or process memory.
- Two-minute idle timeout and one-hour maximum session lifetime.

Handshake slots are released after a successful outbound connection and proxy
reply; all slots are released when a session ends or the Wi-Fi listener resets.
Address-scope and device/connection limits are checked before negotiation or outbound dialing.
Protocol/connect errors appear in the extension's LANProxy logs. Listener bind
errors are logged and do not stop the VPN.

Simulator tests cover private-address boundaries, device slot admission/release,
legacy settings migration, profile vetoes, SOCKS5 negotiation,
real TCP relay (including fragmented requests and coalesced
initial payload), and rejection of HTTP and UDP ASSOCIATE. Actual Wi-Fi reachability,
local network permission, extension background behavior and network changes
still require device testing. The device must grant local network access.

## Profile override

```ini
[General]
lan-proxy-enabled = false
```

After a profile is successfully applied, `false` vetoes the device switch:
existing LAN sessions close and the listener/path monitor are cancelled and
released. No LAN server is constructed at VPN startup while disabled. This
releases sharing resources, not the VPN core or its other connections.

`true` permits the local switch; it does not turn sharing on by itself. The
local enable switch is still required. An absent override
uses the preference value captured by the profile; older bundles with no such
preference permit the local switch. A failed/rejected profile does not change
the active permission. Profile permission is pinned to the active runtime
version and participates in rollback. Saving local port/switch changes
still requires a VPN reconnect.
