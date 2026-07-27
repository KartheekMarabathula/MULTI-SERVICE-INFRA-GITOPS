variable "aws_region" {
  type        = string
  default     = "ap-south-1"
  description = "AWS Repository region for the environment"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., dev, staging, prod)"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC IP range for the environment"
}

variable "cluster_name" {
  type        = string
  description = "EKS Cluster name"
}

variable "eks_instance_types" {
  type        = list(string)
  description = "EKS worker nodes to use for the environment"
}

variable "node_min_size" {
  type        = number
  description = "Minimum number of nodes to maintain in the cluster"
}

variable "node_max_size" {
  type        = number
  description = "Maximum number of nodes to scale the cluster to"
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of nodes to maintain in the cluster"
}
