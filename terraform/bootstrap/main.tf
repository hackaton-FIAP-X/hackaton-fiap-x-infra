# Bucket do estado remoto do Terraform (roda UMA vez por conta/regiao).
#
# O estado deste proprio stack fica local (terraform.tfstate, git-ignored): e so
# um bucket, e um estado remoto para criar o estado remoto seria circular.
#
#   cd terraform/bootstrap && terraform init && terraform apply
#   -> anote o output `state_bucket` e use em terraform/aws/backend.hcl

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
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "fiapx"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

variable "region" {
  description = "Regiao AWS. No Learner Lab so us-east-1 e us-west-2 estao liberadas."
  type        = string
  default     = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "state" {
  # nome global unico: conta + sufixo aleatorio
  bucket = "fiapx-tfstate-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"

  # Ambiente de demo que sobe e destroi: permitir apagar o bucket com o estado
  # dentro evita recurso orfao consumindo o credito do Learner Lab.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  description = "Use em terraform/aws/backend.hcl (bucket = ...)"
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
