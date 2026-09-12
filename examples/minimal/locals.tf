locals {
  region = "us-east-2"
  env    = "dev"
  prefix = "example-oxbow"

  warehouse_bucket = "scribdinc-data-lake-${local.env}"
  s3_path          = "catalogs/bronze_monolith"

  tags = {
    env     = local.env
    service = "oxbow"
  }
}
