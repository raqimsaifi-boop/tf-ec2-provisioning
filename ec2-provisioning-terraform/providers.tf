# provider "aws" {
#   region = var.region
# }



# providers.tf
provider "aws" {
  region = var.region

  # assume into target account for all resource operations
  assume_role {
    role_arn     = var.target_role_arn
    session_name = "tf-session"
    # external_id  = var.external_id  # if your trust requires it
  }
}
