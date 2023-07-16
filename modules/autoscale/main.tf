data "google_compute_default_service_account" "main" {}

# Instance template
resource "google_compute_instance_template" "main" {
  name_prefix      = var.name
  machine_type     = var.machine_type
  min_cpu_platform = var.min_cpu_platform
  tags             = var.tags
  metadata         = var.metadata
  can_ip_forward   = true

  service_account {
    scopes = var.scopes
    email  = var.service_account_email
  }

  dynamic "network_interface" {
    for_each = var.network_interfaces

    content {
      subnetwork = network_interface.value.subnetwork

      dynamic "access_config" {
        for_each = try(network_interface.value.create_public_ip, false) ? ["one"] : []
        content {}
      }
    }
  }

  disk {
    source_image = var.image
    disk_type    = var.disk_type
    auto_delete  = true
    boot         = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Zonal managed instance group and autoscaler
resource "google_compute_instance_group_manager" "zonal" {
  for_each = var.regional_mig ? {} : var.zones

  name               = "${var.name}-${each.value}"
  base_instance_name = var.name
  target_pools       = var.target_pools
  zone               = each.value

  version {
    instance_template = google_compute_instance_template.main.id
  }

  lifecycle {
    ignore_changes = [
      version[0].name,
      version[1].name,
    ]
  }

  update_policy {
    type            = var.update_policy_type
    max_surge_fixed = 1
    minimal_action  = "REPLACE"
  }

  dynamic "named_port" {
    for_each = var.named_ports
    content {
      name = named_port.value.name
      port = named_port.value.port
    }
  }
}

resource "google_compute_autoscaler" "zonal" {
  for_each = var.regional_mig ? {} : var.zones

  name   = "${var.name}-${each.value}"
  target = google_compute_instance_group_manager.zonal[each.key].id
  zone   = each.value

  autoscaling_policy {
    min_replicas    = var.min_vmseries_replicas
    max_replicas    = var.max_vmseries_replicas
    cooldown_period = var.cooldown_period

    dynamic "metric" {
      for_each = var.autoscaler_metrics
      content {
        name   = metric.key
        type   = try(metric.value.type, "GAUGE")
        target = metric.value.target
      }
    }

    scale_in_control {
      time_window_sec = var.scale_in_control_time_window_sec
      max_scaled_in_replicas {
        fixed = var.scale_in_control_replicas_fixed
      }
    }
  }
}

# Regional managed instance group and autoscaler
data "google_compute_zones" "main" {
  count = var.regional_mig ? 1 : 0

  region = var.region
}

resource "google_compute_region_instance_group_manager" "regional" {
  count = var.regional_mig ? 1 : 0

  name               = var.name
  base_instance_name = var.name
  target_pools       = var.target_pools
  region             = var.region

  version {
    instance_template = google_compute_instance_template.main.id
  }

  update_policy {
    type            = var.update_policy_type
    max_surge_fixed = length(data.google_compute_zones.main[0])
    minimal_action  = "REPLACE"
  }

  dynamic "named_port" {
    for_each = var.named_ports
    content {
      name = named_port.value.name
      port = named_port.value.port
    }
  }
}

resource "google_compute_region_autoscaler" "regional" {
  count = var.regional_mig ? 1 : 0

  name   = var.name
  target = google_compute_region_instance_group_manager.regional[0].id
  region = var.region

  autoscaling_policy {
    min_replicas    = var.min_vmseries_replicas
    max_replicas    = var.max_vmseries_replicas
    cooldown_period = var.cooldown_period

    dynamic "metric" {
      for_each = var.autoscaler_metrics
      content {
        name   = metric.key
        type   = try(metric.value.type, "GAUGE")
        target = metric.value.target
      }
    }

    scale_in_control {
      time_window_sec = var.scale_in_control_time_window_sec
      max_scaled_in_replicas {
        fixed = var.scale_in_control_replicas_fixed
      }
    }
  }
}

# Pub/Sub for Panorama Plugin
resource "google_pubsub_topic" "main" {
  count = var.create_pubsub_topic ? 1 : 0

  name = "${var.name}-mig"
}

resource "google_pubsub_subscription" "main" {
  count = var.create_pubsub_topic ? 1 : 0

  name  = "${var.name}-mig"
  topic = google_pubsub_topic.main[0].id
}

resource "google_pubsub_subscription_iam_member" "main" {
  count = var.create_pubsub_topic ? 1 : 0

  subscription = google_pubsub_subscription.main[0].id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${coalesce(var.service_account_email, data.google_compute_default_service_account.main.email)}"
}

data "google_compute_default_service_account" "this" {}

#---------------------------------------------------------------------------------
# The following resources are used for delicensing

resource "random_id" "postfix" {
  byte_length = 2
}

locals {
  delicensing_cfn = {
    panorama_ip             = var.panorama_ip
    bucket_name             = "${var.prefix}${var.delicensing_cfn_name}-${random_id.postfix.hex}"
    source_dir              = "${path.module}/src"
    zip_file_name           = "delicensing_cfn"
    runtime_sa_account_id   = "${var.prefix}${var.delicensing_cfn_name}-sa-${random_id.postfix.hex}"
    runtime_sa_display_name = "Delicensing Cloud Function runtime SA"
    runtime_sa_roles = [
      # "roles/iam.serviceAccountUser",
      "roles/secretmanager.secretAccessor",
      "roles/compute.viewer",
    ]
    topic_name         = "${var.prefix}${var.delicensing_cfn_name}_topic-${random_id.postfix.hex}"
    log_sink_name      = "${var.prefix}${var.delicensing_cfn_name}_logsink-${random_id.postfix.hex}"
    entry_point        = "autoscale_delete_event"
    description        = "Cloud Function to delicense firewalls in Panorama on scale-in events"
    subscription_name  = "${var.prefix}${var.delicensing_cfn_name}_subscription"
    secret_name        = "${var.prefix}${var.delicensing_cfn_name}_pano_creds-${random_id.postfix.hex}"
    vpc_connector_name = "${var.prefix}${var.delicensing_cfn_name}-vpc-connector-${random_id.postfix.hex}"
  }
}

# Secret to store Panorama credentials.
# Credentials itself are set manually.
resource "google_secret_manager_secret" "delicensing_cfn_pano_creds" {
  count     = var.enable_delicensing ? 1 : 0
  secret_id = local.delicensing_cfn.secret_name
  replication {
    automatic = true
  }
}

# Create a log sink to match the delete of a VM from a Managed Instance group during the initial phase
resource "google_logging_project_sink" "delicensing_cfn" {
  count = var.enable_delicensing ? 1 : 0

  destination            = "pubsub.googleapis.com/${google_pubsub_topic.delicensing_cfn[0].id}"
  name                   = local.delicensing_cfn.log_sink_name
  filter                 = "protoPayload.requestMetadata.callerSuppliedUserAgent=\"GCE Managed Instance Group\" AND protoPayload.methodName=\"v1.compute.instances.delete\" AND protoPayload.response.progress=\"0\""
  unique_writer_identity = true
}

# Create a pub/sub topic for messaging log sink events
resource "google_pubsub_topic" "delicensing_cfn" {
  count = var.enable_delicensing ? 1 : 0
  name  = local.delicensing_cfn.topic_name
}

# Create a pub/sub subscription to pull messages from the topic
resource "google_pubsub_subscription" "delicensing_cfn" {
  count                   = var.enable_delicensing ? 1 : 0
  name                    = local.delicensing_cfn.subscription_name
  topic                   = google_pubsub_topic.delicensing_cfn[0].name
  ack_deadline_seconds    = 10
  enable_message_ordering = false
}

# VPC Connector required to access local Panorama instance
data "google_compute_network" "panorama_network" {
  count = var.enable_delicensing ? 1 : 0
  name  = var.vpc_connector_network
}

resource "google_vpc_access_connector" "delicensing_cfn" {
  count         = var.enable_delicensing ? 1 : 0
  name          = local.delicensing_cfn.vpc_connector_name
  region        = var.region
  ip_cidr_range = var.vpc_connector_cidr
  network       = data.google_compute_network.panorama_network[0].self_link
}

resource "google_cloudfunctions_function" "delicensing_cfn" {
  count                 = var.enable_delicensing ? 1 : 0
  name                  = var.delicensing_cfn_name
  description           = local.delicensing_cfn.description
  runtime               = "python310"
  entry_point           = local.delicensing_cfn.entry_point
  source_archive_bucket = google_storage_bucket.delicensing_cfn[0].self_link
  source_archive_object = google_storage_bucket_object.delicensing_cfn[0].self_link
  #checkov:skip=CKV2_GCP_10:When using event trigger, HTTP Trigger is invalid and not used
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.delicensing_cfn[0].id
  }
  available_memory_mb = 256
  timeout             = 60
  max_instances       = 20
  environment_variables = {
    "PANORAMA_IP" = var.panorama_ip
    "SECRET_NAME" = google_secret_manager_secret.delicensing_cfn_pano_creds[0].secret_id
  }
  service_account_email         = google_service_account.delicensing_cfn[0].email
  depends_on                    = [google_storage_bucket_object.delicensing_cfn]
  vpc_connector                 = google_vpc_access_connector.delicensing_cfn[0].self_link
  vpc_connector_egress_settings = "PRIVATE_RANGES_ONLY"
}

# CFN bucket
resource "google_storage_bucket" "delicensing_cfn" {
  count         = var.enable_delicensing ? 1 : 0
  name          = local.delicensing_cfn.bucket_name
  location      = var.delicensing_cfn_bucket_location
  force_destroy = true

  public_access_prevention = "enforced"
}

data "archive_file" "delicensing_cfn" {
  count       = var.enable_delicensing ? 1 : 0
  type        = "zip"
  source_dir  = local.delicensing_cfn.source_dir
  output_path = "/tmp/${local.delicensing_cfn.zip_file_name}.zip"
}

resource "google_storage_bucket_object" "delicensing_cfn" {
  count  = var.enable_delicensing ? 1 : 0
  name   = "${local.delicensing_cfn.zip_file_name}.${lower(replace(data.archive_file.delicensing_cfn[0].output_base64sha256, "=", ""))}.zip"
  bucket = local.delicensing_cfn.bucket_name
  source = "/tmp/${local.delicensing_cfn.zip_file_name}.zip"
}

# CFN Service Account
resource "google_service_account" "delicensing_cfn" {
  count        = var.enable_delicensing ? 1 : 0
  account_id   = local.delicensing_cfn.runtime_sa_account_id
  display_name = local.delicensing_cfn.runtime_sa_display_name
}


data "google_project" "this" { }

resource "google_project_iam_member" "delicensing_cfn" {
  for_each = var.enable_delicensing ? toset(local.delicensing_cfn.runtime_sa_roles) : []
  project = data.google_project.this.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.delicensing_cfn[0].email}"
}

# Allow log router writer to write to pub/sub
resource "google_pubsub_topic_iam_member" "pubsub_sink_member" {
  count  = var.enable_delicensing ? 1 : 0
  project = data.google_project.this.project_id
  topic  = local.delicensing_cfn.topic_name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.delicensing_cfn[0].writer_identity
}