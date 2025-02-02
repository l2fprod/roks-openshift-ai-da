########################################################################################################################
# Determnine if the user named resource group and COS instance exists
########################################################################################################################
data "external" "resource_data" {
  program    = ["bash", "${path.module}/scripts/check-resources.sh"]
  query      = {
    rg_name  = var.resource-group == null ? "does not exist" : var.resource-group
    cos_name = var.cos-instance == null ? "does not exist" : var.cos-instance
  }
}

########################################################################################################################
# Resource Group
########################################################################################################################
resource "ibm_resource_group" "res_group" {
  count = data.external.resource_data.result.create_rg == "true" ? 1 : 0
  name  = var.resource-group == null ? "rhoai-resource-group" : var.resource-group
}

data "ibm_resource_group" "resource_group" {
  count = data.external.resource_data.result.create_rg == "false" ? 1 : 0
  name  = var.resource-group
}

##############################################################################
# Fetch the COS info if one already exists
##############################################################################
data "ibm_resource_instance" "cos_instance" {
  count             = data.external.resource_data.result.create_cos == "false" ? 1 : 0
  name              = var.cos-instance
  service           = "cloud-object-storage"
}

########################################################################################################################
# VPC + Subnet + Public Gateway
#
# NOTE: This is a very simple VPC with single subnet in a single zone with a public gateway enabled, that will allow
# all traffic ingress/egress by default.
# For production use cases this would need to be enhanced by adding more subnets and zones for resiliency, and
# ACLs/Security Groups for network security.
########################################################################################################################

resource "ibm_is_vpc" "vpc" {
  name                      = "rhoai-vpc"
  resource_group            = local.resource_group
  address_prefix_management = "auto"
}

resource "ibm_is_public_gateway" "gateway" {
  name           = "rhoai-gateway"
  vpc            = ibm_is_vpc.vpc.id
  resource_group = local.resource_group
  zone           = "${var.region}-${var.zone}"
}

resource "ibm_is_subnet" "subnet_zone" {
  name                     = "rhoai-subnet"
  vpc                      = ibm_is_vpc.vpc.id
  resource_group           = local.resource_group
  zone                     = "${var.region}-${var.zone}"
  total_ipv4_address_count = 256
  public_gateway           = ibm_is_public_gateway.gateway.id
}


locals {

  kubeconfig = data.ibm_container_cluster_config.da_cluster_config.config_file_path

  resource_group = data.external.resource_data.result.create_rg == "true" ? ibm_resource_group.res_group[0].id : data.ibm_resource_group.resource_group[0].id

###############################
# Pipelines operator locals
###############################
  pipeline_operator_namespace = "openshift-operators"
  # local path to the helm chart
  chart_path_pipeline_operator = "openshift-pipelines"
  # helm release name
  helm_release_name_pipeline_operator = local.chart_path_pipeline_operator
  # operator subscription name
  subscription_name_pipeline_operator = "openshift-pipelines-operator"

###############################
# RHODS operator locals
###############################
  rhods_operator_namespace = "redhat-ods-operator"
  # local path to the helm chart
  chart_path_rhods_operator = "openshift-data-science"
  # helm release name
  helm_release_name_rhods_operator = local.chart_path_rhods_operator
  # operator subscription name
  subscription_name_rhods_operator = "rhods-operator"
  # local path to the helm chart
  chart_path_data_science_cluster = "data-science-cluster"
  # helm release name
  helm_release_name_data_science_cluster = local.chart_path_data_science_cluster
  # data science cluster namespace
  rhods_cluster_namespace = "redhat-ods-applications"

###############################
# NFD operator locals
###############################
  nfd_operator_namespace = "openshift-nfd"
  # local path to the helm chart
  chart_path_nfd_operator = "nfd"
  # helm release name
  helm_release_name_nfd_operator = local.chart_path_nfd_operator
  # operator subscription name
  subscription_name_nfd_operator = "nfd"
  # local path to the helm chart
  chart_path_nfd_instance = "nfd-instance"
  # helm release name
  helm_release_name_nfd_instance = local.chart_path_nfd_instance
  # nfd instance image name
  nfd_image_name = var.ocp-version == "4.15" ? "registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9@sha256:0f7b6eff43ff938a9cb84ca37c75fcefd8c9460d410963085fac5fafd3a6143b" : "registry.redhat.io/openshift4/ose-node-feature-discovery:v${var.ocp-version}"

###############################
# GPU operator locals
###############################
  gpu_operator_namespace = "nvidia-gpu-operator"
  # local path to the helm chart
  chart_path_gpu_operator = "nvidia-gpu-operator"
  # helm release name
  helm_release_name_gpu_operator = local.chart_path_gpu_operator
  # operator subscription name
  subscription_name_gpu_operator = "gpu-operator-certified"
  # local path to the helm chart
  chart_path_cluster_policy = "cluster-policy"
  # helm release name
  helm_release_name_cluster_policy = local.chart_path_cluster_policy

  cluster_vpc_subnets = {
    default = [
      {
        id         = ibm_is_subnet.subnet_zone.id
        cidr_block = ibm_is_subnet.subnet_zone.ipv4_cidr_block
        zone       = ibm_is_subnet.subnet_zone.zone
      }
    ]
  }

  worker_pool_1 = [
    {
      subnet_prefix    = "default"
      pool_name        = "default" # ibm_container_vpc_cluster automatically names default pool "default" (See https://github.com/IBM-Cloud/terraform-provider-ibm/issues/2849)
      machine_type     = "worker-type"
      workers_per_zone = 2
    }
  ]

  worker_pool_2 = [
    {
      subnet_prefix    = "default"
      pool_name        = "default" # ibm_container_vpc_cluster automatically names default pool "default" (See https://github.com/IBM-Cloud/terraform-provider-ibm/issues/2849)
      machine_type     = "worker-type"
      workers_per_zone = 2
    }
  ]

  worker_pool_3 = [
    {
      subnet_prefix    = "default"
      pool_name        = "default" # ibm_container_vpc_cluster automatically names default pool "default" (See https://github.com/IBM-Cloud/terraform-provider-ibm/issues/2849)
      machine_type     = "worker-type"
      workers_per_zone = 2
    }
  ]

  worker_pools = [
    {
      subnet_prefix    = "default"
      pool_name        = "default" # ibm_container_vpc_cluster automatically names default pool "default" (See https://github.com/IBM-Cloud/terraform-provider-ibm/issues/2849)
      machine_type     = var.machine-type
      workers_per_zone = var.number-gpu-nodes
    }
  ]
}

