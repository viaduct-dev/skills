# Contributing to Viaduct Skills

## Prerequisites

- Node.js 18+
- Java 17+
- AI CLI (one of):
  - [Claude CLI](https://github.com/anthropics/claude-code) (`npm install -g @anthropic-ai/claude-code`) - default backend
  - [Crush](https://github.com/charmbracelet/crush) (`brew install charmbracelet/tap/crush`) - lightweight alternative
- jq (`brew install jq` on macOS)

## Authentication

The evaluation harness requires Claude API access. Configure one of:

### Option 1: Anthropic API Key (Recommended)

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Option 2: Airbnb Internal

If you have access to Airbnb's internal gateway, the script will automatically use `iap-auth` when `ANTHROPIC_API_KEY` is not set.

## Running Evaluations

The `test/` directory contains an evaluation harness to test skill effectiveness.

```bash
cd test
./run-evaluations.sh              # Run all evaluations (parallel, Claude CLI)
./run-evaluations.sh --crush      # Run with Crush backend (lower memory)
./run-evaluations.sh eval-01      # Run specific evaluation
./run-evaluations.sh --no-skill   # Run without skills (baseline)
./run-evaluations.sh --parallel=6 # Run 6 evaluations concurrently
./run-evaluations.sh --sequential # Run one at a time (for debugging)
```

### Options

| Option | Description |
|--------|-------------|
| `--skill` | Run with skill documentation (default) |
| `--no-skill` | Run without skills for baseline comparison |
| `--parallel=N` | Run N evaluations concurrently (default: 4 for Claude, 10 for Crush) |
| `--sequential` | Run evaluations one at a time |
| `--backend=X` | Use `claude` (default) or `crush` as the AI backend |
| `--crush` | Shorthand for `--backend=crush` |
| `--claude` | Shorthand for `--backend=claude` |
| `<eval-id>` | Filter to run specific evaluation(s) |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | - | Anthropic API key for Claude access |
| `MAX_RETRIES` | 3 | Max build/fix retry attempts |
| `MAX_PARALLEL` | 4/10 | Max concurrent evaluations (4 for Claude, 10 for Crush) |
| `BACKEND` | claude | AI backend to use (`claude` or `crush`) |

### AI Backends

The harness supports two AI backends:

| Backend | Memory/Process | Default Parallelism | Install |
|---------|---------------|---------------------|---------|
| Claude CLI | ~800 MB | 4 | `npm install -g @anthropic-ai/claude-code` |
| Crush | ~165 MB | 10 | `brew install charmbracelet/tap/crush` |

**Crush** is a lightweight Go-based AI coding assistant that uses ~80% less memory than Claude CLI, enabling higher parallelism on the same hardware.

### Performance & Resource Usage

| Backend | Parallelism | Memory | Wall Time (10 evals) |
|---------|-------------|--------|----------------------|
| Claude CLI | 1 (sequential) | ~800 MB | ~28 min |
| Claude CLI | 4 | ~3.2 GB | ~8 min |
| Claude CLI | 6 | ~4.8 GB | ~6 min |
| Crush | 10 | ~1.6 GB | ~4.5 min |

The harness pre-warms the Gradle daemon and uses unique workspaces per evaluation to enable safe parallel execution. Different backends and modes can run simultaneously without conflicts.

### Output

Evaluation outputs are saved to `test/.eval-outputs/`:

| File | Description |
|------|-------------|
| `<eval-id>-agent.txt` | AI agent's responses |
| `<eval-id>-build.txt` | Gradle build output |
| `<eval-id>-errors.txt` | Error summary |
| `<eval-id>-workspace/` | Full workspace (preserved on failure or retry) |

Files include backend suffix (e.g., `-crush`) when using non-default backend.

## Adding Evaluations

Evaluations are defined in `test/evaluations.json`:

```json
{
  "id": "eval-XX",
  "name": "Description of what's being tested",
  "schema": "type Foo { ... }",
  "query": "Implement a resolver for...",
  "verify_patterns": ["pattern1", "pattern2"],
  "negative_patterns": ["pattern-that-should-not-appear"]
}
```

- **schema**: GraphQL types appended to the base schema
- **query**: The prompt given to Claude
- **verify_patterns**: Regex patterns that MUST appear in the generated code
- **negative_patterns**: Regex patterns that must NOT appear (catches workarounds)

## Project Structure

```
├── bin/install.js       # npx installer (copies from skills/, strips frontmatter)
├── skills/              # Source of truth for all documentation
│   ├── viaduct-mutations/SKILL.md
│   ├── viaduct-query-resolver/SKILL.md
│   ├── viaduct-node-type/SKILL.md
│   ├── viaduct-field-resolver/SKILL.md
│   ├── viaduct-batch/SKILL.md
│   ├── viaduct-relationships/SKILL.md
│   └── viaduct-scopes/SKILL.md
└── test/                # Evaluation harness
    ├── evaluations.json # Evaluation definitions
    ├── run-evaluations.sh
    └── base-template/   # Template Viaduct project for evals
```

## Improving Documentation

When an evaluation fails:

1. Check `test/.eval-outputs/<eval-id>-workspace/` for what Claude generated
2. Identify why Claude made the wrong choice
3. Update the relevant `SKILL.md` in `skills/` with clearer guidance
4. Re-run the evaluation to verify the fix

The goal is for Claude to pass evaluations **one-shot** (without needing retries from build errors).
