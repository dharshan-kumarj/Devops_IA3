# Running a second Jenkins against the same Azure VM

For a teammate who needs to build and deploy from their own laptop, onto the
infrastructure that already exists. Nothing in Azure is recreated.

**Who does what:** steps marked **[OWNER]** are done by whoever created the Azure
resources. Steps marked **[TEAMMATE]** are done on the new laptop.

---

## First: the zip is not what you need, and it carries a risk

Jenkins clones `Devops_IA3` from GitHub during its Deploy stage, so a teammate
does **not** need a copy of the folder to run the pipeline. Everything required
is either on GitHub or is a Jenkins credential.

If a zip of the whole folder was already sent, it contains two files that were
never meant to travel:

| File | What is in it | Risk |
|---|---|---|
| `terraform/terraform.tfvars` | the Azure subscription id | Low. It is an identifier, not a credential — it cannot be used without authenticating as you. Nothing to rotate. |
| `terraform/terraform.tfstate` | every resource id, the VM's **public** key, network layout | Low for disclosure — there is no private key or password in it. **The real risk is operational.** |

The operational risk is worth understanding. That state file is a second copy of
Terraform's record of your infrastructure. If the teammate ever runs
`terraform apply` or `terraform destroy` in that folder, it acts on **your real
resources**. A `destroy` would delete the VM, the network and the public IP.

### [TEAMMATE] Delete those two files from the copy

```bash
cd <wherever the zip was extracted>/devops_IA3
rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup terraform/terraform.tfvars
```

Better still, delete the extracted folder entirely and clone instead:

```bash
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/dharshan-kumarj/Devops_IA3.git devops_IA3
```

The clone has no state and no variables, so Terraform there cannot touch
anything by accident. **The teammate never runs Terraform at all.**

---

## Before anything: two Jenkins, one VM

Both machines will deploy to `172.198.79.131`, replacing the same container.
That works, but:

- If two builds deploy at the same time, the second overwrites the first. Agree
  who is deploying before a demo.
- Whichever built most recently is what is running. If the app looks older than
  expected, someone else's build is live.
- Both pipelines poll `main` every two minutes, so **one push triggers both**.

If that is not acceptable, the teammate should provision their own VM with their
own Terraform and their own `prefix` — see `docs/setup.md`. For showing the same
project to different faculty, sharing one VM is usually fine.

---

## Step 1 — [TEAMMATE] SSH access, without sending a private key

The teammate makes their own key and sends only the **public** half, which is
safe to send over any channel. No private key is ever transferred.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mandi_azure -C "<teammate name> deploy key" -N ""
cat ~/.ssh/mandi_azure.pub          # send THIS line to the owner
```

### [OWNER] Add it to the VM

```bash
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 \
  'echo "<paste the public key line here>" >> ~/.ssh/authorized_keys'

# confirm it landed and nothing was clobbered
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 \
  'wc -l < ~/.ssh/authorized_keys'
```

**Append with `>>`, never overwrite with `>`.** One stray `>` locks everyone out
of the VM, and the only recovery is Azure's serial console or a rebuild.

This appends at the operating-system level and is invisible to Terraform, which
only tracks the `admin_ssh_key` set at creation. Do **not** use
`az vm user update` for this: `admin_ssh_key` forces replacement in the
`azurerm` provider, and the next `terraform plan` would propose destroying and
rebuilding the VM.

### [TEAMMATE] Check it works

```bash
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 'docker ps'
```

To revoke later, the owner deletes that line from `~/.ssh/authorized_keys`.

---

## Step 2 — GHCR access

The image lives at `ghcr.io/dharshan-kumarj/automl_ia3` and the package is
**private**. The teammate's Jenkins has to push to it, which means write access
to someone else's namespace.

### Option A — proper, and revocable (recommended)

**[OWNER]** <https://github.com/users/dharshan-kumarj/packages> → `automl_ia3`
→ **Package settings** → **Manage access** → **Invite teams or people** → add
the teammate with the **Write** role.

**[TEAMMATE]** create your own token at
<https://github.com/settings/tokens> → **Generate new token (classic)** →
tick **`write:packages`** → copy it.

Classic, not fine-grained: GHCR's fine-grained support is incomplete and fails
with a bare `denied` that tells you nothing.

### Option B — quick, if you are short of time

The owner shares their own PAT and the teammate puts it in their Jenkins
credential. It works immediately, but it is one credential in two places and
revoking it breaks both pipelines at once. If you do this, regenerate the token
after the demos.

### Verify before touching Jenkins

```bash
bash scripts/check_ghcr.sh
```

It reads the token with hidden input, reports which account it belongs to and
whether `write:packages` is present, then actually pushes a tiny probe image.
Sorting this out here saves a failed build.

---

## Step 3 — [TEAMMATE] Install the tools

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"        # log out and back in

sudo apt update && sudo apt install -y ansible git curl

# Jenkins, with Java 21, the current signing key and the docker group
cd ~/projects/devops_IA3
sudo bash scripts/install_jenkins.sh
```

The script handles the three things that otherwise cost a build each: Ubuntu
22.04 defaults to Java 11 and Jenkins needs 17 or 21; Jenkins' own documentation
points at a superseded apt signing key; and the `jenkins` user cannot reach the
Docker socket until it is in the `docker` group.

It prints a one-time unlock password at the end.

Terraform is deliberately **not** in that list. The teammate does not provision
anything.

