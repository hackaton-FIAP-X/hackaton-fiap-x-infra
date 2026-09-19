# EKS usando o LabRole pre-existente (Learner Lab nao deixa criar IAM) tanto
# para o control plane quanto para os nos.

data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

locals {
  cluster_name = var.project
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.eks_version
  role_arn = data.aws_iam_role.lab.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    # quem roda o apply (o papel voclabs do Learner Lab) vira admin do cluster
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_route_table_association.private]
}

# Launch template so para o IMDSv2 com hop limit 2: sem isso os pods nao
# alcancam as credenciais do no, e e delas (LabRole) que o S3 e acessado.
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.project}-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-node" }
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = data.aws_iam_role.lab.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = var.node_count
    desired_size = var.node_count
    max_size     = var.node_count * 2
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  update_config {
    max_unavailable = 1
  }
}
