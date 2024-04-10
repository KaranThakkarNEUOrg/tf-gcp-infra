locals {
  sql_private_ip = [for ip in google_sql_database_instance.sql-primary.ip_address : ip.ip_address if ip.type == "PRIVATE"]
}

# [Start]
# [Creating VPC network with 2 subnets]
resource "google_compute_network" "vpc" {
  name                            = var.vpc_name
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp" {
  name                     = var.subnet1_name
  ip_cidr_range            = var.subnet1_ip_address
  network                  = google_compute_network.vpc.self_link
  region                   = var.region
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "db" {
  name                     = var.subnet2_name
  ip_cidr_range            = var.subnet2_ip_address
  network                  = google_compute_network.vpc.self_link
  region                   = var.region
  private_ip_google_access = true
}

resource "google_compute_route" "webapp_route" {
  name             = var.route_name
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.vpc.name
  next_hop_gateway = "default-internet-gateway"
  tags             = [var.subnet1_name]
}
# [End]
# [VPC creation done]

# [Start]
# [Creating Firewall rules to allow application port and deny ssh]
resource "google_compute_firewall" "firewall_allow_rules" {
  name    = "firewall-allow-rules"
  network = google_compute_network.vpc.self_link
  allow {
    protocol = "tcp"
    ports    = var.firewall_allow_ports
  }

  source_ranges = var.source_ranges_https
  target_tags   = [var.subnet1_name, var.subnet2_name]
}

resource "google_compute_firewall" "firewall_deny_rules" {
  name    = "firewall-deny-rules"
  network = google_compute_network.vpc.name
  deny {
    protocol = "tcp"
    ports    = var.firewall_deny_ports
  }

  source_ranges = var.source_ranges
  target_tags   = [var.subnet1_name, var.subnet2_name]
}

# [End]

# [Start google_sql_database_instance sql-primary]
resource "google_sql_database_instance" "sql-primary" {
  name                = var.sql_database_instance_name
  database_version    = "MYSQL_8_0"
  region              = var.sql_db_instance_region
  depends_on          = [google_service_networking_connection.private_vpc_connection]
  deletion_protection = var.sql_deletion_protection
  encryption_key_name = google_kms_crypto_key.crypto_sign_key_sql.id

  settings {
    tier                        = var.sql_db_instance_tier
    deletion_protection_enabled = var.sql_instance_deletion_protection_enabled

    database_flags {
      name  = "max_connections"
      value = "5000"
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_service_networking_connection.private_vpc_connection.network
    }

    disk_autoresize = var.sql_disk_autoresize
    disk_size       = var.sql_instance_disk_size
    disk_type       = var.sql_db_instance_disk_type

    availability_type = var.sql_db_instance_availability_type
  }
}
# [End google_sql_database_instance sql-primary]

# [Start google_sql_database webapp-sql]
resource "google_sql_database" "webapp-sql" {
  name     = var.sql_db_name
  instance = google_sql_database_instance.sql-primary.name
}
# [End google_sql_database webapp-sql]

# [Start google_sql_user]
resource "random_password" "password" {
  length  = var.random_password_length
  special = false
}

resource "google_sql_user" "webapp" {
  name     = var.sql_user_name
  instance = google_sql_database_instance.sql-primary.name
  password = random_password.password.result
}
# [End google_sql_user]

# [Start compute_internal_ip_private_access]
resource "google_compute_global_address" "private_ip_range" {
  name          = var.compute_global_address_name
  purpose       = var.gcga_purpose
  address_type  = var.gcga_address_type
  prefix_length = var.compute_global_address_prefix_length
  network       = google_compute_network.vpc.self_link
}
# [End compute_internal_ip_private_access]

# [Start google_service_networking_connection]
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}
# [End google_service_networking_connection]

# [Start]
# [VM instances creation, assigning tags same as subnetwork]

