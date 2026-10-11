terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "local" {
    path = "bootstrap.tfstate"
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "gha_deploy" {
  name = "sentinel-leoblackbeard-gha-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # GitHub emite el sub con los IDs inmutables del dueño y del repo
        # (repo:<owner>@<owner_id>/<repo>@<repo_id>:...). Se acepta también el
        # formato clásico por compatibilidad. IDs: leoblackbeard = 316173717,
        # Sentinel_Sandbox = 1412442294 (API de GitHub).
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:leoblackbeard@316173717/Sentinel_Sandbox@1412442294:*",
            "repo:leoblackbeard/Sentinel_Sandbox:*",
          ]
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# Policy inline #1 — infra regional, espejo escopeado de Candidates_Policy
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "gha_deploy_infra" {
  name = "sentinel-gha-infra-scoped"
  role = aws_iam_role.gha_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RegionLockedInfra"
        Effect = "Allow"
        Action = [
          "ec2:*", "eks:*", "elasticloadbalancing:*",
          "ecr:*", "autoscaling:*", "cloudwatch:*",
          "route53:*", "s3:*"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = "eu-central-1" } }
      },
      {
        Sid      = "DenyPolicyCreation"
        Effect   = "Deny"
        Action   = ["iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Policy inline #2 — ciclo de vida y PassRole escopeado a los 4 roles EKS
# ---------------------------------------------------------------------------
locals {
  eks_cluster_role_arns = [
    "arn:aws:iam::721500739616:role/eks-eks-gateway-cluster-role",
    "arn:aws:iam::721500739616:role/eks-eks-backend-cluster-role",
  ]
  eks_node_role_arns = [
    "arn:aws:iam::721500739616:role/eks-eks-gateway-node-role",
    "arn:aws:iam::721500739616:role/eks-eks-backend-node-role",
  ]
  # Roles del AWS Load Balancer Controller (EKS Pod Identity), uno por cluster
  eks_lbc_role_arns = [
    "arn:aws:iam::721500739616:role/eks-eks-gateway-lbc-role",
    "arn:aws:iam::721500739616:role/eks-eks-backend-lbc-role",
  ]
  managed_eks_role_arns = concat(local.eks_cluster_role_arns, local.eks_node_role_arns, local.eks_lbc_role_arns)

  managed_aws_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]
}

resource "aws_iam_role_policy" "eks_role_lifecycle" {
  name = "eks-role-lifecycle"
  role = aws_iam_role.gha_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAMRoleLifecycleScoped"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies"
        ]
        Resource = local.managed_eks_role_arns
      },
      {
        Sid      = "ReadManagedPolicyMetadata"
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
        Resource = local.managed_aws_policy_arns
      },
      {
        Sid      = "PassRoleClusterOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.eks_cluster_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "eks.amazonaws.com" }
        }
      },
      {
        Sid      = "PassRoleNodeOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.eks_node_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid      = "PassRoleLbcPodIdentity"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.eks_lbc_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "pods.eks.amazonaws.com" }
        }
      }
    ]
  })
}

output "gha_deploy_role_arn" {
  value       = aws_iam_role.gha_deploy.arn
  description = "Rol asumido por GitHub Actions vía OIDC federation"
}
