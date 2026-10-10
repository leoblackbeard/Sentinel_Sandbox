#resource "aws_ec2_tag" "cluster_subnet_tag" {
#  count       = length(var.private_subnet_ids)
#  resource_id = var.private_subnet_ids[count.index]
#  key         = "kubernetes.io/cluster/${var.cluster_name}"
#  value       = "shared"
#}

# IAM Role: Cluster
resource "aws_iam_role" "cluster" {
  name = "eks-${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# IAM Role: Node Group
resource "aws_iam_role" "node" {
  name = "eks-${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_node_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Security Group del cluster
resource "aws_security_group_rule" "allow_peer_cidr" {
  for_each = toset(var.allowed_peer_cidr_blocks)

  type              = "ingress"
  from_port         = var.allowed_peer_port
  to_port           = var.allowed_peer_port
  protocol          = "tcp"
  cidr_blocks       = [each.value]
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id

  description = "Allow TLS (443) from peered VPC CIDR"
}

# EKS Cluster
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]

  tags = var.tags
}

# Node Group
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "eks-${var.cluster_name}-ng-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  instance_types = var.instance_type

  depends_on = [
    aws_iam_role_policy_attachment.worker_node_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy
  ]

  tags = var.tags
}

resource "aws_eks_access_entry" "gha" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.gha_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.gha_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.gha]
}
