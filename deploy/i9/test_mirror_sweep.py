#!/usr/bin/env python3
"""Checks for the properties the recovery ordering invariant depends on.

Run: python3 deploy/i9/test_mirror_sweep.py
Needs git. Creates everything under a temporary directory.
"""
from __future__ import annotations

import importlib.util
import subprocess
import tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The sweep is an extensionless executable, so the loader must be named.
_loader = SourceFileLoader("sweep_module", str(HERE / "gitclub-mirror-sweep"))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
assert _spec is not None
sweep_module = importlib.util.module_from_spec(_spec)
_loader.exec_module(sweep_module)


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


def make_upstream(root: Path, name: str) -> Path:
    """A bare repository with one commit on main and one on doomed."""
    work = root / ("work-" + name)
    work.mkdir(parents=True)
    run("git", "init", "-q", "-b", "main", str(work))
    run("git", "-c", "user.email=t@e.test", "-c", "user.name=T", "commit",
        "-q", "--allow-empty", "-m", "first", cwd=work)
    run("git", "branch", "doomed", cwd=work)
    bare = root / (name + ".git")
    run("git", "clone", "-q", "--bare", str(work), str(bare))
    return bare


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="sweep-check-") as temporary:
        root = Path(temporary)
        upstream = {1: make_upstream(root, "alpha"), 2: make_upstream(root, "beta")}
        mirrors = root / "mirrors"

        listing = [{"id": i, "full_name": f"owner/{n}"}
                   for i, n in ((1, "alpha"), (2, "beta"))]
        served = [1_000_000.0]
        visible = [listing]

        def working_url(base, full_name):
            name = full_name.split("/")[-1]
            return "file://" + str(upstream[1 if name == "alpha" else 2])

        sweep_module.clone_url = working_url
        sweep_module.repositories = lambda base, token, timeout=60: (visible[0], served[0])

        def do(margin=60.0, allow_shrink=False):
            return sweep_module.sweep("http://unused", "token", mirrors, margin, allow_shrink)

        first = do()
        assert first["repository_count"] == 2, first
        # The target is the server clock less the margin, not the local clock.
        assert first["recovery_target_unix"] == 1_000_000.0 - 60.0, first
        assert (mirrors / "1.git" / "HEAD").is_file(), "mirror was not created"
        print("PASSED target derives from the server clock, mirrors created")

        # A ref deleted upstream must survive on the mirror: the database may
        # still reference objects behind it.
        run("git", "branch", "-D", "doomed", cwd=upstream[1])
        served[0] = 2_000_000.0
        second = do()
        refs = subprocess.run(["git", "--git-dir", str(mirrors / "1.git"),
                               "for-each-ref", "--format=%(refname)"],
                              capture_output=True, text=True, check=True).stdout
        assert "refs/heads/doomed" in refs, f"mirror pruned a deleted ref: {refs!r}"
        assert second["recovery_target_unix"] == 2_000_000.0 - 60.0, second
        print("PASSED upstream ref deletion does not prune the mirror")

        # A failing repository must hold the recovery target where it was.
        held = second["recovery_target_unix"]
        broken = dict(listing[1])
        broken["full_name"] = "owner/missing"
        visible[0] = [listing[0], broken]
        sweep_module.clone_url = lambda base, full_name: "file://" + str(root / "absent.git")
        served[0] = 3_000_000.0
        try:
            do()
        except sweep_module.SweepError as error:
            assert "recovery target held" in str(error), error
        else:
            raise AssertionError("a failed repository advanced the recovery target")
        state = sweep_module.read_state(mirrors / sweep_module.STATE_NAME)
        assert state["recovery_target_unix"] == held, state
        print("PASSED a failed repository holds the recovery target")

        # A shrinking listing must not advance the target either, even when
        # every repository still listed mirrors successfully.
        sweep_module.clone_url = working_url
        visible[0] = [listing[0]]
        served[0] = 4_000_000.0
        try:
            do()
        except sweep_module.SweepError as error:
            assert "refusing to advance" in str(error), error
        else:
            raise AssertionError("a shrinking repository count advanced the recovery target")
        assert sweep_module.read_state(mirrors / sweep_module.STATE_NAME)[
            "recovery_target_unix"] == held
        print("PASSED a shrinking repository count is refused")

        # With the drop acknowledged the sweep proceeds and the target moves.
        accepted = do(allow_shrink=True)
        assert accepted["recovery_target_unix"] == 4_000_000.0 - 60.0, accepted
        # The repository that left the listing keeps its mirror.
        assert (mirrors / "2.git" / "HEAD").is_file(), "an orphaned mirror was deleted"
        assert "2" in accepted["orphaned"], accepted["orphaned"]
        print("PASSED --allow-shrink advances the target and keeps orphaned mirrors")

    print("all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
