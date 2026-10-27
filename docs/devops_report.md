<!--
  DevOps assignment report: "Automated Deployment of a Web Application using
  CI/CD, Terraform, Azure, and Jenkins."

  Every figure here was read from the live deployment or from tool output on
  2026-10-28. Replace each <FILL: ...> before submitting -- those are the only
  things this repository cannot supply.

  Paste into Google Docs or Word, insert the screenshots where marked, export
  as PDF.
-->

<div align="center">

# Automated Deployment of a Web Application using CI/CD, Terraform, Azure and Jenkins

**<FILL: DIVISION / DEPARTMENT>**

**<FILL: INSTITUTE NAME>**

**Submitted by**

<FILL: YOUR NAME> (<FILL: REGISTER NUMBER>)
<FILL: TEAMMATE NAME> (<FILL: REGISTER NUMBER>)
<FILL: TEAMMATE NAME> (<FILL: REGISTER NUMBER>)

**Course:** <FILL: COURSE CODE AND NAME>

**<FILL: OCTOBER 2026>**

</div>

---

## 1. Objective

To provision cloud infrastructure declaratively with Terraform on Microsoft
Azure, and to build a Jenkins pipeline that takes any commit pushed to GitHub
and deploys it to that infrastructure automatically, with no manual step
between the push and the running application.

The application deployed is a real one rather than a placeholder: a machine
learning web service that forecasts next week's wholesale price of four crops
across six Indian states each, serving a JSON API and an HTML dashboard from a
FastAPI process. It is maintained in a separate repository and was not written
for this assignment, which makes the pipeline's job realistic — it must build a
754 MB image containing SciPy, scikit-learn, pandas and LightGBM, run a test
suite of 188 tests, and deploy onto a 2 GB virtual machine.

**Live deployment:** <http://172.198.79.131/>

---

## 2. Tools used

| Tool | Version | Role in this project |
|---|---|---|
| Terraform | 1.17.0 | declares and provisions the eight Azure resources |
| Microsoft Azure | Azure for Students | hosts the virtual machine and its network |
| Azure CLI | 2.91.0 | authentication, and querying the subscription's policies |
| Jenkins | 2.580.1 | the CI/CD server, running locally |
| Java (OpenJDK) | 21.0.12.1 | Jenkins' runtime |
| Docker | 29.4.0 (build host), 29.9.2 (VM) | image build, and the container runtime |
| GitHub Container Registry | — | stores the built images |
| Ansible | 2.10.8 | configures the VM and performs the deployment |
| Git / GitHub | 2.34.1 | version control for both repositories |
| cloud-init | — | installs Docker on the VM at first boot |
| Ubuntu Server | 22.04 LTS | the VM's operating system |
| Python / uv | 3.11 / 0.13.6 | the application's runtime and dependency manager |

---

## 3. Repositories

| Repository | Contents |
|---|---|
| <https://github.com/dharshan-kumarj/AutoML_IA3> | application code, `Dockerfile`, `Jenkinsfile` |
| <https://github.com/dharshan-kumarj/Devops_IA3> | `terraform/`, `ansible/`, `scripts/`, documentation |

The `Jenkinsfile` lives with the application because Jenkins' *Pipeline script
from SCM* reads it from the repository being built. The infrastructure lives
apart so that an application commit cannot modify or destroy infrastructure:
Terraform is run by hand once, and the pipeline only ever replaces a container
on a machine that already exists.

---

## 4. Architecture

