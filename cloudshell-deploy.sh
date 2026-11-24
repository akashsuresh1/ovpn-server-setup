#!/usr/bin/env bash
# =============================================================================
# OpenVPN on EC2 — one-shot deploy from AWS CloudShell
#
#   bootstrap EC2 (runs ovpn-server-setup.sh via user-data, then powers off)
#   → AMI → launch template → ASG (min 0 / max 1 / desired 1) + weekly schedule
#   → bootstrap instance terminated, ASG owns the server
#
# Usage (in CloudShell):
#   git clone https://github.com/akashsuresh1/ovpn-server-setup.git && bash ovpn-server-setup/cloudshell-deploy.sh
#
# Optional env overrides: AWS_REGION NAME SSH_CIDR VPN_REMOTE FREEDNS_URL FALLBACK_TYPES
#                         SCHED_TZ SCHED_STOP SCHED_START
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}── $* ──${RESET}"; }
ask()     { read -rp "$(echo -e "${BOLD}$1${RESET} ")" "$2"; }

# ── Defaults (override via env) ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/ovpn-server-setup.sh"

export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

NAME="${NAME:-ovpn}"                         # prefix for every resource
KEY_NAME="${NAME}-key"
KEY_FILE="$HOME/${KEY_NAME}.pem"
SG_NAME="${NAME}-sg"
LT_NAME="${NAME}-lt"
ASG_NAME="${NAME}-asg"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"
BOOTSTRAP_TIMEOUT_MIN=30

# ASG weekly schedule (Melbourne time, follows AEST/AEDT)
SCHED_TZ="${SCHED_TZ:-Australia/Melbourne}"
SCHED_STOP="${SCHED_STOP:-0 3 * * 3}"        # Wed 03:00 → desired 0
SCHED_START="${SCHED_START:-10 3 * * 3}"     # Wed 03:10 → desired 1

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# =============================================================================
# 0. PRE-FLIGHT
# =============================================================================
header "Pre-flight"

[[ -f "$SETUP_SCRIPT" ]] || die "ovpn-server-setup.sh not found next to this script."
command -v aws >/dev/null || die "aws CLI not found. Run this in AWS CloudShell."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || die "AWS credentials not available."
success "Account ${ACCOUNT_ID}, region ${AWS_REGION}"

EXISTING_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text)
[[ "$EXISTING_ASG" == "None" ]] \
  || die "ASG '${ASG_NAME}' already exists. To change the server, re-bake the AMI (see README)."

# =============================================================================
# 1. USER INPUT
# =============================================================================
header "Configuration"

# ── VPN port ──────────────────────────────────────────────────────────────────
echo
warn "Using the default port 1194 makes your VPN easier to detect and block."
warn "A custom port (e.g. 32030) is strongly recommended."
ask "VPN port [default: 1194]:" VPN_PORT
VPN_PORT="${VPN_PORT:-1194}"
if ! [[ "$VPN_PORT" =~ ^[0-9]+$ ]] || (( VPN_PORT < 1 || VPN_PORT > 65535 )); then
  die "Invalid port: $VPN_PORT"
fi

# ── VPN subnet ────────────────────────────────────────────────────────────────
ask "VPN subnet [default: 10.8.0.0]:" VPN_SUBNET
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
[[ "$VPN_SUBNET" =~ ^([0-9]{1,3}\.){3}0$ ]] || die "Invalid /24 subnet: $VPN_SUBNET"

# ── Instance type ─────────────────────────────────────────────────────────────
echo
FT_TYPES=$(aws ec2 describe-instance-types \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' --output text | tr '\t' '\n' | sort)
if [[ -n "$FT_TYPES" ]]; then
  info "Free-tier eligible instance types in ${AWS_REGION}:"
  sed 's/^/          /' <<<"$FT_TYPES"
else
  warn "No free-tier eligible instance types reported for this account."
fi
ask "Instance type [default: t4g.micro]:" INSTANCE_TYPE
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.micro}"
if [[ -n "$FT_TYPES" ]] && ! grep -qx "$INSTANCE_TYPE" <<<"$FT_TYPES"; then
  warn "${INSTANCE_TYPE} is not free-tier eligible — a Free-plan account may reject it."
