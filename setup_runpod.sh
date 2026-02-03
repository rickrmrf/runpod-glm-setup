#!/usr/bin/env bash
set -euo pipefail

echo "═══════════════════════════════════════════════════════════"
echo "  RunPod GLM/Qwen Setup Script"
echo "  Target: RTX Pro 6000 (96GB VRAM)"
echo "═══════════════════════════════════════════════════════════"

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# Phase 1: System Dependencies
# ============================================================================
echo "[1/10] Installing system dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  git curl wget ca-certificates \
  build-essential pkg-config software-properties-common \
  openssl libssl-dev \
  vim nano unzip zip htop tmux \
  net-tools iproute2 \
  ruby ripgrep jq

# ============================================================================
# Phase 2: Node.js 20 (for Claude Code)
# ============================================================================
echo "[2/10] Installing Node.js 20..."
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 20
nvm use 20
nvm alias default 20

# Persist in bashrc
grep -q 'NVM_DIR' /root/.bashrc || cat >> /root/.bashrc <<'EOF'

# NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF

# ============================================================================
# Phase 3: Python Virtual Environment
# ============================================================================
echo "[3/10] Creating Python virtual environment..."
mkdir -p /workspace/venvs
python3 -m venv /workspace/venvs/glm
source /workspace/venvs/glm/bin/activate

pip install --upgrade pip setuptools wheel

# ============================================================================
# Phase 4: Python Dependencies
# ============================================================================
echo "[4/10] Installing Python dependencies..."
pip install \
  torch \
  "transformers>=4.45" \
  accelerate \
  sentencepiece \
  tokenizers \
  vllm \
  openai \
  fastapi \
  uvicorn \
  pydantic \
  requests \
  httpx \
  rich \
  tqdm \
  python-dotenv \
  reportlab \
  aider-chat \
  ipython

# ============================================================================
# Phase 5: Ruby Bundler
# ============================================================================
echo "[5/10] Installing Ruby bundler..."
gem install bundler

# ============================================================================
# Phase 6: Claude Code
# ============================================================================
echo "[6/10] Installing Claude Code..."
source "$NVM_DIR/nvm.sh"
npm install -g @anthropic-ai/claude-code

# ============================================================================
# Phase 7: Claude → OpenAI Protocol Proxy
# ============================================================================
echo "[7/10] Setting up Claude→OpenAI proxy..."
cd /workspace
if [ ! -d "claude-code-proxy" ]; then
  git clone https://github.com/fuergaosi233/claude-code-proxy.git
fi
cd claude-code-proxy
pip install -r requirements.txt

cat > .env <<'ENV'
OPENAI_API_KEY=dummy
OPENAI_BASE_URL=http://127.0.0.1:8002/v1

# Map all Claude sizes to local model
BIG_MODEL=glm
MIDDLE_MODEL=glm
SMALL_MODEL=glm

HOST=0.0.0.0
PORT=8082
LOG_LEVEL=INFO
ENV

# ============================================================================
# Phase 8: Ruby Thinking Token Proxy
# ============================================================================
echo "[8/10] Creating Ruby thinking token proxy..."
cat > /workspace/strip_think_proxy.rb <<'RUBY'
#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "webrick"

UPSTREAM = URI(ENV.fetch("UPSTREAM", "http://127.0.0.1:8000"))
BIND     = ENV.fetch("BIND", "0.0.0.0")
PORT     = Integer(ENV.fetch("PORT", "8002"))

THINK_RE = /(?im)\s*<think>.*?<\/think>\s*/m
QUOTE_RE = /"([^"\n]{1,200}[.!?])"/

def normalize_content(content)
  case content
  when Array
    content.map { |c| c.is_a?(Hash) ? (c["text"] || c[:text] || c.to_s) : c.to_s }.join("\n")
  when String
    content
  else
    content.to_s
  end
end

def strip_reasoning(text)
  return text unless text.is_a?(String)
  t = text.dup

  # Drop everything up to and including </think> if present
  if (idx = t.rindex("</think>"))
    t = t[(idx + "</think>".length)..]
  end

  # Remove balanced <think>...</think> blocks
  t = t.gsub(THINK_RE, "").strip

  # If there's a quoted final sentence, use it
  if (m = t.match(QUOTE_RE))
    return m[1].strip
  end

  # Otherwise keep the last non-empty line
  lines = t.lines.map(&:strip).reject(&:empty?)
  lines.empty? ? t : lines.last
end

def sanitize_chat_completion!(obj)
  choices = obj["choices"]
  return obj unless choices.is_a?(Array)

  choices.each do |ch|
    msg = ch["message"]
    next unless msg.is_a?(Hash)

    content = msg["content"]
    text = normalize_content(content)
    msg["content"] = strip_reasoning(text)
  end

  obj
