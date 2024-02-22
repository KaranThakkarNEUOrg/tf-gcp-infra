resource "google_compute_network" "vpc" {
  name                            = var.vpc_name
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp" {
  name          = var.subnet1_name
  ip_cidr_range = var.subnet1_ip_address
  network       = google_compute_network.vpc.self_link
  region        = var.region
}

resource "google_compute_subnetwork" "db" {
  name          = var.subnet2_name
  ip_cidr_range = var.subnet2_ip_address
  network       = google_compute_network.vpc.self_link
  region        = var.region
}

resource "google_compute_route" "webapp_route" {
  name             = var.route_name
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.vpc.name
  next_hop_gateway = "default-internet-gateway"
  tags             = [var.subnet1_name]
}

resource "google_compute_firewall" "firewall_allow_rules" {
  name    = "firewall-allow-rules"
  network = google_compute_network.vpc.self_link
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.subnet1_name, "http-server"]
}

resource "google_compute_firewall" "firewall_deny_rules" {
  name    = "firewall-deny-rules"
  network = google_compute_network.vpc.name
  deny {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.subnet1_name, "http-server"]
}


resource "google_compute_instance" "default" {
  name         = var.vm_instance_name
  machine_type = var.machine_type
  zone         = var.vm_instance_zone
  tags         = [var.subnet1_name, "http-server"]
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

}
