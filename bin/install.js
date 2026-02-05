#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const DOCS_DIR = '.viaduct-docs';
const START_MARKER = '<!-- VIADUCT-AGENTS-MD-START -->';
const END_MARKER = '<!-- VIADUCT-AGENTS-MD-END -->';

// Get the directory where this package is installed
const packageDir = path.dirname(__dirname);
const sourceDocsDir = path.join(packageDir, 'viaduct-docs');
const cwd = process.cwd();

console.log('Installing Viaduct documentation...\n');

// 1. Create .viaduct-docs/ directory
const targetDocsDir = path.join(cwd, DOCS_DIR);
if (!fs.existsSync(targetDocsDir)) {
  fs.mkdirSync(targetDocsDir, { recursive: true });
}

// 2. Copy docs
const docFiles = fs.readdirSync(sourceDocsDir).filter(f => f.endsWith('.md'));
for (const file of docFiles) {
  const src = path.join(sourceDocsDir, file);
  const dest = path.join(targetDocsDir, file);
  fs.copyFileSync(src, dest);
  console.log(`  Copied ${file}`);
}

// 3. Generate index with task mapping table
const index = generateIndex();
console.log('\nGenerated index with task mapping table');

// 4. Inject into AGENTS.md or CLAUDE.md
const agentsMdPath = path.join(cwd, 'AGENTS.md');
const claudeMdPath = path.join(cwd, 'CLAUDE.md');
const targetFile = fs.existsSync(claudeMdPath) ? claudeMdPath : agentsMdPath;

let content = '';
if (fs.existsSync(targetFile)) {
  content = fs.readFileSync(targetFile, 'utf-8');
}

const wrappedIndex = `${START_MARKER}\n${index}\n${END_MARKER}`;

if (content.includes(START_MARKER)) {
  // Replace existing
  const startIdx = content.indexOf(START_MARKER);
  const endIdx = content.indexOf(END_MARKER) + END_MARKER.length;
  content = content.slice(0, startIdx) + wrappedIndex + content.slice(endIdx);
} else {
  // Append
  content = content + (content.endsWith('\n') ? '\n' : '\n\n') + wrappedIndex + '\n';
}

fs.writeFileSync(targetFile, content);
console.log(`\nUpdated ${path.basename(targetFile)}`);

// 5. Update .gitignore
const gitignorePath = path.join(cwd, '.gitignore');
let gitignore = fs.existsSync(gitignorePath) ? fs.readFileSync(gitignorePath, 'utf-8') : '';
if (!gitignore.includes(DOCS_DIR)) {
  gitignore += `\n# Viaduct docs (generated)\n${DOCS_DIR}/\n`;
  fs.writeFileSync(gitignorePath, gitignore);
  console.log('Updated .gitignore');
}

console.log('\nDone! Viaduct documentation is now available.');

function generateIndex() {
  return `[Viaduct Docs]|root: ./${DOCS_DIR}

## Viaduct Framework

**⚠️ MANDATORY: Read docs AND check schema before implementing.**

| Task | Read First |
|------|------------|
| Mutation, input with ID field | mutations.md |
| Query with ID argument | query-resolver.md |
| Add computed field (@resolver) | field-resolver.md |
| Create Node type | node-type.md |
| Batch resolution, N+1 | batch.md |
| Entity relationships | relationships.md |
| Scope/visibility | scopes.md |

## ⛔ BEFORE WRITING ANY CODE

**Step 1: Check the schema for missing @idOf directives**

Scan ALL ID fields in input types and query arguments. If any \`id: ID!\` is missing \`@idOf\`, you MUST add it:

\`\`\`graphql
# ❌ BROKEN - Missing @idOf causes "String but GlobalID expected" errors
input UpdateTaskInput {
  id: ID!  # <-- FIX THIS FIRST
}

# ✅ FIXED - Add @idOf to enable .internalID
input UpdateTaskInput {
  id: ID! @idOf(type: "Task")
}
\`\`\`

**Step 2: Then implement the resolver using .internalID**

\`\`\`kotlin
val taskId = input.id.internalID  // Only works with @idOf
\`\`\`

## Common Error → Solution

| Build Error | Solution |
|-------------|----------|
| Type mismatch: String but GlobalID expected | Add \`@idOf(type: "X")\` to schema |
| internalID not a member of String | Add \`@idOf(type: "X")\` to schema |
| Cannot convert String to GlobalID | Add \`@idOf(type: "X")\` to schema |

**DO NOT work around these errors with Base64 decoding or ctx.globalIDFor() on strings. Fix the schema.**`;
}
