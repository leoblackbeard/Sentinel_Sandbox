output "vpc_gateway_id" {
  value = module.vpc_gateway.vpc_id
}

output "vpc_backend_id" {
  value = module.vpc_backend.vpc_id
}

output "eks_backend_cluster_name" {
  description = "Name of the backend EKS cluster"
  value       = module.eks_backend.cluster_name
}

output "eks_gateway_cluster_name" {
  description = "Name of the gateway EKS cluster"
  value       = module.eks_gateway.cluster_name
}

output "eks_gateway_endpoint" {
  value = module.eks_gateway.cluster_endpoint
}

output "eks_backend_endpoint" {
  value = module.eks_backend.cluster_endpoint
}

output "vpc_peering_connection_id" {
  value = module.peering.peering_connection_id
}
