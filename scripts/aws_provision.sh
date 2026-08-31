#!/usr/bin/env bash
# Manual AWS provisioning (no Terraform) — run this from WSL once you have
# the AWS CLI configured (`aws configure`) with an IAM user that has
# EC2 + VPC permissions on a FREE-TIER-ELIGIBLE account.
#
# Sizing: t2.micro (free tier: 750 hrs/month for 12 months), Ubuntu 22.04 LTS,
# 8 GiB gp3 root volume (free tier covers up to 30 GiB EBS).
# Region: change AWS_REGION below if you're not in us-east-1.
#
# This creates:
#   - 1 VPC, 1 public subnet (lb1), 1 private subnet (web/app/db)
#   - An internet gateway + NAT-less setup (private hosts reach the internet
#     for apt via the public subnet's route only if you add a NAT gateway,
#     which is NOT free-tier — instead we pre-stage packages via user-data
#     apt mirror caching, or simply give every host a public IP for the lab
#     and rely on security groups alone for isolation; see notes inline)
#   - 4 security groups enforcing the same tier isolation as the ufw rules
#   - 7 EC2 instances tagged by role
#
# Run with: bash scripts/aws_provision.sh
set -euo pipefail

AWS_REGION="eu-north-1"
AMI_ID="$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text --region "$AWS_REGION")"
KEY_NAME="swiftpay-aws"
INSTANCE_TYPE="t2.micro"

echo "Using AMI: $AMI_ID  (Ubuntu 22.04 LTS, region $AWS_REGION)"

# 1. Keypair (import your existing local pubkey rather than generating a new one)
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ec2 import-key-pair --key-name "$KEY_NAME" \
    --public-key-material fileb://<(ssh-keygen -y -f ~/.ssh/swiftpay_ansible) \
    --region "$AWS_REGION"
  echo "Imported keypair $KEY_NAME from ~/.ssh/swiftpay_ansible"
fi

# 2. VPC + subnet (single AZ is fine for a lab; note this as a SPOF in docs/architecture.md)
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 --region "$AWS_REGION" \
  --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=swiftpay-vpc --region "$AWS_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$AWS_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"

SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.1.0/24 \
  --region "$AWS_REGION" --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch --region "$AWS_REGION"

IGW_ID=$(aws ec2 create-internet-gateway --region "$AWS_REGION" --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$AWS_REGION"

RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$AWS_REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$AWS_REGION"
aws ec2 associate-route-table --subnet-id "$SUBNET_ID" --route-table-id "$RTB_ID" --region "$AWS_REGION"

# NOTE ON REALISM: a proper build puts web/app/db in a private subnet behind
# a NAT gateway (NAT gateways are NOT free-tier and cost ~$0.045/hr). For
# this lab, every host gets a public IP and security groups (below) are the
# real isolation boundary — same effect as the ufw rules, documented as a
# deliberate free-tier trade-off in docs/architecture.md.

# 3. Security groups — mirror the ufw tier-isolation logic exactly
sg() { aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" --region "$AWS_REGION" --query 'GroupId' --output text; }

SG_LB=$(sg swiftpay-lb "SwiftPay load balancer - public 80/443")
SG_WEB=$(sg swiftpay-web "SwiftPay web tier - only from LB")
SG_APP=$(sg swiftpay-app "SwiftPay app tier - only from web")
SG_DB=$(sg swiftpay-db "SwiftPay db tier - only from app + db peers")

aws ec2 authorize-security-group-ingress --group-id "$SG_LB" --region "$AWS_REGION" \
  --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]' \
                    IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]' \
                    IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]'

aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" --region "$AWS_REGION" \
  --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=10.20.0.0/16}]' \
                    IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs="[{GroupId=$SG_LB}]" \
                    IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs="[{GroupId=$SG_LB}]"

aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --region "$AWS_REGION" \
  --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=10.20.0.0/16}]' \
                    IpProtocol=tcp,FromPort=8000,ToPort=8000,UserIdGroupPairs="[{GroupId=$SG_WEB}]"

aws ec2 authorize-security-group-ingress --group-id "$SG_DB" --region "$AWS_REGION" \
  --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=10.20.0.0/16}]' \
                    IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs="[{GroupId=$SG_APP}]" \
                    IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs="[{GroupId=$SG_DB}]"

# 4. Launch instances
launch() {
  local name="$1" sg="$2"
  aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$sg" \
    --region "$AWS_REGION" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=8,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
    --query 'Instances[0].InstanceId' --output text
}

LB1=$(launch lb1 "$SG_LB")
WEB1=$(launch web1 "$SG_WEB")
WEB2=$(launch web2 "$SG_WEB")
APP1=$(launch app1 "$SG_APP")
APP2=$(launch app2 "$SG_APP")
DB1=$(launch db1 "$SG_DB")
DB2=$(launch db2 "$SG_DB")

echo "Waiting for instances to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$LB1" "$WEB1" "$WEB2" "$APP1" "$APP2" "$DB1" "$DB2" --region "$AWS_REGION"

echo ""
echo "== Instance IPs (fill these into inventory/hosts_aws.ini) =="
for pair in "lb1:$LB1" "web1:$WEB1" "web2:$WEB2" "app1:$APP1" "app2:$APP2" "db1:$DB1" "db2:$DB2"; do
  name="${pair%%:*}"; id="${pair##*:}"
  aws ec2 describe-instances --instance-ids "$id" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text \
    | awk -v n="$name" '{print n": public="$1"  private="$2}'
done

echo ""
echo "Next: cp inventory/hosts_aws.ini.example inventory/hosts_aws.ini and fill in the IPs above,"
echo "then: ./bootstrap.sh aws"
echo ""
echo "Remember to terminate everything after your demo to stay inside free tier:"
echo "  aws ec2 terminate-instances --instance-ids $LB1 $WEB1 $WEB2 $APP1 $APP2 $DB1 $DB2 --region $AWS_REGION"