end

server = WEBrick::HTTPServer.new(
  BindAddress: BIND,
  Port: PORT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

server.mount_proc("/") do |req, res|
  upstream_uri = UPSTREAM + req.path
  upstream_uri.query = req.query_string if req.query_string && !req.query_string.empty?

  http = Net::HTTP.new(upstream_uri.host, upstream_uri.port)
  http.use_ssl = (upstream_uri.scheme == "https")
  http.read_timeout = 300
  http.open_timeout = 30

  klass = case req.request_method
          when "GET"    then Net::HTTP::Get
          when "POST"   then Net::HTTP::Post
          when "PUT"    then Net::HTTP::Put
          when "PATCH"  then Net::HTTP::Patch
          when "DELETE" then Net::HTTP::Delete
          else
            res.status = 405
            res.body = "Method Not Allowed\n"
            next
          end

  upstream_req = klass.new(upstream_uri)
  req.header.each do |k, v|
    next if k.downcase == "host"
    upstream_req[k] = v.is_a?(Array) ? v.join(", ") : v.to_s
  end
  upstream_req.body = req.body if req.body && !req.body.empty?

  upstream_res = http.request(upstream_req)

  res.status = upstream_res.code.to_i
  upstream_res.each_header do |k, v|
    next if k.downcase == "transfer-encoding"
    res[k] = v
  end

  body = upstream_res.body.to_s

  # Only rewrite JSON for chat completions
  if req.path.end_with?("/v1/chat/completions") && (res["content-type"] || "").include?("application/json")
    begin
      obj = JSON.parse(body)
      obj = sanitize_chat_completion!(obj)
      body = JSON.generate(obj)
      res["content-length"] = body.bytesize.to_s
    rescue JSON::ParserError
      # pass through raw body
    end
  end

  res.body = body
end

$stderr.puts "strip_think_proxy listening on #{BIND}:#{PORT} -> #{UPSTREAM}"
server.start
RUBY
chmod +x /workspace/strip_think_proxy.rb

# ============================================================================
# Phase 9: vLLM Launcher Scripts
# ============================================================================
echo "[9/10] Creating vLLM launcher scripts..."

# Main vLLM start script with model selection
cat > /workspace/start_vllm.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source /workspace/venvs/glm/bin/activate

# Model selection: glm or qwen
MODEL_TYPE="${1:-glm}"

case "$MODEL_TYPE" in
  glm)
    MODEL="cyankiwi/GLM-4.7-Flash-AWQ-4bit"
    SERVED_NAME="glm"
    MAX_LEN="${MAX_LEN:-32768}"
    ;;
  qwen)
    MODEL="Qwen/Qwen2.5-Coder-14B-Instruct-AWQ"
    SERVED_NAME="qwen"
    MAX_LEN="${MAX_LEN:-32768}"
    ;;
  *)
    echo "Usage: $0 [glm|qwen]"
    exit 1
    ;;
esac

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
GPU_UTIL="${GPU_UTIL:-0.90}"

LOG="/workspace/vllm.log"
PIDFILE="/workspace/vllm.pid"

echo "═══════════════════════════════════════════════════════════"
echo "  Starting vLLM Server"
echo "  Model: $MODEL"
echo "  Served as: $SERVED_NAME"
echo "  Context: $MAX_LEN tokens"
echo "  GPU Utilization: $GPU_UTIL"
echo "═══════════════════════════════════════════════════════════"

nohup python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --served-model-name "$SERVED_NAME" \
  --host "$HOST" \
  --port "$PORT" \
  --dtype auto \
  --max-model-len "$MAX_LEN" \
  --gpu-memory-utilization "$GPU_UTIL" \
  --enable-prefix-caching \
  --trust-remote-code \
  > "$LOG" 2>&1 &

echo $! > "$PIDFILE"

echo "Waiting for vLLM to start..."
for i in {1..120}; do
  if curl -fsS "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "✓ vLLM is up!"
    curl -s "http://localhost:${PORT}/v1/models" | jq -r '.data[].id'
    echo ""
    echo "Logs: tail -f $LOG"
    echo "Stop: /workspace/stop_vllm.sh"
    exit 0
  fi
  sleep 1
done

echo "✗ vLLM failed to start. Check logs: tail -f $LOG"
exit 1
EOF
chmod +x /workspace/start_vllm.sh

# Stop script
cat > /workspace/stop_vllm.sh <<'EOF'
#!/usr/bin/env bash
PIDFILE="/workspace/vllm.pid"
if [ -f "$PIDFILE" ]; then
  kill "$(cat $PIDFILE)" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "vLLM stopped"
