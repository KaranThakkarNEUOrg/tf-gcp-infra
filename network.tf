resource "google_compute_network" "vpc" {
  name                            = "csye-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp" {
  name          = "webapp"
  ip_cidr_range = "10.0.0.0/24"
  network       = google_compute_network.vpc.self_link
  region        = var.region
}

resource "google_compute_subnetwork" "db" {
  name          = "db"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.vpc.self_link
  region        = var.region
}

resource "google_compute_route" "webapp_route" {
  name             = "webapp-route"
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.vpc.name
  next_hop_gateway = "default-internet-gateway"
  tags             = ["webapp"]
}
