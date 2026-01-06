variable "region" {
  description = "AWS region for provider"
  type        = string
  default     = "ap-south-1"
}

variable "network" {
  description = "See modules/ec2/variables.tf"
  type = object({
    vpc_tag_filters     = optional(map(string), {})
    subnet_tag_filters  = optional(map(string), {})
    sg_tag_filters      = optional(map(string), {})
    vpc_id              = optional(string)
    subnet_id           = optional(string)
    security_group_ids  = optional(list(string))
  })
  default = {
    vpc_tag_filters    = {}
    subnet_tag_filters = {}
    sg_tag_filters     = {}
  }
}

variable "instances" {
  description = "List of instances"
  type        = list(any)
}
