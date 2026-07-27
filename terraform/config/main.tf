
# 1. TERRAFORM & PROVIDERS CONFIGURATION

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
  backend "s3" {} 
}

provider "aws" {
  region = var.aws_region
}


# 2. AWS VPC MODULE 

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "org-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 2), cidrsubnet(var.vpc_cidr, 4, 3)]

  enable_nat_gateway = false
  single_nat_gateway = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }
}


# 3. AWS EKS MODULE 

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access = true
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets 

  eks_managed_node_groups = {
    main = {
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      instance_types = ["t2.micro"] 

      labels = {
        Environment = var.environment
      }
    }
  }

  enable_cluster_creator_admin_permissions = true
}


# 4. AWS ROUTE 53 

resource "aws_route53_zone" "primary" {
  name = "org-${var.environment}.internal" 
}

# 5. KUBERNETES AND HELM PROVIDERS 

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

provider "helm" {
  
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}


# 6. GITOPS CONTROLLER: ARGOCD Installation

resource "helm_release" "argocd" {
  depends_on       = [module.eks]
  name             = "argocd"
  
  repository       = "https://github.io" 
  chart            = "argo-cd"
  version          = "5.51.4"
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  
  set = [
    {
      name  = "server.service.type"
      value = "ClusterIP"
    }
  ]
}


# 7. AWS LOAD BALANCER CONTROLLER

resource "helm_release" "aws_lb_controller" {
  depends_on = [module.eks]
  name       = "aws-load-balancer-controller"
  repository = "https://github.io"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set = [
    {
      name  = "clusterName"
      value = var.cluster_name
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    }
  ]
}

# 8. AUTOSCALER ENGINE: KARPENTER

resource "helm_release" "karpenter" {
  depends_on = [module.eks]
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "0.35.0"
  namespace  = "karpenter"
  create_namespace = true

  set = [
    {
      name  = "settings.clusterName"
      value = var.cluster_name
    }
  ]
}


#  AUTOMATIC ARGOCD ROOT APPLICATIONS (Conditional & 100% Automated)


# 1. DEV UMBRELLA APP
resource "kubernetes_manifest" "dev_umbrella_app" {
 
  count      = var.environment == "dev" ? 1 : 0
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "dev-umbrella-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/KartheekMarabathula/MULTI-SERVICE-INFRA-GITOPS"
        targetRevision = "HEAD"
        path           = "gitops/helm-charts/umbrella-app"
        helm = {
          valueFiles = ["values-dev.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "dev"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}

# 2. TEST UMBRELLA APP
resource "kubernetes_manifest" "test_umbrella_app" {
  
  count      = var.environment == "test" ? 1 : 0
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "test-umbrella-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/KartheekMarabathula/MULTI-SERVICE-INFRA-GITOPS"
        targetRevision = "HEAD"
        path           = "gitops/helm-charts/umbrella-app"
        helm = {
          valueFiles = ["values-test.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "test"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}

# 3. STAGE UMBRELLA APP
resource "kubernetes_manifest" "stage_umbrella_app" {
  
  count      = var.environment == "stage" ? 1 : 0
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "stage-umbrella-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/KartheekMarabathula/MULTI-SERVICE-INFRA-GITOPS"
        targetRevision = "HEAD"
        path           = "gitops/helm-charts/umbrella-app"
        helm = {
          valueFiles = ["values-stage.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "stage"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}



# 9. AWS AMAZON ECR REPOSITORIES

resource "aws_ecr_repository" "product_service" {
  name                 = "product-service-${var.environment}" 
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_repository" "user_service" {
  name                 = "user-service-${var.environment}" 
  image_tag_mutability = "MUTABLE"
}
