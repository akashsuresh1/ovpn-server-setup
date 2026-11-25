# OpenVPN Server on EC2 (Amazon Linux 2023)

Full-tunnel OpenVPN server on Amazon Linux 2023, deployed from AWS CloudShell as an Auto Scaling group (ASG) with a weekly stop/start schedule. Includes hardened iptables rules, persistent NAT, and optional FreeDNS dynamic DNS. For VPN clients to keep using the same address after weekly instance replacements, configure FreeDNS before deployment.

**Deployment flow:**
1. For a stable client address, [set up FreeDNS](#freedns-dynamic-dns) before deployment
2. Open CloudShell, run the deploy command → server is built, baked into an AMI, handed to an ASG, and client `.ovpn` profiles are copied to the CloudShell home dir
3. Download the profiles via CloudShell → Actions → Download file (or `scp` from your machine)

---

## Prerequisites

### AWS account (rules as of Nov 2026)

- Accounts created on/after **15 Jul 2025** choose a **Free plan** or **Paid plan** at sign-up
  - Both get **US$100 credits**, plus up to US$100 more for completing onboarding activities
  - Free plan: no charges ever; ends after **6 months or when credits run out** (whichever first), then the account **closes automatically**. You have 90 days to upgrade to Paid before AWS deletes it
  - All usage (instance hours, public IPv4, EBS, snapshots) is drawn from credits
- **Use "Sign up for AWS (advanced)"** (classic flow: root email, card, phone verification)
  - The newer "Sign up for AWS (new)" flow (Builder ID, no root user) pins your region from your contact address — Australia/Japan → `ap-southeast-2` (Sydney) — and doesn't allow opt-in regions (e.g. Zurich `eu-central-2`). You can't pick `ap-northeast-1` there
  - Advanced flow requires a valid payment method and SMS/voice phone verification
- Payment card: create a free Wise account and order a (free) virtual card at https://wise.com/au/virtual-card/
  - AWS will perform a $1 USD card check during account setup so you will need to load the card accordingly
  - AWS doesn't permit the same (virtual) card to be re-used. Virtual cards are free to create/destroy.
- For phone number verification, use temp numbers services like https://temp-number.com/ or https://sms24.me/en/countries/au
- TIP: When you use `john.doe@emailprovider.com` to avail free tier, after the plan ends, append `+aws1` to the user name and repeat the setup, and regenerate client certs (Ex: `john.doe+aws1@emailprovider.com`)
  - AWS states existing customers are ineligible for the free plan/credits; re-used phone/card details may be flagged
- Recommended region: Tokyo `ap-northeast-1` (default in the deploy script)
  - The further the region is from you, the higher the latency
- For a stable client address across weekly ASG replacements, set up FreeDNS before deployment (see [FreeDNS dynamic DNS](#freedns-dynamic-dns))

### Free-tier instance types (accounts created on/after 15 Jul 2025)

`t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large`, `m7i-flex.large` — the deploy script lists them live and defaults to `t4g.micro`.

Rough running cost in Tokyo, drawn from credits (check current pricing):

| Item | ≈ US$/month |
|---|---|
| `t4g.micro` on-demand | 8 |
| Public IPv4 (`$0.005/h`) | 3.60 |
| 8 GB gp3 root volume + AMI snapshot | 1 |
| **Total** | **~12.60 → ~76 over the 6-month plan** |

`t4g.small` roughly doubles the instance line and exceeds US$100 over 6 months unless you earn the extra credits.

---

## Quick start (CloudShell)

The ASG replaces its instance weekly, and each replacement gets a new public IP. Before deploying, complete the [FreeDNS setup](#freedns-dynamic-dns) and have your FreeDNS Direct URL and hostname ready. This is not required to create the ASG, but without a stable DNS name the client profiles stop reaching the server after an IP change; you must then update and redistribute the profiles manually.

Sign in to the AWS console, switch region to **Asia Pacific (Tokyo)**, open **CloudShell** (terminal icon, top bar), and run the command below, replacing the example URL and hostname with your own:

```bash
git clone https://github.com/akashsuresh1/ovpn-server-setup.git && FREEDNS_URL='https://freedns.afraid.org/dynamic/update.php?YOURTOKEN' VPN_REMOTE='myvpn.domainname.com' bash ovpn-server-setup/cloudshell-deploy.sh
```

The script prompts for:
- **VPN port** — defaults to 1194, but a custom port is strongly recommended
- **VPN subnet** — defaults to 10.8.0.0/24
- **Instance type** — lists free-tier eligible types, defaults to `t4g.micro` (with `t4g.small` as capacity fallback)
- **DNS readiness** — confirms FreeDNS is ready when both `FREEDNS_URL` and `VPN_REMOTE` are set; without them, asks you to explicitly continue without stable DNS
- **SSH key**
  - `1` First-time setup: key pair generated, private key saved to `~/ovpn-key.pem` in CloudShell
  - `2` Returning (new account after the free plan ended): paste the public key of your existing key (`ssh-keygen -y -f ovpn-key.pem` prints it)
- **Client profiles** — space-separated names (e.g. `laptop phone`), blank for none

Then it, unattended (~15–25 min):
1. Creates a security group (UDP VPN port + TCP 22) and key pair in the default VPC
2. Launches a bootstrap AL2023 instance whose user-data runs `ovpn-server-setup.sh` non-interactively, then powers off
3. Bakes an AMI from the stopped instance, then terminates it
4. Creates a launch template + ASG (min 0 / max 1 / desired 1) with the weekly schedule
5. Waits for the ASG instance, pulls the profiles into `/home/cloudshell-user/<name>.ovpn` via EC2 Instance Connect (temporary key, no private key needed in CloudShell), and sets their `remote` line to `VPN_REMOTE` (your stable hostname) or, if unset, the current ASG instance IP

After deployment, download each profile: CloudShell → **Actions → Download file** → `/home/cloudshell-user/<name>.ovpn`. Then delete them from CloudShell (`rm ~/*.ovpn`) — they contain private keys.
- First-time setup: also download `/home/cloudshell-user/ovpn-key.pem` (SSH key for later admin)
- If the automatic fetch fails, use the `scp` command printed by the script; it uses the configured hostname (or current IP) and the selected SSH key.

Without a stable DNS hostname, the server IP changes on every weekly replacement and the client profiles must be updated and redistributed. With FreeDNS configured, the profiles use the stable hostname (see [FreeDNS](#freedns-dynamic-dns)).

Install the OpenVPN client from https://openvpn.net/client/ and import the `.ovpn` files.

### Optional env overrides

Prefix the command with any of these, e.g. `NAME=vpn2 bash ovpn-server-setup/cloudshell-deploy.sh`.

| Variable | Default | Purpose |
|---|---|---|
| `AWS_REGION` | `ap-northeast-1` | Region |
| `NAME` | `ovpn` | Resource prefix (`ovpn-sg`, `ovpn-key`, `ovpn-lt`, `ovpn-asg`) |
| `SSH_CIDR` | `0.0.0.0/0` | Source CIDR for TCP 22 |
| `FALLBACK_TYPES` | `t4g.small` (when primary is `t4g.micro`) | Lower-priority types when the primary has no capacity; same arch only. `""` disables |
| `VPN_REMOTE` | current ASG IP | Host written to `remote` in `.ovpn`; set this to your stable DNS hostname |
| `FREEDNS_URL` | unset | FreeDNS Direct URL — bakes the `@reboot` update into the AMI; set this so DNS follows weekly IP changes |
| `SCHED_TZ` / `SCHED_STOP` / `SCHED_START` | `Australia/Melbourne` / `0 3 * * 3` / `10 3 * * 3` | ASG weekly schedule |

### Alternative: run on an existing instance

```bash
sudo dnf install -y git
git clone https://github.com/akashsuresh1/ovpn-server-setup.git
cd ovpn-server-setup
sudo bash ovpn-server-setup.sh
```

Interactive prompts as above. Profiles land in `/root/` and `/home/ec2-user/ovpn/`.

---

## What the server script configures

| Component | Detail |
|---|---|
| **OpenVPN** | `openvpn-server@server` systemd service, enabled on boot |
| **PKI** | EasyRSA — CA, server cert, DH params, TLS auth key, all under `/etc/openvpn/easy-rsa/` |
| **Cipher** | `AES-256-GCM` preferred, `AES-256-CBC` kept as fallback for older clients |
| **DNS push** | Cloudflare `1.1.1.1` / `1.0.0.1` pushed to all clients |
| **Routing** | Full-tunnel via `redirect-gateway def1 bypass-dhcp` |
| **MTU** | `tun-mtu 1420` + `mssfix 1380` — prevents EMSGSIZE drops on Nitro |
| **IP forwarding** | `net.ipv4.ip_forward=1` persisted via `/etc/sysctl.d/99-openvpn.conf` |
| **iptables** | Hardened INPUT chain, stateful FORWARD, NAT masquerade — persisted via `iptables-services` |
| **Client profiles** | `/root/<name>.ovpn` + copy in `/home/ec2-user/ovpn/` for `scp` |

Non-interactive mode (used by the deploy script): `OVPN_NONINTERACTIVE=1 VPN_PORT=… VPN_SUBNET=… CLIENT_NAMES="a b" bash ovpn-server-setup.sh`.

Source/dest check does **not** need to be disabled — clients are MASQUERADEd to the instance's own IP.

---

## Auto Scaling group & weekly schedule

The ASG replaces the old SSM nightly stop/start. Each scheduled stop terminates the instance; each start launches a fresh one from the AMI → new public IP every week.

- Min 0 / max 1 / desired 1, all other settings default
- No subnet pinned: the ASG spans **every AZ** that offers the instance type (default subnet per AZ, created if missing). A single static AZ regularly hits `InsufficientInstanceCapacity`; with all AZs, the ASG retries in another AZ automatically, multiplying the capacity pool. The bootstrap launch falls through AZs the same way
- Mixed instances policy, On-Demand, `prioritized`: `t4g.micro` first, `t4g.small` only when micro can't be placed. Same arm64 AMI works for both (an AMI is tied to architecture, not instance size). Small costs ~2× while it runs — check the running type with `aws ec2 describe-instances --filters Name=tag:Name,Values=ovpn Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceType'`

| Scheduled action | Recurrence (`Australia/Melbourne`) | Desired |
|---|---|---|
| `ovpn-weekly-stop` | `0 3 * * 3` — Wed 03:00 | 0 |
| `ovpn-weekly-start` | `10 3 * * 3` — Wed 03:10 | 1 |

`Australia/Melbourne` follows daylight saving (AEST/AEDT).

> **Anything changed on the running instance is lost on the next replacement** (new/revoked clients, crontab, config). Re-bake the AMI after changes.

### Re-bake the AMI (CloudShell)

```bash
ASG=ovpn-asg; LT=ovpn-lt
IID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
AMI=$(aws ec2 create-image --instance-id $IID --name "ovpn-$(date -u +%Y%m%d-%H%M)" \
  --query ImageId --output text)            # reboots the instance briefly
aws ec2 wait image-available --image-ids $AMI
VER=$(aws ec2 create-launch-template-version --launch-template-name $LT --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"$AMI\"}" --query LaunchTemplateVersion.VersionNumber --output text)
aws ec2 modify-launch-template --launch-template-name $LT --default-version $VER
```

Deregister old AMIs + delete their snapshots to stop paying for them.

---

## EC2 security group

The deploy script creates `ovpn-sg` (UDP VPN port from anywhere, TCP 22 from `SSH_CIDR`). For a manually created instance:

```bash
# AWS CLI example — replace sg-xxxx and the port with your values
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxx \
  --protocol udp \
  --port 1194 \
  --cidr 0.0.0.0/0
```

---

## FreeDNS dynamic DNS

The ASG launches a new instance (new public IP) every week. Configure FreeDNS before running the CloudShell deployment so the deploy script can bake the DNS update into the AMI and put the hostname in client profiles. The ASG itself can be created without DNS, but clients using the old IP will stop connecting after a replacement.

### Setup (one-time, before deployment)

1. Create a free account at [freedns.afraid.org](https://freedns.afraid.org)
2. Add a subdomain (e.g. `<unique_subdomain>.<free_available_domain_name>.com`). The initial IP is updated when the ASG instance starts.
3. Go to Dynamic DNS (https://freedns.afraid.org/dynamic/) → find your subdomain → right-click copy the **Direct URL**
   - It looks like: `https://freedns.afraid.org/dynamic/update.php?YOURTOKEN`
4. Run the deployment with both values set, so the updater and client profiles use the same hostname:

```bash
FREEDNS_URL='https://freedns.afraid.org/dynamic/update.php?YOURTOKEN' \
VPN_REMOTE='myvpn.domainname.com' \
bash ovpn-server-setup/cloudshell-deploy.sh
```

If you deploy without FreeDNS, the script writes the current server IP into the client profiles. Update the profiles' `remote` line and redistribute them after each ASG replacement. For a manually managed instance, FreeDNS can instead be configured on that instance; ensure the updater is included when you [re-bake the AMI](#re-bake-the-ami-cloudshell) if you later move it into this ASG flow.

### Verify after reboot

```bash
curl https://checkip.amazonaws.com                          # server's current public IP
host `<unique_subdomain>.<free_available_domain_name>.com`  # should match
cat /tmp/freedns_update.log                                 # FreeDNS response
```

---

## Managing client certificates

Changes below live only on the running instance — [re-bake the AMI](#re-bake-the-ami-cloudshell) afterwards.

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
OVPN_OUT="/home/ec2-user/ovpn/${CLIENT_NAME}.ovpn"

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

chown ec2-user:ec2-user "$OVPN_OUT" && chmod 600 "$OVPN_OUT"
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
scp -i ~/path/to/ovpn-key.pem 'ec2-user@YOUR_SERVER_IP:ovpn/*.ovpn' .
```

---

## Useful commands

```bash
# Service status
sudo systemctl status openvpn-server@server

# Live connection log
sudo journalctl -u openvpn-server@server -f

# Currently connected clients (look for the line beginning with "CLIENT_LIST")
sudo cat /var/log/openvpn-status.log

# Restart OpenVPN
sudo systemctl restart openvpn-server@server

# Check iptables NAT rule is in place
sudo iptables -t nat -S POSTROUTING

# Verify IP forwarding is on
sysctl net.ipv4.ip_forward

# Check your public IP
curl https://checkip.amazonaws.com

# Bootstrap setup log (baked into the AMI)
sudo cat /var/log/ovpn-setup.log
```

---

## Troubleshooting

**Deploy script: "Server setup failed"**
- Bootstrap instance is left stopped: `aws ec2 get-console-output --instance-id i-xxxx --output text`
- Clean up: `aws ec2 terminate-instances --instance-ids i-xxxx`, then re-run

**Client connects but has no internet**
- Check the NAT rule: `sudo iptables -t nat -S POSTROUTING` — must show a MASQUERADE rule
- Check IP forwarding: `sysctl net.ipv4.ip_forward` — must be `1`
- Confirm the WAN interface in the NAT rule matches `ip addr` output (should be `ens5` on Nitro)

**Connection times out / can't reach server**
- Check the `remote` line in the `.ovpn` matches the current server IP / FreeDNS hostname
- Check the EC2 security group allows inbound UDP on your VPN port
- Check OpenVPN is actually listening: `sudo ss -ulnp | grep openvpn`

**EMSGSIZE errors in the log**
- `mssfix 1380` is already set by the script. If you still see drops, try lowering to `1300`.

**iptables rules disappear after reboot**
- Confirm `iptables-services` is enabled: `sudo systemctl status iptables`
- Re-save if needed: `sudo service iptables save`

**OpenVPN fails to start**
```bash
sudo journalctl -u openvpn-server@server -n 50 --no-pager
```

---

## File layout (condensed)

```
/etc/openvpn/
├── client
├── easy-rsa
│   ├── pki
│   │   ├── ca.crt
│   │   ├── certs_by_serial
│   │   │   ├── ABCDEFGHIJKLMNOP123456789ABCD123.pem
│   │   │   ├── ABCDEFGHIJKLMNOP123456789ABCD789.pem
│   │   ├── dh.pem
│   │   ├── issued
│   │   │   ├── server.crt
│   │   │   └── alice.crt
│   │   ├── private
│   │   │   ├── ca.key       ← keep this secret
│   │   │   ├── server.key
│   │   │   └── alice.key
└── server
    └── server.conf

/home/ec2-user/ovpn/
└── alice.ovpn               ← scp from here
```

---

## Security notes

- `ca.key` at `/etc/openvpn/easy-rsa/pki/private/ca.key` is the root of trust — do not expose it. It is also inside the AMI/snapshot; don't share or make them public
- Client `.ovpn` files contain private keys — treat them like passwords
- `~/ovpn-key.pem` in CloudShell is the SSH key — delete it after downloading if you prefer (CloudShell home is deleted after 120 days of inactivity)
- The INPUT chain defaults to REJECT; only UDP VPN port, TCP 22, ICMP, and established traffic are accepted
- Narrow SSH with `SSH_CIDR=<your-ip>/32` if your IP is stable
- Consider using `tls-crypt` instead of `tls-auth` for additional control-channel encryption (prevents unauthenticated parties from even completing a TLS handshake)
