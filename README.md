# AgentBench (Small Version)

This is a **small version** of [AgentBench](https://github.com/THUDM/AgentBench) containing only the following 2 tasks:

- **Database (DB)** - DBBench
- **House-Holding (HH)** - [ALFWorld](https://github.com/alfworld/alfworld)

Inference is performed via vLLM using the OpenAI-compatible chat API (`configs/agents/openai-chat.yaml`).

## Quick Start

### Step 1. Prerequisites

Clone this repo and install the dependencies.

```bash
conda create -n agent-bench python=3.9
conda activate agent-bench
pip install -r requirements.txt
```

Ensure that [Docker](https://www.docker.com/) is properly installed.

```bash
docker ps
```

Pull required Docker images.

```bash
docker pull mysql
docker pull longinyu/agentbench-alfworld
```

### Step 2. Configure the Agent

Edit `configs/agents/openai-chat.yaml` to point to your vLLM endpoint and set the appropriate model name.

You can verify your agent configuration with:

```bash
python -m src.client.agent_test --config configs/agents/api_agents.yaml --agent gpt-3.5-turbo-0613
```

### Step 3. Start the task server

Ports 5000-5015 should be available.

```bash
python -m src.start_task -a
```

This will launch five task_workers each for `dbbench-std` and `alfworld-std` and connect them to the controller on port 5000. Wait until the terminal shows ".... 200 OK", then proceed.

### Step 4. Start the assigner

```bash
python -m src.assigner
```

## Resource Consumption

| Task Name | Start-up Speed | Memory Consumption |
| --------- | -------------- | ------------------ |
| db        | ~20s           | < 500M             |
| alfworld  | ~10s           | < 500M             |

## Citation

```
@article{liu2023agentbench,
  title   = {AgentBench: Evaluating LLMs as Agents},
  author  = {Xiao Liu and Hao Yu and Hanchen Zhang and Yifan Xu and Xuanyu Lei and Hanyu Lai and Yu Gu and Hangliang Ding and Kaiwen Men and Kejuan Yang and Shudan Zhang and Xiang Deng and Aohan Zeng and Zhengxiao Du and Chenhui Zhang and Sheng Shen and Tianjun Zhang and Yu Su and Huan Sun and Minlie Huang and Yuxiao Dong and Jie Tang},
  year    = {2023},
  journal = {arXiv preprint arXiv: 2308.03688}
}
```
