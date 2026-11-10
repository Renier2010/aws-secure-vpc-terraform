# Secure VPC on AWS with Terraform

A small network lab built with Terraform: a VPC with a public subnet (bastion host) and a private subnet (internal host with no internet route), protected by security groups and network ACLs.

## Architecture
Internet -> Internet Gateway -> Public subnet (10.0.1.0/24, bastion)
                                        |
                                        v  SSH only
                              Private subnet (10.0.2.0/24, no internet route)

## What it demonstrates
- Custom VPC, public/private subnets, route tables and internet gateway
- Security groups: SSH to the bastion from one IP only; the private host accepts SSH only from the bastion's security group
- Network ACLs (stateless), including the ephemeral-port return rules they require
- Hardening: IMDSv2 required, encrypted EBS volumes
- No NAT Gateway, to keep the lab free of ongoing costs

## Usage
    terraform init
    terraform plan  -var="my_ip_cidr=<your-ip>/32"
    terraform apply -var="my_ip_cidr=<your-ip>/32"
    # test, then:
    terraform destroy -var="my_ip_cidr=<your-ip>/32"

Requires an AWS account, the AWS CLI configured, and an SSH key at ~/.ssh/id_ed25519.pub. Region: eu-north-1.

## Tests I ran
- SSH to the bastion from my IP: works
- SSH to the private host through the bastion (ssh -J): works
- curl from the private host: times out (no internet route)
- Direct SSH to the private IP: fails (not reachable from outside the VPC
- Changed the bastion security group to a different IP: SSH blocked; restored with terraform apply

## What I learned
[Two or three sentences in your own words, e.g. the difference between stateful security groups and stateless NACLs, and what you saw when you broke the rule on purpose.]