```
   DEVELOPER                    LOCAL MACHINE                      CLOUD
   ─────────                    ─────────────                      ─────

 git push ──────────────────────────────────────────────▶  github.com
                                                            AutoML_IA3
                                    ┌───────────────────────────┘
                 Poll SCM           │  polled every 2 minutes
                 H/2 * * * *        ▼
          ┌────────────────────────────────────────────┐
          │  JENKINS 2.580.1   (localhost:8080)        │
          │                                            │
          │  1 Checkout          clone at that commit  │
          │  2 Lint & Test       ruff + 188 pytest     │
          │  3 Docker Build      754 MB, tag=<sha>     │
          │  4 Smoke Test        run + curl /health    │
          │  5 Push to GHCR ───────────────────────────────▶ ghcr.io
          │  6 Deploy            clone Devops_IA3            automl_ia3
          │                      ansible-playbook              │
          │  7 Verify            curl the public URL           │
          └──────────────────┬─────────────────────────┘       │
                             │ SSH (azureuser, ed25519)        │
                             ▼                                 │
       ┌───────────────────────────────────────────────┐       │
       │  AZURE  resource group  mandi-rg              │       │
       │  region: indiasouthcentral                    │       │
       │                                               │       │
       │   mandi-vnet        10.20.0.0/16              │       │
       │    └ mandi-subnet-app  10.20.1.0/24           │       │
       │         └ mandi-nsg    allow 22, allow 80     │       │
       │         └ mandi-nic ── mandi-pip (Static)     │       │
       │              └ mandi-vm  Standard_B1ms        │       │
       │                 Ubuntu 22.04, 1898 MB RAM     │       │
       │                                               │       │
       │                 docker pull ◀─────────────────────────┘
       │                 docker run -p 80:8000         │
       └───────────────────────┬───────────────────────┘
                               ▼
                 http://172.198.79.131/
```

> **[SCREENSHOT 1 — architecture]** Optionally redraw the diagram above in
> draw.io or Excalidraw for the PDF.

---

## 5. Infrastructure as Code — Terraform

Eight resources, all within one resource group so that a single
`terraform destroy` removes the entire deployment.

| # | Resource type | Name | Notes |
|---|---|---|---|
| 1 | Resource Group | `mandi-rg` | container for the rest |
| 2 | Virtual Network | `mandi-vnet` | `10.20.0.0/16` |
| 3 | Subnet | `mandi-subnet-app` | `10.20.1.0/24` |
| 4 | Network Security Group | `mandi-nsg` | inbound 22 and 80 |
| 5 | NSG ↔ Subnet association | — | binds the rules |
| 6 | Public IP | `mandi-pip` | **Static** |
| 7 | Network Interface | `mandi-nic` | joins subnet, carries the IP |
| 8 | Linux Virtual Machine | `mandi-vm` | `Standard_B1ms`, Ubuntu 22.04 |

The Network Security Group is not among the six resources the brief lists, but
it is required in practice: an Azure subnet denies all inbound traffic from the
internet until a rule allows it, so without it the deployed application would be
unreachable.

The Public IP is **Static** rather than Dynamic so that stopping the VM to
conserve credit does not change its address, which would otherwise invalidate
the Jenkins credential holding it.

### 5.1 Provider and variables

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id   # from terraform.tfvars, git-ignored
}
```

### 5.2 Network and firewall

```hcl
resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "app" {
  name                 = "${var.prefix}-subnet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_network_security_group" "app" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.app_port)
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}
```

### 5.3 Public IP, NIC and the virtual machine

```hcl
resource "azurerm_public_ip" "app" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "app" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                  = "${var.prefix}-vm"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.vm_size                 # Standard_B1ms
  admin_username        = var.admin_username          # azureuser
  network_interface_ids = [azurerm_network_interface.app.id]

  # Azure refuses password authentication when this is true, which removes the
  # commonest way a student VM is taken over by a bot.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "${var.prefix}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    admin_username = var.admin_username
  }))
}
```

### 5.4 cloud-init — Docker at first boot

```yaml
#cloud-config
packages: [ca-certificates, curl, gnupg, python3]

runcmd:
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - usermod -aG docker ${admin_username}
  - systemctl enable --now docker
  # A marker the playbook waits on, so a deploy arriving mid-boot waits
  # instead of failing with "docker: command not found".
  - touch /var/lib/cloud/docker-ready
