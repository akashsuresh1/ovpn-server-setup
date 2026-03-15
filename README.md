# OpenVPN Server on EC2 (Amazon Linux 2023)

A single interactive script that sets up a full-tunnel OpenVPN server on a fresh Amazon Linux 2023 EC2 instance. Includes hardened iptables rules, persistent NAT, and optional FreeDNS dynamic DNS.

---

## Prerequisites

### Account/Payment Setup

- Create a free Wise account and order a (free) virtual card at https://wise.com/au/virtual-card/
  - AWS will perform a $1 USD card check during account setup so you will need to load the card accordingly
  - AWS doesn't permit the same (virtual) card to be re-used. Virtual cards are free to create/destroy.
- If dynamic DNS is required, create a free account on https://freedns.afraid.org
  - AWS Systems Manager can be used to turn off/on your instance nightly to change the public IP address of your instance (costs ~A$0.30/month)
- Create a new AWS account - Provides 12 months of freetier.micro EC2 intance
  - TIP: When you use `john.doe@emailprovider.com` to avail free tier, after the duration is completed, append `+aws1` to user name and repeat server setup, and regenerate client certs (Ex: `john.doe+aws1@emailprovider.com`)
  - Recommended region: Zurich `eu-central-2`
    - The further the region is from you, the higher the latency 
  - For phone number verification, use temp numbers services like https://temp-number.com/ or https://sms24.me/en/countries/au

| Requirement | Detail |
|---|---|
| EC2 instance | Amazon Linux 2023, any Nitro instance type |
| Instance size | `t3.micro` or `t4g.micro` (ARM) |
| Security group | Inbound: **UDP on your chosen port** + TCP 22 (SSH) |
| Source/dest check | Must be **disabled** on the EC2 instance (EC2 console → Networking → Change source/dest check) |
| User | Script must be run as root (`sudo bash setup.sh`) |

---

## Quick start

```bash
# 1 - Install git
sudo dnf install -y git

# 2 — Clone the repo (or only download ovpn-server-setup.sh and refer to this README) 
git clone https://github.com/akashsuresh1/ovpn-server-setup.git
cd ovpn-server-setup

# 3 — Run the setup script
sudo bash ovpn-server-setup.sh
```

The script will prompt you for:
- **VPN port** — defaults to 1194, but a custom port is strongly recommended
- **VPN subnet** — defaults to 10.8.0.0/24
- **Client certificates** — optional, generate one or more `.ovpn` client profiles

When it finishes, any generated `.ovpn` files are at `/root/<name>.ovpn`. Copy them off the server securely (e.g. `scp`) before distributing to clients.
Install OpenVPN client on the required clients from https://openvpn.net/client/

---

## What the script configures

| Component | Detail |
|---|---|
| **OpenVPN** | Installed via EPEL, `openvpn-server@server` systemd service, enabled on boot |
| **PKI** | EasyRSA — CA, server cert, DH params, TLS auth key, all under `/etc/openvpn/easy-rsa/` |
| **Cipher** | `AES-256-GCM` preferred, `AES-256-CBC` kept as fallback for older clients |
| **DNS push** | Cloudflare `1.1.1.1` / `1.0.0.1` pushed to all clients |
| **Routing** | Full-tunnel via `redirect-gateway def1 bypass-dhcp` |
| **MTU** | `tun-mtu 1420` + `mssfix 1380` — prevents EMSGSIZE drops on Nitro |
| **IP forwarding** | `net.ipv4.ip_forward=1` persisted via `/etc/sysctl.d/99-openvpn.conf` |
| **iptables** | Hardened INPUT chain, stateful FORWARD, NAT masquerade — persisted via `iptables-services` |

---

## EC2 security group

The script cannot modify your security group — you must do this in the AWS console or CLI before connecting clients.

```bash
# AWS CLI example — replace sg-xxxx and the port with your values
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxx \
  --protocol udp \
  --port 1194 \
  --cidr 0.0.0.0/0
```

SSH access (TCP 22) should already be open if you can run the script.

---

## FreeDNS dynamic DNS

EC2 public IPs change on every stop/start. FreeDNS gives your server a stable hostname.

### Setup (one-time, manual)

