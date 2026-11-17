# omp-account

An [omp](https://github.com/can1357/oh-my-pi) extension (not a Tern plugin) that picks which OAuth account
of the current model's provider a conversation uses, for profiles with several accounts of one provider
(two Claude logins, say). Models stay the provider's own; `/model` is unchanged.

## Install

Add it to each profile's `config.yml` (`~/.omp/agent/config.yml` for `default`,
`~/.omp/profiles/<name>/agent/config.yml` for the others):

```yaml
extensions:
  - <clone>/omp-account/account.ts
```

The profile needs the accounts logged in: `/login` once per account.

## Usage

- `/hesap` lists the accounts of the current model's provider; pick one, or **Otomatik** to let omp choose.
- `/hesap 2`, `/hesap inohom` (a unique piece of the e-mail or organization) pick directly; `/hesap oto`
  goes back to automatic.
- The status line shows `hesap: <name>` (the e-mail's domain without its TLD), or `hesap: <name> (oto)`
  while omp chooses. It is hidden for providers with fewer than two accounts.

## How it works

The choice is an explicit session pin (`authStorage.sessions.pin`): omp's account ranking and reserve never
move it. omp still routes around it while the account is blocked (usage limit) or its token cannot be
refreshed. The choice is also saved in the session file (`account-choice` custom entry) and pinned again
on resume and before every prompt; omp's own `credential_pin` restores only an automatic pin, which
re-ranks after an idle hour. Subagents start on the parent's pin.