```

> **[SCREENSHOT 2 — `terraform plan`]**
> **[SCREENSHOT 3 — `terraform apply` completing, with the outputs visible]**
> **[SCREENSHOT 4 — Azure Portal, `mandi-rg`, showing all eight resources]**

Output of a successful apply:

```
app_url        = "http://172.198.79.131/"
public_ip      = "172.198.79.131"
resource_group = "mandi-rg"
ssh_command    = "ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131"
```

---

## 6. The Jenkins pipeline

Seven declarative stages. Every credential is referenced by its Jenkins
credential ID; no secret appears in either repository.

```groovy
// A `when { branch ... }` directive only works in a Multibranch Pipeline,
// where Jenkins sets BRANCH_NAME. This is a plain "Pipeline script from SCM"
// job, where it is null -- so the gate silently skipped Push, Deploy and
// Verify while the build still went green. The git plugin does set
// GIT_BRANCH, as "origin/main", so fall back to it.
def onDeployBranch() {
    String branch = env.BRANCH_NAME ?: env.GIT_BRANCH ?: ''
    return branch == 'main' || branch.endsWith('/main')
}

pipeline {
    agent any

    triggers {
        // Jenkins runs locally and cannot receive a GitHub webhook, so it asks
        // GitHub every two minutes whether main has moved. `H` spreads load.
        pollSCM('H/2 * * * *')
    }

    environment {
        REGISTRY     = 'ghcr.io'
        // GHCR rejects uppercase in a repository path, so this is not the
        // literal GitHub repo name.
        IMAGE_NAME   = 'ghcr.io/dharshan-kumarj/automl_ia3'
        IMAGE_TAG    = "${env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : 'local'}"
        INFRA_REPO   = 'https://github.com/dharshan-kumarj/Devops_IA3.git'
    }

    stages {
        stage('Checkout')   { steps { checkout scm } }

        stage('Lint & Test') {
            steps {
                sh '''
                    set -eu
                    curl -LsSf https://astral.sh/uv/install.sh | sh
                    export PATH="$HOME/.local/bin:$PATH"
                    uv sync --frozen --no-default-groups --group dev
                    uv run ruff check .
                    uv run ruff format --check .
                    uv run pytest -q
                '''
            }
        }

        stage('Docker Build') {
            steps {
                sh '''
                    set -eu
                    test -f models/index.json
                    test -f models/weekly_snapshot.csv
                    docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" \
                                 -t "${IMAGE_NAME}:latest" .
                '''
            }
        }

        stage('Smoke Test Image') {
            steps {
                sh '''
                    set -eu
                    docker rm -f mandi-smoke >/dev/null 2>&1 || true
                    docker run -d --name mandi-smoke -p 18000:8000 \
                        "${IMAGE_NAME}:${IMAGE_TAG}"
                    for attempt in $(seq 1 30); do
                        if curl -fsS http://127.0.0.1:18000/api/health; then break; fi
                        sleep 2
                    done
                    curl -fsS http://127.0.0.1:18000/api/health | grep -q '"status":"ok"'
                '''
            }
            post { always { sh 'docker rm -f mandi-smoke || true' } }
        }

        stage('Push to GHCR') {
            when { expression { onDeployBranch() } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'ghcr-credentials',
                                                  usernameVariable: 'GHCR_USER',
                                                  passwordVariable: 'GHCR_TOKEN')]) {
                    sh '''
                        set -eu
                        # Keep the token in a throwaway config inside the
                        # workspace. A failed push used to leave a bad
                        # credential in the shared ~/.docker/config.json, which
                        # then broke even PUBLIC ghcr.io pulls in later builds.
                        export DOCKER_CONFIG="${WORKSPACE}/.docker-ghcr"
                        rm -rf "$DOCKER_CONFIG"; mkdir -p "$DOCKER_CONFIG"
                        trap 'rm -rf "$DOCKER_CONFIG"' EXIT INT TERM

                        echo "$GHCR_TOKEN" | docker login "${REGISTRY}" \
                            -u "$GHCR_USER" --password-stdin
                        docker push "${IMAGE_NAME}:${IMAGE_TAG}"
                        docker push "${IMAGE_NAME}:latest"
                    '''
                }
            }
        }

        stage('Deploy') {
            when { expression { onDeployBranch() } }
            steps {
                dir('infra') {
                    deleteDir()
                    git url: "${INFRA_REPO}", branch: 'main'
                }
                withCredentials([
                    sshUserPrivateKey(credentialsId: 'azure-vm-ssh',
                                      keyFileVariable: 'SSH_KEY'),
                    string(credentialsId: 'azure-vm-ip', variable: 'VM_IP'),
                    usernamePassword(credentialsId: 'ghcr-credentials',
                                     usernameVariable: 'GHCR_USER',
                                     passwordVariable: 'GHCR_TOKEN')
                ]) {
                    sh '''
                        set -eu
                        cd infra/ansible
                        trap 'rm -f inventory.ini' EXIT
                        { echo "[app]"
                          echo "$VM_IP ansible_user=azureuser"; } > inventory.ini
                        ansible-playbook deploy.yml -i inventory.ini \
                            --private-key "$SSH_KEY" \
                            -e image_name="${IMAGE_NAME}" \
                            -e image_tag="${IMAGE_TAG}" \
                            -e ghcr_user="$GHCR_USER" \
                            -e ghcr_token="$GHCR_TOKEN"
                    '''
                }
            }
        }

        stage('Verify Deployment') {
            when { expression { onDeployBranch() } }
            steps {
                withCredentials([string(credentialsId: 'azure-vm-ip',
                                        variable: 'VM_IP')]) {
                    sh '''
                        set -eu
                        for attempt in $(seq 1 30); do
                            if curl -fsS "http://$VM_IP/api/health" \
                               | grep -q '"status":"ok"'; then
                                echo "deployment healthy: http://$VM_IP/"
                                exit 0
                            fi
                            sleep 5
                        done
                        echo "health check never returned ok"; exit 1
                    '''
                }
            }
        }
    }
}
```

### 6.1 Credentials

| Credential ID | Kind | Used for |
|---|---|---|
| `ghcr-credentials` | Username with password | pushing the image, and letting the VM pull it |
| `azure-vm-ssh` | SSH username with private key | Ansible's connection as `azureuser` |
| `azure-vm-ip` | Secret text | the Ansible inventory and the final health check |

> **[SCREENSHOT 5 — Jenkins credentials list, showing the three IDs]**
> **[SCREENSHOT 6 — Jenkins stage view, all seven stages green]**
> **[SCREENSHOT 7 — console log at Verify Deployment: `deployment healthy`]**

---

## 7. Configuration management — Ansible

`ansible/deploy.yml` runs against the one host written into the inventory at
deploy time:

```yaml
- name: Deploy mandi-automl to the Azure VM
  hosts: app
  become: true
  vars:
    container_name: mandi-automl
    host_port: 80
    container_port: 8000
    web_workers: 1        # the app measured 407 MiB with two; tight on 2 GB

  tasks:
    - name: Wait for cloud-init to finish installing Docker
      ansible.builtin.wait_for:
        path: /var/lib/cloud/docker-ready
        timeout: 600

    - name: Log in to GHCR so the private image can be pulled
      ansible.builtin.command:
        cmd: docker login ghcr.io --username {{ ghcr_user }} --password-stdin
        stdin: "{{ ghcr_token }}"
        stdin_add_newline: false
      no_log: true            # keeps the token out of the Jenkins console

    - name: Pull the image this build produced
      ansible.builtin.command: "docker pull {{ image_name }}:{{ image_tag }}"

    - name: Stop and remove the previous container
      ansible.builtin.command: "docker rm -f {{ container_name }}"
      failed_when: false      # not an error on the first ever deploy

    - name: Start the new container
      ansible.builtin.command: >-
        docker run -d --name {{ container_name }}
        --restart unless-stopped
        -p {{ host_port }}:{{ container_port }}
        --memory 1g
        {{ image_name }}:{{ image_tag }}
        uvicorn app.main:app --host 0.0.0.0 --port {{ container_port }}
        --workers {{ web_workers }} --access-log

    - name: Wait for the app to answer its health check
      ansible.builtin.uri:
        url: "http://127.0.0.1:{{ host_port }}/api/health"
        status_code: 200
      retries: 30
      delay: 5
