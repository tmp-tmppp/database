"""Takes the rendered chart (helm template output) apart for scripts/test-setup.sh.

Writes into OUT_DIR: setup/ (the files of the ConfigMap postgres-setup: roles.conf and the two scripts, exactly as the
Job and the test Pod mount them), image (the server image with its digest), args (the server's arguments, one per
line) and initdb-args (POSTGRES_INITDB_ARGS). Needs PyYAML (preinstalled on GitHub's Ubuntu runners).

Usage: python3 scripts/extract_render.py RENDER.yaml OUT_DIR
"""

import pathlib
import sys

import yaml


def main() -> int:
    render, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    docs = [d for d in yaml.safe_load_all(render.read_text()) if d]
    configmap = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-setup"))
    server = next(d for d in docs if d["kind"] == "StatefulSet")
    container = server["spec"]["template"]["spec"]["containers"][0]

    setup = out / "setup"
    setup.mkdir(parents=True, exist_ok=True)
    for name, text in configmap["data"].items():
        (setup / name).write_text(text)
    (out / "image").write_text(container["image"] + "\n")
    (out / "args").write_text("\n".join(container["args"]) + "\n")
    env = {e["name"]: e.get("value", "") for e in container["env"]}
    (out / "initdb-args").write_text(env["POSTGRES_INITDB_ARGS"] + "\n")
    print(f"extracted {', '.join(sorted(configmap['data']))}, image and {len(container['args'])} server arguments")
    return 0


if __name__ == "__main__":
    sys.exit(main())
