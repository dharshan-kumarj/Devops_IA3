#!/usr/bin/env bash
#
# Diagnoses a "denied" from GitHub Container Registry.
#
#   bash scripts/check_ghcr.sh
#
# Reads the token interactively. It is never echoed, never written to a file,
# and never added to your shell history. Nothing here needs root.
#
# "layers Pushed" followed by "error from registry: denied" means the blob
# uploads were accepted and the manifest PUT was refused. That is a permission
# problem, not a network or image problem, and it has three usual causes:
#   1. the token lacks write:packages
#   2. the token is fine-grained rather than classic
#   3. the Jenkins credential's USERNAME is not the GitHub login that owns the
#      image path (an email address is the common mistake)

set -uo pipefail

OWNER="${1:-dharshan-kumarj}"
IMAGE="ghcr.io/${OWNER}/automl_ia3"

echo "Checking push access to ${IMAGE}"
echo
printf 'Paste your GitHub token (input hidden): '
read -rs TOKEN
echo
echo

if [ -z "$TOKEN" ]; then
    echo "No token entered." >&2
    exit 1
fi

fail=0

# -------------------------------------------------- 1. who is this token?
echo "==> 1. Which account does the token belong to?"
headers="$(curl -sI -H "Authorization: token ${TOKEN}" https://api.github.com/user)"
login="$(curl -s -H "Authorization: token ${TOKEN}" https://api.github.com/user \
         | grep -m1 '"login"' | cut -d'"' -f4)"

if [ -z "$login" ]; then
    echo "    FAIL: the token was rejected by the GitHub API entirely."
    echo "    It is expired, revoked, or was pasted with a missing character."
    exit 1
fi
echo "    token belongs to: ${login}"
if [ "$login" != "$OWNER" ]; then
    echo "    FAIL: the image path is ${OWNER}/... but the token is ${login}'s."
    echo "    Either use ${login}'s namespace or a token belonging to ${OWNER}."
    fail=1
else
    echo "    OK: matches the image path owner."
fi
echo

# -------------------------------------------------- 2. scopes
echo "==> 2. Does the token carry write:packages?"
scopes="$(printf '%s' "$headers" | grep -i '^x-oauth-scopes:' | cut -d: -f2- | tr -d '\r' | sed 's/^ *//')"
if [ -z "$scopes" ]; then
    echo "    FAIL: no x-oauth-scopes header came back."
    echo "    That header is only sent for CLASSIC tokens. A fine-grained token"
    echo "    returns nothing here, and GHCR pushes fail with exactly the"
    echo "    'denied' you are seeing."
    echo "    Fix: github.com/settings/tokens -> Generate new token (CLASSIC)."
    fail=1
else
    echo "    scopes: ${scopes}"
    if printf '%s' "$scopes" | grep -q 'write:packages'; then
        echo "    OK: write:packages present."
    else
        echo "    FAIL: write:packages is missing. That is the cause."
        echo "    Fix: regenerate the token with write:packages ticked."
        fail=1
    fi
fi
echo

# -------------------------------------------------- 3. an actual push
echo "==> 3. Can it actually push?"
# Retag a tiny public image rather than building one: that removes the build
# from the equation, so a failure here can only be the push.
if ! printf '%s' "$TOKEN" | docker login ghcr.io -u "$login" --password-stdin 2>&1 | sed 's/^/    /'; then
    echo "    FAIL: docker login ghcr.io was rejected."
    fail=1
else
    probe="ghcr.io/${login}/ghcr-probe:test"

    echo "    pulling hello-world (public, ~20 kB)"
    if ! docker pull -q hello-world >/dev/null 2>&1; then
        echo "    could not pull hello-world; skipping the push probe."
    else
        docker tag hello-world "$probe"
        echo "    pushing ${probe}"
        echo "    ---- full output, nothing suppressed ----"
        if docker push "$probe" 2>&1 | sed 's/^/    /'; then
            echo "    ----"
            echo "    OK: push succeeded."
            echo "    Delete the probe later at github.com/users/${login}/packages"
        else
            echo "    ----"
            echo "    FAIL: the push was refused. The exact registry message is"
            echo "    printed above -- that text is what identifies the cause,"
            echo "    not the word 'denied' on its own."
            fail=1
        fi
        docker rmi "$probe" >/dev/null 2>&1 || true
    fi
    docker logout ghcr.io >/dev/null 2>&1 || true
fi
echo

unset TOKEN
echo
if [ "$fail" -eq 0 ]; then
    echo "All three checks passed."
    echo "If Jenkins still fails, the token is fine but the Jenkins credential is"
    echo "not: open ghcr-credentials and confirm the USERNAME field is exactly"
    echo "'${login}' -- not an email address -- and re-paste the token."
else
    echo "Fix the FAIL above, update the ghcr-credentials credential in Jenkins,"
    echo "then Build Now again."
fi
