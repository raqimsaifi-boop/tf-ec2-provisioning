terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# New: network selection by tags with optional overrides (used by Lambda)
variable "network" {
  description = <<EOT
Network selector. Either provide explicit IDs (vpc_id, subnet_id, security_group_ids)
or provide tag filters for discovery. Lambda will typically preselect subnet_id (round-robin)
and optionally SGs; Terraform can still fallback to tags-only if not provided.
EOT
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
  description = "EC2 instances to create. Mandatory tags are validated."
  type = list(object({
    name                 = string
    ami_id               = optional(string)
    ami_ssm_param        = optional(string)
    instance_type        = string
    key_name             = string
    iam_instance_profile = string
    enable_public_ip     = bool

    # If not passed, subnet & SGs are discovered via var.network
    subnet_id            = optional(string)
    security_group_ids   = optional(list(string))

    ebs_root_size_gb     = number
    ebs_root_type        = string
    ebs_root_iops        = optional(number)
    additional_volumes   = optional(list(object({
      device_name = string
      size_gb     = number
      type        = string
      iops        = optional(number)
      encrypted   = bool
    })), [])
    user_data_base64     = optional(string)
    tags                 = map(string)
  }))

  # Mandatory tag validation
  validation {
    condition = alltrue([
      for i in var.instances : (
        can(i.tags["Application"]) &&
        can(i.tags["Technical Owner"]) &&
        can(i.tags["Business Owner"]) &&
        can(i.tags["Environment"]) &&
        contains(["Training","Production","Dev","Test","UAT","Staging"], i.tags["Environment"]) &&
        can(i.tags["Criticality"]) && contains(["Critical","Major","Moderate","Minor"], i.tags["Criticality"]) &&
        can(i.tags["Data Sensitivity"]) && contains(["High","Medium","Low"], i.tags["Data Sensitivity"]) &&
        can(i.tags["DeleteOn"]) && can(regex("^\\d{4}-\\d{2}-\\d{2}$", i.tags["DeleteOn"])) &&
        can(i.tags["Schedule"]) &&
        can(i.tags["CreationDate"]) && can(regex("^\\d{4}-\\d{2}-\\d{2}$", i.tags["CreationDate"]))
      )
    ])
    error_message = "Missing/invalid mandatory tags. Dates must be YYYY-MM-DD; Environment in [Training, Production, Dev, Test, UAT, Staging]."
  }

  validation {
    condition = alltrue([
      for i in var.instances : (
        (try(i.ami_id, null) != null) || (try(i.ami_ssm_param, null) != null)
      )
    ])
    error_message = "Provide either ami_id or ami_ssm_param for each instance."
  }
}