fi

ARCHES=$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" \
  --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text) \
  || die "Unknown instance type: $INSTANCE_TYPE"
[[ "$ARCHES" == *arm64* ]] && ARCH=arm64 || ARCH=x86_64

# Fallback type(s), lower priority — used only when the primary has no capacity.
# Must share the AMI's architecture. Override with FALLBACK_TYPES="" to disable.
if [[ -z "${FALLBACK_TYPES+set}" ]]; then
  [[ "$INSTANCE_TYPE" == "t4g.micro" ]] && FALLBACK_TYPES="t4g.small" || FALLBACK_TYPES=""
fi
for t in $FALLBACK_TYPES; do
  FB_ARCHES=$(aws ec2 describe-instance-types --instance-types "$t" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text) \
    || die "Unknown fallback instance type: $t"
  [[ "$FB_ARCHES" == *"$ARCH"* ]] || die "Fallback ${t} is not ${ARCH} — it can't run the AMI."
done
# shellcheck disable=SC2206
INSTANCE_TYPES=("$INSTANCE_TYPE" $FALLBACK_TYPES)

# ── SSH key pair ──────────────────────────────────────────────────────────────
echo
info "SSH key pair — used later to scp the client profiles to your machine."
echo "    1) First-time setup: generate a new key here (download the .pem once)"
echo "    2) Returning (new account after free tier ended): paste your existing public key"
ask "Choice [default: 1]:" KEY_CHOICE
KEY_CHOICE="${KEY_CHOICE:-1}"
[[ "$KEY_CHOICE" == 1 || "$KEY_CHOICE" == 2 ]] || die "Invalid choice: $KEY_CHOICE"

if [[ "$KEY_CHOICE" == 2 ]]; then
  echo "    Tip: get it locally with  ssh-keygen -y -f ~/Downloads/${KEY_NAME}.pem"
  ask "Public key (ssh-ed25519 … / ssh-rsa …):" PUBKEY
  [[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\  ]] \
    || die "That does not look like an OpenSSH public key."
fi

