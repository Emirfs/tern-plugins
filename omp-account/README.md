# omp-account

An [omp](https://github.com/can1357/oh-my-pi) extension (not a Tern plugin) that picks which OAuth account
of the current model's provider a conversation uses, for a profile with several logins of one provider (a
personal and a work Claude subscription, say). No extra profiles, no extra providers: models stay the
provider's own and `/model` is unchanged.

## Install

Add it to each profile's `config.yml` (`~/.omp/agent/config.yml` for `default`,
`~/.omp/profiles/<name>/agent/config.yml` for the others):

```yaml
extensions:
  - <clone>/omp-account/account.ts
```

Log in to every account once with `/login`; omp keeps them side by side.

## Usage

- `/account` lists the accounts of the current model's provider; pick one, or **Automatic** to let omp
  choose again.
- `/account 2` picks by list number, `/account work` by a unique piece of the e-mail or organization,
  `/account auto` goes back to automatic.
- The status line shows `account: <name>` (the e-mail's domain without its TLD, e.g. `gmail`), or
  `account: <name> (auto)` while omp chooses. It is hidden for providers with fewer than two accounts.

## How it works

The choice is an explicit session pin (`authStorage.sessions.pin`), so omp's account ranking and usage
reserve never move it. omp still routes around it while the account is blocked (a usage limit) or its token
cannot be refreshed; the next prompt pins it again. The choice is saved in the session file (an
`account-choice` custom entry) and pinned again on resume and before every prompt: omp's own
`credential_pin` restores only an automatic pin, which re-ranks after an idle hour. Subagents start on the
parent's pin.

Tested with omp 18.22.0.
