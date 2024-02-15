variable "vpc_names" {
  description = "List of VPC names"
  type        = list(string)
  default     = ["csye-vpc"]
}

resource "google_compute_network" "vpc" {
  for_each                        = toset(var.vpc_names)
  name                            = each.value
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "webapp" {
  for_each      = google_compute_network.vpc
  name          = "${each.value.name}-webapp"
  ip_cidr_range = "10.0.0.0/24"
  network       = each.value.self_link
  region        = var.region
}

resource "google_compute_subnetwork" "db" {
  for_each      = google_compute_network.vpc
  name          = "${each.value.name}-db"
  ip_cidr_range = "10.0.1.0/24"
  network       = each.value.self_link
  region        = var.region
}

resource "google_compute_route" "webapp_route" {
  for_each         = google_compute_subnetwork.webapp
  name             = "${each.value.name}-route"
  dest_range       = "0.0.0.0/0"
  network          = each.value.network
  next_hop_gateway = "default-internet-gateway"
  tags             = ["webapp"]
}
