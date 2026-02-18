#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------
# Setup
# ---------------------------------------------------------------
MCL_SECRET_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$MCL_SECRET_TMP_DIR"' EXIT

export HOME="$MCL_SECRET_TMP_DIR/home"
mkdir -p "$HOME/.ssh"

# Prevent age from picking up ssh-agent public keys (which it cannot use
# as identity files for decryption).  We rely on the private key file at
# $HOME/.ssh/id_ed25519 instead.
unset SSH_AUTH_SOCK

# Copy the test identity so age can decrypt with it.
cp "@TEST_KEYS_DIR@/id_ed25519" "$HOME/.ssh/id_ed25519"
chmod 600 "$HOME/.ssh/id_ed25519"

# Create a writable "machine" directory for re-encrypt-all test.
# This mimics the structure expected by the NixOS config's configPath.
MACHINE_DIR="$MCL_SECRET_TMP_DIR/test-machine"
mkdir -p "$MACHINE_DIR/secrets/test-svc"
mkdir -p "$MACHINE_DIR/secrets/other-svc"

# Use the machine directory for all secrets (re-encrypt-all reads from here).
SECRETS_DIR="$MACHINE_DIR/secrets"

# Create a helper script to use as EDITOR — it copies the
# cleartext-input file to the target file that age will encrypt.
export EDITOR="$MCL_SECRET_TMP_DIR/fake-editor"
cat > "$EDITOR" <<'EDSCRIPT'
#!/usr/bin/env bash
cp "$CLEARTEXT_INPUT" "$1"
EDSCRIPT
chmod +x "$EDITOR"

pass=0
fail=0
tests=0
assert_eq() {
  local actual="$1" expected="$2" label="$3"
  tests=$((tests + 1))
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (expected '$expected', got '$actual')"
  fi
}
assert_file_exists() {
  local path="$1" label="$2"
  tests=$((tests + 1))
  if [ -f "$path" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (file does not exist: $path)"
  fi
}

# ---------------------------------------------------------------
# Test 1: `mcl secret edit` — create a new secret
# ---------------------------------------------------------------
echo "=== Test 1: mcl secret edit (create new secret) ==="

export CLEARTEXT_INPUT="$MCL_SECRET_TMP_DIR/cleartext-input"
echo -n "super-secret-password" > "$CLEARTEXT_INPUT"
mcl secret \
  --machine test-secret-machine \
  edit \
  --service test-svc \
  --secret password \
  --secrets-folder "$SECRETS_DIR/test-svc"

assert_file_exists "$SECRETS_DIR/test-svc/password.age" "password.age created"

decrypted=$(age --decrypt \
  -i "$HOME/.ssh/id_ed25519" \
  "$SECRETS_DIR/test-svc/password.age")
assert_eq "$decrypted" "super-secret-password" "decrypted content matches original"

# ---------------------------------------------------------------
# Test 2: `mcl secret edit` — edit an existing secret
# ---------------------------------------------------------------
echo "=== Test 2: mcl secret edit (edit existing secret) ==="

echo -n "updated-password" > "$CLEARTEXT_INPUT"
mcl secret \
  --machine test-secret-machine \
  edit \
  --service test-svc \
  --secret password \
  --secrets-folder "$SECRETS_DIR/test-svc"

decrypted=$(age --decrypt \
  -i "$HOME/.ssh/id_ed25519" \
  "$SECRETS_DIR/test-svc/password.age")
assert_eq "$decrypted" "updated-password" "edited content matches"

# ---------------------------------------------------------------
# Test 3: Create a second secret, then `mcl secret re-encrypt`
# ---------------------------------------------------------------
echo "=== Test 3: mcl secret re-encrypt ==="

echo -n "my-api-key-123" > "$CLEARTEXT_INPUT"
mcl secret \
  --machine test-secret-machine \
  edit \
  --service test-svc \
  --secret api-key \
  --secrets-folder "$SECRETS_DIR/test-svc"

mcl secret \
  --machine test-secret-machine \
  re-encrypt \
  --service test-svc \
  --secrets-folder "$SECRETS_DIR/test-svc"

d1=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/password.age")
d2=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/api-key.age")
assert_eq "$d1" "updated-password" "password preserved after re-encrypt"
assert_eq "$d2" "my-api-key-123" "api-key preserved after re-encrypt"

# ---------------------------------------------------------------
# Test 4: `mcl secret re-encrypt-all`
# ---------------------------------------------------------------
echo "=== Test 4: mcl secret re-encrypt-all ==="

echo -n "other-token-value" > "$CLEARTEXT_INPUT"
mcl secret \
  --machine test-secret-machine \
  edit \
  --service other-svc \
  --secret token \
  --secrets-folder "$SECRETS_DIR/other-svc"

# re-encrypt-all uses configPath-derived folder paths.
# We use --config-path to point to our writable machine directory.
mcl secret \
  --machine test-secret-machine \
  re-encrypt-all \
  --config-path "$MACHINE_DIR"

d1=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/password.age")
d2=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/api-key.age")
d3=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/other-svc/token.age")
assert_eq "$d1" "updated-password" "password preserved after re-encrypt-all"
assert_eq "$d2" "my-api-key-123" "api-key preserved after re-encrypt-all"
assert_eq "$d3" "other-token-value" "token preserved after re-encrypt-all"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "Results: $pass/$tests passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
