# Consumidos por scripts/aws-render.sh para gerar os overlays k8s/*/overlays/aws.

output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "ecr_registry" {
  description = "Registry do ECR (sem o nome do repositorio), para docker login e IMAGE_REGISTRY"
  value       = split("/", aws_ecr_repository.service["auth-service"].repository_url)[0]
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.service : k => r.repository_url }
}

output "db_host" {
  value = aws_db_instance.postgres.address
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_user" {
  value = aws_db_instance.postgres.username
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

# RabbitMQ no cluster (StatefulSet): so as credenciais saem daqui; o host e o
# Service rabbitmq.fiapx.svc.cluster.local:5672, sem TLS (trafego interno).
output "mq_user" {
  value = "fiapx"
}

output "mq_password" {
  value     = random_password.mq.result
  sensitive = true
}

output "redis_host" {
  # primary quando cluster mode esta desligado (nosso caso na AWS); o
  # configuration endpoint cobre cluster mode (e o que o Floci devolve)
  value = coalesce(
    aws_elasticache_replication_group.redis.primary_endpoint_address,
    aws_elasticache_replication_group.redis.configuration_endpoint_address,
  )
}

output "vpc_id" {
  description = "Usado pelo aws-down.sh para esperar os load balancers sairem"
  value       = aws_vpc.main.id
}

output "password_pepper" {
  value     = random_password.pepper.result
  sensitive = true
}

output "jwt_private_key" {
  description = "Base64 de DER PKCS8, formato do JwtKeyConfig"
  value       = local.jwt_private_key
  sensitive   = true
}

output "jwt_public_key" {
  description = "Base64 de DER X509, formato do JwtKeyConfig"
  value       = local.jwt_public_key
  sensitive   = true
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}
