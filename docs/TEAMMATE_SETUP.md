# Teammate setup — from a blank laptop to a working pipeline

Follow top to bottom. Every command is copy-pasteable. Nothing here provisions
cloud infrastructure: the Azure resources already exist and you are only adding
a second machine that can build and deploy to them.

**You will not run Terraform at any point.** If you were sent a zip of the
`devops_IA3` folder, see step 1 before anything else.

Expect about 40 minutes, most of it waiting on downloads.

---

## What you need from the project owner

Ask for these three before you start. Two of them take the owner a minute; the
third needs you to have done step 3 first.

| # | What | Who provides |
|---|---|---|
| 1 | The VM's public IP — `172.198.79.131` | owner |
| 2 | **Write** access to the GHCR package `automl_ia3` | owner grants it on GitHub |
| 3 | Your SSH public key appended to the VM | you generate, owner appends |

---

## Step 1 — Clean up anything you were sent

If you extracted a zip of `devops_IA3`, it contains the owner's Terraform state.
That file is Terraform's record of the **real, live** infrastructure. Running
`terraform destroy` in that folder would delete the owner's VM, network and
public IP.

The safest thing is to throw the extracted copy away and clone instead:

```bash
rm -rf ~/Downloads/devops_IA3          # wherever you extracted it
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/dharshan-kumarj/Devops_IA3.git devops_IA3
git clone https://github.com/dharshan-kumarj/AutoML_IA3.git automl_IA3
```

If you would rather keep the extracted folder, at minimum delete these:

```bash
rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup terraform/terraform.tfvars
```

A fresh clone has no state and no variables, so Terraform there cannot touch
anything by accident.

---

## Step 2 — Install the tools

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

**Log out and back in now.** The group change does not apply to your current
session. Then check it took:

```bash
docker run --rm hello-world
```

If that says "permission denied", you did not log out and back in.

```bash
# the rest
sudo apt update
sudo apt install -y ansible git curl xclip
```

`xclip` matters later — it is how you copy the SSH key without corrupting it.

---

## Step 3 — Make your SSH key and get it onto the VM

Generate your own pair. **Never ask anyone to send you a private key.**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mandi_azure -C "$(whoami) deploy key" -N ""
cat ~/.ssh/mandi_azure.pub
```

That last command prints one line starting `ssh-ed25519 AAAA...`. **Send that
line to the owner.** A public key is safe to send over any channel.

The owner runs this on their machine:

```bash
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 \
  'echo "<your public key line>" >> ~/.ssh/authorized_keys'
```

Wait for them to confirm, then test:

```bash
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 'docker ps'
```

If that prints a container listing (or an empty table), you are in. If it says
`Permission denied (publickey)`, the key has not been added yet — or the VM is
switched off, in which case ask the owner to run
`az vm start -g mandi-rg -n mandi-vm`.

---

## Step 4 — Get a GitHub token for the registry

The pipeline pushes the built image to GitHub Container Registry. The package is
private and lives in the owner's namespace, so you need two things.

**The owner grants you access:** their GitHub → Packages → `automl_ia3` →
Package settings → Manage access → invite you with the **Write** role.

**You create a token:** <https://github.com/settings/tokens> →
**Generate new token (classic)** → tick **`write:packages`** → Generate → copy
it immediately, GitHub shows it once.

> Take the **classic** path, not fine-grained. GHCR's support for fine-grained
> tokens is incomplete and fails with a bare `denied` that explains nothing.

Check it before you go near Jenkins — this takes 30 seconds and saves a failed
build:

```bash
cd ~/projects/devops_IA3
bash scripts/check_ghcr.sh
```

It asks for the token with hidden input (never written to a file or your shell
history), confirms which account it belongs to, checks `write:packages` is
present, and performs a real push. You want all three checks to pass.

---

## Step 5 — Install Jenkins

```bash
cd ~/projects/devops_IA3
sudo bash scripts/install_jenkins.sh
```

This takes a few minutes. It handles three things that each otherwise cost you a
failed build:

- Ubuntu 22.04 defaults to Java 11; Jenkins needs 17 or 21, and on Java 11 it
  installs cleanly and then refuses to start
- Jenkins' own documentation still points at a superseded apt signing key
- the `jenkins` user cannot reach the Docker socket until it is in the `docker`
  group

At the end it prints a one-time unlock password. **Copy it.**

If it fails, re-run it — it clears its own half-finished state first.

---

## Step 6 — First-run wizard

Open <http://localhost:8080>.

1. Paste the unlock password
2. **Install suggested plugins** — wait, it takes a few minutes
3. Create your admin user (remember the password)
4. Accept the default Jenkins URL → **Save and Finish**

Then add two plugins the pipeline needs:

**Manage Jenkins → Plugins → Available plugins** → search and tick:
- **Docker Pipeline**
- **SSH Agent**

Install, and restart Jenkins when it offers.

---

## Step 7 — Add the three credentials

**Manage Jenkins → Credentials → System → Global credentials (unrestricted) →
Add Credentials.** Do this three times.

The **ID must match exactly** — the Jenkinsfile looks each one up by ID, and a
typo produces a confusing failure much later in the build.

### 7a. GHCR

| Field | Value |
|---|---|
| Kind | **Username with password** |
| Username | **your** GitHub username |
| Password | **your** token from step 4 |
| ID | `ghcr-credentials` |

### 7b. SSH key

First copy the key properly:

```bash
xclip -selection clipboard < ~/.ssh/mandi_azure
```

| Field | Value |
|---|---|
| Kind | **SSH Username with private key** |
| ID | `azure-vm-ssh` |
| Username | `azureuser` |
| Private Key | **Enter directly** → Add → **Ctrl+V** into the box |

> Do not select the key text by hand. A manual selection usually drops the
> trailing newline, and OpenSSH will not parse a key file without one. The
> symptom is `Load key: error in libcrypto` in the Deploy stage, which reads
> like a rejected key but means an unreadable file.

### 7c. The VM address

| Field | Value |
|---|---|
| Kind | **Secret text** |
| Secret | `172.198.79.131` |
| ID | `azure-vm-ip` |

Just the address. No `http://`, no trailing slash.

