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
    auto_delete  = true
    boot         = true
    disk_size_gb = var.instance_size
    disk_type    = var.instance_type
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

  lifecycle {
    create_before_destroy = true
  }
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
      repo_source {
        repo_name   = "github_karanthakkarneuorg_serverless"
        branch_name = "main"
      }
      # storage_source {
      #   bucket = var.storage_bucket_name
      #   object = var.storage_bucket_object_name
      # }
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
      sql_hostname        = local.sql_private_ip[0],
      sql_password        = random_password.password.result,
      sql_databasename    = google_sql_database.webapp-sql.name,
      sql_username        = google_sql_user.webapp.name,
      mailgun_username    = var.mailgun_username,
      pubsub_topic_name   = var.pubsub_topic_name,
      webapp_domain_name  = var.webapp_domain_name,
      metadata_table_name = var.metadata_table_name,
      message_from        = var.message_from

    }

  }

  event_trigger {
    event_type            = var.event_trigger_event_type
    pubsub_topic          = google_pubsub_topic.verify_email.id
    retry_policy          = var.event_trigger_retry_policy
    trigger_region        = var.event_trigger_region
    service_account_email = google_service_account.pubsub_service_account.email
  }

  depends_on = [google_pubsub_topic.verify_email, google_service_account.pubsub_service_account]
}
# [End] Creating cloud function for pub/sub

# [Start] creating subscription for cloud functions
# resource "google_pubsub_subscription" "push_msg" {
#   name                       = "push-webapp-msg"
#   topic                      = google_pubsub_topic.verify_email.id
#   message_retention_duration = "604800s" #7days
#   retain_acked_messages      = false

#   ack_deadline_seconds = 120
#   push_config {
#     push_endpoint = google_cloudfunctions2_function.verify_email.url
#     oidc_token {
#       service_account_email = google_service_account.pubsub_service_account.email
#       audience              = google_cloudfunctions2_function.verify_email.url
#     }
#   }

#   retry_policy {
#     minimum_backoff = "10s"
#     maximum_backoff = "600s"
#   }

#   enable_message_ordering = false
# }

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