---

## Step 4 — [TEAMMATE] Configure Jenkins

At <http://localhost:8080>:

1. Paste the unlock password → **Install suggested plugins** → create an admin user
2. **Manage Jenkins → Plugins → Available**: install **Docker Pipeline** and
   **SSH Agent**
3. **Manage Jenkins → Credentials → System → Global credentials → Add**, three
   times. **The IDs must match exactly** — the Jenkinsfile looks them up by ID:

| Kind | ID | Value |
|---|---|---|
| Username with password | `ghcr-credentials` | **your own** GitHub username + **your own** classic PAT |
| SSH Username with private key | `azure-vm-ssh` | username `azureuser`, your `~/.ssh/mandi_azure` |
| Secret text | `azure-vm-ip` | `172.198.79.131` |

> For the SSH key, copy it with a tool rather than selecting the text:
> ```bash
> sudo apt install -y xclip
> xclip -selection clipboard < ~/.ssh/mandi_azure
> ```
> A hand-selected paste usually loses the trailing newline, and OpenSSH then
> fails with `Load key: error in libcrypto` — which reads like a rejected key
> but means an unparseable file.

4. **New Item** → name it → **Pipeline** → OK
   - **Build Triggers**: tick **Poll SCM**, schedule `H/2 * * * *`
   - **Pipeline → Definition**: **Pipeline script from SCM**
     — *not* "Pipeline script". With an inline script `checkout scm` has no SCM
     to check out, and Poll SCM has nothing to poll.
   - **SCM**: Git
   - **Repository URL**: `https://github.com/dharshan-kumarj/AutoML_IA3.git`
   - **Credentials**: *- none -* (the repository is public)
   - **Branch**: `*/main`
   - **Script Path**: `Jenkinsfile`
5. **Save** → **Build Now**

---

## Step 5 — [OWNER] Make sure the VM is running

A deallocated VM makes the Deploy stage fail with an Ansible `UNREACHABLE`,
which reads like a credential problem but is not.

```bash
az vm start -g mandi-rg -n mandi-vm
```

---

## What a good first build looks like

| Stage | Expected |
|---|---|
| Checkout | clones `AutoML_IA3` at `origin/main` |
| Lint & Test | ~30 s; `187 passed, 1 skipped` |
| Docker Build | several minutes on a cold cache — it builds 754 MB from scratch |
| Smoke Test Image | `{"status":"ok","models_loaded":true,...}` |
| Push to GHCR | mostly `Layer already exists`, since the owner pushed the same layers |
| Deploy | Ansible: pull, remove old container, run new, health check |
| Verify Deployment | `deployment healthy: http://172.198.79.131/` |

The first build is much slower than later ones — nothing is cached. Give the
Docker Build stage several minutes before assuming it has hung.

### To prove continuous deployment

```bash
cd ~/projects/automl_IA3     # a clone of the app repo
git commit --allow-empty -m "Verify the pipeline from this machine"
git push
```

Then leave Jenkins alone. Within two minutes Poll SCM triggers a build on its
own, and the build page records the cause as **"Started by an SCM change"**.

Note that **both** machines' Jenkins will see that push and both will build.
That is expected; see the warning at the top.

---

## If something fails

| Symptom | Cause | Fix |
|---|---|---|
| `'checkout scm' is only available when using...` | job Definition is "Pipeline script" | change it to **Pipeline script from SCM** |
| Build green but Push/Deploy/Verify say "skipped" | not on `main`, or an old `Jenkinsfile` | confirm the branch is `*/main` |
| `error from registry: denied` | token lacks `write:packages`, is fine-grained, or has no access to the owner's package | `bash scripts/check_ghcr.sh` |
| `Load key: error in libcrypto` | the key in Jenkins lost its trailing newline | re-paste with `xclip` |
| Ansible `UNREACHABLE` | VM deallocated, or the public key was never appended | `az vm start`, then test SSH by hand |
| `failed to fetch oauth token: denied` during **Docker Build** | a stale GHCR credential from an earlier failed push | `sudo rm -f /var/lib/jenkins/.docker/config.json` |
| `docker: permission denied` | `jenkins` not in the `docker` group | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |

---

## Checklist

```
[TEAMMATE] [ ] delete terraform.tfstate / .tfvars from any copied folder
[TEAMMATE] [ ] clone Devops_IA3 and AutoML_IA3 from GitHub
[TEAMMATE] [ ] ssh-keygen, send the PUBLIC key to the owner
[OWNER]    [ ] append it to the VM's authorized_keys with >>  (never >)
[TEAMMATE] [ ] confirm ssh to the VM works
[OWNER]    [ ] grant Write on the GHCR package
[TEAMMATE] [ ] create a classic PAT with write:packages
[TEAMMATE] [ ] bash scripts/check_ghcr.sh  -> all three checks pass
[TEAMMATE] [ ] install docker, ansible, git
[TEAMMATE] [ ] sudo bash scripts/install_jenkins.sh
[TEAMMATE] [ ] Docker Pipeline + SSH Agent plugins
[TEAMMATE] [ ] three credentials, IDs exactly as above
[TEAMMATE] [ ] pipeline job, "Pipeline script FROM SCM"
[OWNER]    [ ] az vm start -g mandi-rg -n mandi-vm
[TEAMMATE] [ ] Build Now -> all seven stages green
[TEAMMATE] [ ] push a commit -> "Started by an SCM change"
```