---

## Step 8 — Create the pipeline job

**Dashboard → New Item**

- Name: `mandi-devops` (anything works)
- Type: **Pipeline** → **OK**

Then on the configuration page:

**Build Triggers**
- tick **Poll SCM**
- Schedule: `H/2 * * * *`

**Pipeline**

| Field | Value |
|---|---|
| Definition | **Pipeline script from SCM** |
| SCM | **Git** |
| Repository URL | `https://github.com/dharshan-kumarj/AutoML_IA3.git` |
| Credentials | **- none -** (the repository is public) |
| Branch Specifier | `*/main` |
| Script Path | `Jenkinsfile` |

> **Definition must be "Pipeline script from SCM", not "Pipeline script".**
> With an inline script, `checkout scm` has nothing to check out and the build
> fails immediately; Poll SCM also has nothing to poll, so no commit would ever
> trigger anything.

**Save**, then **Build Now**.

---

## Step 9 — What a good first build looks like

Ask the owner to confirm the VM is running first
(`az vm start -g mandi-rg -n mandi-vm`).

| Stage | Expect |
|---|---|
| Checkout | a few seconds |
| Lint & Test | ~30 s, ending `187 passed, 1 skipped` |
| Docker Build | **several minutes** on a cold cache — it builds a 754 MB image from nothing |
| Smoke Test Image | `{"status":"ok","models_loaded":true,...}` |
| Push to GHCR | mostly `Layer already exists` |
| Deploy | Ansible pulls, swaps the container, waits for health |
| Verify Deployment | `deployment healthy: http://172.198.79.131/` |

**Finished: SUCCESS**, and all seven stages green.

Your first build is much slower than later ones because nothing is cached. Give
Docker Build several minutes before assuming it has hung.

Then open <http://172.198.79.131/> in a browser — that is what you deployed.

---

## Step 10 — Prove it is continuous

This is the part that actually demonstrates CI/CD, rather than you pressing a
button.

```bash
cd ~/projects/automl_IA3
git commit --allow-empty -m "Verify the pipeline from my machine"
git push
```

Now **do not touch Jenkins**. Within two minutes Poll SCM notices and starts a
build on its own. The build page will record the cause as
**"Started by an SCM change"** — screenshot that.

> Note: the owner's Jenkins polls the same branch, so your push triggers their
> build too. Both deploy to the same VM and whichever finishes last is what is
> live. Agree who is deploying before a demo.

---

## If something fails

| Symptom | Cause | Fix |
|---|---|---|
| `'checkout scm' is only available when using "Multibranch Pipeline" or "Pipeline script from SCM"` | job Definition is "Pipeline script" | change it to **Pipeline script from SCM** (step 8) |
| Build green, but Push/Deploy/Verify say **"skipped due to when conditional"** | not building `main` | set Branch Specifier to `*/main` |
| `docker: permission denied ... /var/run/docker.sock` | `jenkins` not in the `docker` group | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `error from registry: denied` on push | token lacks `write:packages`, is fine-grained, or you have no access to the package | `bash scripts/check_ghcr.sh`; ask the owner for Write access |
| `failed to fetch oauth token: denied` during **Docker Build** | a stale credential left by an earlier failed push | `sudo rm -f /var/lib/jenkins/.docker/config.json` |
| `Load key: error in libcrypto` + `Permission denied (publickey)` | the key pasted into Jenkins lost its trailing newline | re-paste with `xclip` (step 7b) |
| `ansible-playbook: not found`, exit code 127 | Ansible was never installed (step 2) | `sudo apt install -y ansible && sudo systemctl restart jenkins` |
| `the --mount option requires BuildKit` | the buildx plugin is missing | `sudo apt install -y docker-buildx-plugin && sudo systemctl restart jenkins` |
| `Sending build context to Docker daemon  2.9GB` | you are on an old `Jenkinsfile`/`.dockerignore` | sync your fork from upstream |
| Ansible `UNREACHABLE` | VM is deallocated, or your key was never appended | ask the owner to `az vm start`; test SSH by hand |
| Jenkins will not start after install | wrong Java | re-run `sudo bash scripts/install_jenkins.sh` |
| `uv: command not found` in Lint & Test | transient download failure | re-run the build |

If none of these match, copy the **last 40 lines** of the console output — the
failing stage name and the exact error text are what identify the cause.

---

## Checklist

```
[ ]  1. delete any copied terraform state; clone both repos instead
[ ]  2. install docker (log out/in), ansible, git, xclip
[ ]  3. ssh-keygen; send the PUBLIC key; owner appends it; test ssh
[ ]  4. owner grants package Write; create a CLASSIC PAT; check_ghcr.sh passes
[ ]  5. sudo bash scripts/install_jenkins.sh; keep the unlock password
[ ]  6. wizard: suggested plugins, admin user, + Docker Pipeline, SSH Agent
[ ]  7. three credentials: ghcr-credentials, azure-vm-ssh, azure-vm-ip
[ ]  8. pipeline job, Definition = Pipeline script FROM SCM, branch */main
[ ]  9. owner starts the VM; Build Now; seven stages green
[ ] 10. push a commit; "Started by an SCM change"; screenshot it
```
