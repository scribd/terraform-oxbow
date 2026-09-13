locals {
  region = "us-east-2"
  env    = "dev"
  prefix = "example-oxbow-full"

  bucket    = "scribdinc-data-lake-${local.env}"
  s3_path   = "catalogs/bronze_monolith"
  artifacts = "${local.prefix}-artifacts"
  topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events"

  tags = {
    env     = local.env
    service = "oxbow"
  }
}