```

**The virtual machine never receives source code and never builds anything.**
It pulls a finished image. The reason is measurable: the image is 754 MB and the
VM has 1898 MB of RAM, so compiling SciPy, scikit-learn, pandas and LightGBM
there would exhaust memory, while the build host has sixteen cores and does it
in seconds.

---

## 8. Continuous deployment demonstration

Any commit to `main` redeploys without human intervention.

```bash
cd ~/projects/automl_IA3
# edit something visible, e.g. a heading in app/templates/index.html
git commit -am "Tweak the dashboard heading"
git push
```

Within two minutes Poll SCM detects the change and the pipeline runs end to end.
The build page records the cause as **"Started by an SCM change"**, which is the
evidence that deployment is continuous rather than manually triggered.

> **[SCREENSHOT 8 — a build whose cause reads "Started by an SCM change"]**
> **[SCREENSHOT 9 — the application at http://172.198.79.131/ with the URL bar visible]**

---

## 9. Results

Verified against the live deployment on 2026-10-28:

| Check | Result |
|---|---|
| Container running | `ghcr.io/dharshan-kumarj/automl_ia3:013035d`, healthy, `0.0.0.0:80→8000` |
| `/api/health` | `{"status":"ok","version":"0.1.0","models_loaded":true,"crops":["Cabbage","Onion","Potato","Tomato"]}` |
| Live prediction | Onion / Maharashtra → ₹1315.39 for the week of 2025-11-03 |
| Live backtest | 26 weeks scored; model MAE 68.75 against naive 60.88 |
| Page load | HTTP 200, 10132 bytes, 0.117 s |
| VM memory in use | 434 MB of 1898 MB |
| Pipeline test stage | 187 passed, 1 skipped |
| Image size | 754 MB |
| Full pipeline duration | approximately 50 seconds with warm caches |

---

## 10. Observations

These were the real obstacles. Each one cost a failed build, and together they
are the most instructive part of the exercise — the textbook steps worked
first time; these did not.

**Azure for Students restricts which regions you may deploy to.**
`terraform apply` failed with `403 RequestDisallowedByAzure` on the virtual
network, security group and public IP — but only *after* the resource group had
already been created, which makes the failure look more serious than it is. The
subscription carries an "Allowed resource deployment regions" policy, and
`centralindia` is not in it despite being a genuine Azure region. The permitted
set had to be read from the policy itself:

```bash
az policy assignment list --query "[].parameters" -o json
# indonesiacentral, koreacentral, malaysiawest, indiasouthcentral, eastasia
```

`indiasouthcentral` was adopted. This is worth checking before the first apply,
and each team member's subscription may permit a different set.

**A green pipeline is not the same as a working one.** The most instructive
failure of the project was a build that reported SUCCESS while silently
skipping Push, Deploy and Verify. The directive `when { branch 'main' }` reads
`BRANCH_NAME`, which Jenkins only populates in a Multibranch Pipeline; in a
plain *Pipeline script from SCM* job it is null and the condition never matches.
A `post { success }` block then printed "Deployed ..." regardless, so the console
actively asserted something false. A failing build announces itself; a build
that succeeds while doing nothing does not.

**One failed step can break a later, unrelated-looking one.** After a denied
push, the *next* build failed in Docker Build while pulling a public image, with
`failed to fetch oauth token: denied`. The cause was that `docker logout` sat
after `docker push` inside a `set -eu` block, so the failed push aborted before
logout ran and left a bad credential in the shared Docker config. Docker then
presented that broken token for every ghcr.io request, including anonymous
pulls. The fix was to give the login its own `DOCKER_CONFIG` inside the
workspace, removed by a trap, so no credential outlives the build.

**Published documentation goes stale.** Jenkins' own installation instructions
still point at `jenkins.io-2023.key`, which no longer matches the repository and
fails with `NO_PUBKEY 7198F4B714ABFC68`. The current key is
`jenkins.io-2026.key`; the 2024 and 2025 filenames do not exist, so there is no
sequence to follow forward. Separately, Jenkins requires Java 17 or 21 while
Ubuntu 22.04 defaults to Java 11 — it installs cleanly and then refuses to
start.

**Error messages do not always describe their cause.** Ansible reported
`Load key: error in libcrypto` with `Permission denied (publickey)`, which reads
as a rejected key. The key was in fact valid; the copy pasted into the Jenkins
credential had lost its trailing newline, and OpenSSH will not parse a key file
that does not end with one.

**Testing the pipeline against a clean checkout found two defects before the
first build.** Running the test stage against an extraction of only git-tracked
files revealed a test that required a deliberately git-ignored dataset, and a
Docker Build precondition that required a file excluded by `.dockerignore`. Both
passed locally and could never have passed in CI.

**Separating infrastructure from application code is worth the extra
repository.** Terraform is run by hand once; the pipeline only replaces
containers. The worst a bad commit can do is deploy a broken container, never
destroy a network. The cost is that two repositories must be kept in step, which
in practice meant one commit fixing a capitalisation mismatch in a URL.

**Running Jenkins locally rather than on a second VM was the right trade.** The
build host has sixteen cores and 23 GB of RAM against the VM's one vCPU and
2 GB; a second cloud VM would also have billed continuously against a fixed
student credit. The only capability given up is GitHub webhooks, and the brief
explicitly permits Poll SCM instead.

---

## 11. Conclusion

A complete CI/CD pipeline was built and is in continuous operation. Terraform
declares eight Azure resources that can be created or destroyed with one
command. Jenkins polls GitHub, and on any commit to `main` it lints, tests,
builds, smoke-tests, publishes and deploys the application, then verifies the
result over the public internet. Ansible performs the deployment itself, pulling
a published image rather than building on the server. The application is live
at <http://172.198.79.131/> and was confirmed serving real predictions.

All four requirements of the brief are met: infrastructure is provisioned with
Terraform, the pipeline checks out from GitHub and deploys automatically, GitHub
provides version control with Poll SCM as the trigger, and any commit triggers a
redeployment.

What the exercise actually taught was narrower than the tool list suggests. The
individual tools behaved as documented. Almost all the time went into the joints
between them — a subscription policy that rejects a region the provider accepts,
a conditional that evaluates differently depending on job type, a credential
that survives a failed build and breaks the next one, a key that is valid on
disk and invalid once pasted. The most valuable habit formed was verifying that
a pipeline did what it claimed rather than trusting that it had gone green.

---

## 12. Appendices

**A. How to reproduce this deployment from nothing**

```bash
# 1. prerequisites
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo apt install -y terraform ansible

