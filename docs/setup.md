# Setup run book

Everything you have to supply by hand, where to get it, and the order to do it in.
Follow top to bottom; each step depends on the one before it.

---

## Part 0 — What you need to collect (summary)

| # | Value | Where it goes | How to get it |
|---|---|---|---|
| 1 | Azure Subscription ID | `terraform/terraform.tfvars` | Step 2 |
| 2 | SSH **public** key path | `terraform/terraform.tfvars` | Step 3 |
| 3 | SSH **private** key | Jenkins credential `azure-vm-ssh` | Step 3 |
| 4 | GitHub username | Jenkins credential `ghcr-credentials` | you already know it |
| 5 | GitHub token (PAT) | Jenkins credential `ghcr-credentials` | Step 4 |
| 6 | VM public IP | Jenkins credential `azure-vm-ip` | Step 6, after `terraform apply` |
| 7 | Your own public IP *(optional)* | `terraform/terraform.tfvars` | `curl -s ifconfig.me` |

**You do not need an Azure Service Principal.** You would only need one if Jenkins
itself ran Terraform. Here you run Terraform by hand once, and Jenkins only
deploys containers over SSH — so `az login` in your own browser is enough. That
is one fewer secret to create, store and explain.

---

## Part 1 — Install the tools

Docker is already installed on your machine. These three are not.

```bash
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Terraform (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# Ansible
sudo apt install -y ansible
```

Check all four:

```bash
az version && terraform version && ansible --version && docker --version
```

Jenkins is installed in Part 7.

---

## Step 2 — Azure Subscription ID

**What it is:** a GUID naming which Azure account gets billed and holds the
resources. It is an identifier, not a password — but it still stays out of git.

**Command line (easiest):**

```bash
az login                 # opens a browser; sign in with your student account
az account show --query id -o tsv
```

That prints something like `3f1b9c42-7d10-4a8e-b2c6-9e5a0d7f4c11`.

**Or in the portal:** <https://portal.azure.com> → type **Subscriptions** in the
top search bar → click your subscription (it will be called *Azure for Students*)
→ the **Subscription ID** is on the Overview page, with a copy button next to it.

**If you have more than one subscription**, list them and pick:

```bash
az account list --output table
az account set --subscription "Azure for Students"
```

### Check which regions you are allowed to use

Do this *before* `terraform apply`, not after. A student subscription carries an
**"Allowed resource deployment regions"** policy, and it is narrower than what
Azure offers generally. Deploying outside it fails with a `403
RequestDisallowedByAzure` — and it fails *after* the resource group has already
been created, which looks alarming but is harmless.

```bash
az policy assignment list --query "[].parameters" -o json
```

On this subscription (checked 2026-10-27) that returned:

```
indonesiacentral   koreacentral   malaysiawest   indiasouthcentral   eastasia
```

Note that `centralindia` and `southindia` are **not** in that list, despite both
existing in Azure. `indiasouthcentral` is the closest allowed region to the
Indian mandi data this app serves, and is the default in `variables.tf`.

Your teammates' subscriptions may well allow a different set, so each of you
should run this and set `location` in your own `terraform.tfvars` accordingly.
Confirm the VM size exists there too:

```bash
az vm list-skus --location <region> --resource-type virtualMachines \
  --query "[?name=='Standard_B1ms'].{name:name,restrictions:restrictions}" -o json
```

An empty `restrictions` list means you can use it.

**Check your remaining credit** while you are there — Portal → **Cost Management
+ Billing** → **Credits**. A `Standard_B1ms` runs roughly ₹1,100–1,400/month, so a
$100 student credit lasts the project easily, but only if you run
`terraform destroy` when you are done.

---

## Step 3 — SSH key pair

