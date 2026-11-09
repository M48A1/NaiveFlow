# LAN proxy sharing

Open **About → Advanced Settings → LAN Proxy**. Set a TCP port (default 8080),
add allowed client IPv4 addresses or CIDRs, enable sharing, save, and reconnect
the VPN. Configure the other device to use the displayed Wi-Fi address and port.

The mixed port supports **HTTP CONNECT** and **SOCKS5 CONNECT**. Both relay TCP
through the VPN's current default node or proxy chain. New connections use the
current selection; established connections retain their original outbound.
This ingress does not evaluate per-destination routing rules or run MITM.
Plain HTTP forward-proxy requests, SOCKS BIND, SOCKS UDP ASSOCIATE and IPv6
inbound clients/targets are not supported.

Sharing is off by default. An empty allowlist denies every client. Entries accept
an IPv4 address or CIDR; a malformed entry denies every client rather than being
ignored. Even a broad CIDR cannot admit public, loopback or link-local peers:
only RFC 1918 peers are eligible. This version uses the allowlist for access
control; it does not offer username/password authentication.

The listener binds a specific private IPv4 address on the primary Wi-Fi
interface (`en0`) and requires a Wi-Fi path. It does not bind `0.0.0.0`, loopback,
cellular, Ethernet or a VPN interface. Wi-Fi path changes close old listeners
and clients and rebind when a private address is available. If there is no such
address, nothing listens. Sharing stops with the VPN. LAN settings are local to
the device and take effect at the next VPN start.

There are at most 64 simultaneous clients, a 15-second handshake/dial deadline,
an 8 KiB HTTP header limit, bounded relay reads, and a one-hour maximum session
lifetime. ACL rejection happens before protocol negotiation or outbound dialing.
Protocol/connect errors appear in the extension's LANProxy logs. Listener bind
errors are logged and do not stop the VPN.

Simulator tests cover ACL boundaries, fail-closed behavior, CONNECT parsing,
real TCP relay for both protocols (including fragmented requests and coalesced
initial payload), and rejection of UDP ASSOCIATE. Actual Wi-Fi reachability,
local network permission, extension background behavior and network changes
still require device testing. The device must grant local network access.
