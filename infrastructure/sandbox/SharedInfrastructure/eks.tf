provider "kubernetes" {
  experiments {
    manifest_resource = true
  }
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    token                  = data.aws_eks_cluster_auth.cluster.token
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  apply_retry_count      = 5
}

locals {
  cluster_version = "1.21"
}

output "eks_cluster" {
  value = module.aws-eks-accelerator-for-terraform
}

terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.14.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "3.18.0"
    }
  }
}

data "aws_iam_role" "admin" {
  name = "admin"
}

module "aws-eks-accelerator-for-terraform" {
  source       = "github.com/aws-samples/aws-eks-accelerator-for-terraform.git"
  cluster_name = var.prefix

  # EKS Cluster VPC and Subnets
  vpc_id             = var.vpc.vpc_id
  private_subnet_ids = var.vpc.private_subnets

  # EKS CONTROL PLANE VARIABLES
  cluster_version = local.cluster_version

  # EKS MANAGED NODE GROUPS
  managed_node_groups = {
    mg_4 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["t3.medium"]
      subnet_ids      = var.vpc.private_subnets
    }
  }

  map_roles = concat([for i in var.eks_allowed_roles : {
    rolearn  = i.arn
    username = i.id
    groups   = ["system:masters"]
    }], [{
    rolearn  = data.aws_iam_role.admin.arn
    username = data.aws_iam_role.admin.id
    groups   = ["system:masters"]
  }])

  fargate_profiles = {
    default = {
      additional_iam_policies = [aws_iam_policy.ecr.arn]
      fargate_profile_name    = "default"
      fargate_profile_namespaces = [
        {
          namespace = "default"
        }
      ]
      subnet_ids = flatten([var.vpc.private_subnets])
    }
  }
}

output "oidc_provider_arn" {
  value = module.aws-eks-accelerator-for-terraform.eks_oidc_provider_arn
}

output "oidc_provider" {
  value = module.aws-eks-accelerator-for-terraform.oidc_provider
}

data "aws_eks_cluster" "cluster" {
  name = module.aws-eks-accelerator-for-terraform.eks_cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.aws-eks-accelerator-for-terraform.eks_cluster_id
}

module "kubernetes-addons" {
  source = "github.com/aws-samples/aws-eks-accelerator-for-terraform.git//modules/kubernetes-addons"

  eks_cluster_id               = module.aws-eks-accelerator-for-terraform.eks_cluster_id
  eks_cluster_endpoint         = module.aws-eks-accelerator-for-terraform.eks_cluster_endpoint
  eks_cluster_version          = local.cluster_version
  eks_oidc_provider            = module.aws-eks-accelerator-for-terraform.eks_oidc_issuer_url
  eks_worker_security_group_id = module.aws-eks-accelerator-for-terraform.worker_node_security_group_id

  # EKS Managed Add-ons
  enable_amazon_eks_vpc_cni            = true
  enable_amazon_eks_coredns            = true
  enable_amazon_eks_kube_proxy         = true
  enable_amazon_eks_aws_ebs_csi_driver = true

  #K8s Add-ons
  enable_aws_load_balancer_controller = true
  enable_metrics_server               = false
  enable_cluster_autoscaler           = true
  enable_vpa                          = true
  enable_prometheus                   = false
  enable_ingress_nginx                = false
  enable_aws_for_fluentbit            = false
  enable_argocd                       = false
  enable_fargate_fluentbit            = false
  enable_argo_rollouts                = false
  enable_kubernetes_dashboard         = false
  enable_yunikorn                     = false

  depends_on = [module.aws-eks-accelerator-for-terraform.managed_node_groups]
}

