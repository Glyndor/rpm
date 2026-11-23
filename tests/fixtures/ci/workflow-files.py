# The one place that lists and reads the workflows and actions of a tree, for the suites
# that judge them. It is read into a suite with exec, never run, and it is not named
# *.test.sh because it is not a suite.
#
# What it lists is everything GitHub can run: a workflow with either suffix at any depth
# under .github/workflows, and an action.yml or action.yaml anywhere in the tree. A
# validator that listed less would compare less than GitHub executes. What it reads, it
# reads with a loader that refuses a key written twice in one mapping: the safe loader
# keeps the last and drops the first without a word, and a rule that read the first one
# would judge a file that is not the one GitHub runs.
import os

import yaml


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping with a repeated key."""


def _mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, f"the key {key!r} is written twice in one mapping", key_node.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def enumerate_files(root):
    """Every workflow and action file under root, as paths relative to it, sorted."""
    found = []
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".git"]
        rel = os.path.relpath(folder, root).replace(os.sep, "/")
        for name in names:
            path = name if rel == "." else f"{rel}/{name}"
            if name in ("action.yml", "action.yaml"):
                found.append(path)
            elif path.startswith(".github/workflows/") and name.endswith((".yml", ".yaml")):
                found.append(path)
    return sorted(found)


def load(root, path):
    """The parsed file, or an exception that names why it could not be read."""
    with open(os.path.join(root, path)) as fh:
        return yaml.load(fh, Loader=StrictLoader) or {}


def triggers(spec):
    """The events of a workflow, whichever way `on` was written (PyYAML reads it as True)."""
    on = spec.get("on", spec.get(True))
    if isinstance(on, dict):
        return set(on)
    if isinstance(on, str):
        return {on}
    return set(on or [])
