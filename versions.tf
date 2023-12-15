terraform {
  required_providers {
    # added datadog here because without it terrafrom is looking for provider in hashicorp/datadog - what is wrong
    datadog = {
      source = "datadog/datadog"
    }
  }
}
