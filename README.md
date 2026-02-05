# Viaduct Skills

Documentation for AI coding agents working with the Viaduct GraphQL framework.

## Installation

Run from your Viaduct project root:

```bash
npx @viaduct-dev/skills
```

This will:
1. Copy documentation files to `.viaduct-docs/`
2. Add a task-to-doc mapping to your `AGENTS.md` (or `CLAUDE.md`)
3. Update `.gitignore` to exclude the generated docs

## What's Included

| Doc | When to Read |
|-----|--------------|
| mutations.md | Any mutation |
| query-resolver.md | Any query with ID argument |
| field-resolver.md | Field with @resolver |
| node-type.md | Type with `implements Node` |
| batch.md | List field, N+1 prevention |
| relationships.md | Field returning another Node (createdBy, owner) |
| scopes.md | Scope/visibility |

## Development

### Running Evaluations

The `test/` directory contains an evaluation harness to test skill effectiveness:

```bash
cd test
./run-evaluations.sh              # Run all evaluations
./run-evaluations.sh eval-01      # Run specific evaluation
./run-evaluations.sh --no-skill   # Run without skills (baseline)
```

Evaluations test whether Claude correctly implements Viaduct patterns when given the skill documentation.

### Project Structure

```
├── bin/install.js       # npx installer
├── viaduct-docs/        # Documentation files
├── viaduct-*/           # Micro-skill definitions (for skill triggers)
└── test/                # Evaluation harness
    ├── evaluations.json # Evaluation definitions
    ├── run-evaluations.sh
    └── base-template/   # Template project for evals
```
