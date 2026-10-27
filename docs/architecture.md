# How this deployment works, end to end

Technical documentation of what was built, what talks to what, and why each
choice was made. If you only read one thing before a viva, read §1 and §2.

Everything here describes the system as it actually runs, verified on
2026-10-28 against the live deployment at `http://172.198.79.131/`.

---

## 1. The one-paragraph version

You push a commit to `AutoML_IA3`. A Jenkins running on your own laptop notices
within two minutes, checks the code out, lints and tests it, builds a Docker
image, runs that image locally and curls its health endpoint, pushes it to
GitHub Container Registry, then clones `Devops_IA3` and runs an Ansible
playbook. The playbook SSHes into an Azure virtual machine, pulls the image it
just pushed, replaces the running container, and waits for the app to answer.
Jenkins then curls the public URL itself to confirm. Nobody touches the server.

---

## 2. The flow, step by step

```
   YOU                          YOUR LAPTOP                         THE INTERNET
   ───                          ───────────                         ────────────

 git push ────────────────────────────────────────────────▶  github.com
                                                              AutoML_IA3
                                       ┌─────────────────────────┘
                   Poll SCM            │  (every 2 min: "did main move?")
                   H/2 * * * *         ▼
            ┌──────────────────────────────────────────┐
            │  JENKINS  (localhost:8080)               │
            │                                          │
            │  1 Checkout        git clone AutoML_IA3  │
            │  2 Lint & Test     ruff + 188 pytest     │
            │  3 Docker Build    754 MB image          │
            │  4 Smoke Test      run it, curl /health  │
            │  5 Push to GHCR  ──────────────────────────────▶ ghcr.io
            │  6 Deploy          clone Devops_IA3              automl_ia3
            │                    ansible-playbook               │
            │                         │                         │
            │  7 Verify          curl │ http://<ip>/api/health  │
            └─────────────────────────┼─────────────────────────┘
                                      │ ssh azureuser@172.198.79.131
                                      ▼
            ┌──────────────────────────────────────────┐
            │  AZURE VM  mandi-vm  (Standard_B1ms)     │
            │  Ubuntu 22.04, 1898 MB RAM               │
            │                                          │
            │   docker login ghcr.io                   │
            │   docker pull  ◀─────────────────────────────────┘
            │   docker rm -f mandi-automl              │
            │   docker run -p 80:8000 ...              │
            │   wait for /api/health                   │
            └──────────────────────────────────────────┘
                                      │
                                      ▼
                        http://172.198.79.131/   ◀── anyone with the link
```

### What happens in each stage

| # | Stage | Runs where | What it does | Fails if |
|---|---|---|---|---|
| 1 | Checkout | laptop | `git clone` the app repo at the triggering commit | GitHub unreachable |
| 2 | Lint & Test | laptop | installs `uv`, syncs dev deps, `ruff check`, `ruff format --check`, `pytest` | any test fails or formatting drifts |
| 3 | Docker Build | laptop | asserts `models/index.json` and `models/weekly_snapshot.csv` exist, then builds and tags with the short commit hash *and* `latest` | a model artefact is missing |
| 4 | Smoke Test Image | laptop | runs the new image on port 18000, polls `/api/health` for 60 s, asserts `"status":"ok"` | the image starts but the app does not serve |
| 5 | Push to GHCR | laptop → ghcr.io | logs in with an isolated `DOCKER_CONFIG`, pushes both tags | token lacks `write:packages` |
| 6 | Deploy | laptop → VM | clones `Devops_IA3`, writes a one-host inventory from the `azure-vm-ip` credential, runs `ansible/deploy.yml` over SSH | VM is deallocated, or the SSH key is malformed |
| 7 | Verify Deployment | laptop → public URL | polls `http://<ip>/api/health` for 150 s, asserts `"status":"ok"` | the container started but the NSG blocks port 80 |

Stages 5, 6 and 7 are gated on the branch being `main`. Stages 1–4 run on every
branch, so a feature branch still gets linted, tested and built — it just does
not ship.

---

## 3. The two-repository split, and why

| Repository | Holds | Changes when |
|---|---|---|
| `AutoML_IA3` | application code, `Dockerfile`, `Jenkinsfile` | you change the app |
| `Devops_IA3` | `terraform/`, `ansible/`, `scripts/`, this documentation | you change the infrastructure |

The `Jenkinsfile` lives with the application because Jenkins' *Pipeline script
from SCM* reads it out of the repository it is building. The Terraform lives
apart so that **a code push cannot alter infrastructure**. Terraform is run by
hand, once, at the start; the pipeline only ever replaces a container on a
machine that already exists. That boundary is deliberate: the worst a bad commit
can do is deploy a broken container, not destroy a network.

---

## 4. What Terraform creates

Eight resources, all inside one resource group so that `terraform destroy`
removes everything.

