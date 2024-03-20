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

  source_ranges = var.source_ranges
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
  special = true
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
resource "google_compute_instance" "default" {
  name         = var.vm_instance_name
  machine_type = var.machine_type
  zone         = var.vm_instance_zone
  tags         = [var.subnet1_name]
  depends_on   = [google_service_account.ops_agent_service_account, google_project_iam_binding.logging_admin, google_project_iam_binding.monitoring_metric_writer]
  boot_disk {
    initialize_params {
      image = var.image_name
      size  = var.instance_size
      type  = var.instance_type
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
# [End]

# [Start] DNS connection to VM
resource "google_dns_record_set" "a-record" {
  name         = var.domain_name
  type         = "A"
  ttl          = var.ttl
  managed_zone = var.managed_zone_dns
  rrdatas      = [google_compute_instance.default.network_interface.0.access_config.0.nat_ip]
}
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
# # [End] Service Account Binding


