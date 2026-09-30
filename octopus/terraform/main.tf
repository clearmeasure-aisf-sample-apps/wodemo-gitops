# The Octopus objects around the project wodemo: environments, lifecycle, project group, container feed and the
# project shell. The project's deployment process, settings and variables are config-as-code in .octopus/wodemo/ of this
# repository (read anonymously, because the repository is public).
#
# NOT YET APPLIED: applying needs an Octopus API key, which no automation of this demo holds. See the README, "Octopus".
#   $env:OCTOPUS_URL, $env:OCTOPUS_API_KEY (Space Manager), then from this folder:
#   terraform init; terraform apply -var "space_id=Spaces-335"
# Written against provider OctopusDeployLabs/octopusdeploy 1.x; validate with `terraform validate` before the first apply.
terraform {
  required_version = ">= 1.6"
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeployLabs/octopusdeploy"
      version = "~> 1.0"
    }
  }
}

variable "octopus_url" {
  type        = string
  description = "Octopus Deploy base URL"
  default     = "https://clearmeasure.octopus.app"
}

variable "octopus_api_key" {
  type        = string
  sensitive   = true
  description = "Space Manager API key (TF_VAR_octopus_api_key); never stored in Git"
}

variable "space_id" {
  type        = string
  description = "Octopus space that holds the wodemo project"
}

provider "octopusdeploy" {
  address  = var.octopus_url
  api_key  = var.octopus_api_key
  space_id = var.space_id
}

resource "octopusdeploy_environment" "tdd" {
  name        = "wodemo-tdd"
  description = "wodemo demo: test-driven environment, deployed automatically"
}

resource "octopusdeploy_environment" "uat" {
  name        = "wodemo-uat"
  description = "wodemo demo: user acceptance"
}

resource "octopusdeploy_environment" "prod" {
  name        = "wodemo-prod"
  description = "wodemo demo: production"
}

resource "octopusdeploy_lifecycle" "wodemo" {
  name        = "wodemo"
  description = "tdd automatically, then uat, then prod (prod asks for a go/no-go)"

  phase {
    name                        = "wodemo-tdd"
    automatic_deployment_targets = [octopusdeploy_environment.tdd.id]
  }
  phase {
    name                        = "wodemo-uat"
    optional_deployment_targets = [octopusdeploy_environment.uat.id]
  }
  phase {
    name                        = "wodemo-prod"
    optional_deployment_targets = [octopusdeploy_environment.prod.id]
  }
}

resource "octopusdeploy_project_group" "wodemo" {
  name        = "wodemo"
  description = "The wodemo demo app (GitHub Actions CI, Argo CD)"
}

# Images are published to the Azure Container Registry by the release workflow of wodemo-app (repositories wodemo/<image>).
# Octopus reads the versions with a pull-scoped credential of your own (for example an ACR repository-scoped token with
# content/read); it is passed as a sensitive variable and never stored in Git.
variable "acr_username" {
  type        = string
  description = "Username of a pull-scoped ACR token"
}

variable "acr_password" {
  type        = string
  sensitive   = true
  description = "Password of that token"
}

resource "octopusdeploy_docker_container_registry" "acr" {
  name                           = "acr-wodemo"
  feed_uri                       = "https://acrwodemoce304.azurecr.io"
  api_version                    = "v2"
  username                       = var.acr_username
  password                       = var.acr_password
  download_attempts              = 3
  download_retry_backoff_seconds = 10
}

resource "octopusdeploy_project" "wodemo" {
  name                                 = "wodemo"
  description                          = "Work-order demo app: pins image tags through Argo CD"
  lifecycle_id                         = octopusdeploy_lifecycle.wodemo.id
  project_group_id                     = octopusdeploy_project_group.wodemo.id
  is_version_controlled                = true
  auto_create_release                  = false
  default_to_skip_if_already_installed = false

  git_anonymous_persistence_settings {
    url                = "https://github.com/clearmeasure-aisf-sample-apps/wodemo-gitops.git"
    base_path          = ".octopus/wodemo"
    default_branch     = "main"
    protected_branches = ["main"]
  }
}

output "project_id" {
  value = octopusdeploy_project.wodemo.id
}
