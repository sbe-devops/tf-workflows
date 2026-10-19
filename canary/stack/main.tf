# CANARY FIXTURE (branch canary/checkov-v12-3134 only, never merged): a stack that is
# one PUBLIC module call, the shape of FB's tst/wireguard. Without module download
# checkov sees one check here; with it, the module's resources.
module "bucket" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket.git?ref=v4.1.2"
  bucket = "canary-checkov-sees-modules"
}
