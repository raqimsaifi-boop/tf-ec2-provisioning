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



# --- Helpers to normalize SSM parameter names (Terraform-standard, no regex) ---
locals {
  # 1) Case-insensitive removal of a leading "ssm:" (without altering the rest)
  #    Use substr/lower to test the first 4 chars, then slice if needed.
  instances_with_clean_ssm = {
    for n, i in local.instances_by_name : n => merge(i, {
      ami_ssm_param = (
        try(i.ami_ssm_param, null) != null
        ? (
            length(i.ami_ssm_param) >= 4 && lower(substr(i.ami_ssm_param, 0, 4)) == "ssm:"
            ? substr(i.ami_ssm_param, 4, length(i.ami_ssm_param) - 4)
            : i.ami_ssm_param
          )
        : null
      )
    })
  }

  # 2) Ensure exactly one leading slash and no trailing slash
  #    "path"    -> "/path"
  #    "//path"  -> "/path"
  #    "/path/"  -> "/path"
  instances_by_name_ssm_sanitized = {
    for n, i in local.instances_with_clean_ssm : n => merge(i, {
      ami_ssm_param = (
        try(i.ami_ssm_param, null) != null
        ? "/${trim(i.ami_ssm_param, "/")}"        # <-- interpolation, not '+'
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
  with_decryption = false  # SSM value is a plain String AMI ID
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

  # --- Core inputs from your tfvars/Lambda ---
  ami               = local.effective_ami[each.key]
  instance_type     = each.value.instance_type
  subnet_id         = coalesce(
    try(each.value.subnet_id, null),
    try(var.network.subnet_id, null),
    local.fallback_subnet_id
  )
  
  vpc_security_group_ids = coalesce(
    try(each.value.security_group_ids, null),
    try(var.network.security_group_ids, null),
    local.fallback_sg_ids
  )
  key_name              = each.value.key_name
  iam_instance_profile  = each.value.iam_instance_profile
  associate_public_ip_address = try(each.value.enable_public_ip, false)

  # --- Root volume (encrypted) ---
  root_block_device {
    volume_size           = each.value.ebs_root_size_gb
    volume_type           = each.value.ebs_root_type
    iops                  = try(each.value.ebs_root_iops, 0) > 0 ? each.value.ebs_root_iops : null
    encrypted             = true
    # OPTIONAL: If your SCP mandates CMK, set this to an approved KMS key ARN.
    # kms_key_id            = try(var.kms_key_arn, null)
    delete_on_termination = true
  }

  # --- Additional EBS volumes (if provided in tfvars) ---
  dynamic "ebs_block_device" {
    for_each = try(each.value.additional_volumes, [])
    content {
      device_name           = ebs_block_device.value.device_name
      volume_size           = ebs_block_device.value.size_gb
      volume_type           = ebs_block_device.value.type
      iops                  = try(ebs_block_device.value.iops, 0) > 0 ? ebs_block_device.value.iops : null
      encrypted             = try(ebs_block_device.value.encrypted, true)
      # OPTIONAL: uncomment if SCP enforces CMK usage on all volumes.
      # kms_key_id            = try(var.kms_key_arn, null)
      delete_on_termination = true
    }
  }

  # --- User data (optional) ---
  user_data_base64 = try(each.value.user_data_base64, null)

  # --- Instance tags (dynamic from tfvars + standard) ---
  tags = merge(
    {
      Name            = each.value.name,
      ManagedBy       = "Terraform",
      ProvisionSource = "Lambda+CodeBuild"
    },
    try(each.value.tags, {})
  )

  # --- Volume tags (root + EBS volumes created with this instance) ---
  # Tags applied at instance creation time to block devices.
  volume_tags = merge(
    {
      Name            = each.value.name,
      ManagedBy       = "Terraform",
      ProvisionSource = "Lambda+CodeBuild"
    },
    try(each.value.tags, {})
  )

  # --- Guardrails to fail early if discovery didn’t find required infra ---
  lifecycle {
    precondition {
      condition     = local.selected_vpc_id != null
      error_message = "No VPC matched tag filters and no vpc_id override was provided."
    }
    precondition {
      condition     = coalesce(
        try(each.value.subnet_id, null),
        try(var.network.subnet_id, null),
        local.fallback_subnet_id
      ) != null
      error_message = "No Subnet matched tag filters and no subnet_id override was provided."
    }
    precondition {
      condition     = length(coalesce(
        try(each.value.security_group_ids, null),
        try(var.network.security_group_ids, null),
        local.fallback_sg_ids
      )) > 0
      error_message = "No Security Groups matched tag filters and no security_group_ids override was provided."
    }
  }
}


