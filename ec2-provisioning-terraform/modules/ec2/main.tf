locals {
  instances_by_name = { for i in var.instances : i.name => i }
}

# --- VPC discovery ---
data "aws_vpcs" "candidates" {
  dynamic "filter" {
    for_each = var.network.vpc_tag_filters
    content {
      name   = "tag:${filter.key}"
      values = [filter.value]
    }
  }
}

# Select explicit vpc_id if provided; else first match
locals {
  selected_vpc_id = coalesce(
    try(var.network.vpc_id, null),
    try(element(data.aws_vpcs.candidates.ids, 0), null)
  )
}

# --- Subnet discovery ---
data "aws_subnets" "candidates" {
  filter {
    name   = "vpc-id"
    values = [local.selected_vpc_id]
  }

  dynamic "filter" {
    for_each = var.network.subnet_tag_filters
    content {
      name   = "tag:${filter.key}"
      values = [filter.value]
    }
  }
}

# Lambda can precompute a subnet_id (round-robin). Otherwise pick first.
locals {
  fallback_subnet_id = try(element(data.aws_subnets.candidates.ids, 0), null)
}

# --- Security Group discovery ---
data "aws_security_groups" "candidates" {
  filter {
    name   = "vpc-id"
    values = [local.selected_vpc_id]
  }

  dynamic "filter" {
    for_each = var.network.sg_tag_filters
    content {
      name   = "tag:${filter.key}"
      values = [filter.value]
    }
  }
}

locals {
  fallback_sg_ids = try(data.aws_security_groups.candidates.ids, [])
}



# --- Helpers to normalize SSM parameter names ---
locals {
  # 1) Strip any accidental "ssm:" prefix (case-insensitive) from ami_ssm_param
  #    Use regexreplace, not replace, since we need ^ prefix and (?i) case-insensitivity.
  instances_with_clean_ssm = {
    for n, i in local.instances_by_name : n => merge(i, {
      ami_ssm_param = (
        try(i.ami_ssm_param, null) != null
        ? regexreplace(i.ami_ssm_param, "(?i)^ssm:", "")
        : null
      )
    })
  }

  # 2) Ensure exactly one leading slash and no trailing slash
  #    "path" -> "/path"
  #    "//path" -> "/path"
  #    "/path/" -> "/path"
  instances_by_name_ssm_sanitized = {
    for n, i in local.instances_with_clean_ssm : n => merge(i, {
      ami_ssm_param = (
        try(i.ami_ssm_param, null) != null
        ? "/" + trim(i.ami_ssm_param, "/")
        : null
      )
    })
  }
}

# --- AMI via SSM Parameter (optional) ---
data "aws_ssm_parameter" "ami" {
  for_each = {
    for n, i in local.instances_by_name_ssm_sanitized :
    n => i if try(i.ami_ssm_param, null) != null
  }

  name            = each.value.ami_ssm_param
  with_decryption = false  # AMI ID parameter is plain String, not SecureString
}

# --- Effective AMI selection (prefer explicit ami_id, else SSM) ---
locals {
  effective_ami = {
    for n, i in local.instances_by_name_ssm_sanitized : n =>
      (try(i.ami_id, null) != null ? i.ami_id : data.aws_ssm_parameter.ami[n].value)
  }
}


resource "aws_instance" "this" {
  for_each = local.instances_by_name

  ami                    = local.effective_ami[each.key]
  instance_type          = each.value.instance_type

  # Prefer per-instance override; else use network.subnet_id from Lambda; else fallback to tags
  subnet_id              = coalesce(
    try(each.value.subnet_id, null),
    try(var.network.subnet_id, null),
    local.fallback_subnet_id
  )

  vpc_security_group_ids = coalesce(
    try(each.value.security_group_ids, null),
    try(var.network.security_group_ids, null),
    local.fallback_sg_ids
  )

  key_name               = each.value.key_name
  iam_instance_profile   = each.value.iam_instance_profile
  associate_public_ip_address = each.value.enable_public_ip

  root_block_device {
    volume_size = each.value.ebs_root_size_gb
    volume_type = each.value.ebs_root_type
    iops        = try(each.value.ebs_root_iops, 0) > 0 ? each.value.ebs_root_iops : null
    encrypted   = true
    delete_on_termination = true
  }

  dynamic "ebs_block_device" {
    for_each = try(each.value.additional_volumes, [])
    content {
      device_name           = ebs_block_device.value.device_name
      volume_size           = ebs_block_device.value.size_gb
      volume_type           = ebs_block_device.value.type
      iops                  = try(ebs_block_device.value.iops, 0) > 0 ? ebs_block_device.value.iops : null
      encrypted             = ebs_block_device.value.encrypted
      delete_on_termination = true
    }
  }

  user_data_base64 = try(each.value.user_data_base64, null)

  tags = merge(
    {
      "Name"            = each.value.name,
      "ManagedBy"       = "Terraform",
      "ProvisionSource" = "Lambda+CodeBuild"
    },
    each.value.tags
  )

  # Guardrails so Terraform fails early if discovery fails
  lifecycle {
    precondition {
      condition     = local.selected_vpc_id != null
      error_message = "No VPC matched tag filters and no vpc_id override was provided."
    }
    precondition {
      condition     = coalesce(try(each.value.subnet_id, null), try(var.network.subnet_id, null), local.fallback_subnet_id) != null
      error_message = "No Subnet matched tag filters and no subnet_id override was provided."
    }
    precondition {
      condition     = length(coalesce(try(each.value.security_group_ids, null), try(var.network.security_group_ids, null), local.fallback_sg_ids)) > 0
      error_message = "No Security Groups matched tag filters and no security_group_ids override was provided."
    }
  }
}
