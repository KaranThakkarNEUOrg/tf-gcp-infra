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
  name             = var.sql_database_instance_name
  database_version = "MYSQL_8_0"
  region           = var.sql_db_instance_region
  depends_on       = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier                        = var.sql_db_instance_tier
    deletion_protection_enabled = false

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_service_networking_connection.private_vpc_connection.network
    }

    disk_autoresize = true
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
  length  = 16
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
