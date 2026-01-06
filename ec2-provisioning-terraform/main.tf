module "ec2" {
  source    = "./modules/ec2"
  network   = var.network
  instances = var.instances
}
