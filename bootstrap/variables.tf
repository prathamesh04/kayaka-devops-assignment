variable "aws_region" {
  description = "AWS region for the OIDC provider and roles"
  type        = string
  default     = "ap-south-1"
}

variable "github_repo" {
  description = "GitHub repository in the form owner/repo that pipelines run from"
  type        = string
  default     = "prathamesh04/kayaka-devops-assignment"
}

variable "state_bucket" {
  description = "S3 bucket that holds Terraform state"
  type        = string
  default     = "kayaka-terraform-state"
}

variable "lock_table" {
  description = "DynamoDB table used for Terraform state locking"
  type        = string
  default     = "terraform-locks"
}