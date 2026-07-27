aws_region         = "ap-south-1" 
environment        = "dev"
vpc_cidr           = "10.0.0.0/16"
cluster_name       = "Dev-Multi-service-eks-cluster"
eks_instance_types = ["t3.micro"] 
node_min_size      = 1
node_desired_size  = 1
node_max_size      = 1
