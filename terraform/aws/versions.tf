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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Estado remoto num bucket de nome fixo por conta/regiao, criado de forma
  # idempotente por scripts/aws-lib.sh (ensure_state_bucket). Configuracao parcial:
  # o bucket e a regiao chegam por -backend-config no `terraform init`.
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
