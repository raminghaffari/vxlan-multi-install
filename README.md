VXLAN Multi-Peer Installer

Simple interactive installer for creating point-to-point VXLAN tunnels between an IRAN server and one or more FOREIGN servers.
All in one script with a clean menu: IRAN mode, FOREIGN mode, Remove instance, List & status, Full uninstall, and Connectivity check.

Menus are English-only to avoid locale issues in terminals.

✨ Features

IRAN mode: connect to N foreign servers in one go.

Auto assigns:

VNI starting at 88 (88, 89, 90, …)

/30 subnets: 10.8.<VNI>.0/30 → IRAN .1, FOREIGN .2

UDP ports starting at 4789 (4789, 4790, …)

Creates per-peer configs under /etc/vxlan/*.conf and a systemd template vxlan@.service.

Optional persistence of firewall rules via iptables-persistent.

Handy tools: Remove instance, List & status, Connectivity check, Full uninstall.

🧩 Requirements

Debian/Ubuntu with systemd

Root privileges (sudo or root)

Outbound UDP allowed, and inbound UDP from the peer on the chosen port(s)

🚀 One-liner Install (latest main)
bash <(curl -Ls "https://raw.githubusercontent.com/raminghaffari/vxlan-multi-install/main/install.sh")


If caching causes old versions, pin to a commit:

bash <(curl -Ls "https://raw.githubusercontent.com/raminghaffari/vxlan-multi-install/<COMMIT_SHA>/install.sh")


Or bypass cache:

bash <(curl -Ls "https://raw.githubusercontent.com/raminghaffari/vxlan-multi-install/main/install.sh?cb=$(date +%s)")

🔧 Menu Options
1) IRAN mode (multi FOREIGN)

Use this on the IRAN server.

What it asks:

WAN interface (default auto-detected)

IRAN public IP (auto-detects; confirm)

VXLAN MTU (default 1450)

How many FOREIGN servers?

For each FOREIGN: FOREIGN public IP

What it does:

For tunnel #1 → VNI=88, Subnet=10.8.88.0/30, IRAN=10.8.88.1/30, FOREIGN=10.8.88.2/30, UDP=4789

For tunnel #2 → VNI=89, 10.8.89.0/30, …, UDP=4790

Writes /etc/vxlan/peerN.conf, enables vxlan@peerN, opens firewall for each foreign IP/port

At the end, it prints a summary table for you to configure each FOREIGN.

2) FOREIGN mode (single peer)

Use this on each FOREIGN server.

What it asks:

WAN interface (auto)

FOREIGN public IP (this host)

IRAN public IP

VNI (e.g., 88)

UDP port (e.g., 4789)

VXLAN MTU (default 1450)

What it does:

Sets local tunnel IP to 10.8.<VNI>.2/30

Creates /etc/vxlan/x<VNI>.conf, enables vxlan@x<VNI>, opens firewall from IRAN IP to the specified UDP port

3) Remove an instance

Shows a table with all instances

Remove by number or name

Stops & disables service and deletes its config

4) List & status

Shows a live table:

NAME, VNI, IFACE, LOCAL_PUBLIC, REMOTE_PUBLIC, LOCAL_ADDR, PORT, STATUS

5) Full uninstall

Stops & disables all vxlan@*

Removes /etc/vxlan/*.conf and the vxlan@.service template

Reloads systemd

6) Connectivity check

For each instance:

Derives peer IP (.1 ↔ .2 in /30)

ping (1 packet) to the peer’s tunnel IP

Shows UDP_RX counter from iptables for that peer/port (packets seen on this host)

Summarizes SVC (systemd), PING, UDP_RX

Interpretation tips

PING=OK and UDP_RX>0 → tunnel + return path OK

PING=FAIL but UDP_RX>0 → remote VXLAN/IP likely wrong (IP bound, VNI mismatch, etc.)

UDP_RX=0 → no VXLAN UDP arriving (firewall/ISP/port blocked)

📘 Example: 2 tunnels from IRAN

After running IRAN mode with 2 foreign servers:

Tunnel	VNI	Subnet (/30)	IRAN IP	FOREIGN IP	UDP Port
1	88	10.8.88.0/30	10.8.88.1	10.8.88.2	4789
2	89	10.8.89.0/30	10.8.89.1	10.8.89.2	4790

On each FOREIGN:

Set same VNI & port as table

Ensure LOCAL_PUBLIC (foreign IP), REMOTE_PUBLIC (IRAN IP)

LOCAL_ADDR=10.8.<VNI>.2/30

🔐 Firewall

The script adds rules like:

iptables -I INPUT -p udp -s <REMOTE_PUBLIC_IP> --dport <PORT> -j ACCEPT


Optionally persist:

apt-get install -y iptables-persistent
netfilter-persistent save

🛡️ Security Notes

Prefer pinning to a tag or commit for stable installs.

Review the script before running in production.

Use unique ports per tunnel if your provider filters default VXLAN port 4789.

🧪 Troubleshooting

1) Service failed / wrong WAN interface

WAN must be your internet NIC (e.g., eth0, ens3), not vxlanXX.

ip route show default | awk '/default/ {print $5; exit}'


Edit /etc/vxlan/<name>.conf → WAN_IFACE=<correct> and:

systemctl daemon-reload
systemctl restart vxlan@<name>


2) Ping fails

Check both sides have matching VNI and UDP port.

IRAN must have .1/30, FOREIGN .2/30.

Run Connectivity check from the menu.

3) No UDP packets counted (UDP_RX=0)

Likely firewall/ISP blocking. Try another port (e.g., 4799) on both sides and open firewall accordingly.

4) Raw URL shows old script

Pin to a commit or add a cache-buster query:

.../main/install.sh?cb=$(date +%s)

🇮🇷 راهنمای سریع (فارسی خلاصه)
نصب یک‌خطی
bash <(curl -Ls "https://raw.githubusercontent.com/raminghaffari/vxlan-multi-install/main/install.sh")

حالت ایران

تعداد سرورهای خارج + IP عمومی هرکدام را بده.

برای هر تونل: VNI=88+، ساب‌نت 10.8.<VNI>.0/30، ایران .1، خارج .2، پورت 4789+.

حالت خارج

IP عمومی خودش، IP ایران، VNI و پورت (همان جدول ایران).

بررسی اتصال

از منو گزینه Connectivity check را بزن؛ PING و UDP_RX را ببین.

حذف‌ها

Remove an instance: حذف یک تونل

Full uninstall: حذف کامل همه تونل‌ها و سرویس

📝 License

MIT (or your preferred license)

🤝 Contributing

Issues and PRs are welcome. Please describe environment, logs (systemctl status vxlan@<name>, ip -d link show vxlan<VNI>, iptables -nvL), and exact steps to reproduce.
