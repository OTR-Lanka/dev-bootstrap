# OTR-Lanka developer VM bootstrap (stage 0)

This public repository holds one small script, `bootstrap.sh`, that starts the
setup of an OTR-Lanka developer VM. It is public so that a brand-new VM can
download it before any GitHub sign-in exists.

It deliberately contains nothing internal: no tokens, hostnames, repository
lists or configuration. It only:

1. installs `git`, `curl` and the GitHub CLI (`gh`) from GitHub's apt repository;
2. signs you in to GitHub with a one-time device code, and lets `gh` create and
   upload an SSH key;
3. checks that you are a member of the `OTR-Lanka` organization;
4. clones the private `OTR-Lanka/otr-workspace` repository into `~/dev/projects`;
5. runs `otr-workspace/bootstrap.sh`, which does the full setup.

## Usage

Use the exact command from the Developer Guide (`OTR-Lanka/docs`,
`onboarding/developer-guide.md`, section 13). It pins a release tag and verifies
the file's SHA-256 checksum before running it:

```bash
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/OTR-Lanka/dev-bootstrap/<tag>/bootstrap.sh
echo "<sha256 from the Developer Guide>  bootstrap.sh" | sha256sum -c - && bash bootstrap.sh
```

Options: `-n`/`--dry-run` (or `OTR_BOOTSTRAP_DRY_RUN=true`) shows the plan
without changing anything; `-y`/`--yes` skips the confirmation (needed without
a terminal); `-h`/`--help` lists all options. `--dry-run` and `--yes` are also
passed on to stage 1 (`otr-workspace/bootstrap.sh`), and anything after `--`
is passed to stage 1 as well, for example
`bash bootstrap.sh -- --profile backend`. `OTR_PROJECTS_DIR` changes the base
directory for repositories (default `~/dev/projects`).

The script follows the OTR-Lanka Shell Script Standard: the plan goes to
stdout, progress and messages to stderr. Exit codes: 0 done (also after
answering "no" to "Continue?"), 1 a check or step failed, 2 a usage error,
127 a required tool is missing, 130 interrupted; after the hand-over, stage 1's
exit code.

## Requirements

- Ubuntu (the developer VMs run Ubuntu 24.04), run as your own user with sudo,
  with bash 4.4 or later, and `ssh` and `curl` (or `wget`) installed.
- Network access to github.com. From outside the office network, connect the
  VPN client first. If SSH port 22 is blocked, the script routes GitHub SSH
  through `ssh.github.com:443`, backing up `~/.ssh/config` to
  `~/.config/otr/backup/` before it changes it.
- Membership of the `OTR-Lanka` GitHub organization.

## Releasing a change

This script runs on every new developer VM, so changes need care:

1. Open a pull request. A review from a code owner is required.
2. After merge, create a SemVer tag (`vX.Y.Z`) on the merged commit.
3. Compute the checksum: `sha256sum bootstrap.sh`.
4. In the same rollout, update the command and checksum in the Developer Guide
   (`OTR-Lanka/docs`).

Never move or delete an existing tag: the guide and people's notes point at it.
