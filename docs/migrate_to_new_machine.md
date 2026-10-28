# Moving this deployment to a different laptop

Same Azure subscription, same code, new machine. The Azure resources stay
exactly where they are — nothing is recreated and the public IP does not change.

**Time:** about 30 minutes, most of it waiting on installs.

---

## What actually has to move

Both repositories are on GitHub, so the code is not the problem. **Four files
live outside git** and cannot be recovered from GitHub:

| File | Why it matters |
|---|---|
| `terraform/terraform.tfstate` | Terraform's only record that your 8 Azure resources exist |
| `terraform/terraform.tfvars` | your subscription id and settings |
| `~/.ssh/mandi_azure` | the private key the VM accepts |
| `~/.ssh/mandi_azure.pub` | its public half, which Terraform reads |

### The state file is the one to be careful with

Terraform does not ask Azure what exists. It reads `terraform.tfstate`. On a
machine with no state file, `terraform apply` believes **nothing exists** and
tries to build a second complete deployment — which either fails on name
collisions or, worse, succeeds and quietly bills you twice.

Equally, never run `terraform destroy` from a machine whose state is stale.

---

## Path A — you still have the old laptop

### 1. On the OLD laptop

```bash
cd ~/projects/devops_IA3
bash scripts/migrate_machine.sh export
```

This writes `~/mandi-migration-<date>.tar.gz` containing the four files and a
manifest.

> **The bundle holds a private key.** Move it on a USB stick, or `scp` it
> straight to the new machine. Do not email it, put it in Drive, or send it
> through WhatsApp. Delete it from both machines afterwards.

```bash
scp ~/mandi-migration-*.tar.gz <you>@<new-laptop>:~/
```

### 2. On the NEW laptop — install the tools

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"     # log out and back in after this

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Terraform + Ansible + git
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform ansible git

# uv, for running the application locally
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### 3. Clone both repositories

```bash
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/dharshan-kumarj/AutoML_IA3.git automl_IA3
git clone https://github.com/dharshan-kumarj/Devops_IA3.git devops_IA3
```

> Use SSH URLs instead if you want to push, and add that machine's own GitHub
> key first. The GitHub key and the Azure deploy key are different things —
> do not reuse `mandi_azure` for GitHub.

### 4. Restore the four files

```bash
cd ~/projects/devops_IA3
az login
bash scripts/migrate_machine.sh import ~/mandi-migration-*.tar.gz
```

The script restores the files with correct permissions, confirms the key parses,
and then runs `terraform plan` to check that the state still matches Azure. You
want it to report **no changes**. If it reports differences, read the plan
before applying anything.

```bash
shred -u ~/mandi-migration-*.tar.gz     # or just rm
```

### 5. Confirm you can reach the VM

```bash
az vm start -g mandi-rg -n mandi-vm          # if it is deallocated
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 'docker ps'
curl http://172.198.79.131/api/health
```

### 6. Jenkins

Jenkins' credentials are encrypted with a key unique to each installation, so
they cannot be copied — recreate them. This is the longest manual part, about
ten minutes.

```bash
cd ~/projects/devops_IA3
sudo bash scripts/install_jenkins.sh
```

It prints the unlock password. Then at <http://localhost:8080>:

1. Install suggested plugins, create your admin user
2. **Manage Jenkins → Plugins**: install **Docker Pipeline** and **SSH Agent**
3. **Manage Jenkins → Credentials → System → Global** — add all three. The IDs
   must match exactly:

| Kind | ID | Value |
|---|---|---|
| Username with password | `ghcr-credentials` | `dharshan-kumarj` + a classic PAT with `write:packages` |
| SSH Username with private key | `azure-vm-ssh` | username `azureuser`, the restored `~/.ssh/mandi_azure` |
| Secret text | `azure-vm-ip` | `172.198.79.131` |

> For the SSH key, copy it with a tool rather than selecting the text:
> `sudo apt install -y xclip && xclip -selection clipboard < ~/.ssh/mandi_azure`
> A hand-selected paste usually loses the trailing newline, and OpenSSH then
> fails with `Load key: error in libcrypto`.

4. **New Item** → `mandi-devops` → **Pipeline**
   - Build Triggers: **Poll SCM**, `H/2 * * * *`
   - Pipeline → Definition: **Pipeline script from SCM**  ← not "Pipeline script"
   - SCM **Git**, URL `https://github.com/dharshan-kumarj/AutoML_IA3.git`
   - Branch `*/main`, Script Path `Jenkinsfile`
