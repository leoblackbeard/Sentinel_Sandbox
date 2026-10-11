# ---------------------------------------------------------------------------
# AWS Load Balancer Controller — permisos vía EKS Pod Identity
#
# Los Services en k8s/ usan `aws-load-balancer-type: external`, que solo
# reconcilia el AWS Load Balancer Controller. Sin él, el Service se queda en
# <pending> y el pipeline expira esperando el hostname del NLB.
#
# El chart de Helm lo instala el workflow; aquí solo damos la identidad IAM.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [aws_eks_node_group.default]

  tags = var.tags
}

resource "aws_iam_role" "lbc" {
  name = "eks-${var.cluster_name}-lbc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

# Inline (no iam:CreatePolicy, que el rol de GHA tiene denegado).
# Fuente: kubernetes-sigs/aws-load-balancer-controller docs/install/iam_policy.json
resource "aws_iam_role_policy" "lbc" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.lbc.name
  policy = jsonencode(jsondecode(file("${path.module}/lbc_iam_policy.json")))
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn

  depends_on = [aws_eks_addon.pod_identity_agent, aws_iam_role_policy.lbc]

  tags = var.tags
}
