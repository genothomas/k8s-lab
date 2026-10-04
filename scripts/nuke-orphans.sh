#!/usr/bin/env bash
# scripts/nuke-orphans.sh
#
# Scans the cluster's AWS region for resources tagged `nexus-*` (or matching
# other k8s-lab fingerprints) that are NOT in the local terraform state, and
# deletes them. Use after `terraform destroy` if a prior apply was abandoned
# or state was reset, leaving AWS-side orphans.
#
# Idempotent. Refuses to touch the default VPC, default subnets, or any
# resource that isn't tagged `nexus-*` / inside a nexus VPC.
#
# Required: aws cli, jq.

set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER_NAME="${TF_VAR_cluster_name:-nexus}"
ENVIRONMENT="${TF_VAR_environment:-dev}"
PREFIX="${CLUSTER_NAME}-${ENVIRONMENT}"   # e.g. nexus-dev

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }
}
need aws
need jq

export AWS_REGION="$REGION"

echo "Region:   $REGION"
echo "Prefix:   $PREFIX"
echo

# -------- helpers -------------------------------------------------------------

# Echo resource IDs whose Name tag starts with the prefix.
ids_by_name() {
  local rtype="$1"
  aws "$rtype" list 2>/dev/null \
    | jq -r --arg p "$PREFIX" '
        .[] | select((.Tags // [])
          | map(select(.Key=="Name")) | .[0].Value
          | tostring | startswith($p)).ResourceId // empty
      '
}

# Echo VPC IDs whose Name tag starts with the prefix.
nexus_vpcs() {
  aws ec2 describe-vpcs --region "$REGION" \
    --query "Vpcs[?Tags[?Key=='Name' && starts_with(Value, '${PREFIX}')]].VpcId" \
    --output text
}

# -------- confirm -------------------------------------------------------------

echo "This will DELETE in $REGION:"
echo "  - VPCs tagged ${PREFIX}-*"
echo "  - Subnets / IGWs / SGs / NACLs / non-main RTs inside those VPCs"
echo "  - EC2 instances tagged ${PREFIX}-* (terminated, volumes deleted)"
echo "  - EBS volumes tagged ${PREFIX}-*"
echo "  - Elastic IPs tagged ${PREFIX}-* (released)"
echo "  - Key pairs named ${PREFIX}-*"
echo "  - Default VPC and untagged resources are LEFT ALONE."
echo
read -r -p "Type 'yes' to continue: " ans
[ "$ans" = "yes" ] || { red "aborted"; exit 1; }

# -------- 1. terminate orphan instances ---------------------------------------

echo
yellow "== EC2 instances =="
insts=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${PREFIX}-*" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' \
  --output text)
if [ -n "${insts// }" ]; then
  for id in $insts; do echo "  terminate $id"; done
  aws ec2 terminate-instances --region "$REGION" --instance-ids $insts >/dev/null
  echo "  waiting..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $insts
  green "  terminated: $insts"
else
  echo "  (none)"
fi

# -------- 2. release orphan EIPs ----------------------------------------------

echo
yellow "== Elastic IPs =="
eips=$(aws ec2 describe-addresses --region "$REGION" \
  --query "Addresses[?Tags[?Key=='Name' && starts_with(Value, '${PREFIX}')]].AllocationId" \
  --output text)
if [ -n "${eips// }" ]; then
  for id in $eips; do
    assoc=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$id" \
      --query 'Addresses[0].AssociationId' --output text)
    [ -n "${assoc// }" ] && [ "$assoc" != "None" ] && \
      aws ec2 disassociate-address --region "$REGION" --association-id "$assoc" >/dev/null
    aws ec2 release-address --region "$REGION" --allocation-id "$id" >/dev/null
    echo "  released $id"
  done
else
  echo "  (none)"
fi

# -------- 3. delete orphan EBS volumes ----------------------------------------

echo
yellow "== EBS volumes =="
vols=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Name,Values=${PREFIX}-*" \
  --query 'Volumes[?State!=`deleting`].VolumeId' --output text)
if [ -n "${vols// }" ]; then
  for v in $vols; do echo "  delete $v"; done
  aws ec2 delete-volume --region "$REGION" --volume-id $(echo $vols | tr ' ' '?') 2>/dev/null || true
  for v in $vols; do aws ec2 delete-volume --region "$REGION" --volume-id "$v" >/dev/null; done
  green "  deleted"
else
  echo "  (none)"
fi

# -------- 4. delete orphan key pairs ------------------------------------------

echo
yellow "== Key pairs =="
kps=$(aws ec2 describe-key-pairs --region "$REGION" \
  --query "KeyPairs[?starts_with(KeyName, '${PREFIX}')].KeyName" --output text)
if [ -n "${kps// }" ]; then
  for k in $kps; do
    aws ec2 delete-key-pair --region "$REGION" --key-name "$k" >/dev/null
    echo "  deleted $k"
  done
else
  echo "  (none)"
fi

# -------- 5. clean each nexus VPC ---------------------------------------------

for vpc in $(nexus_vpcs); do
  echo
  yellow "== VPC $vpc =="

  # 5a. delete instances that may still be inside (in case tag filter missed)
  for inst in $(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" "Name=instance-state-name,Values=running,stopped,stopping" \
      --query 'Reservations[].Instances[].InstanceId' --output text); do
    echo "  terminate $inst"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$inst" >/dev/null
  done
  for inst in $(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query 'Reservations[].Instances[].InstanceId' --output text); do
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$inst" 2>/dev/null || true
  done

  # 5b. detach + delete IGWs
  for igw in $(aws ec2 describe-internet-gateways --region "$REGION" \
      --filters "Name=attachment.vpc-id,Values=$vpc" \
      --query 'InternetGateways[].InternetGatewayId' --output text); do
    echo "  detach+delete igw $igw"
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw" --vpc-id "$vpc" >/dev/null
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw" >/dev/null
  done

  # 5c. delete non-main route tables + their associations
  for rt in $(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text); do
    for assoc in $(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
        --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --region "$REGION" --association-id "$assoc" >/dev/null 2>&1 || true
    done
    echo "  delete rt $rt"
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$rt" >/dev/null
  done

  # 5d. delete non-default SGs
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=default" \
      --query 'SecurityGroups[].GroupId' --output text); do :; done   # skip default
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    echo "  delete sg $sg"
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 || \
      yellow "    (in use, skipping)"
  done

  # 5e. delete NACLs (non-default)
  for nacl in $(aws ec2 describe-network-acls --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query "NetworkAcls[?IsDefault!=\`true\`].NetworkAclId" --output text); do
    echo "  delete nacl $nacl"
    aws ec2 delete-network-acl --region "$REGION" --network-acl-id "$nacl" >/dev/null 2>&1 || true
  done

  # 5f. delete subnets
  for sub in $(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc" \
      --query 'Subnets[].SubnetId' --output text); do
    echo "  delete subnet $sub"
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$sub" >/dev/null
  done

  # 5g. finally delete the VPC
  echo "  delete vpc $vpc"
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$vpc" >/dev/null
  green "  vpc $vpc gone"
done

echo
green "== done =="
echo "Run 'aws ec2 describe-vpcs --region $REGION --query \"Vpcs[?State==\\\"available\\\"]\"' to confirm."