1. Create a free account at [freedns.afraid.org](https://freedns.afraid.org)
2. Add a subdomain (e.g. `<unique_subdomain>.<free_available_domain_name>.com`) pointing to your current public IP
3. Go to Dynamic DNS (https://freedns.afraid.org/dynamic/) → find your subdomain → right-click copy the **Direct URL**
   - It looks like: `https://freedns.afraid.org/dynamic/update.php?YOURTOKEN`
4. Add it manually to root cron:

```bash
# Add manually to root crontab
sudo crontab -e
# Add this line:
@reboot wget -q -O /tmp/freedns_update.log 'https://freedns.afraid.org/dynamic/update.php?YOURTOKEN'
```

5. Update the `remote` line in all client `.ovpn` files to use the hostname instead of an IP:
   ```
   remote myvpn.chickenkiller.com <specified_port>
   ```

### Nightly Stop/Start (Optional)
- Create an IAM role that SSM can use to stop/start the instance
- Trust relationship required
  ```
  {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "ec2.amazonaws.com",
                    "ssm.amazonaws.com"
                ]
            },
            "Action": "sts:AssumeRole"
        }
    ]
  }
  ```
- AWS Managed Permissions policies to add:
  - AmazonEC2FullAccess
  - AmazonSSMManagedEC2InstanceDefaultPolicy
  - AmazonSSMManagedInstanceCore
 
- Create association from AWS Systems Manager > State Manager (using the IAM role created above)
  - Stop-EC2-Instance-Daily > cron(0 00 16 ? * * *)
  - Start-EC2-Instance-Daily > cron(0 04 16 ? * * *)

### Verify after reboot

```bash
curl https://checkip.amazonaws.com                          # server's current public IP
host `<unique_subdomain>.<free_available_domain_name>.com`  # should match
cat /tmp/freedns_<subdomain>_<domain>_com.log               # FreeDNS response
```

---

## Managing client certificates

### Add a new client

```bash
cd /etc/openvpn/easy-rsa
EASYRSA_BATCH=1 ./easyrsa build-client-full CLIENT_NAME nopass
```

Then build the `.ovpn` profile. The easiest way is to re-run the relevant section
of the setup script, or use this one-liner (replace variables as needed):

```bash
CLIENT_NAME="alice"
PKI_DIR="/etc/openvpn/easy-rsa"
PUBLIC_IP=$(curl -sf https://checkip.amazonaws.com)
VPN_PORT="1194"
OVPN_OUT="/root/${CLIENT_NAME}.ovpn"

cat > "$OVPN_OUT" <<EOF
client
dev tun
proto udp

remote ${PUBLIC_IP} ${VPN_PORT}

resolv-retry infinite
nobind
persist-key
persist-tun

cipher AES-256-CBC
auth SHA256

remote-cert-tls server
key-direction 1
verb 3

<ca>
$(cat ${PKI_DIR}/pki/ca.crt)
</ca>

<cert>
$(openssl x509 -in ${PKI_DIR}/pki/issued/${CLIENT_NAME}.crt)
</cert>

<key>
$(cat ${PKI_DIR}/pki/private/${CLIENT_NAME}.key)
</key>

<tls-auth>
$(cat ${PKI_DIR}/ta.key)
</tls-auth>
EOF

echo "Profile written to $OVPN_OUT"
```

### List all issued certificates

```bash
ls /etc/openvpn/easy-rsa/pki/issued/
```

### Revoke a client

```bash
cd /etc/openvpn/easy-rsa
./easyrsa revoke CLIENT_NAME
./easyrsa gen-crl
cp pki/crl.pem /etc/openvpn/server/
```

Then add this line to `/etc/openvpn/server/server.conf` if not already present:

```
crl-verify /etc/openvpn/server/crl.pem
```

Restart OpenVPN:

```bash
sudo systemctl restart openvpn-server@server
```

### Copy a profile to your local machine

```bash
# Run this on your LOCAL machine, not the server
scp -i ~/.ssh/your-key.pem ec2-user@YOUR_SERVER_IP:/root/alice.ovpn ./alice.ovpn
```

---

## Useful commands

```bash
# Service status
sudo systemctl status openvpn-server@server

# Live connection log
sudo journalctl -u openvpn-server@server -f

# Currently connected clients
sudo cat /run/openvpn-server/status-server.log

# Restart OpenVPN
sudo systemctl restart openvpn-server@server

# Check iptables NAT rule is in place
sudo iptables -t nat -S POSTROUTING

# Verify IP forwarding is on
sysctl net.ipv4.ip_forward

# Check your public IP
curl https://checkip.amazonaws.com
```

---

## Troubleshooting

**Client connects but has no internet**
- Check the NAT rule: `sudo iptables -t nat -S POSTROUTING` — must show a MASQUERADE rule
- Check IP forwarding: `sysctl net.ipv4.ip_forward` — must be `1`
- Confirm the WAN interface in the NAT rule matches `ip addr` output (should be `ens5` on Nitro)

**Connection times out / can't reach server**
- Check the EC2 security group allows inbound UDP on your VPN port
- Check OpenVPN is actually listening: `sudo ss -ulnp | grep openvpn`

**EMSGSIZE errors in the log**
- `mssfix 1300` is already set by the script. If you still see drops, try lowering to `1280`.

**iptables rules disappear after reboot**
- Confirm `iptables-services` is enabled: `sudo systemctl status iptables`
- Re-save if needed: `sudo service iptables save`

**OpenVPN fails to start**
```bash
sudo journalctl -u openvpn-server@server -n 50 --no-pager
```

---

## File layout

```
/etc/openvpn/
├── server/
│   └── server.conf
└── easy-rsa/
    ├── ta.key
    └── pki/
        ├── ca.crt
        ├── dh.pem
        ├── issued/
        │   ├── server.crt
        │   └── <client>.crt
        └── private/
            ├── ca.key          ← keep this secret
            ├── server.key
            └── <client>.key
```

---

## Security notes

- `ca.key` at `/etc/openvpn/easy-rsa/pki/private/ca.key` is the root of trust — do not expose it
- Client `.ovpn` files contain private keys — treat them like passwords
- The INPUT chain defaults to REJECT; only UDP VPN port, TCP 22, ICMP, and established traffic are accepted
- Consider using `tls-crypt` instead of `tls-auth` for additional control-channel encryption (prevents unauthenticated parties from even completing a TLS handshake)