resource "google_compute_region_instance_template" "default" {
  name         = var.vm_instance_name
  machine_type = var.machine_type
  region       = var.region
  depends_on   = [google_service_account.ops_agent_service_account, google_project_iam_binding.logging_admin, google_project_iam_binding.monitoring_metric_writer, google_project_iam_binding.ops_agent_publisher]
  tags         = [var.subnet1_name]

  disk {
    source_image = var.image_name
    auto_delete  = false
    boot         = true
    disk_size_gb = var.instance_size
    disk_type    = var.instance_type

    disk_encryption_key {
      kms_key_self_link = google_kms_crypto_key.crypto_sign_key_vm.id
    }
  }

  network_interface {
    network    = google_compute_network.vpc.self_link
    subnetwork = google_compute_subnetwork.webapp.self_link
    access_config {
    }
  }

  service_account {
    email  = google_service_account.ops_agent_service_account.email
    scopes = var.service_account_scopes
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh", {
    sql_hostname     = local.sql_private_ip[0],
    sql_password     = random_password.password.result,
    sql_databasename = google_sql_database.webapp-sql.name,
    sql_username     = google_sql_user.webapp.name,
    sql_port         = var.database_port,
    salt_rounds      = var.salt_rounds
  })
}

resource "google_compute_health_check" "health_check" {
  name                = var.health_check_name
  check_interval_sec  = var.check_interval_sec
  timeout_sec         = var.timeout_sec
  healthy_threshold   = var.healthy_threshold
  unhealthy_threshold = var.unhealthy_threshold

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_region_autoscaler" "autoscaler" {
  name   = var.autoscaler_name
  target = google_compute_region_instance_group_manager.instance_group_manager.id
  region = var.region

  autoscaling_policy {
    max_replicas    = var.max_replicas
    min_replicas    = var.min_replicas
    cooldown_period = var.cooldown_period

    cpu_utilization {
      target = var.cpu_utilization
    }
  }

  depends_on = [google_compute_region_instance_group_manager.instance_group_manager]
}

resource "google_compute_region_instance_group_manager" "instance_group_manager" {
  name               = var.instance_group_manager_name
  base_instance_name = "instance"
  region             = var.region

  version {
    instance_template = google_compute_region_instance_template.default.id
  }

  named_port {
    name = var.custom_port_name
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.health_check.id
    initial_delay_sec = 300
  }

  update_policy {
    type                  = var.update_policy
    minimal_action        = var.update_polic_minimal_action
    max_surge_fixed       = var.update_policy_max_surge_fixed
    max_unavailable_fixed = var.update_policy_max_unavailable_fixed
    replacement_method    = var.update_policy_replacement_method
  }

}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = var.forwarding_rule_name
  target     = google_compute_target_https_proxy.https_proxy.id
  port_range = "443"
}

resource "google_compute_target_https_proxy" "https_proxy" {
  name             = var.http_proxy_name
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ssl_certificate.id]
}

resource "google_compute_url_map" "url_map" {
  name            = var.url_map_name
  default_service = google_compute_backend_service.backend_service.id
}

resource "google_compute_backend_service" "backend_service" {
  name                  = var.backend_service_name
  port_name             = var.custom_port_name
  protocol              = var.http_protocol
  health_checks         = [google_compute_health_check.health_check.id]
  load_balancing_scheme = var.load_balancing_scheme

  backend {
    group = google_compute_region_instance_group_manager.instance_group_manager.instance_group
  }
}

resource "google_compute_managed_ssl_certificate" "ssl_certificate" {
  name = "ssl-certificate"

  managed {
    domains = [var.main_domain_name]
  }
}

resource "google_dns_record_set" "a-record" {
  name         = var.domain_name
  type         = "A"
  ttl          = var.ttl
  managed_zone = var.managed_zone_dns
  rrdatas      = [google_compute_global_forwarding_rule.forwarding_rule.ip_address]
  depends_on   = [google_compute_global_forwarding_rule.forwarding_rule]
}


