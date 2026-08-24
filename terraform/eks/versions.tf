# =============================================================================
# A SEPARATE ROOT MODULE, AND THE SEPARATION IS THE POINT
# =============================================================================
# The HCL at the repository root builds a single EC2 host that runs the Compose
# stack. This module builds an EKS cluster that runs the Helm chart. They are
# two deployment planes for the same observability stack, and they must be able
# to exist independently.
#
# WHY NOT ADD THESE FILES TO THE ROOT MODULE. OpenTofu applies a root module as
# one graph against one state file. Dropping an EKS cluster in beside the EC2
# host would mean a single `tofu apply` creates or destroys both, a single state
# file records both, and a mistake in one plane can destroy the other. A distinct
# directory with a distinct state key removes that entire class of accident.
#
# NOTHING AT THE REPOSITORY ROOT IS MODIFIED OR REMOVED BY THIS MODULE.
#
# =============================================================================
# THE TOOL IS OpenTofu. RUN `tofu`, NEVER `terraform`.
# =============================================================================
# The Terraform CLI moved to the BUSL-1.1 source-available licence in 2023.
# OpenTofu is the MPL-2.0 fork under the Linux Foundation, and it is what this
# repository already uses: the root .terraform.lock.hcl records providers from
# registry.opentofu.org.
#
# THE PROVIDER SOURCES BELOW ARE NOT A LICENCE PROBLEM, and it is worth stating
# so nobody re-opens the question. Only the CLI changed licence. The providers
# named `hashicorp/...` are still MPL-2.0 open source, and OpenTofu resolves
# them from its own registry. The prefix is a namespace, not a vendor lock.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used only on the IRSA path, to read the OIDC issuer's certificate
    # thumbprint. The Pod Identity path needs no OIDC provider and never
    # instantiates it - which is one more reason it is the default.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # A DISTINCT KEY FROM THE ROOT MODULE'S. Sharing the key would make the two
  # planes overwrite each other's state, which is the worst possible failure:
  # the resources keep running and OpenTofu no longer knows they exist.
  backend "s3" {
    bucket       = "example-terraform-state"
    key          = "lgtm-stack/eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "lgtm-stack"
      Plane     = "kubernetes"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
