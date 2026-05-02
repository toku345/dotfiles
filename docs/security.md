# Security Guide

This guide covers security best practices and emergency procedures for managing encrypted dotfiles with age and chezmoi.

## Table of Contents

1. [Security Overview](#security-overview)
2. [Emergency Key Rotation](#emergency-key-rotation)
3. [CI/CD Security Checks](#cicd-security-checks)
4. [Audit Trail](#audit-trail)
5. [Package Manager Supply Chain Defense](#package-manager-supply-chain-defense)
6. [Best Practices](#best-practices)

## Security Overview

### Two-Layer Security Model

This repository uses a two-layer encryption model to protect sensitive data:

```text
key.txt.age (in repository, password-protected)
    ↓ Decrypt with password from 1Password
~/key.txt (local age identity/private key)
    ↓ Decrypt other encrypted files
encrypted_*.age (SSH config, Google IME dictionary, etc.)
```

**Key Points:**
- `key.txt.age` is stored in the repository, encrypted with a password (scrypt)
- The password is stored securely in 1Password
- Only those with the password can extract the age private key
- The age private key (`~/key.txt`) is used to decrypt other encrypted files
- **NEVER commit `~/key.txt` to the repository**

### What's Protected

- `key.txt.age` - Password-protected age private key
- `encrypted_*.age` - Age-encrypted sensitive files (SSH configs, etc.)
- All encryption uses the age tool with strong cryptographic primitives

## Emergency Key Rotation

**IMPORTANT:** This procedure is for emergencies only (key leak, device compromise, etc.).
Do NOT perform routine key rotation unless necessary.

### When to Rotate

Rotate your age key immediately if:
- Your `~/key.txt` file is accidentally committed to a public repository
- Your device is lost, stolen, or compromised
- You suspect unauthorized access to your encrypted files
- You accidentally shared your age private key

### Rotation Steps

#### 1. Generate New Age Key

```bash
# Generate new age key pair
age-keygen --output ~/key.txt.new

# Backup the old key temporarily (in case rotation fails)
cp ~/key.txt ~/key.txt.backup
```

**Extract the new public key:**
```bash
grep "^# public key: " ~/key.txt.new
```

#### 2. Re-encrypt All Files

Navigate to your chezmoi source directory:
```bash
cd ~/.local/share/chezmoi
```

**Re-encrypt key.txt.age:**
```bash
# Create a secure temporary directory
TMPDIR="$(mktemp -d)"
chmod 700 "$TMPDIR"

# Encrypt the NEW private key with a password
# Note: key.txt.age is password-protected, not recipient-encrypted
age -p -o key.txt.age.new ~/key.txt.new
# Enter a strong password (store in 1Password immediately!)

# Verify the new encrypted file works (with error handling)
# This will prompt for the password you just set
age -d -o "$TMPDIR/test_decrypt.txt" key.txt.age.new
diff ~/key.txt.new "$TMPDIR/test_decrypt.txt" || {
  echo "ERROR: Re-encrypted file verification failed!"
  rm -rf "$TMPDIR"
  exit 1
}

# Replace old with new
mv key.txt.age.new key.txt.age

# Clean up the temporary directory
rm -rf "$TMPDIR"
```

**Re-encrypt other .age files:**
```bash
# Fail loudly on any step — never overwrite an encrypted file with an
# untrusted result. `set -o pipefail` makes pipeline failures fatal too.
set -euo pipefail

# Create a secure temporary directory
TMPDIR="$(mktemp -d)"
chmod 700 "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# Find all .age files (excluding key.txt.age)
git ls-files '*.age' | grep -v '^key\.txt\.age$'

# Extract and validate the new public key
NEW_PUBLIC_KEY=$(grep "^# public key: " ~/key.txt.new | sed 's/^# public key: //')
if [ -z "$NEW_PUBLIC_KEY" ]; then
  echo "ERROR: Could not extract public key from ~/key.txt.new" >&2
  exit 1
fi

# For each file: decrypt with old key, re-encrypt with new key, verify
# decryption with the new key, then atomically replace the original.
# Any failure aborts the script with the original file untouched.
F=private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age

age -d -i ~/key.txt.backup -o "$TMPDIR/temp_decrypted.txt" "$F"
age -r "$NEW_PUBLIC_KEY"   -o "$F.new"                     "$TMPDIR/temp_decrypted.txt"
age -d -i ~/key.txt.new    -o /dev/null                    "$F.new"

# Atomic replace only after the .new file has been proven decryptable.
mv "$F.new" "$F"
```

#### 3. Update Local Key

```bash
# Replace old key with new key
mv ~/key.txt.new ~/key.txt
chmod 600 ~/key.txt

# Test that chezmoi can decrypt files
chezmoi diff
```

#### 4. Commit and Push Changes

```bash
cd ~/.local/share/chezmoi

# Verify no plaintext keys are being committed
git status
git diff

# Commit the re-encrypted files
git add key.txt.age
git add private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age
# Add any other re-encrypted .age files

git commit -m "security: rotate age encryption key

Re-encrypted all .age files with new age key due to [reason].

- Generated new age key pair
- Re-encrypted key.txt.age with new password
- Re-encrypted all sensitive files
"

git push
```

#### 5. Clean Up

```bash
# Securely delete old key backup
rm -f ~/key.txt.backup

# Update password in 1Password
# Store the new password for key.txt.age in 1Password
```

### Post-Rotation Checklist

- [ ] All `.age` files re-encrypted with new key
- [ ] `chezmoi diff` works without errors
- [ ] Changes committed and pushed to GitHub
- [ ] New password stored in 1Password
- [ ] Old key backup deleted
- [ ] Test recovery on different machine (optional but recommended)

## CI/CD Security Checks

This repository includes automated security checks that run on every push and pull request.

### What Gets Checked

The GitHub Actions workflow (`.github/workflows/security-checks.yml`) performs:

1. **Plaintext Key Detection**
   - Prevents accidental commit of `~/key.txt` (unencrypted private key)
   - Checks for common key file naming patterns
   - PASS: No plaintext key files found
   - FAIL: Plaintext key detected in commit

2. **Age Encryption Verification**
   - Verifies `key.txt.age` exists in repository
   - Validates all `.age` files are properly encrypted
   - Checks file format headers (`age-encryption.org/v1` or `-----BEGIN AGE ENCRYPTED FILE-----`)
   - PASS: All files properly encrypted
   - FAIL: Missing or corrupted .age files

3. **Secret Pattern Detection**
   - Scans for common secrets using pattern matching
   - Detects: AWS keys, private keys, GitHub tokens, API keys
   - Excludes: Encrypted files, documentation examples
   - PASS: No secrets detected
   - FAIL: Potential secrets found

### How It Works

The workflow uses:
- **ripgrep** - Fast pattern matching for secret detection
- **Shell scripts** - Lightweight checks without external dependencies
- **No password required** - CI cannot decrypt files (password not stored)

### Limitations

- Cannot verify decryption (no password in CI)
- Pattern matching may have false positives
- Only catches common secret patterns
- Manual review still important for sensitive changes

### If CI Fails

1. **Review the error message** - Identifies which check failed
2. **Remove sensitive data** if detected
3. **Fix corrupted .age files** if encryption check failed
4. **Verify you didn't commit `~/key.txt`** (plaintext key)

If you believe it's a false positive, review the patterns in the workflow file.

## Audit Trail

Git history serves as the audit trail for encrypted files:

- **Change history**: `git log --follow -- '*.age'` tracks all changes
- **Diff check**: `git diff` shows which files changed (content is encrypted)
- **Commit messages**: Document reasons for important changes

### View Encrypted File History

```bash
# All .age file changes
git log --oneline --name-only -- '*.age'

# Specific file history
git log --follow -- key.txt.age

# Recent changes with dates
git log --pretty=format:"%h %ad %s" --date=short -- '*.age'
```

### Best Practices for Audit Trail

1. **Meaningful commit messages** - Explain why encrypted files changed
2. **Separate commits** - Don't mix encrypted file changes with other changes
3. **Review before push** - Always check `git diff` before pushing

## Package Manager Supply Chain Defense

Hardening defaults are committed for npm/bun, pip, and uv to mitigate the class of
attack exemplified by [Mini Shai-Hulud](https://blog.flatt.tech/entry/mini_shai_hulud)
(2026-04, npm postinstall + malicious bun runtime download) and the
`lightning@2.6.2/2.6.3` PyPI compromise (2026-04).

### Defenses in place

| File | Setting | Effect |
| --- | --- | --- |
| `~/.npmrc` | `ignore-scripts=true` | Disables `pre/postinstall` lifecycle scripts for **npm only**. Blocks the most common arbitrary-code-execution vector. |
| `~/.bunfig.toml` | `[install] minimumReleaseAge = 604800` | Time-based isolation for bun's npm package manager. Refuses npm packages younger than 7 days (in seconds). Mirrors uv's `exclude-newer`. |
| `~/.bunfig.toml` | `[install] ignoreScripts = true` | Disables lifecycle scripts for **bun only**. bun does not honor `~/.npmrc`'s `ignore-scripts`, so this is a separate defense, not a backup. As a global toggle it skips scripts even for packages listed in a project's `trustedDependencies`. |
| `~/.config/pip/pip.conf` | `[install] only-binary = :all:` | Refuses sdists; installs pre-built wheels only. Prevents `setup.py` / build-backend code from executing at install time. |
| `~/.config/uv/uv.toml` | `exclude-newer = "7 days"` | Time-based isolation: refuses to resolve PyPI distributions uploaded within the last 7 days. Most malicious versions are detected and yanked inside this window. |
| `~/.config/uv/uv.toml` | `no-build = true` | Refuses sdists; installs pre-built wheels only. Mirrors pip's `only-binary = :all:`. Prevents PEP 517 build-backend / `setup.py` code from executing at install time — `exclude-newer` alone does not close this path. |

Both time-based settings (`minimumReleaseAge`, `exclude-newer`) are expressed
as **durations**, not absolute dates, so the cooldown window slides
automatically — no periodic maintenance is required. If a value blocks a
legitimately-needed fresh package, dependency resolution simply pins to an
older version (fail-safe).

### Defense scope (what is and isn't blocked)

A few subtleties that are easy to read past in the table above:

- **Time-based isolation does not stop build-time code execution.** uv's
  `exclude-newer` only filters which distributions are *resolvable*; once
  a sdist is selected, its `setup.py` / PEP 517 build backend still
  executes arbitrary Python at install time. `no-build = true` is what
  closes that path. pip's `only-binary = :all:` plays the same role.
  Treat `exclude-newer` and `no-build` as complementary, not redundant.
- **`ignore-scripts=true` silently skips lifecycle scripts.** Many npm
  packages legitimately rely on `postinstall` to fetch platform binaries
  or run native builds. Under this default, `npm install` / `bun install`
  succeed but the runtime later fails with a missing module or binary.
  When such a failure is suspected, follow the *isolated recovery* flow
  in the next section rather than relaxing the defense in the daily
  project tree.
- **`~/.npmrc` and `~/.bunfig.toml` are independent.** Disabling scripts
  in one file does not cover the other tool — see the table above.

### Recovery workflow (when a package legitimately needs lifecycle scripts)

The straightforward-looking per-package overrides are easy to misuse:

- `npm install --ignore-scripts=false <pkg>` re-enables lifecycle scripts
  for the **entire invocation**, including every transitive dependency —
  not just `<pkg>`. A single recovery command therefore widens the trust
  surface across all packages being resolved at the same time.
- `bun install --ignore-scripts=false` only governs the *project's own*
  lifecycle scripts; bun gates dependency scripts independently via
  `trustedDependencies` and the built-in default-trusted list
  (`bun pm default-trusted`), so this flag does not unblock a blocked
  postinstall on a dependency.
- Under global `bunfig.toml` `ignoreScripts = true`, the toggle skips
  scripts even for packages listed in a project's `trustedDependencies`
  (see the defenses table), so `bun add --trust <pkg>` does not by
  itself restore lifecycle scripts while the global toggle is active.

The recommended path is to do recovery in a **throwaway project**, audit
the resolved lockfile and trust list, then return to the main workspace
with only the metadata that survived review:

```bash
# 1. Spin up an isolated workspace outside the daily project tree.
mkdir -p "/tmp/recovery-$(date +%s)" && cd "$_"
echo '{"name":"recovery","private":true}' > package.json

# 2. Install so the lockfile reflects the real dependency graph.
#    bun: dep scripts are blocked by default; review what bun blocked.
bun install <pkg>
bun pm untrusted
#    npm: re-running scripts is invocation-wide — only do this in the
#    throwaway, never in the main workspace.
npm install --ignore-scripts=false <pkg>

# 3. Audit the lockfile diff (trusted deps, transitive surface, sources)
#    before copying the dependency entry — and only that entry — back
#    into the real project. The main workspace's global defenses stay
#    intact throughout.
```

Per-package overrides for the non-script gates remain safe and narrow:

```bash
# bun: widen the cooldown
#   per-invocation:
bun add --minimum-release-age 0 <pkg>
#   per-project (edit project-local bunfig.toml):
#     [install]
#     minimumReleaseAge = 0
#   per-package (persistent, in ~/.bunfig.toml):
#     [install]
#     minimumReleaseAgeExcludes = ["@types/node", "typescript"]

# pip: allow sdist for a specific package that ships no wheel.
# Must disable the global only-binary in the same invocation, otherwise
# the two flags are additive and pip exits with "No matching distribution".
# Use the CLI form — it takes the highest precedence over pip.conf and
# avoids the ambiguity of env→config merging for cumulative options:
pip install --only-binary=:none: --no-binary=<pkg> <pkg>

# uv: temporarily widen the time window (per-invocation, no config edit)
UV_EXCLUDE_NEWER="0 seconds" uv pip install <pkg>
# or persistent per-package override in ~/.config/uv/uv.toml:
#   exclude-newer-package = { foo = "0 seconds" }
# Note: `uv add --exclude-newer=...` writes the value into pyproject.toml
# (project-scoped persistent), so it is not actually a one-shot override.

# uv: allow sdist for a specific package that ships no wheel.
UV_NO_BUILD=0 uv pip install <pkg>
# or persistent per-package override in ~/.config/uv/uv.toml:
#   no-build-package = ["foo"]
```

Use overrides only for the single command (or single project) that needs
them — never edit the user-global config files to weaken defaults.

### Verification

```bash
npm config get ignore-scripts                     # → true
grep -E 'minimumReleaseAge|ignoreScripts' ~/.bunfig.toml
pip config list                                    # → install.only-binary = :all:
grep -E 'exclude-newer|no-build' ~/.config/uv/uv.toml  # → both settings present
```

## Best Practices

### Daily Operations

1. **Never commit plaintext keys**
   - Keep `~/key.txt` outside git-tracked directories
   - Only commit `key.txt.age` (password-protected)
   - CI will catch accidental commits

2. **Store passwords securely**
   - Use 1Password for the `key.txt.age` password
   - Enable 2FA on 1Password
   - Keep Emergency Kit in secure physical location

3. **Minimize exposure**
   - Only decrypt when needed
   - Use secure temporary directories (`mktemp -d` with `chmod 700`)
   - Clean up decrypted files immediately

4. **Regular backups**
   - 1Password Emergency Kit (printed, in safe)
   - GitHub repository (encrypted files)
   - See [backup-restore.md](./backup-restore.md) for details

### Before Committing

```bash
# Always review what you're committing
git status
git diff

# Check for secrets locally (requires ripgrep)
# Use same exclusions as CI for consistent results
rg -i 'AKIA[0-9A-Z]{16}' --type-not lock --type-not svg -g '!*.age' -g '!**/security.md' .
rg -e '-----BEGIN.*PRIVATE KEY-----' --type-not lock --type-not svg -g '!*.age' -g '!**/security.md' .

# Verify encrypted files. Aggregates failures and exits non-zero so this
# block is safe to embed in CI / pre-commit, not just eyeball checks.
(
  set -uo pipefail
  failed=0
  while IFS= read -r f; do
    if ! head_line=$(head -n 1 "$f"); then
      echo "ERROR: cannot read $f" >&2
      failed=1
      continue
    fi
    if printf '%s\n' "$head_line" | grep -qE 'age-encryption.org|BEGIN AGE ENCRYPTED'; then
      echo "OK: $f"
    else
      echo "ERROR: $f does not look like an age file" >&2
      failed=1
    fi
  done < <(git ls-files '*.age')
  exit "$failed"
)
```

### Key Management

1. **Rotation Policy**
   - No routine rotation required for personal dotfiles
   - Rotate only in emergencies (see [Emergency Key Rotation](#emergency-key-rotation))
   - Document reason for rotation in commit message

2. **Access Control**
   - Keep `key.txt.age` password to yourself
   - Don't share age private key (`~/key.txt`)
   - Review repository access regularly

3. **Audit Trail**
   - Git history tracks all changes to encrypted files
   - Commit messages should explain sensitive changes
   - Monitor notifications for unexpected changes

### Machine Setup

1. **New machine checklist**
   - Clone repository via SSH (not HTTPS)
   - Decrypt `key.txt.age` to `~/key.txt`
   - Set permissions: `chmod 600 ~/key.txt`
   - Verify: `chezmoi diff` works
   - See [backup-restore.md](./backup-restore.md) for full setup

2. **Machine retirement**
   - Securely delete `~/key.txt`
   - Clear shell history if it contains passwords
   - Consider key rotation if machine was compromised

## Additional Resources

- [Age encryption tool](https://age-encryption.org/)
- [Chezmoi documentation](https://www.chezmoi.io/)
- [Backup and Restore Guide](./backup-restore.md)
- [CLAUDE.md](../CLAUDE.md) - Repository overview
