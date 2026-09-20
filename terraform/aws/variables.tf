variable "project" {
  description = "Prefixo dos nomes dos recursos."
  type        = string
  default     = "fiapx"
}

variable "region" {
  description = "Regiao AWS. No Learner Lab so us-east-1 e us-west-2 estao liberadas."
  type        = string
  default     = "us-east-1"
}

variable "lab_role_name" {
  description = <<-EOT
    Papel IAM pre-existente usado pelo cluster EKS e pelos nos. O AWS Academy
    Learner Lab nao permite criar IAM; ele ja fornece o LabRole.
  EOT
  type        = string
  default     = "LabRole"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "eks_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_type" {
  description = "t3.large: 2 vCPU/8 GiB — cabe os 3 servicos, o HPA do worker e a observabilidade."
  type        = string
  default     = "t3.large"
}

variable "node_count" {
  description = "Nos do node group (min = desired). O maximo e o dobro, para o HPA ter para onde crescer. 3 nos: com 2 o RabbitMQ nao cabia no no da AZ do volume EBS dele."
  type        = number
  default     = 3
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "cache_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "enable_ebs_csi" {
  description = "Instala o addon aws-ebs-csi-driver (volume do RabbitMQ). So o Floci desliga: ele nao emula addons"
  type        = bool
  default     = true
}
