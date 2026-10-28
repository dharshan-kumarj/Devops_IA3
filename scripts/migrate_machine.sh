#!/usr/bin/env bash
#
# Moves this deployment's unversioned state between machines.
#
#   OLD laptop:   bash scripts/migrate_machine.sh export
#   NEW laptop:   bash scripts/migrate_machine.sh import <bundle.tar.gz>
#
# Four files live outside git and cannot be recovered from GitHub:
#
#   terraform/terraform.tfstate   Terraform's record that your 8 Azure
#                                 resources exist. WITHOUT IT, terraform apply
#                                 believes nothing exists and tries to build a
#                                 SECOND deployment.
#   terraform/terraform.tfvars    your subscription id and settings
#   ~/.ssh/mandi_azure            the private key the VM accepts
#   ~/.ssh/mandi_azure.pub        its public half, which Terraform reads
#
# The bundle contains a PRIVATE KEY. Move it on a USB stick, or scp it directly
# between the two machines. Do not email it, put it in cloud storage, or send
# it through a chat app. Delete it from both machines once the import is done.

set -euo pipefail

MODE="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
KEY="$HOME/.ssh/mandi_azure"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

case "$MODE" in
# ---------------------------------------------------------------- export ----
export)
    bundle="$HOME/mandi-migration-$(date +%Y%m%d-%H%M).tar.gz"
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT

    say "Collecting the files that are not in git"
    mkdir -p "$staging/terraform" "$staging/ssh"

    missing=0
    for f in terraform.tfstate terraform.tfvars; do
        if [ -f "$TF_DIR/$f" ]; then
            cp "$TF_DIR/$f" "$staging/terraform/$f"
            echo "    terraform/$f"
        else
            echo "    MISSING: terraform/$f" >&2
            missing=1
        fi
    done
    [ -f "$TF_DIR/terraform.tfstate.backup" ] && \
        cp "$TF_DIR/terraform.tfstate.backup" "$staging/terraform/" && \
        echo "    terraform/terraform.tfstate.backup"

    for f in "$KEY" "$KEY.pub"; do
        if [ -f "$f" ]; then
            cp "$f" "$staging/ssh/$(basename "$f")"
            echo "    $(basename "$f")"
        else
            echo "    MISSING: $f" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "Something above is missing. Fix that before exporting."

    # A manifest, so the import can tell you what it is restoring.
    {
        echo "exported_from : $(hostname)"
        echo "exported_at   : $(date -Iseconds)"
        echo "resources     : $(cd "$TF_DIR" && terraform state list 2>/dev/null | wc -l)"
    } > "$staging/MANIFEST.txt"

    tar -czf "$bundle" -C "$staging" .
    chmod 600 "$bundle"

    say "Bundle written"
    echo "    $bundle"
    echo "    $(stat -c%s "$bundle") bytes"
    echo
    echo "    This contains a PRIVATE KEY."
    echo "    Move it by USB stick, or directly between the machines:"
    echo
    echo "        scp '$bundle' <you>@<new-laptop>:~/"
    echo
    echo "    Then delete it from BOTH machines. Do not email it or put it in"
    echo "    cloud storage."
    ;;

# ---------------------------------------------------------------- import ----
import)
    bundle="${2:-}"
    [ -n "$bundle" ] || die "Usage: bash scripts/migrate_machine.sh import <bundle.tar.gz>"
    [ -f "$bundle" ] || die "No such file: $bundle"

    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT
    tar -xzf "$bundle" -C "$staging"

    say "Bundle contents"
    sed 's/^/    /' "$staging/MANIFEST.txt" 2>/dev/null || echo "    (no manifest)"

    # Refuse to clobber a state file that is already here and different.
    if [ -f "$TF_DIR/terraform.tfstate" ] \
       && ! cmp -s "$TF_DIR/terraform.tfstate" "$staging/terraform/terraform.tfstate"; then
        die "terraform.tfstate already exists here and differs from the bundle.
       Refusing to overwrite it -- one of the two records real resources and
       losing the wrong one orphans them. Move the existing file aside first:
         mv '$TF_DIR/terraform.tfstate' '$TF_DIR/terraform.tfstate.old'"
    fi

    say "Restoring terraform state and variables"
    mkdir -p "$TF_DIR"
    cp "$staging/terraform/"* "$TF_DIR/"
    chmod 600 "$TF_DIR/terraform.tfstate" "$TF_DIR/terraform.tfvars"
    echo "    into $TF_DIR"

    say "Restoring the SSH key"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    cp "$staging/ssh/mandi_azure" "$KEY"
    cp "$staging/ssh/mandi_azure.pub" "$KEY.pub"
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"
    ssh-keygen -l -f "$KEY" >/dev/null 2>&1 \
        && echo "    key restored and parses correctly" \
        || die "the restored key does not parse -- the bundle is damaged"

    say "Checking that Terraform agrees with Azure"
    if command -v terraform >/dev/null && command -v az >/dev/null; then
        if az account show >/dev/null 2>&1; then
            ( cd "$TF_DIR" && terraform init -input=false >/dev/null 2>&1 \
              && terraform plan -input=false -detailed-exitcode >/dev/null 2>&1 )
            case $? in
                0) echo "    state matches Azure exactly -- nothing to create or change" ;;
                2) echo "    terraform plan reports DIFFERENCES. Run 'terraform plan'"
                   echo "    and read it before applying anything." ;;
                *) echo "    could not run plan; do it by hand" ;;
            esac
        else
            echo "    not logged in -- run 'az login', then 'terraform plan'"
        fi
    else
        echo "    terraform or az not installed yet; see docs/migrate_to_new_machine.md"
    fi

    say "Done. Remaining steps are Jenkins-side -- see docs/migrate_to_new_machine.md"
    echo "    Delete the bundle now:  shred -u '$bundle'  (or just rm)"
    ;;

*)
    die "Usage:
  OLD machine:  bash scripts/migrate_machine.sh export
  NEW machine:  bash scripts/migrate_machine.sh import <bundle.tar.gz>"
    ;;
esac
