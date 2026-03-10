import json
import os
import re
from copy import deepcopy
from typing import Any, Dict, Set

import yaml


def _expand_env_vars(value):
    """文字列中の ${VAR} や $VAR を環境変数で展開する."""
    if not isinstance(value, str):
        return value
    return re.sub(
        r'\$\{(\w+)\}|\$(\w+)',
        lambda m: os.environ.get(m.group(1) or m.group(2), m.group(0)),
        value,
    )


def deep_merge(base_item, new_item):
    if isinstance(base_item, dict) and isinstance(new_item, dict):
        ret = deepcopy(base_item)
        for key in new_item:
            if key in ret:
                ret[key] = deep_merge(ret[key], new_item[key])
            else:
                ret[key] = new_item[key]
        return ret
    if isinstance(base_item, list) and isinstance(new_item, list):
        ret = deepcopy(base_item)
        ret.extend(new_item)
        return ret
    return new_item


class ConfigLoader:
    def __init__(self) -> None:
        self.loading: Set[str] = set()
        self.loaded: Dict[str, Any] = dict()

    def load_from(self, path) -> Dict:
        path = os.path.realpath(path)
        if path in self.loading:
            raise Exception("Circular import detected: {}".format(path))
        if path in self.loaded:
            return deepcopy(self.loaded[path])
        if not os.path.exists(path):
            raise Exception("File not found: {}".format(path))
        if path.endswith(".yaml") or path.endswith(".yml"):
            with open(path) as f:
                config = yaml.safe_load(f)
        elif path.endswith(".json"):
            with open(path) as f:
                config = json.load(f)
        else:
            raise Exception("Unknown file type: {}".format(path))
        self.loading.add(path)
        try:
            config = self.parse_imports(os.path.dirname(path), config)
        except Exception as e:
            self.loading.remove(path)
            raise e
        self.loading.remove(path)
        self.loaded[path] = config
        result = self.parse_default_and_overwrite(deepcopy(config))
        return self._expand_env_vars_recursive(result)

    def parse_imports(self, path, raw_config):
        raw_config = deepcopy(raw_config)
        if isinstance(raw_config, dict):
            ret = {}
            if "import" in raw_config:
                v = raw_config.pop("import")
                if isinstance(v, str):
                    config = self.load_from(os.path.join(path, v))
                    ret = deep_merge(ret, config)
                elif isinstance(v, list):
                    for vv in v:
                        assert isinstance(
                            vv, str
                        ), "Import list must be a list of strings, found {}".format(
                            type(vv)
                        )
                        config = self.load_from(os.path.join(path, vv))
                        ret = deep_merge(ret, config)
                else:
                    raise Exception("Unknown import value: {}".format(v))
            for k, v in raw_config.items():
                raw_config[k] = self.parse_imports(path, v)
            ret = deep_merge(ret, raw_config)
            return ret
        elif isinstance(raw_config, list):
            ret = []
            for v in raw_config:
                ret.append(self.parse_imports(path, v))
            return ret
        else:
            return raw_config

    def parse_default_and_overwrite(self, config):
        if isinstance(config, dict):
            if not config:
                return {}
            ret = {}
            overwriting = False
            defaulting = False
            if "overwrite" in config:
                overwrite = self.parse_default_and_overwrite(config.pop("overwrite"))
                overwriting = True
            if "default" in config:
                default = self.parse_default_and_overwrite(config.pop("default"))
                defaulting = True
            for k, v in config.items():
                parsed_v = self.parse_default_and_overwrite(v)
                if overwriting:
                    parsed_v = deep_merge(parsed_v, overwrite)
                if defaulting:
                    parsed_v = deep_merge(default, parsed_v)
                ret[k] = parsed_v
            return ret
        elif isinstance(config, list):
            ret = []
            for v in config:
                ret.append(self.parse_default_and_overwrite(v))
            return ret
        else:
            return config


    @staticmethod
    def _expand_env_vars_recursive(config):
        """config 内の全文字列値に対して環境変数を展開する."""
        if isinstance(config, dict):
            return {k: ConfigLoader._expand_env_vars_recursive(v) for k, v in config.items()}
        elif isinstance(config, list):
            return [ConfigLoader._expand_env_vars_recursive(v) for v in config]
        elif isinstance(config, str):
            return _expand_env_vars(config)
        return config


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=str, help="Config file to load")
    # output format: choice from json or yaml
    parser.add_argument(
        "--output", "-o", choices=["json", "yaml"], default="yaml", help="Output format"
    )
    args = parser.parse_args()
    config_ = ConfigLoader().load_from(args.config)
    if args.output == "json":
        print(json.dumps(config_, indent=2))
    elif args.output == "yaml":
        print(yaml.dump(config_))

# try:  python -m src.configs configs/assignments/test.yaml
