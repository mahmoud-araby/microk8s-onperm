# -*- coding: utf-8 -*-
"""Filters for the "ConfigMap Ansible" feature (role: k8s_configmaps).

  cfg | find_secret_keys(patterns)   -> ["database.password", ...] keys that look like secrets
                                        and hold a literal value (placeholders like ${X} allowed)
  cfg | flatten_env(prefix="APP")    -> {"APP_DATABASE_POOL_MAX": "80", ...} (camelCase -> UPPER_SNAKE)
  obj | to_k8s_yaml                  -> YAML with multi-line strings as literal blocks (|)
  data | config_checksum             -> sha256 over the canonical JSON of the ConfigMap data
"""

from __future__ import absolute_import, division, print_function

__metaclass__ = type

import hashlib
import json
import re
from collections.abc import Mapping, Sequence

import yaml

from ansible.errors import AnsibleFilterError

_CAMEL_1 = re.compile(r"(.)([A-Z][a-z]+)")
_CAMEL_2 = re.compile(r"([a-z0-9])([A-Z])")
_NON_ALNUM = re.compile(r"[^A-Za-z0-9]+")
_PLACEHOLDER = re.compile(r"^\$\{[A-Za-z0-9_.:-]+\}$")


def _plain(obj):
    """Convert Ansible wrapper types (AnsibleUnsafeText, tagged str, ...) to plain Python."""
    if obj is None or isinstance(obj, bool):
        return obj
    if isinstance(obj, int):
        return int(obj)
    if isinstance(obj, float):
        return float(obj)
    if isinstance(obj, str):
        return str(obj)
    if isinstance(obj, Mapping):
        return {str(k): _plain(v) for k, v in obj.items()}
    if isinstance(obj, Sequence):
        return [_plain(v) for v in obj]
    return str(obj)


def _upper_snake(key):
    key = _CAMEL_1.sub(r"\1_\2", str(key))
    key = _CAMEL_2.sub(r"\1_\2", key)
    return _NON_ALNUM.sub("_", key).strip("_").upper()


def _scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        return ",".join(_scalar(v) for v in value)
    return str(value)


def flatten_env(obj, prefix="", sep="_"):
    """Flatten a nested mapping to UPPER_SNAKE environment variables."""
    out = {}
    obj = _plain(obj)

    def walk(node, path):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, path + [_upper_snake(key)])
        else:
            if not path:
                raise AnsibleFilterError("flatten_env expects a mapping")
            out[sep.join(path)] = _scalar(node)

    walk(obj, [_upper_snake(prefix)] if prefix else [])
    return dict(sorted(out.items()))


def find_secret_keys(obj, patterns=None):
    """Return dotted paths of keys that look like secrets and carry a literal value."""
    patterns = patterns or ["(password|passwd|pwd|secret|token|apikey|privatekey|credentials?|connectionstring)$"]
    compiled = [re.compile(p, re.IGNORECASE) for p in patterns]
    found = []

    def walk(node, path):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, path + [str(key)])
        elif isinstance(node, list):
            for idx, value in enumerate(node):
                walk(value, path + [str(idx)])
        else:
            if not path:
                return
            # normalise "api-key" / "api_key" / "apiKey" -> "apikey"
            leaf = path[-1].replace("-", "").replace("_", "").replace(".", "")
            if any(c.search(leaf) for c in compiled):
                if isinstance(node, str) and (node == "" or _PLACEHOLDER.match(node)):
                    return
                if node is None or isinstance(node, bool):
                    return
                found.append(".".join(path))

    walk(_plain(obj), [])
    return found


class _LiteralDumper(yaml.SafeDumper):
    """SafeDumper that keeps key order and renders multi-line strings as `|` blocks."""


def _str_representer(dumper, data):
    if "\n" in data:
        # trailing spaces break the literal style; strip them per line
        data = "\n".join(line.rstrip() for line in data.split("\n"))
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


_LiteralDumper.add_representer(str, _str_representer)


def to_k8s_yaml(obj):
    return yaml.dump(
        _plain(obj),
        Dumper=_LiteralDumper,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
        width=4096,
        explicit_start=True,
    )


def config_checksum(obj):
    canonical = json.dumps(_plain(obj), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class FilterModule(object):
    def filters(self):
        return {
            "flatten_env": flatten_env,
            "find_secret_keys": find_secret_keys,
            "to_k8s_yaml": to_k8s_yaml,
            "config_checksum": config_checksum,
        }
