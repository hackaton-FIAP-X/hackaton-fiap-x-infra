# Override para testar o stack terraform/aws contra o Floci (emulador AWS local,
# http://localhost:4566). NAO fica em terraform/aws: scripts/tf-floci.sh copia o
# stack para um diretorio temporario e adiciona este arquivo la. O Terraform
# mescla *_override.tf por cima da configuracao original.

terraform {
  backend "local" {}
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2         = "http://localhost:4566"
    eks         = "http://localhost:4566"
    ecr         = "http://localhost:4566"
    rds         = "http://localhost:4566"
    elasticache = "http://localhost:4566"
    iam         = "http://localhost:4566"
    sts         = "http://localhost:4566"
  }
}

# O Floci nao implementa a API de addons do EKS (CreateAddon da 404)
variable "enable_ebs_csi" {
  default = false
}
