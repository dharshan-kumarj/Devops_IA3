# devops_IA3 — infrastructure for mandi-automl

Terraform and Ansible that provision an Azure VM and deploy the
[AutoML_IA3](https://github.com/dharshan-kumarj/AutoML_IA3) web app onto it.

> On GitHub this repository is **`Devops_IA3`** (capital D); the local working
> folder is `devops_IA3`. The `Jenkinsfile` in the app repo clones the GitHub
> spelling, so keep that one exact.

The application code, its `Dockerfile` and its `Jenkinsfile` live in that other
repository. This one owns only the infrastructure, and Jenkins checks it out
during its Deploy stage.

```
devops_IA3/
├── terraform/                 provisions the Azure resources
│   ├── versions.tf            provider pin
│   ├── variables.tf           every value you supply
│   ├── main.tf                RG, VNet, Subnet, NSG, Public IP, NIC, VM
│   ├── cloud-init.yaml        installs Docker on first boot
│   ├── outputs.tf             public IP, app URL, ssh command
│   └── terraform.tfvars.example
├── ansible/
│   ├── deploy.yml             pulls the image and runs the container
│   ├── ansible.cfg
│   └── inventory.ini.example
└── docs/
    └── setup.md               the step-by-step run book
```

## How the pieces fit together

```
  git push                 Jenkins (local)                   Azure
  ────────                 ───────────────                   ─────
  AutoML_IA3  ──Poll SCM──▶ checkout
                            ruff + pytest
                            docker build
                            smoke test  ──push──▶  GHCR
                            checkout devops_IA3
                            ansible-playbook ───ssh──▶  VM ──pull──▶ GHCR
                            curl /api/health  ◀──────── http://<ip>/
```

Terraform runs **once, by hand** — infrastructure is created at the start and
destroyed at the end. Jenkins runs **on every commit** and only ever deploys a
new container onto the VM that already exists. Keeping them separate means a
code push can never accidentally destroy or rebuild the VM.

## Quick start

See `docs/setup.md` for the full run book. The short version:

```bash
az login
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in subscription_id
terraform init
terraform plan
terraform apply
terraform output app_url
```

## Tearing it down

A student subscription has a fixed credit. When you are finished:

```bash
cd terraform && terraform destroy
```

Everything lives in one resource group, so this removes all of it.
