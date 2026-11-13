"""scripts/upgrade_pins.py: the pins file comes from the sources, never from a hand (#287)."""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import upgrade_pins as up  # noqa: E402

APT = """Package: kubeadm
Version: 1.37.0-1.1

Package: kubeadm
Version: 1.37.2-1.1

Package: kubelet
Version: 1.37.0-1.1

Package: kubelet
Version: 1.37.2-1.1

Package: kubectl
Version: 1.37.0-1.1

Package: kubectl
Version: 1.37.2-1.1

Package: cri-tools
Version: 1.37.9-1.1
"""
KIND = json.dumps({"tag_name": "v0.33.0", "body": "Images:\n- kindest/node:v1.37.0@sha256:aa\n"
                   "- kindest/node:v1.36.4@sha256:bb\n- kindest/node:v1.37.1@sha256:cc\n"})


def sources(stable="v1.37.2\n", apt=APT, kind=KIND):
    table = {up.STABLE.format(target="1.37"): stable, up.APT.format(target="1.37"): apt, up.KIND: kind}
    return lambda url: table[url]


class Repo:
    """A minimal repo: catalog, one spec, one target snapshot, the editor."""

    def __init__(self, tracked="1.34"):
        self.tmp = tempfile.TemporaryDirectory()
        r = self.root = Path(self.tmp.name)
        (r / "scripts").mkdir()
        (r / "scripts" / "upgrade_versions.py").write_text("# editor\n")
        (r / "catalog.yaml").write_text(yaml.safe_dump({"certs": {"cks": {"tracked_version": tracked}}}))
        (r / "syllabi" / "cks").mkdir(parents=True)
        (r / "syllabi" / "cks" / "v1.37.yaml").write_text(yaml.safe_dump(
            {"version": "1.37", "source": {"path": "CKS_Curriculum v1.37.pdf", "commit": "4de0c31" + "0" * 33}}))
        (r / "docs" / "upgrades").mkdir(parents=True)
        self.spec = r / "docs" / "upgrades" / "cks-1.37.yaml"
        self.spec.write_text(yaml.safe_dump({"certs": {"cks": {"target": "syllabi/cks/v1.37.yaml"}}}))


class Build(unittest.TestCase):
    def test_every_value_comes_from_the_repo_or_a_source(self):
        r = Repo()
        pins = up.build(r.spec, "2026-11-13", get=sources(), root=r.root)
        self.assertEqual((pins["tracked"], pins["target"], pins["shift"]), ("1.34", "1.37", 3))
        self.assertEqual(pins["patch"], "1.37.2")
        self.assertEqual(pins["kindest_node"], "v1.37.1")               # the newest node image of the target minor
        self.assertEqual(pins["curriculum_commit"], {"CKS": "4de0c31" + "0" * 33})
        self.assertEqual(pins["tool_sha256"], hashlib.sha256(b"# editor\n").hexdigest())
        self.assertEqual(pins["upgrade"], "cks-1.37")

    def test_a_stable_release_apt_does_not_have_yet_falls_back_to_the_newest_shared_patch(self):
        r = Repo()
        pins = up.build(r.spec, "2026-11-13", get=sources(stable="v1.37.3\n"), root=r.root)
        self.assertEqual(pins["patch"], "1.37.2")

    def test_a_patch_only_some_packages_have_is_not_picked(self):
        apt = APT + "\nPackage: kubeadm\nVersion: 1.37.3-1.1\n"
        self.assertEqual(up.pick_patch("v1.37.3", apt, "1.37")[0], "1.37.2")

    def test_it_refuses_instead_of_guessing(self):
        r = Repo()
        with self.assertRaises(SystemExit):                              # stable file of another minor
            up.build(r.spec, "d", get=sources(stable="v1.36.9\n"), root=r.root)
        with self.assertRaises(SystemExit):                              # no node image for the target
            up.build(r.spec, "d", get=sources(kind=json.dumps({"tag_name": "v0.1", "body": "kindest/node:v1.36.4"})),
                     root=r.root)
        done = Repo(tracked="1.37")
        with self.assertRaises(SystemExit):                              # already switched
            up.build(done.spec, "d", get=sources(), root=done.root)

    def test_the_file_is_what_upgrade_versions_reads(self):
        r = Repo()
        pins = up.build(r.spec, "2026-11-13", get=sources(), root=r.root)
        text = up.render(pins, "docs/upgrades/cks-1.37.yaml", "docs/upgrades/cks-1.37.pins.yaml")
        back = yaml.safe_load(text)
        for key in ("tracked", "target", "shift", "patch", "kindest_node", "tool", "tool_sha256", "curriculum_commit", "date"):
            self.assertEqual(back[key], pins[key], key)
        self.assertIsInstance(back["patch"], str)
        self.assertTrue(text.startswith("# The one place the cks-1.37 upgrade pins its versions."))


class Check(unittest.TestCase):
    def test_check_ignores_the_date_and_reports_a_moved_source(self):
        r = Repo()
        out = r.root / "pins.yaml"
        pins = up.build(r.spec, "2026-11-01", get=sources(), root=r.root)
        out.write_text(up.render(pins, "s", "o"))
        later = up.build(r.spec, "2026-11-13", get=sources(), root=r.root)
        self.assertEqual(up.comparable(yaml.safe_load(out.read_text())), up.comparable(later))
        moved = up.build(r.spec, "2026-11-13", get=sources(apt=APT.replace("1.37.2", "1.37.4")
                                                           , stable="v1.37.4\n"), root=r.root)
        self.assertNotEqual(up.comparable(yaml.safe_load(out.read_text())), up.comparable(moved))


class RepoPins(unittest.TestCase):
    def test_the_cks_pins_file_was_written_by_this_script(self):
        f = REPO / "docs" / "upgrades" / "cks-1.37.pins.yaml"
        self.assertTrue(f.read_text().startswith("# The one place the cks-1.37 upgrade pins its versions."))


if __name__ == "__main__":
    unittest.main()
