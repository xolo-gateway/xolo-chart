# Contributing to xolo-chart

xolo-chart holds the Helm chart of [Xolo](https://github.com/xolo-gateway/xolo) and its Kubernetes bench. It follows the governance, the code of conduct and the
contribution rules of Xolo, described in Xolo's
[GOVERNANCE.md](https://github.com/xolo-gateway/xolo/blob/main/GOVERNANCE.md)
and [CODE_OF_CONDUCT.md](https://github.com/xolo-gateway/xolo/blob/main/CODE_OF_CONDUCT.md).

Issues and pull requests may be written in English or French.

## Before you start

Open a pull request directly for a bug fix, a typo or a documentation
change. For a new feature or a change of behaviour, open an issue first and
describe what you want to do. A problem of Xolo itself belongs in the
[Xolo issue tracker](https://github.com/xolo-gateway/xolo/issues).

## Development setup

You need Helm 3 and, for the bench, kind, kubectl, Docker and Go.

```bash
helm lint charts/xolo
helm template xolo charts/xolo --set database.dsn=postgres://xolo@db/xolo > /dev/null
```

The [bench](bench/README.md) deploys the chart on a local kind cluster. Run
`bench/validate.sh` after a change to the templates, and the matching phase
of `bench/campaign.sh` after a change that can affect performance.

## Conventions

- Rendering must fail, with a clear message, on a configuration that cannot
  work, rather than deploy it (see `templates/_helpers.tpl`).
- Every value is documented in `values.yaml`; user-facing behaviour is
  documented in `charts/xolo/README.md`.
- A change of the chart bumps `version` in `Chart.yaml`; following a Xolo
  release bumps `appVersion`. Pushing the tag `v<version>` publishes the
  chart to `oci://ghcr.io/xolo-gateway/charts` and creates the GitHub
  release.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(scope): subject`, `fix: subject`, etc.

## Developer Certificate of Origin (DCO)

This project uses the [Developer Certificate of Origin](DCO) rather than a
contributor license agreement. By signing off your commits you certify that
you have the right to submit the code and that it can be distributed under the
project license, the [Apache License 2.0](LICENSE). You keep your copyright in
full.

```bash
git commit -s -m "fix: description of the change"
```

Every commit of a pull request must carry the `Signed-off-by` line: a check
refuses the pull request otherwise.

### If you forgot to sign off

Last commit:

```bash
git commit --amend -s --no-edit
```

Several commits:

```bash
git rebase --signoff main
```

Then push again with `git push --force-with-lease`.
