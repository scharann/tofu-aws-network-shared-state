# End-to-End Lab Test & Cleanup Guide (Shared State Collision Lab)

## Purpose
This runbook walks through testing the cloned `tofu-aws-network-shared-state` and `tofu-aws-compute-shared-state` repositories end-to-end—demonstrating what happens when two root modules share a single S3 state key (`shared-collision/terraform.tfstate`) and how to recover and clean up stranded AWS resources after state corruption.

---

## Step 1: Authenticate AWS CLI & Create Backend Prerequisites

1. **Export your AWS profile and verify active SSO credentials:**
~~~bash
export AWS_PROFILE=<YOUR-PROFILE-NAME>
aws sts get-caller-identity || aws sso login
~~~

2. **Confirm the S3 bucket name and shared state key configured in `backend.tf`:**
~~~bash
grep -E "bucket|key" tofu-aws-network-shared-state/backend.tf tofu-aws-compute-shared-state/backend.tf
~~~
*Expected:* Both files point to the exact same `<YOUR-S3-BUCKET-NAME>` and `key = "shared-collision/terraform.tfstate"`.

3. **Create the S3 state bucket (with versioning enabled) and DynamoDB lock table in `ap-southeast-2`:**
~~~bash
aws s3api create-bucket \
  --bucket <YOUR-S3-BUCKET-NAME> \
  --region ap-southeast-2 \
  --create-bucket-configuration LocationConstraint=ap-southeast-2

aws s3api put-bucket-versioning \
  --bucket <YOUR-S3-BUCKET-NAME> \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name tofu-lab-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-2
~~~

4. **Verify both backend prerequisites exist and are ready:**
~~~bash
aws s3 ls s3://<YOUR-S3-BUCKET-NAME>/
aws dynamodb describe-table --table-name tofu-lab-locks --region ap-southeast-2 --query "Table.TableStatus"
~~~
*Expected:* `aws s3 ls` succeeds without errors, and DynamoDB returns `"ACTIVE"`.

---

## Step 2: Deploy & Verify the Network Stack First (`tofu-aws-network-shared-state`)

1. **Navigate to `tofu-aws-network-shared-state` and initialize/apply:**
~~~bash
cd ~/Downloads/Charan/Tofu-Lab-Github-Repositories/tofu-aws-network-shared-state
tofu init
tofu plan
tofu apply -auto-approve
~~~

2. **Verify initial network deployment and S3 state file:**
~~~bash
tofu state list
tofu output
aws s3 ls s3://<YOUR-S3-BUCKET-NAME>/shared-collision/
~~~
*Expected:*
- `tofu state list` tracks all **12 managed network resources** (`aws_vpc.main`, 4 subnets, `aws_internet_gateway.igw`, 2 route tables, and 4 route table associations).
- `tofu output` displays populated `vpc_id`, `public_subnet_ids`, and `private_subnet_ids`.
- `aws s3 ls` confirms `terraform.tfstate` exists under `shared-collision/`.

---

## Step 3: Trigger & Observe the State Collision (`tofu-aws-compute-shared-state`)

1. **Switch to `tofu-aws-compute-shared-state` and re-verify AWS session & backend prerequisites:**
~~~bash
cd ~/Downloads/Charan/Tofu-Lab-Github-Repositories/tofu-aws-compute-shared-state

export AWS_PROFILE=<YOUR-PROFILE-NAME>
aws sts get-caller-identity || aws sso login

aws s3 ls s3://<YOUR-S3-BUCKET-NAME>/
aws dynamodb describe-table --table-name tofu-lab-locks --region ap-southeast-2 --query "Table.TableStatus"
~~~

2. **Initialize and run `tofu plan` (Observe the Destructive Plan):**
~~~bash
tofu init
tofu plan
~~~
*Expected:* OpenTofu reads `vpc_id` and `public_subnet_ids` from `shared-collision/terraform.tfstate`, then plans **`Plan: 2 to add, 0 to change, 12 to destroy`** (and shows all network outputs changing to `-> null`) because it views the 12 network resources in the shared state file as deleted from this repository's `.tf` code.

