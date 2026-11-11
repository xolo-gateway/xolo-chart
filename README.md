# xolo-chart

Helm chart for [Xolo](https://github.com/xolo-gateway/xolo), an enterprise LLM
gateway, and the Kubernetes bench that tests it.

## Contents

| Path | Role |
|---|---|
| [`charts/xolo`](charts/xolo/README.md) | the chart: requirements, install, values, behaviour, sizing |
| [`bench`](bench/README.md) | a local kind cluster with a fake LLM provider, functional checks of a release, load campaigns |

```bash
helm install xolo oci://ghcr.io/xolo-gateway/charts/xolo \
  --set baseURL=https://xolo.example.com \
  --set database.existingSecret=xolo-db
```

The [chart's README](charts/xolo/README.md) describes a complete install.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions require a DCO sign-off
(`git commit -s`). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

Apache License 2.0, see [LICENSE](LICENSE). Xolo itself is distributed under
the GNU AGPL v3. This chart only deploys its published images.
