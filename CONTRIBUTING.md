# Contributing to Glyndor/rpm

This repository has its own guide because the organisation's shared one
describes a `topic → develop → main` flow that does not exist here. Following it
would tell you to target a branch this repository does not have.

Contributions are invitation-only. Bug reports and ideas through issues are
welcome; unsolicited pull requests are not accepted.

## What this repository is

The RPM package repository for Glyndor's products, to be served at
**rpm.glyndor.net**. It carries no product source. The packages are built and signed in
each product's own repository, and nothing is published from here yet; what it
holds today is its CI and the public key the repository will be signed with.

## Branch flow

```
topic branch ──PR──▶ main
```

There is no `develop`. Branch from `main`, open a pull request against `main`,
squash-merge back.

## Before you open a pull request

- **An issue first**, where one applies. Labels are the tracking system here;
  there is no board. Apply `type:`, `prio:`, `effort:` and `status:`.
- **Sign every commit off** with `git commit -s`, using your GitHub noreply address
  (`git config user.email`). The `dco` check is required and `commit identity`
  rejects any other address in the author, `Signed-off-by` or `Co-authored-by`.
  The `secret scan` rejects a line that looks like a credential.
- **Commits are signed**, GPG or SSH. `required_signatures` is enforced on `main`,
  and rebase-merge is disabled because GitHub re-creates rebased commits without
  signatures.
- **Conventional Commit title** on the pull request. It becomes the squashed
  commit message.

## Tests

Run the suite before pushing. It needs `python3-yaml` and `shellcheck` installed:

```sh
fail=0
suite=$(find tests -name '*.test.sh' -type f | sort)
# The completeness check takes the other test files as arguments and runs them
# itself, so this command runs each suite exactly once. On its own it only
# prints its usage.
# shellcheck disable=SC2086
# A runner that is not executable must fail the command, not skip the suites.
if [ -x tests/ci/suites/check-suite-completeness.test.sh ]; then
  tests/ci/suites/check-suite-completeness.test.sh $(grep -vx 'tests/ci/suites/check-suite-completeness\.test\.sh' <<< "$suite") || fail=1
else
  echo "FAILED: tests/ci/suites/check-suite-completeness.test.sh is not executable"; fail=1
fi
find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck || fail=1
[ "$fail" -eq 0 ] && echo "all green" || echo "SOMETHING FAILED"
[ "$fail" -eq 0 ]
```

The `fail` flag is not decoration. The loop runs every test instead of stopping at
the first red one, which is what you want locally, but it means the loop ends on
`echo` and reports success no matter how many scripts failed. CI lists the suites
one per line in `.github/workflows/tests.yml` and runs them through one runner that
runs every suite and fails at the end if any failed.
`tests/ci/suites/ci-runs-every-test.test.sh` fails when a test exists that the list
does not run.

Rules that matter more than coverage:

**Every script in `scripts/` needs a test** at the same depth in `tests/`.
`scripts/quality/coverage/check-test-coverage.sh` fails when one does not, itself
included.

**A test you have not watched fail is not a test.** Before claiming a check works,
delete or invert the control it covers, run it, and confirm it goes red for the
reason it names. Assert which failure fired, never that some failure did.

**A new suite needs an entry in `scripts/quality/scope/suite-scope.txt`**, the map
of paths whose change can alter its verdict, and one in
`scripts/quality/scope/suite-dependencies.txt` for the packages it needs. A suite
with no entry always runs, which is safe and is why the file may lag; the map has
its own test.

A suite that cannot run on a pull request goes in
`scripts/quality/coverage/suite-exemptions.txt` with its reason. That list is read
from the base commit too, so an entry takes effect from the pull request after the
one that adds it.

## What CI checks, and in what order

`.github/workflows/tests.yml` holds every check of a pull request. The ones that
read a diff or a tree and finish in seconds run first: `dco`, `empty-diff`,
`commit-identity`, `secret-scan`, `folder-limit`, `line-limit` and `workflow-lint`.
The suite and the shell lint (`shell`) wait for all of them, so a pull request
that is already red does not install packages to run a suite. `gate` always runs
and fails unless every other job succeeded.

`deprecations` in `tests.yml`, and `heavy tests deprecations` in
`tests-heavy.yml`, wait for the last job of their run, read the annotations of
every job of it and fail on a warning that something is deprecated or going
away. Neither is in the ruleset of `main`, and `gate` does not wait for them.

A file may hold 500 lines of code (comments and blank lines do not count), and a
folder twenty files directly. A folder over twenty is listed with a ceiling and a
reason in `.github/folder-limit-exceptions.txt`; the ceiling can only go down.

The scripts that judge a pull request (`check-secrets.sh`,
`check-commit-identity.sh`, `folder-limit.sh` and the rules under
`scripts/quality/lint/`) are read from the base commit, not from the pull
request. A change to one of them is judged by the rule `main` holds and takes
effect once it is merged.