**What it is:** the only way into the VM. Terraform puts the **public** half on
the VM at creation time; Jenkins uses the **private** half to deploy. Azure
refuses password logins entirely, so if you lose the private key you must
recreate the VM.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mandi_azure -C "mandi-automl deploy key" -N ""
```

That writes two files:

| File | Half | Goes to |
|---|---|---|
| `~/.ssh/mandi_azure.pub` | public | `terraform.tfvars` → onto the VM |
| `~/.ssh/mandi_azure` | **private** | Jenkins credential `azure-vm-ssh` |

`-N ""` means no passphrase. That is deliberate: Jenkins runs unattended and
cannot type one. The key is a deploy key for a throwaway course VM, not your
GitHub key — keep them separate, which is why it has its own filename.

**Never commit the private one.** The repo's `.gitignore` already blocks
`id_rsa*`, `id_ed25519*`, `*.pem` and `*.key`, but the safest thing is that it
lives in `~/.ssh/` and never goes near the project folder.

---

## Step 4 — GitHub token for GHCR

**What it is:** Jenkins pushes the built Docker image to GitHub Container
Registry, and the Azure VM pulls it back down. Both need a token; your GitHub
password will not work.

1. Go to <https://github.com/settings/tokens>
2. **Generate new token** → **Generate new token (classic)**
   *(classic, not fine-grained — GHCR's support for fine-grained tokens is still
   incomplete and silently fails on pull)*
3. **Note:** `jenkins-ghcr-mandi`
4. **Expiration:** 90 days is plenty for a course project
5. **Scopes** — tick exactly these:
   - [x] `write:packages` *(ticking this auto-ticks `read:packages` and `repo`)*
   - [x] `delete:packages` *(optional, lets you clean up old images)*
6. **Generate token**, then **copy it immediately** — GitHub shows it once and
   never again. Paste it somewhere safe for the next ten minutes.

Format: `ghp_` followed by 36 characters.

---

## Step 5 — Fill in terraform.tfvars

```bash
cd ~/projects/devops_IA3/terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

Set at minimum:

```hcl
subscription_id     = "<the GUID from Step 2>"
ssh_public_key_path = "~/.ssh/mandi_azure.pub"
prefix              = "mandi"          # make this unique per team member
location            = "centralindia"
```

Optionally lock SSH to your own IP (recommended — otherwise port 22 is open to
the whole internet and will be probed within minutes):

```bash
curl -s ifconfig.me          # prints e.g. 203.0.113.9
```

```hcl
allowed_ssh_cidr = "203.0.113.9/32"
```

Caveat: on a home or college connection that IP usually changes when the router
reconnects. If a deploy suddenly times out on SSH, re-check it and
`terraform apply` again.

`terraform.tfvars` is git-ignored. Confirm before you ever push:

```bash
git status --short     # terraform.tfvars must NOT appear
```

---

## Step 6 — Create the infrastructure

```bash
cd ~/projects/devops_IA3/terraform
terraform init      # downloads the azurerm provider
terraform fmt       # tidy formatting
terraform validate  # catches syntax and type errors before touching Azure
terraform plan      # SCREENSHOT THIS for the report
terraform apply     # type: yes      SCREENSHOT THIS TOO
```

`apply` takes 2–4 minutes. When it finishes it prints:

```
app_url        = "http://<ip>/"
public_ip      = "<ip>"
resource_group = "mandi-rg"
ssh_command    = "ssh -i ~/.ssh/mandi_azure azureuser@<ip>"
```

**Write down `public_ip`** — it is Step 7's `azure-vm-ip` credential. You can
always get it again with `terraform output public_ip`.

Check you can get in (cloud-init needs ~2 minutes to finish installing Docker):

```bash
ssh -i ~/.ssh/mandi_azure azureuser@<ip> 'docker --version'
```

If that says *command not found*, cloud-init is still running. Wait a minute and
retry, or watch it with `sudo tail -f /var/log/cloud-init-output.log`.

---

## Step 7 — Install and configure Jenkins

Use the script, which also handles the Java version and the docker group:

```bash
cd ~/projects/devops_IA3
sudo bash scripts/install_jenkins.sh
```

It prints the one-time unlock password at the end. The manual equivalent, if you
would rather see each step:

```bash
sudo apt install -y fontconfig openjdk-21-jre
sudo wget -O /usr/share/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list
sudo apt update && sudo apt install -y jenkins
sudo systemctl enable --now jenkins
```

Jenkins runs as its own `jenkins` user, which must be allowed to use Docker:

