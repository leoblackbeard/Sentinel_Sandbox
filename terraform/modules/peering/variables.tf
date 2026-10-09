variable "requester_vpc_id" {
  type = string
}

variable "accepter_vpc_id" {
  type = string
}

variable "requester_cidr" {
  type = string
}

variable "accepter_cidr" {
  type = string
}

variable "requester_route_table_id" {
  type = string
}

variable "accepter_route_table_id" {
  type = string
}

variable "requester_region" {
  type    = string
  default = "eu-central-1"
}

variable "accepter_region" {
  type    = string
  default = "eu-central-1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