# ── Client profiles ───────────────────────────────────────────────────────────
echo
ask "Client profiles to generate (space-separated, blank = none) [e.g. laptop phone]:" CLIENT_NAMES
for c in $CLIENT_NAMES; do
  [[ "$c" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid client name '$c' (allowed: A-Z a-z 0-9 _ . -)"
done

# ── Confirm ───────────────────────────────────────────────────────────────────
header "Summary"
echo -e "  ${BOLD}Region${RESET}          ${AWS_REGION}"
echo -e "  ${BOLD}Instance${RESET}        ${INSTANCE_TYPE} (${ARCH})${FALLBACK_TYPES:+, fallback: ${FALLBACK_TYPES}}"
echo -e "  ${BOLD}VPN${RESET}             ${VPN_PORT}/UDP, ${VPN_SUBNET}/24"
echo -e "  ${BOLD}SSH key${RESET}         $([[ $KEY_CHOICE == 1 ]] && echo "generate → ${KEY_FILE}" || echo "import pasted public key")"
echo -e "  ${BOLD}Clients${RESET}         ${CLIENT_NAMES:-none}"
echo -e "  ${BOLD}Client remote${RESET}   ${VPN_REMOTE:-<bootstrap IP — fixed up in the scp command>}"
echo -e "  ${BOLD}FreeDNS cron${RESET}    $([[ -n ${FREEDNS_URL:-} ]] && echo "baked into AMI" || echo "not set (see README)")"
echo -e "  ${BOLD}ASG schedule${RESET}    stop '${SCHED_STOP}', start '${SCHED_START}' (${SCHED_TZ})"
echo
ask "Proceed? [Y/n]:" GO
[[ "${GO:-y}" =~ ^[Yy]$ ]] || die "Aborted."

# =============================================================================
# 2. NETWORK, SECURITY GROUP, KEY PAIR
# =============================================================================
header "Network & access"

VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" != "None" ]] || die "No default VPC in ${AWS_REGION}."
success "Default VPC: $VPC_ID"

# Every AZ that offers the instance type. Bootstrap and ASG both fall through
# to the next AZ when one has no capacity (InsufficientInstanceCapacity).
AZS=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values="$(IFS=,; echo "${INSTANCE_TYPES[*]}")" \
  --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort -u)
mapfile -t OFFERED_AZS <<<"$AZS"
[[ -n "${OFFERED_AZS[0]}" ]] || OFFERED_AZS=()
(( ${#OFFERED_AZS[@]} )) || die "${INSTANCE_TYPE} is not offered in ${AWS_REGION}."

# Each AZ needs a default subnet — create any that are missing
AZ_LIST=(); SUBNETS=()
for az in "${OFFERED_AZS[@]}"; do
  sn=$(aws ec2 describe-subnets --filters \
    Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true Name=availability-zone,Values="$az" \
    --query 'Subnets[0].SubnetId' --output text)
  if [[ "$sn" == "None" ]]; then
    sn=$(aws ec2 create-default-subnet --availability-zone "$az" \
      --query Subnet.SubnetId --output text) \
      || { warn "No default subnet in ${az} and could not create one — skipping AZ."; continue; }
    info "Created default subnet ${sn} in ${az}"
  fi
  AZ_LIST+=("$az"); SUBNETS+=("$sn")
done
(( ${#AZ_LIST[@]} )) || die "No usable default subnets for ${INSTANCE_TYPE}."
success "AZs: ${AZ_LIST[*]}"

SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "OpenVPN UDP + SSH" --vpc-id "$VPC_ID" --query GroupId --output text)
fi

authorize_ingress() {  # proto port cidr — ignores duplicate rules
  local out
  if ! out=$(aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol "$1" --port "$2" --cidr "$3" 2>&1); then
    grep -q 'InvalidPermission.Duplicate' <<<"$out" || die "$out"
  fi
}
authorize_ingress udp "$VPN_PORT" 0.0.0.0/0
authorize_ingress tcp 22 "$SSH_CIDR"
success "Security group: $SG_ID (UDP ${VPN_PORT}, TCP 22 from ${SSH_CIDR})"

KEY_EXISTS=$(aws ec2 describe-key-pairs --filters Name=key-name,Values="$KEY_NAME" \
  --query 'length(KeyPairs)' --output text)

if [[ "$KEY_CHOICE" == 1 ]]; then
  if [[ "$KEY_EXISTS" != 0 ]]; then
    [[ -f "$KEY_FILE" ]] \
      || die "Key pair '${KEY_NAME}' exists but ${KEY_FILE} is missing. Delete it (aws ec2 delete-key-pair --key-name ${KEY_NAME}) or choose option 2."
    warn "Reusing existing key pair '${KEY_NAME}' (${KEY_FILE})."
  else
    aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
      --query KeyMaterial --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    success "Key pair created, private key saved to ${KEY_FILE}"
  fi
else
  [[ "$KEY_EXISTS" == 0 ]] || aws ec2 delete-key-pair --key-name "$KEY_NAME"
  printf '%s\n' "$PUBKEY" > "$TMP_DIR/key.pub"
  aws ec2 import-key-pair --key-name "$KEY_NAME" \
    --public-key-material "fileb://$TMP_DIR/key.pub" >/dev/null
  success "Public key imported as '${KEY_NAME}'."
fi

# =============================================================================
# 3. BOOTSTRAP INSTANCE
# =============================================================================
header "Bootstrap instance"

AMI_BASE=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}" \
  --query Parameter.Value --output text)
success "Base AMI (AL2023 ${ARCH}): $AMI_BASE"

# user-data: run setup non-interactively, report to serial console, power off
PAYLOAD=$(gzip -9c "$SETUP_SCRIPT" | base64 -w0)
USERDATA_FILE="$TMP_DIR/user-data.sh"
cat > "$USERDATA_FILE" <<EOF
#!/bin/bash
set -o pipefail
export OVPN_NONINTERACTIVE=1
export VPN_PORT=$(printf %q "$VPN_PORT")
export VPN_SUBNET=$(printf %q "$VPN_SUBNET")
export CLIENT_NAMES=$(printf %q "$CLIENT_NAMES")
export VPN_REMOTE=$(printf %q "${VPN_REMOTE:-}")
export FREEDNS_URL=$(printf %q "${FREEDNS_URL:-}")
echo '${PAYLOAD}' | base64 -d | gunzip > /root/ovpn-server-setup.sh
if bash /root/ovpn-server-setup.sh 2>&1 | tee /var/log/ovpn-setup.log; then R=OK; else R=FAIL; fi
for d in /dev/console /dev/kmsg; do echo "OVPN_SETUP_RESULT=\$R" > \$d 2>/dev/null || true; done
sync
poweroff
EOF
(( $(wc -c < "$USERDATA_FILE") < 16000 )) || die "user-data exceeds the 16 KB limit."

# Try every AZ with the primary type, then every AZ with each fallback type
INSTANCE_ID=""
for t in "${INSTANCE_TYPES[@]}"; do
  for i in "${!SUBNETS[@]}"; do
    if OUT=$(aws ec2 run-instances \
        --image-id "$AMI_BASE" \
        --instance-type "$t" \
        --key-name "$KEY_NAME" \
        --subnet-id "${SUBNETS[$i]}" \
        --security-group-ids "$SG_ID" \
        --associate-public-ip-address \
        --instance-initiated-shutdown-behavior stop \
        --metadata-options HttpTokens=required,HttpEndpoint=enabled \
        --user-data "file://${USERDATA_FILE}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}-bootstrap}]" \
        --query 'Instances[0].InstanceId' --output text 2>&1); then
      INSTANCE_ID="$OUT"
      break 2
    fi
    grep -qE 'InsufficientInstanceCapacity|Unsupported' <<<"$OUT" || die "$OUT"
    warn "No ${t} capacity in ${AZ_LIST[$i]} — trying next."
  done
done
[[ -n "$INSTANCE_ID" ]] || die "No capacity for ${INSTANCE_TYPES[*]} in any AZ. Re-run later."
success "Launched ${INSTANCE_ID} (${t}) in ${AZ_LIST[$i]}"

info "Waiting for setup to finish and the instance to power off (~5–15 min)..."
DEADLINE=$((SECONDS + BOOTSTRAP_TIMEOUT_MIN * 60))
while :; do
  STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)
  [[ "$STATE" == "stopped" ]] && break
  (( SECONDS < DEADLINE )) || die "Timed out (state: ${STATE}). Inspect: aws ec2 get-console-output --instance-id ${INSTANCE_ID} --output text"
  printf '.'; sleep 20
done
echo

RESULT=""
for _ in {1..12}; do
  RESULT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" \
    --query Output --output text 2>/dev/null \
    | grep -ao 'OVPN_SETUP_RESULT=[A-Z]*' | tail -1 || true)
  [[ -n "$RESULT" ]] && break
  sleep 10
done

case "$RESULT" in
  *=OK)   success "Server setup completed." ;;
  *=FAIL) die "Server setup failed. Instance ${INSTANCE_ID} left stopped for debugging:
          aws ec2 get-console-output --instance-id ${INSTANCE_ID} --output text
          Clean up: aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}" ;;
  *)      warn "Could not confirm the setup result from the console output."
          ask "Bake the AMI anyway? [y/N]:" CONT
          [[ "${CONT:-n}" =~ ^[Yy]$ ]] || die "Aborted. Instance ${INSTANCE_ID} left stopped." ;;