# [End]
# [End] DNS connection to VM

# # [Start] Service Account
resource "google_service_account" "ops_agent_service_account" {
  account_id   = var.ops_agent_account_id
  display_name = var.ops_agent_display_name
  description  = var.ops_agent_description
}
# # [End] Service Account

# # [Start] IAM policy
resource "google_project_iam_binding" "logging_admin" {
  project    = var.project_id
  role       = var.iam_logging_admin_role
  depends_on = [google_service_account.ops_agent_service_account]

  members = [
    "serviceAccount:${google_service_account.ops_agent_service_account.email}"
  ]
}

resource "google_project_iam_binding" "monitoring_metric_writer" {
  project    = var.project_id
  role       = var.iam_monitoring_role
  depends_on = [google_service_account.ops_agent_service_account]

  members = [
    "serviceAccount:${google_service_account.ops_agent_service_account.email}"
  ]
}
resource "google_project_iam_binding" "ops_agent_publisher" {
  project    = var.project_id
  role       = var.iam_publishing_message
  depends_on = [google_service_account.ops_agent_service_account, google_service_account.pubsub_service_account]

  members = [
    "serviceAccount:${google_service_account.ops_agent_service_account.email}",
    "serviceAccount:${google_service_account.pubsub_service_account.email}"
  ]
}

# [End] Service Account Binding

# [Start] Creating Pub/Sub topic
resource "google_pubsub_topic" "verify_email" {
  name                       = var.pubsub_topic_name
  message_retention_duration = var.pubsub_topic_message_retention # 7 days
}
# [End] Creating Pub/Sub topic

# [Start] Creating service account for pub/sub
resource "google_service_account" "pubsub_service_account" {
  account_id   = var.pubsub_service_account_id
  display_name = var.pubsub_service_account_display_name
  depends_on   = [google_pubsub_topic.verify_email]
}
# [End] Creating service account for pub/sub

# [Start] Binding pub/sub service account
resource "google_project_iam_binding" "pubsub_service_account_invoker_binding" {
  project    = var.project_id
  role       = var.pubsub_invoker_role
  depends_on = [google_service_account.pubsub_service_account]

  members = [
    "serviceAccount:${google_service_account.pubsub_service_account.email}"
  ]
}
# [End] Binding pub/sub service account
resource "google_cloudfunctions2_function" "verify_email" {
  name        = var.cloud_function_name
  location    = var.cloud_function_region
  description = var.cloud_function_description

  build_config {
    runtime     = var.cloud_function_runtime
    entry_point = var.cloud_function_entry_point
    source {
      # repo_source {
      #   repo_name   = "github_karanthakkarneuorg_serverless"
      #   branch_name = "main"
      # }
      storage_source {
        bucket = google_storage_bucket.storage_bucket.name
        object = google_storage_bucket_object.storage_bucket_object.name
      }
    }
  }

  service_config {
    available_memory      = var.cloud_function_available_memory_mb
    timeout_seconds       = var.cloud_function_timeout
    service_account_email = google_service_account.pubsub_service_account.email
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    vpc_connector         = google_vpc_access_connector.cf_vpc_connector.self_link

    environment_variables = {
      MAILGUN_API_KEY     = var.MAILGUN_API_KEY
      WEBAPP_URL          = var.WEBAPP_URL
      SQL_HOSTNAME        = local.sql_private_ip[0],
      SQL_PASSWORD        = random_password.password.result,
      SQL_DATABASENAME    = google_sql_database.webapp-sql.name,
      SQL_USERNAME        = google_sql_user.webapp.name,
      MAILGUN_USERNAME    = var.mailgun_username,
      PUBSUB_TOPIC_NAME   = var.pubsub_topic_name,
      WEBAPP_DOMAIN_NAME  = var.webapp_domain_name,
      METADATA_TABLE_NAME = var.metadata_table_name,
      MESSAGE_FROM        = var.message_from

    }

  }

  event_trigger {
    event_type            = var.event_trigger_event_type
    pubsub_topic          = google_pubsub_topic.verify_email.id
    retry_policy          = var.event_trigger_retry_policy
    trigger_region        = var.event_trigger_region
    service_account_email = google_service_account.pubsub_service_account.email
  }

  depends_on = [google_pubsub_topic.verify_email, google_service_account.pubsub_service_account, google_storage_bucket.storage_bucket, google_storage_bucket_object.storage_bucket_object]
}
# [End] Creating cloud function for pub/sub

