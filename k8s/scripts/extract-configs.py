#!/usr/bin/env python3
"""Extract the rendered backend configs from `helm template` output.

WHY THIS EXISTS. `helm lint` checks the CHART. It does not open the YAML inside a ConfigMap
and ask whether Loki would still start. That matters here more than in most charts, because
two of these configs are not copies: the Mimir and Tempo configs are re-emitted after a
deep merge, and the collector gateway config is the real file with two keys removed. A
transform that produces valid Kubernetes YAML and an invalid Loki config is exactly the
failure this repository already guards against elsewhere with positive controls.

Writing the configs out lets `make -C k8s verify-configs` run each backend's OWN validator
against the bytes a pod will actually read.

Usage: extract-configs.py <rendered.yaml> <output-dir>
"""
import sys
import pathlib
import yaml

# ConfigMap name -> the key inside it that holds a whole config file.
WANTED = {
    "loki-config": "config.yaml",
    "tempo-config": "config.yaml",
    "mimir-config": "config.yaml",
    "otel-collector-config": "config.yaml",
    "otel-agent-config": "config.yaml",
}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    rendered, outdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    found = {}
    for doc in yaml.safe_load_all(rendered.read_text()):
        if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
            continue
        name = doc.get("metadata", {}).get("name")
        if name in WANTED:
            found[name] = doc.get("data", {}).get(WANTED[name], "")

    missing = sorted(set(WANTED) - set(found))
    if missing:
        # A vacuous validator is worse than none: it reports green forever. If a ConfigMap
        # is renamed and this script silently skips it, `make verify-configs` would keep
        # passing while checking less and less.
        print(f"ERROR: these ConfigMaps were not in the rendered output: {missing}",
              file=sys.stderr)
        print("Either a template was renamed, or a values flag disabled it. Fix the name "
              "in WANTED above rather than deleting the entry.", file=sys.stderr)
        return 1

    for name, body in found.items():
        if not body.strip():
            print(f"ERROR: {name} rendered EMPTY. A validator would pass vacuously on it.",
                  file=sys.stderr)
            return 1
        path = outdir / f"{name}.yaml"
        path.write_text(body)
        print(f"wrote {path} ({len(body)} bytes)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
