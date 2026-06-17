# GitHub Account Security Audit

A periodic runbook for hardening the GitHub account and inventorying long-lived credentials. The account is the root of trust for repositories, Actions, SSH/GPG key registration, and recovery, so it is the highest-value single account to harden once package-level supply-chain defenses are in place (see [security.md](./security.md) and [ADR 0027](./adr/0027-headless-linux-github-only-key-systemd-agent.md)).

Tracked as #251; the credential inventory in step 8 determines whether the npm-OIDC (#252) and cloud short-lived credential (#253) follow-ups apply.

Run this from a trusted machine while signed in to GitHub. The steps below are generic and safe to keep in the repo. **Do not commit the findings** (token names, app names, key fingerprints, account identifiers) — record those privately.

## 1. Phishing-resistant 2FA

Settings → Password and authentication (`https://github.com/settings/security`):

- [ ] Add a **Passkey / WebAuthn** authenticator (Touch ID, or a hardware security key). Passkeys resist phishing.
- [ ] Prefer passkey / security key over TOTP; **remove SMS** as a 2FA method (SIM-swap risk).
- [ ] Regenerate **recovery codes** (`https://github.com/settings/auth/recovery-codes`); store them in the password manager (and optionally a printed copy in a secure offline location). Confirm they are current.

## 2. Sessions, email, and audit log

- [ ] `https://github.com/settings/sessions` — revoke any web session on an unrecognized or retired device.
- [ ] `https://github.com/settings/emails` — confirm there are no unexpected addresses, and that the backup email is one you control and have secured. Email is a common account-takeover pivot (attackers add an address, then trigger a reset).
- [ ] `https://github.com/settings/security-log` — scan recent events (logins, key/secret additions, email/2FA changes) for anything unexpected.

## 3. Personal access tokens

The main long-lived credential surface — review carefully.

- [ ] Classic tokens: `https://github.com/settings/tokens`
- [ ] Fine-grained tokens: `https://github.com/settings/personal-access-tokens`
- [ ] For each token, note its name, scopes, and last-used date. **Revoke** if it was last used more than ~90 days ago, is scoped more broadly than needed, or is unrecognized. Keep only actively-used, minimally-scoped tokens.
- [ ] Note whether any npm-publish / automation tokens exist (this drives the npm OIDC decision).

## 4. OAuth apps and GitHub Apps

`https://github.com/settings/applications`:

- [ ] Authorized OAuth Apps — revoke anything not actively used.
- [ ] Authorized GitHub Apps / Installed GitHub Apps — review the granted permissions; remove unused.

## 5. SSH and GPG keys

`https://github.com/settings/keys`:

- [ ] Cross-check each listed SSH key against your known-good keys (the keys held in your password-manager SSH agent, any headless-box agent keys, and future hardware keys). Revoke anything unrecognized or retired.
- [ ] Review GPG keys the same way.

## 6. Deploy keys

- [ ] For repositories that use deploy keys (per-repo Settings → Deploy keys), revoke unused keys.

## 7. Actions secrets

- [ ] For repositories that run Actions, review Settings → Secrets and variables → Actions and remove stale secrets. (This dotfiles repo's CI runs without secrets — confirm none have crept in.)

## 8. Long-lived npm / cloud credential inventory

Run on the workstation. These results determine whether the npm-OIDC and cloud short-lived credential follow-ups apply:

```bash
# npm publish / automation tokens.
# Run `npm whoami` first: an empty list while logged OUT means "not checked".
# npm moved to session-based auth (classic/legacy tokens revoked Dec 2025); the
# 2-hour session token never appears here, and `npm token list` now shows only
# explicitly-created Granular access tokens (write tokens cap at 90 days). So an
# empty list while logged IN means no long-lived automation tokens exist — the
# #252 OIDC work then only concerns moving CI publishing to trusted publishing.
npm whoami && npm token list

# AWS static long-lived keys
test -e ~/.aws/credentials && grep -c 'aws_access_key_id' ~/.aws/credentials
aws configure list 2>/dev/null

# GCP long-lived service-account key files
ls ~/.config/gcloud/*.json 2>/dev/null
gcloud auth list 2>/dev/null
```

If no long-lived publish or cloud credentials exist (only OIDC / SSO / short-lived), the corresponding migration follow-ups can be closed as not-applicable.

## Cadence

Re-run on a security trigger (suspected compromise, lost device, a published advisory affecting an authorized app) and at least annually. Pair any long-lived credential that must remain with a calendar reminder to re-review.
