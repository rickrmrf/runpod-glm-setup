# RunPod GLM/Qwen Setup

Automated setup script for deploying GLM-4.7-Flash and Qwen2.5-Coder on RunPod with vLLM, Aider, Claude Code, and glm_agent support.

## Target Environment

- **Base Image**: `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`
- **GPU**: RTX Pro 6000 (96GB VRAM)
- **RAM**: 188GB System RAM
- **Models**: GLM-4.7-Flash-AWQ + Qwen2.5-Coder-14B-Instruct-AWQ

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      DEVELOPMENT TOOLS                       │
├─────────────────┬─────────────────┬─────────────────────────┤
│     Aider       │   glm_agent     │     Claude Code         │
│  (CLI coding)   │ (planning agent)│   (chat interface)      │
└────────┬────────┴────────┬────────┴───────────┬─────────────┘
         │                 │                    │
         │ OpenAI API      │ OpenAI API         │ Anthropic API
         │                 │                    │
         │                 │         ┌──────────▼──────────┐
         │                 │         │ Claude→OpenAI Proxy │
         │                 │         │     (:8082)         │
         │                 │         └──────────┬──────────┘
         │                 │                    │
         │                 │         ┌──────────▼──────────┐
         │                 │         │  Ruby Think Proxy   │
         │                 │         │     (:8002)         │
         └─────────────────┴─────────┴──────────┬──────────┘
                                                │
                              ┌─────────────────▼─────────────────┐
                              │           vLLM Server             │
                              │            (:8000)                │
                              │  GLM-4.7-Flash / Qwen-Coder-14B   │
                              └─────────────────┬─────────────────┘
                                                │
                              ┌─────────────────▼─────────────────┐
                              │     RTX Pro 6000 (96GB VRAM)      │
                              └───────────────────────────────────┘
```

## Quick Start

### 1. Run Setup Script

```bash
# Upload to RunPod and run
chmod +x setup_runpod.sh
./setup_runpod.sh
```

### 2. Start Services

```bash
source ~/.bashrc

# Start with GLM (default)
stack-start glm

# Or start with Qwen (better for coding)
stack-start qwen
```

### 3. Use Development Tools

**Aider:**
```bash
cd /workspace/your_repo
aider --model openai/glm    # or openai/qwen
```

**Claude Code:**
```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8082
export ANTHROPIC_AUTH_TOKEN=local
claude --model glm
```

**glm_agent:**
```bash
cd /workspace/glm_agent
python run_planning_agent.py
```

## Commands

| Alias | Description |
|-------|-------------|
| `stack-start glm` | Start full stack with GLM model |
| `stack-start qwen` | Start full stack with Qwen model |
| `stack-stop` | Stop all services |
| `vllm-start glm` | Start only vLLM with GLM |
| `vllm-stop` | Stop vLLM |
| `vllm-logs` | Tail vLLM logs |
| `gpu` | Show GPU status |

## Services

| Service | Port | Description |
|---------|------|-------------|
| vLLM | 8000 | OpenAI-compatible LLM server |
| Ruby Proxy | 8002 | Strips `<think>` tokens from responses |
| Claude Proxy | 8082 | Translates Anthropic API to OpenAI API |

## Files Created

| File | Purpose |
|------|---------|
| `/workspace/start_vllm.sh` | Start vLLM with GLM or Qwen |
| `/workspace/stop_vllm.sh` | Stop vLLM server |
| `/workspace/start_all.sh` | Start full stack (vLLM + proxies) |
| `/workspace/stop_all.sh` | Stop all services |
| `/workspace/strip_think_proxy.rb` | Ruby proxy to strip thinking tokens |
| `/workspace/.env` | Environment variables |
| `/root/.aider.conf.yml` | Aider configuration |
| `/workspace/claude-code-proxy/` | Claude to OpenAI protocol bridge |

## Health Checks

```bash
# vLLM alive
curl -s http://localhost:8000/v1/models | jq

# Inference test
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"glm","messages":[{"role":"user","content":"Say hi"}],"max_tokens":50}' | jq

# GPU status
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv
```

## Hardware Optimization (96GB VRAM)

With 96GB VRAM, you can:
- Run **unquantized** GLM-4.7-Flash or Qwen-14B if preferred
- Use **32K+ context length** comfortably
- Run **multiple models** simultaneously if needed
- Enable **higher concurrency** (`--max-num-seqs 128`)

Recommended settings for 96GB:
```bash
--max-model-len 32768
--gpu-memory-utilization 0.90
--max-num-seqs 64
--max-num-batched-tokens 16384
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| vLLM OOM | Reduce `MAX_LEN` or `GPU_UTIL` in `/workspace/.env` |
| Transformers error | `pip install -U "transformers>=4.45"` |
| Thinking tokens in output | Use Ruby proxy (port 8002) |
| Claude Code fails | Check proxy is running on 8082 |
| Model not found | Run `curl localhost:8000/v1/models` to get exact name |

## Verification Checklist

- [ ] System packages installed
- [ ] Node.js 20 available
- [ ] Python venv at `/workspace/venvs/glm`
- [ ] vLLM starts and serves model
- [ ] Ruby proxy strips thinking tokens
- [ ] Claude proxy translates API calls
- [ ] Aider connects to vLLM
- [ ] Claude Code connects through proxies
- [ ] glm_agent runs planning workflow
