terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.42"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = local.region
}

provider "datadog" {}