5. **Build Now**

### 7. Prove it end to end

```bash
cd ~/projects/automl_IA3
git commit --allow-empty -m "Verify the pipeline from the new machine"
git push
```

Leave Jenkins alone. Within two minutes Poll SCM should trigger a build that
goes green through all seven stages.

---

## Path B — the old laptop is gone or unusable

Both missing pieces are recoverable. Neither requires rebuilding anything.

### Rebuild the Terraform state by importing

Terraform can adopt resources that already exist. Create `terraform.tfvars`
first (the example file shows the fields; get the subscription id with
`az account show --query id -o tsv`), then:

```bash
cd ~/projects/devops_IA3/terraform
terraform init

SUB=$(az account show --query id -o tsv)
RG="/subscriptions/$SUB/resourceGroups/mandi-rg"
NET="$RG/providers/Microsoft.Network"

terraform import azurerm_resource_group.main "$RG"
terraform import azurerm_virtual_network.main "$NET/virtualNetworks/mandi-vnet"
terraform import azurerm_subnet.app "$NET/virtualNetworks/mandi-vnet/subnets/mandi-subnet-app"
terraform import azurerm_network_security_group.app "$NET/networkSecurityGroups/mandi-nsg"
terraform import azurerm_subnet_network_security_group_association.app "$NET/virtualNetworks/mandi-vnet/subnets/mandi-subnet-app"
terraform import azurerm_public_ip.app "$NET/publicIPAddresses/mandi-pip"
terraform import azurerm_network_interface.app "$NET/networkInterfaces/mandi-nic"
terraform import azurerm_linux_virtual_machine.app "$RG/providers/Microsoft.Compute/virtualMachines/mandi-vm"

terraform plan     # should report no changes once all eight are imported
```

If `plan` still wants to change something, read it carefully — it usually means
a variable in `terraform.tfvars` does not match what is actually deployed, and
the fix is to correct the variable rather than to apply.

### Issue a new SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mandi_azure -C "mandi-automl deploy key" -N ""
az vm user update -g mandi-rg -n mandi-vm \
  --username azureuser \
  --ssh-key-value "$(cat ~/.ssh/mandi_azure.pub)"
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 'echo ok'
```

**Then point `terraform.tfvars` at the new public key** and run
`terraform plan`. If the plan proposes *replacing the virtual machine*, stop:
`admin_ssh_key` forces replacement in the `azurerm` provider, and applying
would destroy and rebuild the VM. Aligning the variable with the key you just
installed should leave the plan clean. Do not apply a plan that says
`must be replaced` unless you intend exactly that.

---

## Avoiding this next time: remote state

The underlying problem is that Terraform state lives on one laptop. Keeping it
in Azure Storage instead means any machine with `az login` picks it up, and
teammates cannot overwrite each other.

```hcl
# in terraform/versions.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "mandi-tfstate-rg"
    storage_account_name = "<globally unique name>"
    container_name       = "tfstate"
    key                  = "mandi.tfstate"
  }
}
```

Create the storage account first, then `terraform init -migrate-state`.

This is the right answer for real work. It is **not** worth doing the week of a
demo: a botched backend migration can orphan your resources, and the migration
script above solves the immediate problem without touching state.

---

## Quick checklist

```
[ ] OLD: bash scripts/migrate_machine.sh export
[ ] transfer the bundle by USB or scp (NOT email/cloud/chat)
[ ] NEW: install docker, az, terraform, ansible, git, uv
[ ] NEW: clone both repos into ~/projects
[ ] NEW: az login
[ ] NEW: bash scripts/migrate_machine.sh import <bundle>
[ ] NEW: terraform plan  ->  expect "no changes"
[ ] NEW: ssh to the VM, curl /api/health
[ ] NEW: sudo bash scripts/install_jenkins.sh
[ ] NEW: install Docker Pipeline + SSH Agent plugins
[ ] NEW: add ghcr-credentials, azure-vm-ssh, azure-vm-ip
[ ] NEW: create the pipeline job (Pipeline script FROM SCM)
[ ] NEW: Build Now, then push a commit to prove Poll SCM
[ ] BOTH: delete the bundle
[ ] OLD: once satisfied, remove ~/.ssh/mandi_azure and the tfstate
```