resource "google_pubsub_subscription" "pull_msg" {
  name                       = var.pubsub_pull_subscription_name
  topic                      = google_pubsub_topic.verify_email.id
  message_retention_duration = var.message_retention_duration #7days
  retain_acked_messages      = var.retain_acked_messages
  ack_deadline_seconds       = var.ack_deadline_seconds

  retry_policy {
    minimum_backoff = var.minimum_backoff
    maximum_backoff = var.maximum_backoff
  }

  enable_exactly_once_delivery = var.enable_exactly_once_delivery
  enable_message_ordering      = var.enable_message_ordering
}

# [End] creating subscription for cloud functions

# [Start] Create a Serverless VPC Access connector
resource "google_vpc_access_connector" "cf_vpc_connector" {
  name          = var.vpc_connector_name
  region        = var.vpc_connector_region
  ip_cidr_range = var.vpc_ip_cidr_range
  network       = var.vpc_name
  machine_type  = var.vpc_connector_machine_type
  depends_on    = [google_compute_network.vpc]
}
# [End] Create a Serverless VPC Access connector


# [Start] Creating storage bucket
data "google_storage_project_service_account" "gcs_account" {
}

resource "google_kms_crypto_key_iam_binding" "crypto_key_bucket" {
  crypto_key_id = google_kms_crypto_key.crypto_sign_key_bucket.id
  role          = var.encrypter_decrypter_role_name

  members = ["serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"]
}

resource "google_kms_crypto_key_iam_binding" "crypto_key_object" {
  crypto_key_id = google_kms_crypto_key.crypto_sign_key_bucket_object.id
  role          = var.encrypter_decrypter_role_name

  members = ["serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"]
}

resource "google_kms_crypto_key_iam_binding" "crypto_key_vm" {
  crypto_key_id = google_kms_crypto_key.crypto_sign_key_vm.id
  role          = var.encrypter_decrypter_role_name

  members = [
    "serviceAccount:${var.default_service_account}",
  ]
}


resource "google_storage_bucket" "storage_bucket" {
  name                        = var.storage_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = true
  uniform_bucket_level_access = true
  encryption {
    default_kms_key_name = google_kms_crypto_key.crypto_sign_key_bucket.id
  }

  depends_on = [google_kms_crypto_key_iam_binding.crypto_key_bucket]

}

resource "google_storage_bucket_object" "storage_bucket_object" {
  name         = var.storage_bucket_object_name
  bucket       = google_storage_bucket.storage_bucket.name
  source       = "./cloud_function.zip"
  kms_key_name = google_kms_crypto_key.crypto_sign_key_bucket_object.id
}
# [End] Creating storage bucket

# [Start] Creating Project service account
resource "google_project_service_identity" "gcp_sa_cloud_sql" {
  project  = var.project_id
  provider = google-beta
  service  = var.sql_googleapi_service
}
# [End] Creating Project service account

resource "google_kms_crypto_key_iam_binding" "crypto_key_sql" {
  provider      = google-beta
  crypto_key_id = google_kms_crypto_key.crypto_sign_key_sql.id
  role          = var.encrypter_decrypter_role_name

  members = [
    "serviceAccount:${google_project_service_identity.gcp_sa_cloud_sql.email}",
  ]
}


# # [Start] Creating KMS keyring and key
resource "google_kms_key_ring" "key_ring" {
  name     = var.kms_key_name
  location = var.region
}

