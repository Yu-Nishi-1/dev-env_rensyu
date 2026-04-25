terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      }
  }
}

# Configure the AWS Provider
provider "aws" {
  version = "~> 5.0"
  region = "ap-northeast-1"
  default_tags {
        tags = {
            Scope = "SharedPlatform"
            Environment = "common"
            ManagedBy = "terraform"
        }
  }
}