# 2. authenticate and find your subscription
az login
az account show --query id -o tsv

# 3. check which regions YOUR subscription allows
az policy assignment list --query "[].parameters" -o json

# 4. deploy key
ssh-keygen -t ed25519 -f ~/.ssh/mandi_azure -N ""

# 5. infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in subscription_id
terraform init && terraform plan && terraform apply
terraform output public_ip

# 6. Jenkins
sudo bash scripts/install_jenkins.sh

# 7. add the three credentials, create the pipeline job, Build Now
#    full detail in docs/setup.md
```

**B. Repository layout**

```
Devops_IA3/
├── terraform/
│   ├── versions.tf              provider pin
│   ├── variables.tf             every input, with validation
│   ├── main.tf                  the eight resources
│   ├── cloud-init.yaml          Docker at first boot
│   ├── outputs.tf               public IP, URL, ssh command
│   ├── terraform.tfvars.example
│   └── .terraform.lock.hcl      committed, pins provider checksums
├── ansible/
│   ├── deploy.yml               pull image, restart container, health check
│   ├── ansible.cfg
│   └── inventory.ini.example
├── scripts/
│   ├── install_jenkins.sh       Java 21, signing key, docker group
│   └── check_ghcr.sh            diagnoses a denied registry push
└── docs/
    ├── setup.md                 step-by-step run book
    ├── architecture.md          how it all fits together
    └── devops_report.md         this document
```

**C. Teardown**

```bash
cd terraform && terraform destroy
```

Everything lives in one resource group, so this removes all of it. To pause
without destroying, `az vm deallocate -g mandi-rg -n mandi-vm`; the Static
public IP is retained, so nothing else needs reconfiguring.

**D. Related documentation**

- `docs/setup.md` — the run book, including a troubleshooting table
- `docs/architecture.md` — the detailed as-built description
- `AutoML_IA3/docs/skill_evaluation_report.md` — the report for the AutoML course