3. **Run `tofu apply` to observe the live collision:**
~~~bash
tofu apply -auto-approve
~~~
*(Note: `aws_vpc.main` will enter a `DependencyViolation` retry loop trying to delete the VPC while `aws_security_group.ec2_sg` is attached to it. Press **`Ctrl+C`** once after ~30 seconds if you do not want to wait for the full AWS deletion timeout).*

4. **Inspect the corrupted state and verify `tofu destroy` fails:**
~~~bash
tofu state list
tofu plan
~~~
*Expected:*
- `tofu state list` shows **4 entries**: 2 read-only data sources (`data.aws_ami.al2023`, `data.terraform_remote_state.network`) and 2 stranded managed resources (`aws_security_group.ec2_sg`, `aws_vpc.main`)—all subnets, IGW, and route tables are gone.
- `tofu plan` (or `tofu destroy`) crashes with `Error: Unsupported attribute: This object does not have an attribute named "vpc_id"` because the network `outputs` block was erased from `shared-collision/terraform.tfstate`.

---

## Step 4: Recover & Clean Up Stranded AWS Resources

Because `tofu destroy` cannot run against the corrupted state file, clean up using OpenTofu state removal and AWS CLI commands:

1. **Grab the stranded Security Group ID and VPC ID from state before removing them:**
~~~bash
tofu state show aws_security_group.ec2_sg | grep -E "^\s*(id|vpc_id)\s*="
~~~

2. **Remove both stranded managed resources from OpenTofu state tracking:**
~~~bash
tofu state rm aws_security_group.ec2_sg aws_vpc.main
tofu state list
~~~
*Expected:* `tofu state list` shows only the 2 read-only data sources (`data.aws_ami.al2023` and `data.terraform_remote_state.network`) and **zero managed `aws_*` resources**.

3. **Delete the stranded Security Group first, then the VPC in AWS (`ap-southeast-2`):**
~~~bash
aws ec2 delete-security-group --group-id <SG-ID> --region ap-southeast-2
aws ec2 delete-vpc --vpc-id <VPC-ID> --region ap-southeast-2
~~~

4. **Verify your specific lab VPC, Security Group, and EC2 instances are gone in AWS (`ap-southeast-2`):**
~~~bash
aws ec2 describe-vpcs \
  --region ap-southeast-2 \
  --query "Vpcs[?IsDefault==\`false\`].VpcId" | grep -i <VPC-ID>

aws ec2 describe-security-groups \
  --region ap-southeast-2 \
  --query "SecurityGroups[].GroupId" | grep -i <SG-ID>

aws ec2 describe-instances \
  --region ap-southeast-2 \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId"
~~~
*Expected:* Both `grep` checks return no output (exit status 1, confirming `<VPC-ID>` and `<SG-ID>` no longer exist), and `describe-instances` returns `[]`.

5. **(Optional) Remove & Verify the S3 State Bucket and DynamoDB Lock Table:**
If you are completely finished testing and want zero S3/DynamoDB footprint left in AWS:

~~~bash
# 1. Delete all versioned objects inside the S3 bucket
aws s3api delete-objects --bucket <YOUR-S3-BUCKET-NAME> \
  --delete "$(aws s3api list-object-versions --bucket <YOUR-S3-BUCKET-NAME> \
  --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"

# 2. Verify zero object versions remain in the S3 bucket
aws s3api list-object-versions --bucket <YOUR-S3-BUCKET-NAME> --query "Versions"
~~~
*Expected:* Returns `null` (confirming all state file versions have been purged).

~~~bash
# 3. Delete the empty S3 bucket and DynamoDB lock table
aws s3api delete-bucket --bucket <YOUR-S3-BUCKET-NAME> --region ap-southeast-2
aws dynamodb delete-table --table-name tofu-lab-locks --region ap-southeast-2

# 4. Verify both the S3 bucket and DynamoDB table no longer exist
aws s3api head-bucket --bucket <YOUR-S3-BUCKET-NAME> 2>&1 || echo "S3 bucket deleted"
aws dynamodb describe-table --table-name tofu-lab-locks --region ap-southeast-2 2>&1 || echo "DynamoDB table deleted"
~~~
*Expected:* Both verification commands report `Not Found` / `ResourceNotFoundException` and print `"S3 bucket deleted"` and `"DynamoDB table deleted"`.
