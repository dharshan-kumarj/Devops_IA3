# Every value you have to supply lives here. Nothing below has a secret in it:
# the subscription id is an identifier, not a credential, but it is still kept
# out of git so the repository says nothing about your Azure account.

variable "subscription_id" {
  description = "Azure subscription GUID. Get it with: az account show --query id -o tsv"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a 36-character GUID, e.g. 00000000-1111-2222-3333-444444444444."
  }
}

variable "prefix" {
  description = "Short name put in front of every resource, so two students sharing a subscription do not collide."
  type        = string
  default     = "mandi"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.prefix))
    error_message = "prefix must be 3-12 lowercase letters/digits and start with a letter."
  }
}

variable "location" {
  description = "Azure region. Must be one your subscription's region policy allows (see README)."
  type        = string
  default     = "indiasouthcentral"

  # An Azure for Students subscription carries an "Allowed resource deployment
  # regions" policy, and centralindia is NOT in it -- a deploy there fails with
  # RequestDisallowedByAzure (403) after the resource group has already been
  # created. List the regions yours permits with:
  #
  #   az policy assignment list --query "[].parameters" -o json
  #
  # On this subscription (checked 2026-10-27) that returned:
  #   indonesiacentral, koreacentral, malaysiawest, indiasouthcentral, eastasia
  # indiasouthcentral is the closest to the Indian mandi data this app serves.
}

variable "vm_size" {
  description = "VM SKU. B1ms is 1 vCPU / 2 GiB, which fits the app (measured at 407 MiB) and is the cheapest size that does."
  type        = string
  default     = "Standard_B1ms"
}

variable "admin_username" {
  description = "Linux login on the VM. Ansible and Jenkins both SSH in as this user."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the PUBLIC half of your SSH key. Azure disables password login entirely, so this is the only way in."
  type        = string
  default     = "~/.ssh/mandi_azure.pub"
}

variable "allowed_ssh_cidr" {
  description = "Who may reach port 22. Your own IP (e.g. 203.0.113.9/32) is far safer than the default; see README."
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_port" {
  description = "Port the app is published on. The container listens on 8000; Ansible maps this host port onto it."
  type        = number
  default     = 80
}

variable "tags" {
  description = "Tags written onto every resource, so you can find and delete the whole set later."
  type        = map(string)
  default = {
    project = "mandi-automl"
    course  = "devops-ia3"
    owner   = "student"
  }
}
