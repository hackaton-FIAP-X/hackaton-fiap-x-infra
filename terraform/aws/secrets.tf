# Segredos da aplicacao que precisam ser ESTAVEIS entre deploys. Gerados aqui e
# guardados no estado do Terraform (bucket S3 criptografado), em vez de no
# infra/.env de quem roda: o deploy pelo CD nao tem esse arquivo, e gerar de novo
# a cada deploy quebraria as senhas ja cadastradas (pepper) e os tokens ja
# emitidos (chave do JWT). Somem junto com o ambiente no `terraform destroy`.

resource "random_password" "pepper" {
  length  = 48
  special = false
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

# Par RSA que assina os JWT (AUTH-3) e e publicado na JWKS (AUTH-4)
resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  # O JwtKeyConfig do auth-service le Base64 de DER em uma linha: PKCS8 na
  # privada, X509 (SubjectPublicKeyInfo) na publica. O corpo de um PEM ja e esse
  # Base64 — basta tirar cabecalho, rodape e quebras de linha.
  jwt_private_key = replace(replace(replace(tls_private_key.jwt.private_key_pem_pkcs8,
  "-----BEGIN PRIVATE KEY-----", ""), "-----END PRIVATE KEY-----", ""), "\n", "")
  jwt_public_key = replace(replace(replace(tls_private_key.jwt.public_key_pem,
  "-----BEGIN PUBLIC KEY-----", ""), "-----END PUBLIC KEY-----", ""), "\n", "")
}
