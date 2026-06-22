# AWS Credential Hardening

Static, long-lived AWS access keys (`AKIA…`) stored in plaintext at `~/.aws/credentials` are a prime target for credential-harvesting malware — the npm/PyPI supply-chain worms that motivate [security.md](./security.md) read this file directly, and a stolen static key stays valid until it is manually revoked. This runbook removes static keys from disk and moves access to short-lived credentials. Part of the cloud short-lived-credentials follow-up (#253).

The steps are generic and safe to keep in the repo. **Do not commit findings** (key IDs, profile names, account identifiers) — record those privately.

## Detect

```bash
grep -c '^aws_session_token' ~/.aws/credentials            # 0 = static long-lived; >0 = already short-lived STS
grep -oE 'AKIA|ASIA' ~/.aws/credentials | sort | uniq -c   # AKIA = static IAM keys (harden these); ASIA = temp STS
grep -oE '^\[[^]]+\]' ~/.aws/credentials                   # profile names
```

`AKIA` keys with **no** `aws_session_token` are the long-lived static keys to eliminate. SSO/STS-backed profiles already write short-lived `ASIA` credentials (e.g. an SSO with a 1-hour session) — leave those; they are already the target state.

## Triage each static profile

For every static (`AKIA`) profile, decide:

- **Unused** (a finished lab/tutorial, a retired integration) → delete it entirely; the cleanest outcome is one fewer credential:

  ```bash
  aws --profile <name> iam list-access-keys                        # confirm the AKIA id
  aws --profile <name> iam delete-access-key --access-key-id <AKIA...>
  # remove the [<name>] block from ~/.aws/credentials (and ~/.aws/config)
  # if its IAM user is dedicated and now unused, delete the user too (detach policies first)
  ```

- **Still needed** → migrate it to short-lived credentials (below).

## Migrate to short-lived

### Option A — aws-vault (recommended; low setup)

Keeps the IAM user but moves the key off plaintext disk into the OS keychain (macOS Keychain), and vends short-lived STS credentials on demand.

```bash
brew install --cask aws-vault
aws-vault add <profile>                                   # store the key in the keychain (paste once)
aws-vault exec <profile> -- aws sts get-caller-identity   # verify it vends STS creds
aws-vault rotate --no-session <profile>                   # create a new key, store it, delete the old one (atomic)
# remove the aws_access_key_id / aws_secret_access_key lines for <profile> from
# ~/.aws/credentials (keep ~/.aws/config). Going forward: aws-vault exec <profile> -- <cmd>
```

`aws-vault rotate --no-session` matters: the old key sat in plaintext on disk, so treat it as exposed and rotate it as part of the migration. `--no-session` makes the IAM access-key rotation call with the stored master credentials rather than a temporary STS session, which avoids session-token failures on some IAM management calls.

On macOS, prefer a dedicated aws-vault Keychain instead of storing the long-lived key in the login Keychain. The default dedicated Keychain name is `aws-vault`, so the end state should not need `AWS_VAULT_KEYCHAIN_NAME` in shell startup files.

If a key was first added to the login Keychain and must be copied into the dedicated Keychain without printing the secret, run the copy from a normal user terminal:

```bash
aws-vault exec <profile> --no-session -- env AWS_VAULT_KEYCHAIN_NAME=aws-vault aws-vault add <profile> --env
aws-vault exec <profile> -- aws sts get-caller-identity
```

After verifying the dedicated Keychain path, remove any leftover login-Keychain copy as hygiene. These commands do not print the secret:

```bash
security find-generic-password -s aws-vault -a <profile> ~/Library/Keychains/login.keychain-db
security delete-generic-password -s aws-vault -a <profile> ~/Library/Keychains/login.keychain-db
```

If `security` reports that the item could not be found, the login Keychain is already clean. Keychain and `aws-vault exec` checks can fail from sandboxed or headless automation sessions even when they work from the user's terminal, so run these commands in an interactive terminal tied to the user's Keychain session.

### Option B — IAM Identity Center (SSO; full end state)

No IAM-user access keys at all — a browser SSO login vends short-lived credentials.

- Enable IAM Identity Center, create a user + permission set, assign it to the account.
- `aws configure sso` (set the start URL, region, and sso-session), then `aws sso login`.
- Point the `~/.aws/config` profiles at the SSO session; remove static keys from `~/.aws/credentials`.
- Delete the old IAM-user access keys in the console.

## Harden and verify

- Enable MFA on any IAM user that remains.
- Scope each policy to least privilege. For a human admin identity, prefer moving toward IAM Identity Center plus assumable roles; if an IAM user remains temporarily, keep MFA enabled and use IAM Access Analyzer or last-accessed data to reduce broad managed policies.
- Verify no static keys remain on disk:

  ```bash
  grep -oE 'AKIA|ASIA' ~/.aws/credentials            # expect: empty
  grep -c '^aws_access_key_id' ~/.aws/credentials    # expect: 0
  ```

Done: `~/.aws/credentials` holds no static `AKIA` keys; access is via aws-vault (keychain + STS) or IAM Identity Center (SSO).

## GCP (parallel principle)

Long-lived service-account key files (downloaded JSON, e.g. under `~/.config/gcloud/`) are the GCP equivalent of static AWS keys. Prefer short-lived Application Default Credentials via `gcloud auth application-default login`, service-account impersonation, or workload identity over downloaded key files. Detect with `ls ~/.config/gcloud/*.json` and `gcloud auth list`; remove long-lived key files once a short-lived flow is in place.

## Cadence

Re-run the detection on each workstation periodically and when provisioning a new machine. Never let a long-lived `AKIA` key (or a downloaded GCP service-account key) persist in plaintext on disk.
