import datetime
import json
import os
import random
import threading
import time
from typing import Dict, List, Union
from typing import Tuple, Callable, Iterator
import contextlib
import sys
from tqdm.contrib import DummyTqdmFile

import yaml
from tqdm import tqdm

from src.client.task import TaskError
from .client import TaskClient, AgentClient
from .configs import ConfigLoader
from .typings import AssignmentConfig, SampleIndex, TaskOutput, TaskClientOutput
from .utils import ColorMessage
from .utils import Graph, MaxFlow
from time import sleep
import contextlib
import sys
from tqdm import tqdm
from tqdm.contrib import DummyTqdmFile

@contextlib.contextmanager
def std_out_err_redirect_tqdm():
    orig_out_err = sys.stdout, sys.stderr
    try:
        sys.stdout, sys.stderr = map(DummyTqdmFile, orig_out_err)
        yield orig_out_err[0]
    # Relay exceptions
    except Exception as exc:
        raise exc
    # Always restore sys.stdout/err if necessary
    finally:
        sys.stdout, sys.stderr = orig_out_err

class Assigner:
    def __init__(self, config: AssignmentConfig, auto_retry: bool = True) -> None:
        """
        Logic:
            1. Check if output folder exists (resume or create)
            2. Walk through all the folders in output folder, and remove the finished samples
            3. Create agents
        """
        self.auto_retry = auto_retry
        self.tqdm_ordered_by_agent = {}
        self.overall_tqdm = None
        self.config = config
        self.free_worker = config.concurrency.copy(deep=True)
        self.agents: Dict[str, AgentClient] = {}
        self.tasks: Dict[str, TaskClient] = {}
        self.task_indices: Dict[str, List[SampleIndex]] = {}
        self.task_worker_fail_count: Dict[str, int] = {}
        self.assignment_lock = threading.Lock()
        self.remaining_tasks: Dict[
            str, Dict[str, List[int]]
        ] = {}  # {agent: {task: [index]}}
        self.completions: Dict[
            str, Dict[str, List[TaskOutput]]
        ] = {}  # {agent: {task: [{index: int, result: JSONSerializable}]}}
        self.finished_count = 0
        self.started_count = 0
        self.running_count = 0

        # Step 1. Check if output folder exists (resume or create)

        if not os.path.exists(self.config.output):
            os.makedirs(self.config.output)
            # Write config file
            with open(os.path.join(self.config.output, "config.yaml"), "w") as f:
                f.write(yaml.dump(self.config.dict()))

        # Step 2. walk through all the folders in output folder({output}/agent/task/runs.jsonl),
        # and remove the finished samples

        for assignment in self.config.assignments:
            agent = assignment.agent
            task = assignment.task
            runs_file = os.path.join(self.get_output_dir(agent, task), "runs.jsonl")
            result_file = os.path.join(self.get_output_dir(agent, task), "overall.json")
            if os.path.exists(result_file):
                continue
            if agent not in self.remaining_tasks:
                self.remaining_tasks[agent] = {}
            if task not in self.remaining_tasks[agent]:
                self.remaining_tasks[agent][task] = []
            if task not in self.tasks:
                print(ColorMessage.green(f"creating {task} client..."))
                task_factory = self.config.definition.task[task]
                print(ColorMessage.cyan(
                    f"[DEBUG] Task '{task}' factory: module={task_factory.module}, "
                    f"params={json.dumps({k: str(v) for k, v in task_factory.parameters.items()}, ensure_ascii=False)}"
                ))
                self.tasks[task] = task_factory.create()
                print(ColorMessage.cyan(f"[DEBUG] Task '{task}' client created: {self.tasks[task]}"))
                try:
                    self.task_indices[task] = self.tasks[task].get_indices()
                    print(ColorMessage.cyan(
                        f"[DEBUG] Task '{task}' get_indices() → {len(self.task_indices[task])} samples"
                    ))
                except Exception as e:
                    print(ColorMessage.red(
                        f"[DEBUG] Task '{task}' get_indices() FAILED: {e}"
                    ))
                    raise
            self.remaining_tasks[agent][task] = self.task_indices[task].copy()
            if not os.path.exists(runs_file):
                continue
            with open(runs_file, "r") as f:
                for line in f:
                    try:
                        run = json.loads(line)
                        run.pop("time")
                        index = run.pop("index")
                        assert index is not None
                        run = TaskClientOutput.parse_obj(run)
                        assert isinstance(run.output, TaskOutput)
                    except:
                        continue
                    if index in self.remaining_tasks[agent][task]:
                        self.remaining_tasks[agent][task].remove(index)
                        self.record_completion(agent, task, index, run.output)
                    else:
                        print(
                            ColorMessage.yellow(
                                f"Warning: {agent}/{task}#{index} is finished, but not in the index list."
                            )
                        )

        count = sum(
            [
                len(self.remaining_tasks[agent][task])
                for agent in self.remaining_tasks
                for task in self.remaining_tasks[agent]
            ]
        )
        print(
            ColorMessage.cyan(f"Message: {count} samples remaining.")
        )

        for agent in self.remaining_tasks:
            agent_ = json.dumps(agent)
            tasks_ = len(self.remaining_tasks[agent])
            samples_ = sum(
                [
                    len(self.remaining_tasks[agent][task])
                    for task in self.remaining_tasks[agent]
                ]
            )
            if samples_ == 0:
                continue
            print(
                ColorMessage.cyan(
                    f"Agent {agent_} needs to run {tasks_} tasks with total {samples_} samples:"
                )
            )
            for task in self.remaining_tasks[agent]:
                print(
                    ColorMessage.cyan(
                        f"    Task {json.dumps(task)}: {len(self.remaining_tasks[agent][task])}"
                    )
                )

        # Create agents

        for agent in self.remaining_tasks:
            agent_factory = self.config.definition.agent[agent]
            print(ColorMessage.cyan(
                f"[DEBUG] Agent '{agent}' factory: module={agent_factory.module}, "
                f"params={json.dumps({k: str(v) for k, v in agent_factory.parameters.items()}, ensure_ascii=False)}"
            ))
            self.agents[agent] = agent_factory.create()
            print(ColorMessage.cyan(f"[DEBUG] Agent '{agent}' created: {self.agents[agent]}"))

    def get_output_dir(self, agent: str, task: str) -> str:
        return os.path.join(self.config.output, agent, task)

    def worker_generator(
        self, interval=10
    ) -> Iterator[Tuple[str, str, SampleIndex]]:

        node_list = ["SRC", "DST"]
        agent_node_index = {}
        task_node_index = {}
        for agent in self.agents:
            node_list.append(agent)
            agent_node_index[agent] = len(node_list) - 1
        for task in self.tasks:
            node_list.append(task)
            task_node_index[task] = len(node_list) - 1

        while True:

            # Step 0. Get real time task free worker

            with self.assignment_lock:
                for task in self.tasks:
                    conc = self.tasks[task].get_concurrency()
                    self.free_worker.task[task] = conc
                    print(ColorMessage.cyan(
                        f"[DEBUG] task '{task}' get_concurrency()={conc}"
                    ))
                for agent in self.agents:
                    print(ColorMessage.cyan(
                        f"[DEBUG] agent '{agent}' free_worker={self.free_worker.agent.get(agent, '?')}"
                    ))
                print("Running Count: {}".format(self.running_count))

            # Step 1. init edges: SRC -> agent -> task -> DST

            with self.assignment_lock:
                edges = {}
                for agent in self.agents:
                    edges[(0, agent_node_index[agent])] = self.free_worker.agent[agent]
                for task in self.tasks:
                    edges[(task_node_index[task], 1)] = self.free_worker.task[task]
                tot_remaining_samples = 0
                for agent in self.remaining_tasks:
                    for task in self.remaining_tasks[agent]:
                        tot_remaining_samples += len(self.remaining_tasks[agent][task])
                        edges[(agent_node_index[agent], task_node_index[task])] = len(
                            self.remaining_tasks[agent][task]
                        )
            print(ColorMessage.cyan(
                f"[DEBUG] remaining_samples={tot_remaining_samples}, edges={edges}"
            ))
            if tot_remaining_samples == 0:
                if self.running_count == 0:
                    break
                else:
                    time.sleep(interval / 2 + random.random() * interval)
                    continue

            # Step 2. Create graph and calculate max flow

            graph = Graph(node_count=len(node_list), edges=edges)
            max_flow = MaxFlow(graph, src=0, dst=1)

            print(ColorMessage.cyan(
                f"[DEBUG] max_flow={max_flow.max_flow}"
            ))
            if max_flow.max_flow == 0:
                print(ColorMessage.yellow(
                    "[DEBUG] max_flow=0 → ワーカー不足で割り当て不可。"
                    "タスクサーバーのワーカーが ALIVE か確認してください。"
                    f" agent_cap={dict((a, self.free_worker.agent[a]) for a in self.agents)},"
                    f" task_cap={dict((t, self.free_worker.task[t]) for t in self.tasks)}"
                ))
                time.sleep(interval / 2 + random.random() * interval)
                continue

            # Step 3. yield all (agent, task, index) tuples

            for (src, dst), e in max_flow.edges_dict.items():
                if (
                    src not in agent_node_index.values()
                    or dst not in task_node_index.values()
                ):
                    continue
                if e.flow == 0:
                    continue
                agent = node_list[src]
                task = node_list[dst]
                for _ in range(e.flow):
                    with self.assignment_lock:
                        index = self.remaining_tasks[agent][task].pop()
                        self.free_worker.agent[agent] -= 1
                        self.free_worker.task[task] -= 1
                    print(ColorMessage.green(f"Assigned {agent}/{task}#{index}"))
                    yield agent, task, index

            # Step 4. sleep for a while
            time.sleep(interval / 2 + random.random() * interval)

    def start(self, tqdm_out=None):
        self.started_count = sum(
            [
                len(self.remaining_tasks[agent][task])
                for agent in self.remaining_tasks
                for task in self.remaining_tasks[agent]
            ]
        )
        generator = self.worker_generator()
        self.overall_tqdm = tqdm(
            total=self.started_count,
            desc="Total",
            position=0,
            file=tqdm_out,
        )
        for idx, agent in enumerate(self.remaining_tasks.keys()):
            self.tqdm_ordered_by_agent[agent] = tqdm(
                total=sum(
                    [
                        len(self.remaining_tasks[agent][task])
                        for task in self.remaining_tasks[agent]
                    ]
                ),
                desc=agent,
                position=idx + 1,
                file=tqdm_out,
            )
        while True:
            try:
                agent, task, index = next(generator)
            except StopIteration:
                break
            self.start_worker(agent, task, index, self.finish_callback)

        self.overall_tqdm.close()
        for agent in self.tqdm_ordered_by_agent:
            self.tqdm_ordered_by_agent[agent].close()

        final_message = (
            "\n\n============================================\n"
            + ColorMessage.cyan(f"Message: {self.started_count} sample(s) started. ")
            + "\n"
            + ColorMessage.green(
                f"   >> {self.finished_count} sample(s) finished successfully."
            )
            + "\n"
        )
        if self.started_count != self.finished_count:
            final_message += (
                ColorMessage.red(
                    f"   >> {self.started_count - self.finished_count} sample(s) failed."
                )
                + "\n"
            )
        final_message += (
            ColorMessage.cyan(
                f"   >> results are saved to {self.config.output}"
            )
            + "\n"
        )
        final_message += "============================================\n\n"
        print(final_message)

    def record_completion(
        self, agent: str, task: str, index: SampleIndex, result: TaskOutput
    ):
        def calculate_overall_worker():
            nonlocal agent, task, index, result
            task_client = self.tasks[task]
            overall = task_client.calculate_overall(self.completions[agent][task])
            with open(
                os.path.join(self.get_output_dir(agent, task), "overall.json"), "w"
            ) as f:
                f.write(json.dumps(overall, indent=4, ensure_ascii=False))

        overall_calculation = False
        with self.assignment_lock:
            if agent not in self.completions:
                self.completions[agent] = {}
            if task not in self.completions[agent]:
                self.completions[agent][task] = []
            result.index = index
            self.completions[agent][task].append(result)
            if len(self.completions[agent][task]) == len(self.task_indices[task]):
                overall_calculation = True
        if overall_calculation:
            output_dir = self.get_output_dir(agent, task)
            if os.path.exists(os.path.join(output_dir, "overall.json")):
                return
            threading.Thread(target=calculate_overall_worker).start()

    def finish_callback(
        self, agent: str, task: str, index: SampleIndex, result: TaskClientOutput
    ):
        if result.error == TaskError.NOT_AVAILABLE.value:
            print(
                ColorMessage.yellow(
                    f"Warning: {task} is not available, retrying."
                )
            )
            with self.assignment_lock:
                self.remaining_tasks[agent][task].insert(0, index)
                self.free_worker.agent[agent] += 1
                self.free_worker.task[task] += 1
                self.running_count -= 1
            return

        if result.error is not None:
            print(ColorMessage.yellow(f"Warning: {agent}/{task}#{index} "
                                      f"failed with error {result.error} {result.info} {result.output}"))
            if self.auto_retry:
                with self.assignment_lock:
                    self.remaining_tasks[agent][task].insert(0, index)

        output_folder = self.get_output_dir(agent, task)
        os.makedirs(output_folder, exist_ok=True)
        timestamp: int = int(time.time() * 1000)
        time_str = datetime.datetime.fromtimestamp(timestamp / 1000).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        write_to_file = (
            json.dumps(
                {
                    "index": index,
                    **result.dict(),
                    "time": {"timestamp": timestamp, "str": time_str},
                }
            )
            + "\n"
        )
        if not result.error:
            target_file = os.path.join(output_folder, "runs.jsonl")
            with self.assignment_lock:
                self.finished_count += 1
            self.record_completion(agent, task, index, result.output)
            self.overall_tqdm.update(1)
            self.tqdm_ordered_by_agent[agent].update(1)
        else:
            target_file = os.path.join(output_folder, "error.jsonl")
        with open(target_file, "a+", encoding="utf-8") as f:
            f.write(write_to_file)

        with self.assignment_lock:
            self.free_worker.agent[agent] += 1
            self.free_worker.task[task] += 1
            self.running_count -= 1

    def start_worker(
        self,
        agent: str,
        task: str,
        index: SampleIndex,
        finish_callback: Union[
            Callable[[str, str, SampleIndex, TaskClientOutput], None], None
        ] = None,
    ):
        def worker_thread():
            nonlocal agent, task, index, finish_callback
            print(ColorMessage.cyan(
                f"[DEBUG] worker_thread 開始: {agent}/{task}#{index}"
            ))
            result = self.tasks[task].run_sample(index, self.agents[agent])
            print(ColorMessage.cyan(
                f"[DEBUG] worker_thread 完了: {agent}/{task}#{index} "
                f"error={result.error}, output_type={type(result.output).__name__}"
            ))

            if finish_callback:
                finish_callback(agent, task, index, result)

        with self.assignment_lock:
            self.running_count += 1
        threading.Thread(target=worker_thread).start()


