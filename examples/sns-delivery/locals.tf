locals {
  region = "us-east-2"
  env    = "dev"
  prefix = "example-oxbow-sns"

  warehouse_bucket = "scribdinc-data-lake-${local.env}"
  s3_path          = "catalogs/bronze_monolith"

  # A topic the bucket already fans its object-created events out to.
  topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events"

  tags = {
    env     = local.env
    service = "oxbow"
  }
}