resource "google_kms_crypto_key" "crypto_sign_key_bucket_object" {
  name     = var.crypto_sign_key_bucket_object_name
  key_ring = google_kms_key_ring.key_ring.id
  purpose  = var.crypto_purpose

  version_template {
    algorithm = var.crypto_algorithm
  }
  lifecycle {
    prevent_destroy = false
  }

  rotation_period = var.rotation_period
}

resource "google_kms_crypto_key" "crypto_sign_key_vm" {
  name     = var.crypto_sign_key_vm_name
  key_ring = google_kms_key_ring.key_ring.id
  purpose  = var.crypto_purpose

  version_template {
    algorithm = var.crypto_algorithm
  }
  lifecycle {
    prevent_destroy = false
  }

  rotation_period = var.rotation_period
}

resource "google_kms_crypto_key" "crypto_sign_key_bucket" {
  name     = var.crypto_sign_key_bucket_name
  key_ring = google_kms_key_ring.key_ring.id
  purpose  = var.crypto_purpose

  version_template {
    algorithm = var.crypto_algorithm
  }
  lifecycle {
    prevent_destroy = false
  }

  rotation_period = var.rotation_period
}

resource "google_kms_crypto_key" "crypto_sign_key_sql" {
  name     = var.crypto_sign_key_sql_name
  key_ring = google_kms_key_ring.key_ring.id
  purpose  = var.crypto_purpose

  version_template {
    algorithm = var.crypto_algorithm
  }
  lifecycle {
    prevent_destroy = false
  }

  rotation_period = var.rotation_period
}
# [End] Creating KMS keyring and key

# [Start] Creating secret manger
resource "google_secret_manager_secret" "secret_manager_sql_password" {
  secret_id = var.secret_manager_sql_password_name
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "secret_manager_version_sql_password" {
  secret      = google_secret_manager_secret.secret_manager_sql_password.name
  secret_data = random_password.password.result
}

resource "google_secret_manager_secret" "secret_manager_sql_host" {
  secret_id = var.secret_manager_sql_host_name
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "secret_manager_version_sql_host" {
  secret      = google_secret_manager_secret.secret_manager_sql_host.name
  secret_data = local.sql_private_ip[0]
}

resource "google_secret_manager_secret" "secret_manager_sql_database" {
  secret_id = var.secret_manager_sql_database_name
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "secret_manager_version_sql_database" {
  secret      = google_secret_manager_secret.secret_manager_sql_database.name
  secret_data = var.sql_db_name
}

resource "google_secret_manager_secret" "secret_manager_sql_user" {
  secret_id = var.secret_manager_sql_user_name
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "secret_manager_version_sql_user" {
  secret      = google_secret_manager_secret.secret_manager_sql_user.name
  secret_data = var.sql_user_name
}

resource "google_secret_manager_secret" "secret_manager_crypto_key_vm" {
  secret_id = var.secret_manager_vm_name
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "secret_manager_version_crypto_key_vm" {
  secret      = google_secret_manager_secret.secret_manager_crypto_key_vm.name
  secret_data = google_kms_crypto_key.crypto_sign_key_vm.id
}

resource "google_project_iam_binding" "secret_manager" {
  project    = var.project_id
  role       = var.secret_manager_role
  depends_on = [google_secret_manager_secret.secret_manager_sql_password, google_secret_manager_secret.secret_manager_sql_host, google_secret_manager_secret.secret_manager_crypto_key_vm, google_secret_manager_secret.secret_manager_sql_database, google_secret_manager_secret.secret_manager_sql_user]

  members = [
    "serviceAccount:${var.packer_service_account}"
  ]
}
resource "google_project_iam_binding" "secret_manager_health_check" {
  project = var.project_id
  role    = var.secret_manager_health_check_role

  members = [
    "serviceAccount:${var.packer_service_account}"
  ]
}
# [End] Creating secret manger



