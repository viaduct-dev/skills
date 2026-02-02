/**
 * Viaduct Skill Evaluation Harness
 *
 * Runs evaluations against the viaduct skill using the Claude Agent SDK.
 *
 * Usage:
 *   npx tsx run-evaluations.ts [eval-id]
 *
 * Requirements:
 *   - npm install @anthropic-ai/claude-agent-sdk
 *   - ANTHROPIC_API_KEY environment variable set
 *   - Claude Code installed
 */

import { query, ClaudeAgentOptions } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";

interface Evaluation {
  id: string;
  name: string;
  skills: string[];
  query: string;
  files: string[];
  expected_behavior: string[];
}

interface EvalResult {
  id: string;
  name: string;
  query: string;
  passed: boolean;
  behaviors_found: string[];
  behaviors_missing: string[];
  output: string;
  error?: string;
}

async function runEvaluation(
  eval_: Evaluation,
  workingDir: string
): Promise<EvalResult> {
  const result: EvalResult = {
    id: eval_.id,
    name: eval_.name,
    query: eval_.query,
    passed: false,
    behaviors_found: [],
    behaviors_missing: [],
    output: "",
  };

  try {
    // Collect all output from the agent
    const outputs: string[] = [];

    for await (const message of query({
      prompt: eval_.query,
      options: {
        // Load skills from project directory
        settingSources: ["project"],
        // Allow code generation tools but not execution for safety
        allowedTools: ["Read", "Glob", "Grep", "Write", "Edit"],
        // Run without interactive prompts
        permissionMode: "acceptEdits",
        // Set working directory
        cwd: workingDir,
      } as ClaudeAgentOptions,
    })) {
      // Capture text output and tool results
      if ("result" in message) {
        outputs.push(String(message.result));
      }
      if ("content" in message && typeof message.content === "string") {
        outputs.push(message.content);
      }
    }

    result.output = outputs.join("\n");

    // Check each expected behavior against the output
    for (const behavior of eval_.expected_behavior) {
      // Simple heuristic: check if key terms from behavior appear in output
      const keyTerms = extractKeyTerms(behavior);
      const found = keyTerms.every((term) =>
        result.output.toLowerCase().includes(term.toLowerCase())
      );

      if (found) {
        result.behaviors_found.push(behavior);
      } else {
        result.behaviors_missing.push(behavior);
      }
    }

    // Pass if majority of behaviors found
    result.passed =
      result.behaviors_found.length > result.behaviors_missing.length;
  } catch (error) {
    result.error = String(error);
  }

  return result;
}

function extractKeyTerms(behavior: string): string[] {
  // Extract code-like terms (PascalCase, camelCase, snake_case, @decorators)
  const codeTerms =
    behavior.match(
      /@?\b[A-Z][a-zA-Z]+(?:\.[A-Z][a-zA-Z]+)*\b|\b[a-z]+[A-Z][a-zA-Z]*\b|\b[a-z]+_[a-z_]+\b|ctx\.[a-zA-Z]+/g
    ) || [];

  // Also extract quoted terms
  const quotedTerms = behavior.match(/'[^']+'/g)?.map((t) => t.slice(1, -1)) || [];

  return [...codeTerms, ...quotedTerms].filter((t) => t.length > 2);
}

async function main() {
  const args = process.argv.slice(2);
  const evalFilter = args[0]; // Optional: run specific evaluation

  // Load evaluations
  const evalPath = join(__dirname, "evaluations.json");
  const evaluations: Evaluation[] = JSON.parse(readFileSync(evalPath, "utf-8"));

  // Filter if specified
  const toRun = evalFilter
    ? evaluations.filter((e) => e.id === evalFilter || e.name.includes(evalFilter))
    : evaluations;

  if (toRun.length === 0) {
    console.error(`No evaluations found matching: ${evalFilter}`);
    process.exit(1);
  }

  console.log(`Running ${toRun.length} evaluation(s)...\n`);

  // Create temp working directory for evaluation
  const workDir = join(__dirname, ".eval-workspace");
  mkdirSync(workDir, { recursive: true });

  const results: EvalResult[] = [];

  for (const eval_ of toRun) {
    console.log(`\n${"=".repeat(60)}`);
    console.log(`Running: ${eval_.id} - ${eval_.name}`);
    console.log(`Query: ${eval_.query.slice(0, 100)}...`);
    console.log("=".repeat(60));

    const result = await runEvaluation(eval_, workDir);
    results.push(result);

    // Print result summary
    const status = result.passed ? "✅ PASSED" : "❌ FAILED";
    console.log(`\nResult: ${status}`);
    console.log(`  Behaviors found: ${result.behaviors_found.length}/${eval_.expected_behavior.length}`);

    if (result.behaviors_missing.length > 0) {
      console.log(`  Missing:`);
      for (const b of result.behaviors_missing) {
        console.log(`    - ${b}`);
      }
    }

    if (result.error) {
      console.log(`  Error: ${result.error}`);
    }
  }

  // Summary
  console.log(`\n${"=".repeat(60)}`);
  console.log("SUMMARY");
  console.log("=".repeat(60));

  const passed = results.filter((r) => r.passed).length;
  console.log(`Passed: ${passed}/${results.length}`);

  for (const r of results) {
    const icon = r.passed ? "✅" : "❌";
    console.log(`  ${icon} ${r.id}: ${r.name}`);
  }

  // Save detailed results
  const resultsPath = join(__dirname, "evaluation-results.json");
  writeFileSync(resultsPath, JSON.stringify(results, null, 2));
  console.log(`\nDetailed results saved to: ${resultsPath}`);

  process.exit(passed === results.length ? 0 : 1);
}

main().catch(console.error);
