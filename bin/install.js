#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const DOCS_DIR = '.viaduct/agents';
const START_MARKER = '<!-- VIADUCT-AGENTS-MD-START -->';
const END_MARKER = '<!-- VIADUCT-AGENTS-MD-END -->';

// Map skill directory names to output file names
const SKILL_MAP = {
  'viaduct-mutations': 'mutations.md',
  'viaduct-query-resolver': 'query-resolver.md',
  'viaduct-field-resolver': 'field-resolver.md',
  'viaduct-node-type': 'node-type.md',
  'viaduct-batch': 'batch.md',
  'viaduct-relationships': 'relationships.md',
  'viaduct-scopes': 'scopes.md',
};

// Get the directory where this package is installed
const packageDir = path.dirname(__dirname);
const skillsDir = path.join(packageDir, 'skills');
const cwd = process.cwd();

console.log('Installing Viaduct documentation...\n');

// 1. Create .viaduct/agents/ directory
const targetDocsDir = path.join(cwd, DOCS_DIR);
if (!fs.existsSync(targetDocsDir)) {
  fs.mkdirSync(targetDocsDir, { recursive: true });
}

// 2. Copy docs from skills/*/SKILL.md, stripping YAML frontmatter
for (const [skillDir, outputFile] of Object.entries(SKILL_MAP)) {
  const srcPath = path.join(skillsDir, skillDir, 'SKILL.md');
  const destPath = path.join(targetDocsDir, outputFile);

  if (fs.existsSync(srcPath)) {
    let content = fs.readFileSync(srcPath, 'utf-8');

    // Strip YAML frontmatter (---\n...\n---)
    content = content.replace(/^---\n[\s\S]*?\n---\n*/, '');

    fs.writeFileSync(destPath, content);
    console.log(`  Copied ${outputFile}`);
  } else {
    console.log(`  Warning: ${srcPath} not found`);
  }
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

**⚠️ MANDATORY: Read the relevant doc before implementing.**

| Task | Read First |
|------|------------|
| When authoring any mutation | mutations.md |
| Any query with ID argument | query-resolver.md |
| Field with @resolver | field-resolver.md |
| Type with \`implements Node\` | node-type.md |
| List field, N+1 prevention | batch.md |
| Field returning another Node (createdBy, owner) | relationships.md |
| Scope/visibility | scopes.md |

**⚠️ @idOf CHECK:** Before implementing, scan schema for \`id: ID!\` in input types and query args. If missing \`@idOf\`, add it first. See mutations.md or query-resolver.md.`;
}