esac

# =============================================================================
# 4. AMI
# =============================================================================
header "Baking AMI"

AMI_NAME="${NAME}-$(date -u +%Y%m%d-%H%M)"
AMI_ID=$(aws ec2 create-image --instance-id "$INSTANCE_ID" --name "$AMI_NAME" \
  --description "OpenVPN server (${VPN_PORT}/udp)" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}}]" \
                       "ResourceType=snapshot,Tags=[{Key=Name,Value=${AMI_NAME}}]" \
  --query ImageId --output text)
info "Waiting for ${AMI_ID} to become available..."
while :; do
  AMI_STATE=$(aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].State' --output text)
  [[ "$AMI_STATE" == "available" ]] && break
  [[ "$AMI_STATE" == "failed" ]] && die "AMI creation failed."
  printf '.'; sleep 20
done
echo
success "AMI ready: ${AMI_ID} (${AMI_NAME})"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
success "Bootstrap instance ${INSTANCE_ID} terminated."

# =============================================================================
# 5. LAUNCH TEMPLATE + ASG (no subnet pinned → default subnets in every AZ)
# =============================================================================
header "Launch template & Auto Scaling group"

LT_DATA=$(cat <<EOF
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEY_NAME}",
  "NetworkInterfaces": [{
    "DeviceIndex": 0,
    "AssociatePublicIpAddress": true,
    "DeleteOnTermination": true,
    "Groups": ["${SG_ID}"]
  }],
  "MetadataOptions": { "HttpTokens": "required", "HttpEndpoint": "enabled" },
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [{ "Key": "Name", "Value": "${NAME}" }]
  }]
}
EOF
)

