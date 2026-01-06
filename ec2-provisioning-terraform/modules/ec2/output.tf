output "instances" {
  description = "Provisioned EC2 instance attributes"
  value = {
    for k, v in aws_instance.this :
    k => {
      id         = v.id
      private_ip = v.private_ip
      public_ip  = v.public_ip
      az         = v.availability_zone
      state      = v.instance_state
      tags       = v.tags
    }
  }
}
