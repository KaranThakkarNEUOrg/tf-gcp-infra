resource "google_compute_network" "vpc" {
  name                            = var.vpc_name
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp" {
  name          = var.subnet1_nam
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

resource "google_compute_firewall" "firewall" {
  name    = "allow-traffic"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = [80, 8080, 22]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "vm_instance" {
  name         = "terraform-instance"
  machine_type = "e2-medium"
  zone         = "us-east1-b"
  boot_disk {
    initialize_params {
      image = "csye-centos-8"
      size  = "100"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.webapp.name
  }
}