def _auto_detect_vllm_model(vllm_url: str = "http://localhost:8000") -> str:
    """vLLM の /v1/models からモデル名を自動取得する"""
    import urllib.request
    try:
        req = urllib.request.Request(f"{vllm_url}/v1/models", method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            model_id = data["data"][0]["id"]
            print(ColorMessage.green(f"Auto-detected VLLM_MODEL: {model_id}"))
            return model_id
    except Exception as e:
        print(ColorMessage.yellow(f"Warning: vLLM モデル自動検出に失敗: {e}"))
        return ""


def _load_env_file(env_path: str = ".env"):
    """.env ファイルから環境変数を読み込む（未設定の変数のみ）"""
    if not os.path.exists(env_path):
        return
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if key and key not in os.environ:
                os.environ[key] = val


if __name__ == "__main__":
    import argparse
    import urllib.request

    def _debug(msg):
        print(ColorMessage.cyan(f"[DEBUG] {msg}"))

    def _check_port(host, port, label):
        """指定ポートの疎通確認"""
        import socket
        try:
            with socket.create_connection((host, port), timeout=3):
                _debug(f"{label} (port {port}): OK - 接続可能")
                return True
        except (ConnectionRefusedError, OSError) as e:
            print(ColorMessage.red(f"[DEBUG] {label} (port {port}): NG - {e}"))
            return False

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config", "-c", type=str, default="configs/assignments/default.yaml"
    )
    parser.add_argument(
        "--auto-retry", "-r", action="store_true", dest="retry"
    )
    args = parser.parse_args()

    print("=" * 60)
    _debug("=== 評価起動デバッグ開始 ===")
    print("=" * 60)

    # ── 0. 前提条件チェック ──

    _debug("[Phase 0] 前提条件チェック")

    # vLLM サーバー (port 8000) の確認
    vllm_ok = _check_port("localhost", 8000, "vLLM サーバー")
    if vllm_ok:
        try:
            req = urllib.request.Request("http://localhost:8000/v1/models", method="GET")
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                models = [m["id"] for m in data.get("data", [])]
                _debug(f"vLLM ロード済みモデル: {models}")
        except Exception as e:
            print(ColorMessage.red(f"[DEBUG] vLLM /v1/models 応答取得失敗: {e}"))

    # タスクサーバー (port 5000) の確認
    task_ok = _check_port("localhost", 5000, "タスクサーバー")
    if task_ok:
        try:
            req = urllib.request.Request("http://localhost:5000/api/list_workers", method="GET")
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                _debug(f"タスクサーバー ワーカー一覧: {list(data.keys())}")
                for task_name, info in data.items():
                    workers = info.get("workers", {})
                    alive = sum(1 for w in workers.values() if w.get("status") == "alive")
                    _debug(f"  {task_name}: {alive}/{len(workers)} workers alive")
        except Exception as e:
            print(ColorMessage.yellow(f"[DEBUG] タスクサーバー ワーカー取得失敗: {e}"))

    if not vllm_ok:
        print(ColorMessage.red(
            "\n*** FATAL: vLLM サーバー (port 8000) に接続できません ***\n"
            "  → eval/step1_start_vllm.sh でモデルを起動してください\n"
            "  → または docker compose up -d で起動してください\n"
        ))
        sys.exit(1)

    if not task_ok:
        print(ColorMessage.red(
            "\n*** FATAL: タスクサーバー (port 5000) に接続できません ***\n"
            "  → eval/run-task-server.sh をバックグラウンドで起動してください:\n"
            "     bash eval/run-task-server.sh &\n"
            "  → または eval/step2_evaluate.sh 経由で実行してください\n"
        ))
        sys.exit(1)

    # ── 1. 環境変数の解決 ──

    _debug("[Phase 1] 環境変数の解決")

    # .env を読み込み（未設定の環境変数のみ）
    _load_env_file()
    _debug(f".env 読み込み後 VLLM_MODEL={os.environ.get('VLLM_MODEL', '(未設定)')}")

    # VLLM_MODEL が未設定なら vLLM サーバーから自動取得
    if not os.environ.get("VLLM_MODEL"):
        _debug("VLLM_MODEL 未設定 → vLLM サーバーから自動取得...")
        detected = _auto_detect_vllm_model()
        if detected:
            os.environ["VLLM_MODEL"] = detected
            _debug(f"自動取得成功: VLLM_MODEL={detected}")
        else:
            print(ColorMessage.red(
                "ERROR: VLLM_MODEL が未設定で、vLLM サーバーからも取得できませんでした。\n"
                "  export VLLM_MODEL=<model_name> を実行するか、.env に設定してください。"
            ))
            sys.exit(1)
    else:
        _debug(f"VLLM_MODEL 既設定: {os.environ['VLLM_MODEL']}")

    # ── 2. コンフィグ読み込み ──

    _debug("[Phase 2] コンフィグ読み込み")
    _debug(f"config file: {args.config}")

    loader = ConfigLoader()
    config_ = loader.load_from(args.config)

    # agent 定義のデバッグ出力
    agents_def = config_.get("definition", {}).get("agent", {})
    for aname, acfg in agents_def.items():
        module = acfg.get("module", "(none)")
        body = acfg.get("parameters", {}).get("body", {})
        model_val = body.get("model", "(none)")
        _debug(f"Agent '{aname}': module={module}, body.model={model_val}")

    # api_agents.yaml の model: "${VLLM_MODEL}" を実際のモデル名に置換
    vllm_model = os.environ.get("VLLM_MODEL", "")
    replaced_count = 0
    if vllm_model:
        for aname, agent_cfg in agents_def.items():
            body = agent_cfg.get("parameters", {}).get("body", {})
            if isinstance(body.get("model"), str) and "${VLLM_MODEL}" in body["model"]:
                body["model"] = vllm_model
                replaced_count += 1
                _debug(f"Agent '{aname}': model を '{vllm_model}' に置換")

    if replaced_count == 0:
        _debug("WARNING: ${{VLLM_MODEL}} を含む agent が見つかりませんでした")
        # sed 済みの場合はそのまま使われる
        for aname, acfg in agents_def.items():
            body = acfg.get("parameters", {}).get("body", {})
            model_val = body.get("model", "(none)")
            _debug(f"  → Agent '{aname}' は model='{model_val}' のまま使用")

    # task 定義のデバッグ出力
    tasks_def = config_.get("definition", {}).get("task", {})
    for tname, tcfg in tasks_def.items():
        module = tcfg.get("module", "(none)")
        addr = tcfg.get("parameters", {}).get("controller_address", "(default)")
        _debug(f"Task '{tname}': module={module}, controller={addr}")

    # assignments のデバッグ出力
    assignments = config_.get("assignments", [])
    _debug(f"Assignments: {len(assignments)} 件")
    for a in assignments:
        _debug(f"  agent={a.get('agent')} → task={a.get('task')}")

    # ── 3. 評価開始 ──

    _debug("[Phase 3] AssignmentConfig パース開始")

    value = AssignmentConfig.parse_obj(config_)
    value = AssignmentConfig.post_validate(value)

    _debug("[Phase 4] Assigner 初期化・評価開始")

    v = value.dict()
    with std_out_err_redirect_tqdm() as orig_stdout:
        Assigner(value, args.retry).start(tqdm_out=orig_stdout)
