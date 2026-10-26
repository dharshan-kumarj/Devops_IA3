#!/usr/bin/env bash
#
# Installs Jenkins locally and configures it for this project's pipeline.
#
#   sudo bash scripts/install_jenkins.sh
#
# Idempotent: safe to re-run. It does three things that are easy to miss when
# following the Jenkins docs by hand, and each one otherwise costs you a failed
# build before you work out why:
#
#   1. Jenkins LTS needs Java 17 or 21. Ubuntu 22.04 ships Java 11 as default,
#      and Jenkins refuses to start on it. This installs 21 and points *only*
#      Jenkins at it, leaving the system default alone so nothing else breaks.
#   2. Jenkins runs as its own `jenkins` user, which cannot use Docker until it
#      is in the `docker` group. Without this the Docker Build stage fails with
#      "permission denied while trying to connect to the Docker daemon socket".
#   3. The pipeline shells out to ansible-playbook, so that must be installed
#      and on PATH for the jenkins user.

set -euo pipefail

JAVA_VERSION=21
JAVA_HOME_DIR="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-$(dpkg --print-architecture)"
JAVA_BIN="${JAVA_HOME_DIR}/bin/java"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs root. Run: sudo bash $0" >&2
    exit 1
fi

say() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- 1. Java 21
say "Installing Java ${JAVA_VERSION} (your system default stays as it is)"
apt-get update -qq
apt-get install -y -qq fontconfig "openjdk-${JAVA_VERSION}-jre"

if [ ! -x "$JAVA_BIN" ]; then
    echo "Expected Java at $JAVA_BIN but it is not there. Found:" >&2
    ls -1 /usr/lib/jvm/ >&2
    exit 1
fi
echo "    $("$JAVA_BIN" -version 2>&1 | head -1)"

# ----------------------------------------------------- 2. Jenkins apt repo
say "Adding the Jenkins apt repository"
install -m 0755 -d /usr/share/keyrings
wget -qO /usr/share/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc]" \
     "https://pkg.jenkins.io/debian-stable binary/" \
     > /etc/apt/sources.list.d/jenkins.list

say "Installing Jenkins"
apt-get update -qq
apt-get install -y -qq jenkins

# ------------------------------------------- 3. Point Jenkins at Java 21
# The packaged unit calls /usr/bin/java, which is Java 11 here. Rather than
# repointing the system-wide `java` alternative -- which would change the Java
# every other program on this machine gets -- override just this one unit's
# ExecStart, derived from whatever the package actually shipped.
say "Pointing the jenkins service at Java ${JAVA_VERSION}"
exec_line="$(systemctl cat jenkins.service | grep -m1 '^ExecStart=')"
if [ -z "$exec_line" ]; then
    echo "Could not read ExecStart from jenkins.service" >&2
    exit 1
fi
new_exec="${exec_line//\/usr\/bin\/java/$JAVA_BIN}"

if [ "$new_exec" = "$exec_line" ]; then
    echo "    warning: ExecStart does not call /usr/bin/java, so nothing was" >&2
    echo "    repointed. Check it by hand:  $exec_line" >&2
fi

mkdir -p /etc/systemd/system/jenkins.service.d
# $new_exec already begins with "ExecStart=". The bare "ExecStart=" line before
# it clears the one the package shipped; systemd otherwise treats ours as an
# additional command and tries to start Jenkins twice.
cat > /etc/systemd/system/jenkins.service.d/override.conf <<EOF
# Managed by scripts/install_jenkins.sh -- re-run that script to regenerate.
[Service]
Environment="JAVA_HOME=${JAVA_HOME_DIR}"
ExecStart=
${new_exec}
EOF
echo "    override written:"
sed 's/^/      /' /etc/systemd/system/jenkins.service.d/override.conf

# --------------------------------------------- 4. Docker and Ansible access
say "Granting the jenkins user access to Docker"
if ! getent group docker >/dev/null; then
    echo "    no docker group -- is Docker installed?" >&2
    exit 1
fi
usermod -aG docker jenkins
echo "    jenkins is now in: $(id -nG jenkins)"

say "Checking the tools the pipeline shells out to"
for tool in docker ansible-playbook git curl; do
    if command -v "$tool" >/dev/null; then
        printf '    %-16s %s\n' "$tool" "$(command -v "$tool")"
    else
        echo "    $tool MISSING -- the pipeline will fail without it" >&2
    fi
done

# ----------------------------------------------------------- 5. Start it up
say "Starting Jenkins"
systemctl daemon-reload
systemctl enable --now jenkins
systemctl restart jenkins

printf '    waiting for Jenkins to come up'
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null http://localhost:8080/login 2>/dev/null; then
        printf ' up\n'
        break
    fi
    printf '.'
    sleep 2
done

if ! systemctl is-active --quiet jenkins; then
    echo
    echo "Jenkins did not start. The last 30 log lines:" >&2
    journalctl -u jenkins -n 30 --no-pager >&2
    exit 1
fi

# -------------------------------------------------------------- 6. Hand off
secret=/var/lib/jenkins/secrets/initialAdminPassword
say "Jenkins is running at http://localhost:8080"
if [ -r "$secret" ]; then
    echo
    echo "    Unlock it with this one-time password:"
    echo
    echo "        $(cat "$secret")"
    echo
else
    echo "    (already unlocked -- no initial password file)"
fi
cat <<'NEXT'
Next, in the browser:
  1. paste the password above
  2. "Install suggested plugins", then create your admin user
  3. Manage Jenkins -> Plugins -> Available: install "Docker Pipeline"
     and "SSH Agent"
  4. add the three credentials and create the job -- see docs/setup.md Step 7
NEXT
