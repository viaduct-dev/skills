# Viaduct Claude Code Skills

A collection of Claude Code skills for Viaduct development.

## Available Skills

| Skill | Description |
|-------|-------------|
| [viaduct](./viaduct/) | Viaduct GraphQL framework development guide (auto-triggers) |

## Installation

### Global Installation (all projects)

Symlink the skill directory to your Claude skills folder:

```bash
ln -s /path/to/skills/viaduct ~/.claude/skills/viaduct
```

### Project-Specific Installation

```bash
ln -s /path/to/skills/viaduct .claude/skills/viaduct
```

## Contributing

Each skill lives in its own directory with:
- `SKILL.md` - Main skill file with YAML frontmatter for auto-triggering
- `resources/` - Supporting documentation files

See the [viaduct](./viaduct/) skill for an example structure.
