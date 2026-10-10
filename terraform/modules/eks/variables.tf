variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
}

variable "vpc_id" {
  type        = string
  description = "VPC where nodes are deployed"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EKS nodes"
}

variable "cluster_version" {
  type        = string
  description = "EKS control plane version"
  default     = "1.30"
}

variable "instance_type" {
  type        = list(string)
  description = "EC2 instance type for managed node group"
  default     = ["t3.medium"]
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 3
}

variable "allowed_peer_cidr_blocks" {
  description = "CIDR blocks from peered VPCs allowed to reach this cluster's nodes/pods"
  type        = list(string)
  default     = []
}

variable "allowed_peer_port" {
  description = "TCP ports allowed from peered VPC CIDR"
  type        = number
  default     = 8080
}

variable "gha_role_arn" {
  type        = string
  description = "IAM Role ARN for GitHub Actions OIDC deploy role"
  default     = "arn:aws:iam::721500739616:role/sentinel-leoblackbeard-gha-deploy"
}

variable "tags" {
  type    = map(string)
  default = {}
}
