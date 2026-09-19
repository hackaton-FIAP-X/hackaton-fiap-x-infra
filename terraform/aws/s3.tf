# Bucket da aplicacao: videos em fiapx/inputs/..., ZIPs em fiapx/outputs/...
# (layout do video-service, StorageKey). Acesso pelos pods via LabRole dos nos.

data "aws_caller_identity" "current" {}

resource "random_id" "bucket_suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "app" {
  bucket        = "${var.project}-app-${data.aws_caller_identity.current.account_id}-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Videos originais nao precisam ficar para sempre num ambiente de demo
resource "aws_s3_bucket_lifecycle_configuration" "app" {
  bucket = aws_s3_bucket.app.id
  rule {
    id     = "expira-videos-originais"
    status = "Enabled"
    filter {
      prefix = "fiapx/inputs/"
    }
    expiration {
      days = 7
    }
  }
}