```bash
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

Open <http://localhost:8080>. The first-run password is:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Choose **Install suggested plugins**, create your admin user, then add the two
plugins this pipeline needs: **Manage Jenkins → Plugins → Available** →
`Docker Pipeline` and `SSH Agent`.

### Add the three credentials

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials.**
The IDs must match exactly — the Jenkinsfile looks them up by ID.

| Kind | ID | Fields |
|---|---|---|
| Username with password | `ghcr-credentials` | Username = your GitHub username, Password = the PAT from Step 4 |
| SSH Username with private key | `azure-vm-ssh` | Username = `azureuser`, Private Key = *Enter directly*, paste all of `~/.ssh/mandi_azure` including the `-----BEGIN`/`-----END` lines |
| Secret text | `azure-vm-ip` | Secret = the public IP from Step 6 (just the IP, no `http://`, no slash) |

```bash
cat ~/.ssh/mandi_azure      # copy the whole thing, both header lines included
```

### Create the pipeline job

**New Item** → name `mandi-automl` → **Pipeline** → OK.

- **Build Triggers:** tick **Poll SCM**, schedule `H/2 * * * *`
  *(the Jenkinsfile also declares this, but ticking it here makes it visible to
  the faculty, and Jenkins needs one successful build before a declared trigger
  takes effect)*
- **Pipeline → Definition:** *Pipeline script from SCM*
- **SCM:** Git
- **Repository URL:** `https://github.com/dharshan-kumarj/AutoML_IA3.git`
- **Branch:** `*/main`
- **Script Path:** `Jenkinsfile`

**Save** → **Build Now**.

---

## Step 8 — Prove continuous deployment

This is the thing the assignment is actually marking, so do it on camera:

```bash
cd ~/projects/automl_IA3
# any visible change — e.g. edit a heading in app/templates/index.html
git commit -am "Tweak the dashboard heading"
git push
```

Within two minutes Jenkins starts on its own. Watch the stage view go green, then
reload `http://<ip>/` and see the change.

### Screenshots for the report

1. `terraform plan` output
2. `terraform apply` finishing, with the outputs visible
3. Azure Portal → `mandi-rg` → the resource list (RG, VNet, Subnet, NSG, PIP, NIC, VM)
4. Jenkins stage view, all stages green
5. Jenkins console log at the **Verify Deployment** stage, showing `deployment healthy`
6. The running app at `http://<ip>/` with the URL bar visible
7. The Poll SCM build that was triggered by a push, with "Started by an SCM change"

---

## Step 9 — Tear it down

```bash
cd ~/projects/devops_IA3/terraform
terraform destroy       # type: yes
```

Do this the moment the demo is over. A VM left running bills every hour,
including while you sleep.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform apply` → *SubscriptionNotFound* | wrong GUID, or not logged in | `az login` then re-check `az account show --query id -o tsv` |
| `403 RequestDisallowedByAzure` on VNet/NSG/PIP | `location` is outside your subscription's allowed-regions policy | `az policy assignment list --query "[].parameters" -o json`, put an allowed region in `terraform.tfvars`, `terraform apply` again. The resource group gets replaced; it is empty, so nothing is lost. |
| *QuotaExceeded* / *SkuNotAvailable* | the region has no B1ms quota for student subs | pick another **allowed** region and re-check the SKU with `az vm list-skus` |
| Jenkins → `docker: permission denied` | the `jenkins` user is not in the docker group | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| Push to GHCR → `denied` | PAT missing `write:packages`, or image name has a capital letter | regenerate the token; GHCR paths must be all lowercase |
| VM pull → `unauthorized` | the GHCR package is private and the token is not reaching the VM | check the Deploy stage passes `ghcr_token`, or make the package public under GitHub → Packages → Package settings |
| Ansible → `UNREACHABLE` | `allowed_ssh_cidr` no longer matches your IP | `curl -s ifconfig.me`, update `terraform.tfvars`, `terraform apply` |
| Ansible → *docker-ready* wait times out | cloud-init failed | `ssh` in and read `/var/log/cloud-init-output.log` |
| App URL does not load, but health check passed locally | NSG rule or port mapping | confirm `allow-http` exists on the NSG and the container maps `80:8000` |