LT_EXISTS=$(aws ec2 describe-launch-templates \
  --filters Name=launch-template-name,Values="$LT_NAME" \
  --query 'length(LaunchTemplates)' --output text)
if [[ "$LT_EXISTS" == 0 ]]; then
  aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
    --launch-template-data "$LT_DATA" >/dev/null
else
  LT_VER=$(aws ec2 create-launch-template-version --launch-template-name "$LT_NAME" \
    --launch-template-data "$LT_DATA" \
    --query LaunchTemplateVersion.VersionNumber --output text)
  aws ec2 modify-launch-template --launch-template-name "$LT_NAME" \
    --default-version "$LT_VER" >/dev/null
fi
success "Launch template: ${LT_NAME}"

# On-Demand only; overrides are tried in list order (primary first, then fallbacks)
OVERRIDES=$(printf '{"InstanceType":"%s"},' "${INSTANCE_TYPES[@]}")
MIXED_POLICY=$(cat <<EOF
{
  "LaunchTemplate": {
    "LaunchTemplateSpecification": { "LaunchTemplateName": "${LT_NAME}", "Version": "\$Default" },
    "Overrides": [${OVERRIDES%,}]
  },
  "InstancesDistribution": {
    "OnDemandAllocationStrategy": "prioritized",
    "OnDemandBaseCapacity": 0,
    "OnDemandPercentageAboveBaseCapacity": 100
  }
}
EOF
)

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --mixed-instances-policy "$MIXED_POLICY" \
  --min-size 0 --max-size 1 --desired-capacity 1 \
  --availability-zones "${AZ_LIST[@]}" \
  --health-check-type EC2 --health-check-grace-period 300 \
  --tags "Key=Name,Value=${NAME},PropagateAtLaunch=true"
success "ASG: ${ASG_NAME} (min 0 / max 1 / desired 1; types: ${INSTANCE_TYPES[*]})"

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name "$ASG_NAME" --scheduled-action-name "${NAME}-weekly-stop" \
  --recurrence "$SCHED_STOP" --time-zone "$SCHED_TZ" \
  --min-size 0 --max-size 1 --desired-capacity 0
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name "$ASG_NAME" --scheduled-action-name "${NAME}-weekly-start" \
  --recurrence "$SCHED_START" --time-zone "$SCHED_TZ" \
  --min-size 0 --max-size 1 --desired-capacity 1
success "Schedule: stop '${SCHED_STOP}', start '${SCHED_START}' (${SCHED_TZ})"

info "Waiting for the ASG instance to come up..."
ASG_IID="None"
for _ in {1..40}; do
  ASG_IID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
    --output text)
  [[ "$ASG_IID" != "None" ]] && break
  printf '.'; sleep 15
done
echo
[[ "$ASG_IID" != "None" ]] || die "ASG instance not InService yet. Check the EC2 console."
aws ec2 wait instance-running --instance-ids "$ASG_IID"
read -r SERVER_IP SERVER_TYPE < <(aws ec2 describe-instances --instance-ids "$ASG_IID" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,InstanceType]' --output text)
success "Server instance ${ASG_IID} (${SERVER_TYPE}) at ${SERVER_IP}"

