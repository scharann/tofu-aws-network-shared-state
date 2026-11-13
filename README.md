# OpenTofu AWS Network (Shared State Collision Lab)

## Purpose & Problem Being Solved
This repository provisions foundational AWS networking infrastructure (VPC, public/private subnets, Internet Gateway, and route tables) in `ap-southeast-2` and intentionally shares a **single S3 state file key** (`shared-collision/terraform.tfstate`) with `tofu-aws-compute-shared-state`.

**The Problem Demonstrated:**
In multi-repository OpenTofu/Terraform architectures, teams sometimes mistakenly configure multiple root modules to write to the exact same remote state file. Because OpenTofu treats the state file as a single root module's exclusive memory, running `tofu apply` from a second repository causes OpenTofu to view this network stack's resources as "deleted from code"—triggering destructive deletion races and state corruption.

## Architecture & Shared State Key
- **Region:** `ap-southeast-2`
- **Backend Bucket:** `<YOUR-S3-BUCKET-NAME>`
- **Shared State Key:** `shared-collision/terraform.tfstate` *(Intentionally collides with the compute repository)*
- **Lock Table:** `tofu-lab-locks`

## How to Run (Step 1 of the Lab)
1. Ensure your AWS SSO session is active (`aws sso login` and `export AWS_PROFILE=|YOUR-PROFILE>`).
2. Initialize and deploy the network layer first:
   ```bash
   tofu init
   tofu apply
   ```
3. **Verify Deployment:**
   - Run `tofu state list` — confirms 8 network resources (`aws_vpc.main`, 4 subnets, `aws_internet_gateway.igw`, route tables/associations) are tracked.
   - Run `tofu output` — confirms `vpc_id` and `public_subnet_ids` are exported into `shared-collision/terraform.tfstate`.

## Expected Errors When Compute Applies Next
Once you run `tofu apply` in `tofu-aws-compute-shared-state` against this same state key:
1. **Parallel Destruction Race:** OpenTofu attempts to destroy the 8 network resources while simultaneously creating the EC2 security group and instance inside them.
2. **`DependencyViolation` Loop on `aws_vpc.main`:** Because `aws_security_group.ec2_sg` is created inside `vpc-xxxxxxxx` before the VPC finishes deleting, AWS rejects `DeleteVpc` with:
   ```text
   api error DependencyViolation: The vpc 'vpc-xxxxxxxx' has dependencies and cannot be deleted.
   ```
3. **State Overwrite & Output Loss:** Even after `aws_vpc.main` fails to delete, OpenTofu overwrites `shared-collision/terraform.tfstate` with the compute repo's state—wiping out `vpc_id` and `public_subnet_ids` and stranding `aws_vpc.main` in the state file without its subnets or IGW.

## How to Clean Up Stranded Resources
Because the shared state file becomes corrupted after the collision, clean up using these steps:

1. **Inspect remaining tracked resources (in `tofu-aws-compute-shared-state`)��   ```bash
   tofu state list
   ```
2. **Remove leftover resources from OpenTofu state tracking:** 
   ```bash
   tofu state rm aws_security_group.ec2_sg aws_vpc.main
   ```
3. **Delete the stranded Security Group and VPC in AWS (`ap-southeast-2`):**
   ```bash
   aws ec2 delete-security-group --group-id <SG-ID> --region ap-southeast-2
   aws ec2 delete-vpc --vpc-id <VPC-ID> --region ap-southeast-2
   ```
4. **Verify Complete Cleanup:**
   - Run `tofu state list` — returns zero managed resources.
   - Run `aws ec2 describe-vpcs --region ap-southeast-2` — confirms the lab VPC no longer exists.
   - If finished with all labs, empty and delete the S3 state bucket and delete the `tofu-lab-locks` DynamoDB table.
