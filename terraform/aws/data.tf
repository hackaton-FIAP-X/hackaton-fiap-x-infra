# Servicos gerenciados: RDS Postgres, Amazon MQ (RabbitMQ) e ElastiCache Redis.
# Todos em subnets privadas, acessiveis so a partir dos nos do EKS.

resource "aws_security_group" "data" {
  name        = "${var.project}-data"
  description = "Postgres, RabbitMQ (AMQPS) e Redis, liberados so para o EKS"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-data" }
}

locals {
  data_ports = {
    postgres = 5432
    amqps    = 5671
    redis    = 6379
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_eks" {
  for_each                     = local.data_ports
  security_group_id            = aws_security_group.data.id
  description                  = "${each.key} a partir dos nos do EKS"
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_vpc_security_group_egress_rule" "data_all" {
  security_group_id = aws_security_group.data.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- RDS -------

resource "random_password" "db" {
  length  = 24
  special = false # RDS recusa / @ " e espaco; so alfanumerico evita surpresa
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # authdb nasce com a instancia; o videodb e criado por um Job no cluster
  # (k8s/apps/overlays/aws/job-create-databases.yaml)
  db_name  = "authdb"
  username = "fiapx"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.data.id]
  publicly_accessible    = false
  multi_az               = false

  # ambiente de demo: destroy sem snapshot final nem protecao
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  apply_immediately       = true
}

# ---------------------------------------------------------- Amazon MQ -------

resource "random_password" "mq" {
  length  = 24
  special = false # Amazon MQ recusa , : = na senha
}

resource "aws_mq_broker" "rabbitmq" {
  broker_name                = "${var.project}-rabbitmq"
  engine_type                = "RabbitMQ"
  engine_version             = var.mq_engine_version
  host_instance_type         = var.mq_instance_type
  deployment_mode            = "SINGLE_INSTANCE"
  auto_minor_version_upgrade = true

  publicly_accessible = false
  subnet_ids          = [aws_subnet.private[0].id]
  security_groups     = [aws_security_group.data.id]

  user {
    username = "fiapx"
    password = random_password.mq.result
  }
}

# ------------------------------------------------------------- Redis --------

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-cache"
  subnet_ids = aws_subnet.private[*].id
}

# Replication group com 1 no (sem replica): a API moderna do ElastiCache para
# Redis/Valkey. O aws_elasticache_cluster com engine redis e legado.
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project}-redis"
  description          = "Cache da listagem de videos e contador do rate limit do login"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.cache_node_type
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.data.id]
  apply_immediately  = true
}
