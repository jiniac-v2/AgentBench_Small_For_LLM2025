#!/bin/bash
set -e

# Substitute environment variables in agent config
envsubst < configs/agents/api_agents.yaml > configs/agents/api_agents.yaml.tmp
mv configs/agents/api_agents.yaml.tmp configs/agents/api_agents.yaml

exec python -m "$@"