else
  pkill -f "vllm.entrypoints.openai.api_server" || true
  echo "vLLM stopped (no pidfile)"
fi
EOF
chmod +x /workspace/stop_vllm.sh

# Start all services script
cat > /workspace/start_all.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODEL_TYPE="${1:-glm}"

echo "Starting full stack with $MODEL_TYPE model..."

# 1. Start vLLM
/workspace/start_vllm.sh "$MODEL_TYPE"

# 2. Start Ruby thinking proxy (background)
echo "Starting Ruby thinking proxy on :8002..."
cd /workspace
nohup ruby strip_think_proxy.rb > /workspace/ruby_proxy.log 2>&1 &
echo $! > /workspace/ruby_proxy.pid
sleep 2

# 3. Start Claude→OpenAI proxy (background)
echo "Starting Claude→OpenAI proxy on :8082..."
cd /workspace/claude-code-proxy
source /workspace/venvs/glm/bin/activate
nohup python start_proxy.py > /workspace/claude_proxy.log 2>&1 &
echo $! > /workspace/claude_proxy.pid
sleep 2

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  All services started!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  vLLM:              http://localhost:8000/v1"
echo "  Ruby Proxy:        http://localhost:8002/v1"
echo "  Claude Proxy:      http://localhost:8082"
echo ""
echo "  For Aider:"
echo "    export OPENAI_API_BASE=http://127.0.0.1:8000/v1"
echo "    export OPENAI_API_KEY=local"
echo "    aider --model openai/$MODEL_TYPE"
echo ""
echo "  For Claude Code:"
echo "    export ANTHROPIC_BASE_URL=http://127.0.0.1:8082"
echo "    export ANTHROPIC_AUTH_TOKEN=local"
echo "    claude --model $MODEL_TYPE"
echo ""
EOF
chmod +x /workspace/start_all.sh

# Stop all services
cat > /workspace/stop_all.sh <<'EOF'
#!/usr/bin/env bash
echo "Stopping all services..."

for pidfile in /workspace/*.pid; do
  if [ -f "$pidfile" ]; then
    kill "$(cat $pidfile)" 2>/dev/null || true
    rm -f "$pidfile"
  fi
done

pkill -f "vllm.entrypoints" || true
pkill -f "strip_think_proxy" || true
pkill -f "start_proxy.py" || true

echo "All services stopped"
EOF
chmod +x /workspace/stop_all.sh

# ============================================================================
# Phase 10: Configuration Files & Environment
# ============================================================================
echo "[10/10] Creating configuration files..."

# Aider configuration
cat > /root/.aider.conf.yml <<'YAML'
openai-api-base: http://127.0.0.1:8000/v1
openai-api-key: local-anything

# Default to GLM, change to qwen if needed
model: openai/glm

yes-always: true
auto-commits: true
dirty-commits: false
stream: false
pretty: true
auto-lint: false
auto-test: false
no-show-model-warnings: true
YAML

# Environment file
cat > /workspace/.env <<'ENV'
# Model selection
MODEL=cyankiwi/GLM-4.7-Flash-AWQ-4bit
# MODEL=Qwen/Qwen2.5-Coder-14B-Instruct-AWQ

# vLLM settings (96GB VRAM allows generous context)
MAX_LEN=32768
GPU_UTIL=0.90

# API endpoints
OPENAI_API_BASE=http://127.0.0.1:8000/v1
OPENAI_API_KEY=local-anything

# For Claude Code
ANTHROPIC_BASE_URL=http://127.0.0.1:8082
ANTHROPIC_AUTH_TOKEN=local-dev
ENV

# Bashrc additions
cat >> /root/.bashrc <<'EOF'

# GLM/Qwen environment
source /workspace/.env 2>/dev/null || true
source /workspace/venvs/glm/bin/activate 2>/dev/null || true

# Aliases
alias vllm-start='/workspace/start_vllm.sh'
alias vllm-stop='/workspace/stop_vllm.sh'
alias stack-start='/workspace/start_all.sh'
alias stack-stop='/workspace/stop_all.sh'
alias vllm-logs='tail -f /workspace/vllm.log'
alias gpu='nvidia-smi'
EOF

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Setup Complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Quick Start:"
echo "    source ~/.bashrc"
echo "    stack-start glm      # Start with GLM model"
echo "    stack-start qwen     # Start with Qwen model"
echo ""
echo "  Individual Services:"
echo "    vllm-start glm       # Just vLLM"
echo "    vllm-stop            # Stop vLLM"
echo ""
echo "  Health Check:"
echo "    curl -s http://localhost:8000/v1/models | jq"
echo ""
