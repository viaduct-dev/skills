#!/bin/bash
#
# Installs Viaduct skill documentation into a project.
# Usage: ./install.sh [project-name]
#
# This script:
# 1. Creates .viaduct/agents/ directory
# 2. Downloads skill docs from GitHub, stripping YAML frontmatter
# 3. Creates/updates AGENTS.md with task mapping table
# 4. Updates .gitignore
#

set -e

PROJECT_NAME="${1:-myapp}"
DOCS_DIR=".viaduct/agents"
START_MARKER="<!-- VIADUCT-AGENTS-MD-START -->"
END_MARKER="<!-- VIADUCT-AGENTS-MD-END -->"
# Skill directory -> output file mapping
declare -A SKILL_MAP=(
  ["viaduct-mutations"]="mutations.md"
  ["viaduct-query-resolver"]="query-resolver.md"
  ["viaduct-field-resolver"]="field-resolver.md"
  ["viaduct-node-type"]="node-type.md"
  ["viaduct-batch"]="batch.md"
  ["viaduct-relationships"]="relationships.md"
  ["viaduct-scopes"]="scopes.md"
)

echo "Installing Viaduct documentation..."
echo

# 1. Create .viaduct/agents/ directory
mkdir -p "$DOCS_DIR"

# 2. Download docs from GitHub (try curl first, fall back to gh api for private repos)
SKILLS_BASE_URL="https://raw.githubusercontent.com/viaduct-dev/skills/main/skills"

for skill_dir in "${!SKILL_MAP[@]}"; do
  output_file="${SKILL_MAP[$skill_dir]}"
  url="$SKILLS_BASE_URL/$skill_dir/SKILL.md"
  api_path="repos/viaduct-dev/skills/contents/skills/$skill_dir/SKILL.md"

  # Try curl first (works if repo is public)
  if content=$(curl -fsSL "$url" 2>/dev/null); then
    echo "$content" | sed '/^---$/,/^---$/d' > "$DOCS_DIR/$output_file"
    echo "  Downloaded $output_file"
  # Fall back to gh api (works for private repo)
  elif content=$(gh api "$api_path" --jq '.content' 2>/dev/null | base64 -d); then
    echo "$content" | sed '/^---$/,/^---$/d' > "$DOCS_DIR/$output_file"
    echo "  Downloaded $output_file"
  else
    echo "  Warning: Failed to fetch $skill_dir"
  fi
done

# 3. Generate index content
generate_index() {
  cat << 'EOF'
[Viaduct Docs]|root: ./.viaduct/agents

## Viaduct Framework

**⚠️ MANDATORY: Read the relevant doc before implementing.**

| Task | Read First |
|------|------------|
| Any mutation | mutations.md |
| Any query with ID argument | query-resolver.md |
| Field with @resolver | field-resolver.md |
| Type with `implements Node` | node-type.md |
| List field, N+1 prevention | batch.md |
| Field returning another Node (createdBy, owner) | relationships.md |
| Scope/visibility | scopes.md |

**⚠️ @idOf CHECK:** Before implementing, scan schema for `id: ID!` in input types and query args. If missing `@idOf`, add it first. See mutations.md or query-resolver.md.
EOF
}

# 4. Create or update AGENTS.md
AGENTS_FILE="AGENTS.md"
CLAUDE_FILE="CLAUDE.md"

if [ -f "$CLAUDE_FILE" ]; then
  TARGET_FILE="$CLAUDE_FILE"
else
  TARGET_FILE="$AGENTS_FILE"
fi

INDEX_CONTENT=$(generate_index)
WRAPPED_INDEX="$START_MARKER
$INDEX_CONTENT
$END_MARKER"

if [ -f "$TARGET_FILE" ]; then
  CONTENT=$(cat "$TARGET_FILE")

  if echo "$CONTENT" | grep -q "$START_MARKER"; then
    # Replace existing content between markers
    # Use awk for multi-line replacement
    awk -v start="$START_MARKER" -v end="$END_MARKER" -v new="$WRAPPED_INDEX" '
      $0 ~ start { found=1; print new; next }
      $0 ~ end { found=0; next }
      !found { print }
    ' "$TARGET_FILE" > "$TARGET_FILE.tmp"
    mv "$TARGET_FILE.tmp" "$TARGET_FILE"
  else
    # Append to end
    echo "" >> "$TARGET_FILE"
    echo "$WRAPPED_INDEX" >> "$TARGET_FILE"
  fi
else
  # Create new file
  cat > "$TARGET_FILE" << EOF
# $PROJECT_NAME

This is a Viaduct GraphQL service.

$WRAPPED_INDEX
EOF
fi

echo
echo "Updated $(basename "$TARGET_FILE")"

# 5. Update .gitignore
GITIGNORE_FILE=".gitignore"
if [ -f "$GITIGNORE_FILE" ]; then
  if ! grep -q "$DOCS_DIR" "$GITIGNORE_FILE"; then
    echo "" >> "$GITIGNORE_FILE"
    echo "# Viaduct docs (generated)" >> "$GITIGNORE_FILE"
    echo "$DOCS_DIR/" >> "$GITIGNORE_FILE"
    echo "Updated .gitignore"
  fi
else
  cat > "$GITIGNORE_FILE" << EOF
# Viaduct docs (generated)
$DOCS_DIR/
EOF
  echo "Created .gitignore"
fi

echo
echo "Done! Viaduct documentation is now available."