| Resource | Name | Purpose |
|---|---|---|
| Resource Group | `mandi-rg` | container for everything below |
| Virtual Network | `mandi-vnet` | private address space `10.20.0.0/16` |
| Subnet | `mandi-subnet-app` | `10.20.1.0/24`, where the NIC lives |
| Network Security Group | `mandi-nsg` | allows inbound 22 (SSH) and 80 (HTTP) |
| NSG ↔ Subnet association | — | binds the rules to the subnet |
| Public IP | `mandi-pip` | **Static**, so stop/start keeps `172.198.79.131` |
| Network Interface | `mandi-nic` | the virtual network card |
| Linux Virtual Machine | `mandi-vm` | `Standard_B1ms`, Ubuntu 22.04, 30 GB SSD |

The NSG is not on the assignment's list of six, but without it the deployment
is unreachable: an Azure subnet denies all inbound internet traffic until a rule
permits it.

**The Public IP is Static on purpose.** A Dynamic IP changes on every
stop/start, which would break the `azure-vm-ip` Jenkins credential every time
you deallocate the VM to save credit.

**cloud-init** runs once on first boot and installs Docker from Docker's own apt
repository, adds `azureuser` to the `docker` group, and touches
`/var/lib/cloud/docker-ready`. The playbook waits on that marker, so a deploy
that arrives while the VM is still booting waits rather than failing with
`docker: command not found`.

---

## 5. What Ansible does

`ansible/deploy.yml`, one host, eight tasks:

1. assert `image_name` and `image_tag` were passed
2. wait for the `docker-ready` marker (up to 10 min)
3. confirm `docker info` succeeds, retrying
4. `docker login ghcr.io` with the token passed in (`no_log: true`)
5. `docker pull <image>:<tag>`
6. `docker rm -f mandi-automl` — not an error on the first deploy
7. `docker run -d -p 80:8000 --restart unless-stopped --memory 1g` with one
   uvicorn worker
8. poll `/api/health` until it returns 200, then `docker logout` and prune old
   images

### The VM never sees your source code

This is the design decision most worth being able to explain. The VM does not
clone the repository, does not install Python, does not run `uv`, and does not
build anything. It pulls a finished image.

The reason is measurable: the image is **754 MB**, and the VM has **1898 MB** of
RAM. Building it there — compiling and installing SciPy, scikit-learn, pandas
and LightGBM — would exhaust memory. The laptop that builds it has sixteen cores
and does it in seconds. One uvicorn worker is used rather than two because the
app measured 407 MiB with two, which is tight on a 2 GB machine.

---

## 6. Credentials

Three, referenced by ID only. Nothing secret appears in either repository.

| Jenkins credential ID | Kind | Used by |
|---|---|---|
| `ghcr-credentials` | Username with password | stage 5 to push, stage 6 to let the VM pull |
| `azure-vm-ssh` | SSH username with private key | stage 6, as `azureuser` |
| `azure-vm-ip` | Secret text | stage 6 inventory, stage 7 health check |

Two habits are built into the pipeline:

- **The GHCR login writes to a throwaway `DOCKER_CONFIG` inside the workspace**,
  removed by a `trap` on EXIT/INT/TERM, so no token outlives the build and a
  failed push cannot leave a broken credential behind. §8 explains why that
  matters more than it sounds.
- **The Ansible inventory is written at deploy time** from the `azure-vm-ip`
  credential and deleted by a trap, so the server's address is not committed.

---

## 7. Why Jenkins runs locally

The assignment permits webhooks **or** Poll SCM. Local Jenkins was chosen, and
Poll SCM follows from it: a laptop behind NAT cannot receive a webhook from
GitHub.

The reasoning:

| | Local Jenkins | Jenkins on a cloud VM |
|---|---|---|
| Build machine | 16 cores, 23 GB | 1 vCPU, 2 GB |
| Cost | nothing | a second VM, billing continuously |
| Team of three | one each, fully independent | shared, or three more VMs |
| Webhooks | no (Poll SCM instead) | yes |

Building a 754 MB image on a B1ms while Jenkins' JVM also runs there is not
viable. If a live webhook demonstration is ever needed, `ngrok` exposes a local
Jenkins in about two minutes.

---

## 8. Problems hit, and what each one taught

Every item here cost a real build. They are the most useful part of this
document, and they belong in the report's *Observations* section.

### Azure for Students restricts regions

`terraform apply` failed with `403 RequestDisallowedByAzure` on the VNet, NSG
and Public IP — *after* creating the resource group, which makes it look worse
than it is. The subscription carries an **"Allowed resource deployment
regions"** policy and `centralindia` is not in it, despite being a real Azure
region.

```bash
az policy assignment list --query "[].parameters" -o json
# indonesiacentral, koreacentral, malaysiawest, indiasouthcentral, eastasia
```

`indiasouthcentral` is the closest allowed region. **Query this before your
first apply**, and note that each team member's subscription may allow a
different set.

### Jenkins rotated its apt signing key

Jenkins' own installation documentation still points at `jenkins.io-2023.key`,
which no longer matches the repository:

