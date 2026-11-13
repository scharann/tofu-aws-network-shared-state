terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "bucket-722141136946-lab" # Replace with your S3 bucket
    key            = "shared-collision/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "tofu-lab-locks"            # Replace with your DynamoDB table
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}