##############################################################################
# Create the cluster
##############################################################################
module "ocp_base" {
  source                              = "terraform-ibm-modules/base-ocp-vpc/ibm"
  ibmcloud_api_key                    = var.ibmcloud_api_key
  resource_group_id                   = local.resource_group
  region                              = var.region
  tags                                = ["createdby:RHOAI-DA"]
  cluster_name                        = var.cluster-name
  force_delete_storage                = true
  vpc_id                              = ibm_is_vpc.vpc.id
  vpc_subnets                         = local.cluster_vpc_subnets
  ocp_version                         = var.ocp-version
  worker_pools                        = local.worker_pools
  ocp_entitlement                     = null
  disable_outbound_traffic_protection = true
  #operating_system                    = var.ocp-version == "4.15" ? "RHCOS" : null
  use_existing_cos                    = data.external.resource_data.result.create_cos == "false" ? true : false
  existing_cos_id                     = data.external.resource_data.result.create_cos == "false" ? data.ibm_resource_instance.cos_instance[0].id : null
  cos_name                            = var.cos-instance == null ? "rhoai-cos-instance" : var.cos-instance
}

##############################################################################
# Retrieve information about all the Kubernetes configuration files and
# certificates to access the cluster in order to run kubectl / oc commands
##############################################################################
data "ibm_container_cluster_config" "da_cluster_config" {
  cluster_name_id = module.ocp_base.cluster_id
  config_dir      = "${path.module}/kubeconfig"
  endpoint_type   = null # null represents default
  admin           = true
}

##############################################################################
# Delay after the cluster creation to let things settle
##############################################################################
resource "time_sleep" "wait" {
  depends_on      = [data.ibm_container_cluster_config.da_cluster_config]
  create_duration = "120s"
}

##############################################################################
# Install the Pipelines operator if requested by the user
##############################################################################
resource "helm_release" "pipelines_operator" {
  depends_on = [time_sleep.wait]

  name              = local.helm_release_name_pipeline_operator
  chart             = "${path.module}/chart/${local.chart_path_pipeline_operator}"
  namespace         = local.pipeline_operator_namespace
  create_namespace  = true
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false

  set {
    name  = "operators.namespace"
    type  = "string"
    value = local.pipeline_operator_namespace
  }
  set {
    name  = "operators.subscription_name"
    type  = "string"
    value = local.subscription_name_pipeline_operator
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/approve-install-plan.sh ${local.subscription_name_pipeline_operator} ${local.pipeline_operator_namespace} 'wait'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = local.kubeconfig
    }
  }
}

