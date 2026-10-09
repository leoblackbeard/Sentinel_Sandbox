provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project     = "sentinel-split-architecture"
      Environment = "sandbox"
      ManagedBy   = "terraform"
    }
  }
}
