# Viaduct Skills

Documentation for AI coding agents working with the Viaduct GraphQL framework.

## Installation

There are two ways to install Viaduct skills:

### Option 1: AGENTS.md Integration (Recommended)

Run from your Viaduct project root:

```bash
curl -fsSL https://raw.githubusercontent.com/viaduct-dev/skills/main/bin/install.sh | bash -s -- myapp
```

Replace `myapp` with your project name.

Or, if you have Node.js installed:

```bash
npx @viaduct-dev/skills
```

This will:
1. Copy documentation files to `.viaduct/agents/`
2. Add a task-to-doc mapping to your `AGENTS.md` (or `CLAUDE.md`)
3. Update `.gitignore` to exclude the generated docs

The task mapping tells Claude which doc to read before implementing each type of task.

**This is the most reliable method** — micro-skills don't always load, whereas AGENTS.md ensures documentation is always available.

### Option 2: Micro-Skills via skills.sh

Install all Viaduct skills using the [skills.sh](https://skills.sh) CLI:

```bash
npx skills add viaduct-dev/viaduct-skills
```

This installs all micro-skills from the `skills/` directory. Each skill is triggered automatically based on task context.

**Manual installation for Claude Code:**

```bash
cp -r skills/* ~/.claude/skills/
```

**For claude.ai:**

Add individual skill files to project knowledge, or paste SKILL.md contents into the conversation.

## What's Included

| Skill / Doc | When Used |
|-------------|-----------|
| viaduct-mutations | Any mutation, CRUD operations, `@idOf` in input types |
| viaduct-query-resolver | Any query with ID argument |
| viaduct-field-resolver | Field with `@resolver` directive |
| viaduct-node-type | Type with `implements Node` |
| viaduct-batch | List field, N+1 prevention |
| viaduct-relationships | Field returning another Node (createdBy, owner) |
| viaduct-scopes | Scope/visibility configuration |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and running evaluations.