##############################################################################
# Install the NFD operator
# (will start at the same time as the pipelines operator if enabled)
##############################################################################
resource "helm_release" "nfd_operator" {
  depends_on = [time_sleep.wait]

  name              = local.helm_release_name_nfd_operator
  chart             = "${path.module}/chart/${local.chart_path_nfd_operator}"
  namespace         = local.nfd_operator_namespace
  create_namespace  = true
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false

  set {
    name  = "operators.namespace"
    type  = "string"
    value = local.nfd_operator_namespace
  }
  set {
    name  = "operators.subscription_name"
    type  = "string"
    value = local.subscription_name_nfd_operator
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/approve-install-plan.sh ${local.subscription_name_nfd_operator} ${local.nfd_operator_namespace} 'wait'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = local.kubeconfig
    }
  }
}

##############################################################################
# Install the Node Discovery Feature instance
##############################################################################
resource "helm_release" "nfd_instance" {
  depends_on = [helm_release.nfd_operator]

  name              = local.helm_release_name_nfd_instance
  chart             = "${path.module}/chart/${local.chart_path_nfd_instance}"
  namespace         = local.nfd_operator_namespace
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false

  set {
    name  = "operators.namespace"
    type  = "string"
    value = local.nfd_operator_namespace
  }
  set {
    name  = "operators.instance_image"
    type  = "string"
    value = local.nfd_image_name
  }

  provisioner "local-exec" {
    command     = "${path.module}/chart/${local.chart_path_nfd_instance}/validate.sh ${var.number-gpu-nodes}"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = local.kubeconfig
    }
  }
}

##############################################################################
# Collect GPU operator data from the OperatorHub catalog
##############################################################################
data "external" "gpu_operator_data" {
  depends_on = [time_sleep.wait]
  program    = ["bash", "${path.module}/scripts/get-gpu-operator-data.sh"]
}

##############################################################################
# Install the NVIDIA GPU operator
# (depends on the NFD operator)
##############################################################################
resource "helm_release" "gpu_operator" {
  depends_on = [data.ibm_container_cluster_config.da_cluster_config, helm_release.nfd_instance, data.external.gpu_operator_data]

  name              = local.helm_release_name_gpu_operator
  chart             = "${path.module}/chart/${local.chart_path_gpu_operator}"
  namespace         = local.gpu_operator_namespace
  create_namespace  = true
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false

  set {
    name  = "operators.namespace"
    type  = "string"
    value = local.gpu_operator_namespace
  }
  set {
    name  = "operators.subscription_name"
    type  = "string"
    value = local.subscription_name_gpu_operator
  }
  set {
    name  = "operators.channel"
    type  = "string"
    value = data.external.gpu_operator_data.result.channel
  }
  set {
    name  = "operators.startingCSV"
    type  = "string"
    value = data.external.gpu_operator_data.result.csv
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/approve-install-plan.sh ${local.subscription_name_gpu_operator} ${local.gpu_operator_namespace} 'approve'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = local.kubeconfig
    }
  }
}

##############################################################################
# Install the Cluster Policy in the GPU operator
##############################################################################
resource "helm_release" "cluster-policy" {
  depends_on = [helm_release.gpu_operator]

  name              = local.helm_release_name_cluster_policy
  chart             = "${path.module}/chart/${local.chart_path_cluster_policy}"
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false
}


##############################################################################
# Install the RHODS operator
# (requires the NFD operator and GPU operator installs to be complete)
##############################################################################
resource "helm_release" "rhods_operator" {
  depends_on = [data.ibm_container_cluster_config.da_cluster_config, helm_release.cluster-policy, helm_release.nfd_instance]

  name              = local.helm_release_name_rhods_operator
  chart             = "${path.module}/chart/${local.chart_path_rhods_operator}"
  namespace         = local.rhods_operator_namespace
  create_namespace  = true
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false

  set {
    name  = "operators.namespace"
    type  = "string"
    value = local.rhods_operator_namespace
  }
  set {
    name  = "operators.subscription_name"
    type  = "string"
    value = local.subscription_name_rhods_operator
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/approve-install-plan.sh ${local.subscription_name_rhods_operator} ${local.rhods_operator_namespace} 'wait'"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = local.kubeconfig
    }
  }
}

##############################################################################
# Install the Data Science Cluster in the RHODS operator
##############################################################################
resource "helm_release" "data_science_cluster" {
  depends_on = [helm_release.rhods_operator]

  name              = local.helm_release_name_data_science_cluster
  chart             = "${path.module}/chart/${local.chart_path_data_science_cluster}"
  timeout           = 300
  dependency_update = true
  force_update      = false
  cleanup_on_fail   = false
  wait              = true

  disable_openapi_validation = false
}

##############################################################################
# Do some post install pod checking
##############################################################################
resource "null_resource" "pod_check" {
   depends_on = [helm_release.data_science_cluster]

   provisioner "local-exec" {
    command     = "${path.module}/scripts/pod_check.sh ${local.gpu_operator_namespace} ${var.number-gpu-nodes} ${local.rhods_cluster_namespace}"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = local.kubeconfig
    }
  }
}

