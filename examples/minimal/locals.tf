locals {
  region = "us-east-2"
  env    = "dev"
  prefix = "example-oxbow"

  bucket  = "example-data-lake-${local.env}"
  s3_path = "catalogs/bronze_monolith"

  tags = {
    env     = local.env
    service = "oxbow"
  }
}
