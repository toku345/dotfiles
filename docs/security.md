# Security Guide

This guide covers security best practices and emergency procedures for managing encrypted dotfiles with age and chezmoi.

## Table of Contents

1. [Security Overview](#security-overview)
2. [Emergency Key Rotation](#emergency-key-rotation)
3. [CI/CD Security Checks](#cicd-security-checks)
4. [Best Practices](#best-practices)

## Security Overview

### Two-Layer Security Model

This repository uses a two-layer encryption model to protect sensitive data:

```
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

**IMPORTANT:** This procedure is for emergency situations only (key leak, device compromise, etc.).
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
age-keygen -o ~/key.txt.new

# Backup the old key temporarily (in case rotation fails)
cp ~/key.txt ~/key.txt.backup
```

**Extract the new public key:**
```bash
grep "# public key:" ~/key.txt.new
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

# Decrypt with old key to get plaintext
age -d -i ~/key.txt -o "$TMPDIR/key_plaintext.txt" key.txt.age

# Verify it's the new key you just created
diff ~/key.txt.new "$TMPDIR/key_plaintext.txt"

# Re-encrypt with password
age -p -o key.txt.age.new "$TMPDIR/key_plaintext.txt"
# Enter a strong password (store in 1Password immediately!)

# Verify the new encrypted file works
age -d -o "$TMPDIR/test_decrypt.txt" key.txt.age.new
diff ~/key.txt.new "$TMPDIR/test_decrypt.txt"

# Replace old with new
mv key.txt.age.new key.txt.age

# Clean up the temporary directory
rm -rf "$TMPDIR"
```

**Re-encrypt other .age files:**
```bash
# Create a secure temporary directory (reuse or create new)
TMPDIR="$(mktemp -d)"
chmod 700 "$TMPDIR"

# Find all .age files (excluding key.txt.age)
git ls-files '*.age' | grep -v '^key\.txt\.age$'

# For each file, decrypt with old key and re-encrypt with new key
# Example for Google IME dictionary:
age -d -i ~/key.txt.backup \
  -o "$TMPDIR/temp_decrypted.txt" \
  private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age

age -r $(grep "# public key:" ~/key.txt.new | cut -d: -f2 | xargs) \
  -o private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age.new \
  "$TMPDIR/temp_decrypted.txt"

# Verify decryption works with new key
age -d -i ~/key.txt.new private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age.new > /dev/null

# Replace old with new
mv private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age.new \
   private_dot_config/google_ime/encrypted_google_ime_dictionary.txt.age

# Clean up the temporary directory
rm -rf "$TMPDIR"
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
   - ✅ PASS: No plaintext key files found
   - ❌ FAIL: Plaintext key detected in commit

2. **Age Encryption Verification**
   - Verifies `key.txt.age` exists in repository
   - Validates all `.age` files are properly encrypted
   - Checks file format headers (`age-encryption.org/v1` or `-----BEGIN AGE ENCRYPTED FILE-----`)
   - ✅ PASS: All files properly encrypted
   - ❌ FAIL: Missing or corrupted .age files

3. **Secret Pattern Detection**
   - Scans for common secrets using pattern matching
   - Detects: AWS keys, private keys, GitHub tokens, API keys
   - Excludes: Encrypted files, documentation examples
   - ✅ PASS: No secrets detected
   - ❌ FAIL: Potential secrets found

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

## Best Practices

### Daily Operations

1. **Never commit plaintext keys**
   - Keep `~/key.txt` in `~/.gitignore` equivalent
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

# Check for secrets locally (if ripgrep installed)
rg -i 'AKIA[0-9A-Z]{16}' --type-not lock --type-not svg -g '!*.age' -g '!**/security.md' .
rg '-----BEGIN.*PRIVATE KEY-----' --type-not lock --type-not svg -g '!*.age' .

# Verify encrypted files
git ls-files '*.age' | while IFS= read -r f; do
  head -n 1 "$f" | grep -qE 'age-encryption.org|BEGIN AGE ENCRYPTED' && echo "✅ $f" || echo "❌ $f"
done
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

## Support

For security concerns:
- Review this guide and [backup-restore.md](./backup-restore.md)
- Check GitHub Issues for similar problems
- Create new issue with `security` label if needed