resource "helm_release" "haproxy_ingress" {
  name      = "haproxy-ingress-controller"
  namespace = "kube-system"

  repository = "https://haproxy-ingress.github.io/charts"
  chart      = "haproxy-ingress"

  set {
    name  = "controller.hostNetwork"
    value = "true"
  }

  set {
    name  = "controller.kind"
    value = "DaemonSet"
  }

  set {
    name  = "controller.service.type"
    value = "NodePort"
  }

  set {
    name  = "controller.defaultBackendService"
    value = "kube-system/default-redirect"
  }
}

resource "aws_lb_target_group" "eks" {
  name     = var.prefix
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc.vpc_id
  health_check {
    matcher = "302"
  }
}

resource "kubernetes_manifest" "targetgroupbinding" {
  manifest = {
    "apiVersion" = "elbv2.k8s.aws/v1beta1"
    "kind"       = "TargetGroupBinding"
    "metadata" = {
      "name"      = "haproxy"
      "namespace" = "kube-system"
    }
    "spec" = {
      "targetGroupARN" = aws_lb_target_group.eks.arn
      "serviceRef" = {
        "name" = helm_release.haproxy_ingress.name
        "port" = 80
      }
      "targetType" = "instance"
      "networking" = {
        "ingress" = [{
          "from" = [{
            "securityGroup" = {
              "groupID" = aws_security_group.lb.id
            }
          }]
          "ports" = [{
            "protocol" = "TCP"
          }]
        }]
      }
    }
  }
}

resource "kubernetes_service" "redirect" {
  metadata {
    name      = "default-redirect"
    namespace = "kube-system"
  }

  spec {
    selector = {
      app = kubernetes_deployment.redirect.metadata.0.labels.app
    }
    port {
      port = 80
      name = "http"
    }
  }
}

resource "kubernetes_deployment" "redirect" {
  metadata {
    name      = "default-redirect"
    namespace = "kube-system"
    labels = {
      app = "default-redirect"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "default-redirect"
      }
    }

    template {
      metadata {
        labels = {
          app = "default-redirect"
        }
      }

      spec {
        container {
          image = "nginx:1.23.1"
          name  = "nginx"

          port {
            name           = "http"
            container_port = 80
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }

          volume_mount {
            mount_path = "/etc/nginx"
            read_only  = true
            name       = "nginx-conf"
          }
        }
        volume {
          name = "nginx-conf"
          config_map {
            name = "default-redirect-config"
            items {
              key  = "nginx.conf"
              path = "nginx.conf"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_config_map" "redirect" {
  metadata {
    name      = "default-redirect-config"
    namespace = "kube-system"
  }

  data = {
    "nginx.conf" = <<-EOT
    user nginx;
    worker_processes 1;
    error_log  /dev/stderr;
    events {
      worker_connections  10240;
    }
    http {
      log_format  main
              'remote_addr:$remote_addr\t'
              'time_local:$time_local\t'
              'method:$request_method\t'
              'uri:$request_uri\t'
              'host:$host\t'
              'status:$status\t'
              'bytes_sent:$body_bytes_sent\t'
              'referer:$http_referer\t'
              'useragent:$http_user_agent\t'
              'forwardedfor:$http_x_forwarded_for\t'
              'request_time:$request_time';
      access_log	/dev/stderr main;
      server {
          listen       80;
          server_name  _;
          location / {
            return 302 https://fleetdm.com/try-fleet/sandbox-expired;
          }
      }
    }
    EOT
  }
}

resource "aws_iam_policy" "ecr" {
  name   = "${var.prefix}-ecr"
  policy = data.aws_iam_policy_document.ecr.json
}

data "aws_iam_policy_document" "ecr" {
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }
  statement {
    actions = [ #tfsec:ignore:aws-iam-no-policy-wildcards
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]
    resources = [aws_kms_key.ecr.arn]
  }
}

resource "aws_ecr_repository" "main" {
  name                 = "${var.prefix}-eks"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

output "ecr" {
  value = aws_ecr_repository.main
}

resource "aws_kms_key" "ecr" {
  deletion_window_in_days = 10
  enable_key_rotation     = true
}