```
NO_PUBKEY 7198F4B714ABFC68
The repository 'https://pkg.jenkins.io/debian-stable binary/' is not signed.
```

The current key is `jenkins.io-2026.key`, fingerprint
`5E386EADB55F01504CAE8BCF7198F4B714ABFC68` — the last sixteen digits are the id
apt reported missing. `jenkins.io-2024.key` and `-2025.key` do not exist, so
there is no sequence to follow. `scripts/install_jenkins.sh` now probes for
every year's key and installs all that exist.

### Jenkins needs Java 17 or 21; Ubuntu 22.04 defaults to 11

Jenkins installs cleanly on Java 11 and then refuses to start. The install
script installs Java 21 and points only the `jenkins` systemd unit at it, via a
drop-in that rewrites `ExecStart`, rather than changing the system-wide `java`.

### A failed run poisoned apt for the next one

The first failed install left `/etc/apt/sources.list.d/jenkins.list` behind, so
every subsequent `apt-get update` — including the one near the top of the
script, before the key-repair code — aborted under `set -e`. The script was
described as idempotent and was not: the broken state it needed to fix was the
state preventing it from running. It now clears that entry first.

### `when { branch 'main' }` does nothing outside Multibranch

Build #2 reported **SUCCESS** having skipped Push, Deploy and Verify. That
directive reads `BRANCH_NAME`, which Jenkins only sets in a Multibranch Pipeline
or Organization Folder. In a plain *Pipeline script from SCM* job it is null, so
the condition never matched.

A green build that ships nothing is worse than a red one, because nothing looks
wrong. The pipeline now uses a helper that falls back to `GIT_BRANCH` (which the
git plugin sets as `origin/main`) and accepts either spelling.

### A failed push broke the *next* build, in an unrelated-looking way

After a denied push, the following build failed in **Docker Build**, pulling a
*public* image:

```
#6 [internal] load metadata for ghcr.io/astral-sh/uv:0.11.3
#6 ERROR: failed to authorize: failed to fetch oauth token: denied: denied
```

`docker logout` sat after `docker push` under `set -eu`, so the failed push
aborted the script before logout ran, leaving a bad credential in the jenkins
user's `~/.docker/config.json`. Docker then presented that broken token for
every ghcr.io request, including anonymous pulls. One bad token turned a push
problem into a build problem that looks nothing like it.

Fixed by the isolated `DOCKER_CONFIG` described in §6, plus a `post { always }`
safety net.

### `error in libcrypto` means a malformed key, not a rejected one

```
Load key "****": error in libcrypto
azureuser@****: Permission denied (publickey).
```

The key on disk was valid — 419 bytes, 7 lines, correct header and footer. The
copy pasted into the Jenkins credential had lost its **trailing newline**, and
OpenSSH will not parse a key file that does not end with one. Copy it with
`xclip -selection clipboard < ~/.ssh/mandi_azure` rather than selecting by hand.

### Two build-breakers caught before the first build

Both were found by running the pipeline's test stage against an extraction of
only git-tracked files, simulating a clean checkout:

- a test compared the generated report against its committed copy, which needs a
  deliberately git-ignored dataset — it now skips in CI instead of failing
- the Docker Build stage asserted `data/processed/weekly.parquet` exists, which
  is git-ignored *and* excluded by `.dockerignore`, so it could never have
  passed on a fresh checkout

Both would have failed build #1 for reasons unrelated to the code.

---

## 9. Day-to-day operation

```bash
# start the VM before a demo (static IP, so nothing else changes)
az vm start -g mandi-rg -n mandi-vm

# stop billing when you are done for the day
az vm deallocate -g mandi-rg -n mandi-vm

# what is running out there
ssh -i ~/.ssh/mandi_azure azureuser@172.198.79.131 'docker ps'

# the app's own view of itself
curl http://172.198.79.131/api/health

# remove everything, permanently
cd terraform && terraform destroy
```

`deallocate` is the one that stops compute billing. Shutting down from *inside*
the VM (`sudo poweroff`) leaves it allocated and still charging. The Static
Public IP bills a small amount even while deallocated; only `terraform destroy`
ends that.

---

## 10. Verified state

Checked against the live deployment on 2026-10-28:

| | |
|---|---|
| Container | `ghcr.io/dharshan-kumarj/automl_ia3:013035d`, healthy, `0.0.0.0:80→8000` |
| `/api/health` | `{"status":"ok","version":"0.1.0","models_loaded":true,"crops":["Cabbage","Onion","Potato","Tomato"]}` |
| Live prediction | Onion / Maharashtra → ₹1315.39 for the week of 2025-11-03 |
| Live backtest | 26 weeks, model MAE 68.75 vs naive 60.88, `model_beats_naive: false` |
| VM memory | 434 MB used of 1898 MB |
| Tests in CI | 187 passed, 1 skipped |

The backtest reporting `false` is the application working correctly: every
figure it serves is computed per request, so it reports honestly when the model
is losing to the naive baseline rather than displaying a flattering fixed number.