# =============================================================================
# 6. FETCH CLIENT PROFILES INTO CLOUDSHELL HOME (for Actions → Download file)
# =============================================================================
# Uses EC2 Instance Connect (preinstalled on AL2023): a throwaway key pushed for
# 60 s, so this works for both key choices without the private key in CloudShell.
FETCHED=()
if [[ -n "$CLIENT_NAMES" ]]; then
  header "Fetching client profiles"

  ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/eic"
  mkdir -p "$TMP_DIR/profiles"

  # SSH_CIDR may exclude CloudShell — open TCP 22 to CloudShell's IP temporarily
  TEMP_CIDR=""
  CS_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com || true)
  if [[ "$SSH_CIDR" != "0.0.0.0/0" && -n "$CS_IP" && "${CS_IP}/32" != "$SSH_CIDR" ]]; then
    TEMP_CIDR="${CS_IP}/32"
    authorize_ingress tcp 22 "$TEMP_CIDR"
  fi

  SSH_OPTS=(-i "$TMP_DIR/eic" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o ConnectTimeout=10 -o LogLevel=ERROR)
  for _ in {1..12}; do   # sshd may still be starting
    if aws ec2-instance-connect send-ssh-public-key --instance-id "$ASG_IID" \
         --instance-os-user ec2-user --ssh-public-key "file://$TMP_DIR/eic.pub" >/dev/null \
       && scp -q "${SSH_OPTS[@]}" "ec2-user@${SERVER_IP}:ovpn/*.ovpn" "$TMP_DIR/profiles/"; then
      break
    fi
    printf '.'; sleep 10
  done
  echo

  [[ -z "$TEMP_CIDR" ]] || aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$TEMP_CIDR" >/dev/null || true

  for f in "$TMP_DIR"/profiles/*.ovpn; do
    [[ -e "$f" ]] || continue
    # 'remote' points at the terminated bootstrap instance unless VPN_REMOTE was set
    [[ -n "${VPN_REMOTE:-}" ]] || sed -i "s/^remote .*/remote ${SERVER_IP} ${VPN_PORT}/" "$f"
    install -m 600 "$f" "$HOME/$(basename "$f")"
    FETCHED+=("$HOME/$(basename "$f")")
  done

  if (( ${#FETCHED[@]} )); then
    success "Saved ${#FETCHED[@]} profile(s) to ${HOME}"
  else
    warn "Could not fetch profiles via EC2 Instance Connect. Use the scp command below instead."
  fi
fi

# =============================================================================
# 7. NEXT STEP — download
# =============================================================================
header "Setup complete"

REMOTE_HOST="${VPN_REMOTE:-$SERVER_IP}"
if [[ "$KEY_CHOICE" == 1 ]]; then SCP_KEY="${KEY_NAME}.pem"; else SCP_KEY="~/.ssh/<your-key>"; fi

if [[ -z "$CLIENT_NAMES" ]]; then
  warn "No client profiles generated. See README → Managing client certificates."
elif (( ${#FETCHED[@]} )); then
  echo
  echo "  CloudShell → Actions → Download file, one path at a time:"
  echo
  printf '     %s\n' "${FETCHED[@]}"
  echo
  warn "Profiles contain private keys — delete them from CloudShell after downloading:  rm ~/*.ovpn"
else
  echo
  echo "  On your machine:"
  echo
  FIXUP=""
  [[ -n "${VPN_REMOTE:-}" ]] || FIXUP=" && sed -i.bak 's/^remote .*/remote ${SERVER_IP} ${VPN_PORT}/' *.ovpn"
  echo "     scp -o StrictHostKeyChecking=accept-new -i ${SCP_KEY} 'ec2-user@${REMOTE_HOST}:ovpn/*.ovpn' .${FIXUP}"
fi
if [[ "$KEY_CHOICE" == 1 ]]; then
  echo
  info "SSH key for later admin/scp: download ${KEY_FILE} too (Actions → Download file)."
fi
echo
[[ -n "${VPN_REMOTE:-}" ]] || warn "The public IP changes whenever the ASG replaces the instance — point 'remote' at your FreeDNS hostname (README)."
warn "Changes made on the running instance (new clients, revocations, crontab) are lost on the next weekly replacement unless you re-bake the AMI (README)."
echo
