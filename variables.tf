# Non-secret stack configuration.
#
# These are deliberately Terraform variables rather than Secrets Manager keys.
# Reading them from a secret would force `terraform plan` to call
# secretsmanager:GetSecretValue, which writes the whole secret bundle -- the
# Grafana passwords and the git deploy key included -- into the state file and
# into any CI plan output. Only the true secrets stay in Secrets Manager, and
# the instance fetches those itself at boot via its IAM role (user_data.tpl).
#
# Every value below carries a placeholder default so `terraform plan` runs on a
# fresh checkout. Override them in a terraform.tfvars (gitignored) or with
# -var. None of these is secret.

variable "secret_name" {
  description = "Secrets Manager secret holding the Grafana passwords and the git deploy key. Read by the instance role at boot, never by terraform plan."
  type        = string
  default     = "/example/dev/lgtm-stack"
}

variable "vpc_id" {
  description = "VPC the LGTM stack's public subnet is created in."
  type        = string
  default     = "vpc-0123456789abcdef0"
}

variable "subnet_cidr" {
  description = "CIDR for the dedicated LGTM public subnet. Must be free inside the VPC."
  type        = string
  default     = "10.0.200.0/24"
}

variable "availability_zone" {
  description = "AZ for the LGTM subnet. Pick one that offers your chosen instance_type -- not every AZ carries every family."
  type        = string
  default     = "us-east-1a"
}

variable "internet_gateway_id" {
  description = "Internet gateway of the VPC. Used to find the public route table."
  type        = string
  default     = "igw-0123456789abcdef0"
}

variable "instance_type" {
  description = "EC2 instance type for the LGTM host. Loki, Tempo and Mimir are memory-hungry; 16 GB is the practical floor."
  type        = string
  default     = "t3a.xlarge"
}

variable "domain_name" {
  description = "Public Grafana hostname. Also the Route53 A-record name."
  type        = string
  default     = "grafana.example.com"
}

variable "public_zone_name" {
  description = "Existing public Route53 hosted zone that contains domain_name."
  type        = string
  default     = "example.com"
}

variable "internal_zone_name" {
  description = "Private hosted zone created for VPC-internal OTLP service discovery."
  type        = string
  default     = "internal.example.com"
}

variable "certbot_email" {
  description = "Contact address for Let's Encrypt expiry notices."
  type        = string
  default     = "devops@example.com"
}

variable "ssh_public_key_pair_name" {
  description = "Name of an existing EC2 key pair. Kept for break-glass console access; routine access is via SSM Session Manager."
  type        = string
  default     = "lgtm-stack-ssh-key"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed SSH ingress. Referenced only by the commented break-glass rule in main.tf. Never widen this to 0.0.0.0/0."
  type        = string
  default     = "127.0.0.1/32"
}

# Ports are declared as number so the security-group from_port/to_port values
# are numeric without coercion.

variable "grafana_port" {
  description = "Grafana HTTP port."
  type        = number
  default     = 3000
}

variable "otlp_http_port" {
  description = "OTLP HTTP receiver port."
  type        = number
  default     = 4318
}

variable "otlp_grpc_port" {
  description = "OTLP gRPC receiver port."
  type        = number
  default     = 4317
}

variable "tempo_http_port" {
  description = "Tempo HTTP port."
  type        = number
  default     = 3200
}
