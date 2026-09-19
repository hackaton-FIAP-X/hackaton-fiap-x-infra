terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Estado remoto no bucket criado por terraform/bootstrap. Configuracao parcial:
  #   terraform init -backend-config=backend.hcl
  # use_lockfile (Terraform >= 1.10) faz o lock no proprio S3, sem DynamoDB.
  backend "s3" {
    key          = "fiapx/aws/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "aws"
    }
  }
}
