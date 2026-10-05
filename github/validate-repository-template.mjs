import {
  chmodSync,
  cpSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const registry = `# name\tvisibility\tprofile\tstate\tpurpose
sample-app\tpublic\tsource\tproposed\tSample source repository
private-app\tprivate\tdistribution\tproposed\tPrivate distribution repository
custom.app\tpublic\tcustom-profile\tproposed\tCustom profile repository
.github\tpublic\torganization\tproposed\tOrganization profile
.github-private\tprivate\tmetadata\tproposed\tPrivate dot-prefixed repository
_samples\tpublic\texamples\tproposed\tSample collection
existing-app\tprivate\toperations\texisting\tExisting repository
`;
const branch = "release/v1+special chars";
const encodedBranch = "release%2Fv1%2Bspecial%20chars";
const fakeGh = `#!/usr/bin/env node
const { appendFileSync, existsSync, readFileSync, writeFileSync } = require("node:fs");
const args = process.argv.slice(2); const log = process.env.GH_LOG; const state = process.env.GH_STATE;
const input = readFileSync(0, "utf8"); appendFileSync(log, args.join(" ") + "\\t" + input + "\\n");
const endpoint = args.find((arg) => arg.startsWith("repos/")) || ""; const jqIndex = args.indexOf("--jq"); const jq = jqIndex === -1 ? "" : args[jqIndex + 1];
if (args[0] === "repo") process.exit(0);
if (!jq) process.exit(0);
const target = endpoint.split("/").slice(1, 3).join("/");
const visibility = target.endsWith("private-app") || target.endsWith("existing-app") ? "private" : "public";
if (jq === "[.full_name,.visibility,.permissions.admin] | @json") {
  const count = existsSync(state) ? Number(readFileSync(state, "utf8")) : 0; writeFileSync(state, String(count + 1));
  if (process.env.GH_SCENARIO === "wrong-target") console.log('["other-owner/other","public",false]');
  else if (process.env.GH_SCENARIO === "wrong-visibility") console.log(JSON.stringify([target, "private", true]));
  else if (process.env.GH_SCENARIO === "transient-failure" || (process.env.GH_SCENARIO === "transient" && count < 2)) process.exit(1);
  else console.log(JSON.stringify([target, visibility, true]));
} else if (jq === ".default_branch") console.log(process.env.GH_SCENARIO === "null-branch" ? "null" : process.env.GH_SCENARIO === "empty-branch" ? "" : ${JSON.stringify(branch)});
else if (jq.includes("has_wiki")) console.log(process.env.GH_SCENARIO === "common-mismatch" ? "[true,false,false,true,false,false,false,true]" : "[false,false,false,true,false,false,false,true]");
else if (endpoint.endsWith("actions/permissions")) console.log("false");
else if (jq.includes("secret_scanning")) console.log('["enabled","enabled"]');
else if (endpoint.endsWith("private-vulnerability-reporting") || endpoint.endsWith("immutable-releases")) console.log("true");
else if (endpoint.includes("/protection")) console.log("[null,true,true,false,0,null,true,false,false,true]");
`;

function run(name, args, scenario = "", includeRegistry = true) {
  const temp = mkdtempSync(join(tmpdir(), "repository-template-"));
  try {
    const toolHome = join(temp, "tool-home");
    const registryDirectory = join(temp, "registry inputs");
    const registryPath = join(registryDirectory, "registry file.tsv");
    mkdirSync(join(toolHome, "github"), { recursive: true });
    mkdirSync(registryDirectory);
    mkdirSync(join(temp, "run-from-here"));
    mkdirSync(join(temp, "bin"));
    cpSync(
      join(root, "github/manage-repository.sh"),
      join(toolHome, "github/manage-repository.sh"),
    );
    chmodSync(join(toolHome, "github/manage-repository.sh"), 0o644);
    writeFileSync(registryPath, registry);
    writeFileSync(join(temp, "bin/gh"), fakeGh, { mode: 0o755 });
    writeFileSync(join(temp, "bin/sleep"), "#!/usr/bin/env sh\nexit 0\n", {
      mode: 0o755,
    });
    const log = join(temp, "gh.log");
    const result = spawnSync(
      "bash",
      [
        join(toolHome, "github/manage-repository.sh"),
        ...(includeRegistry ? ["--registry", registryPath, ...args] : args),
      ],
      {
        cwd: join(temp, "run-from-here"),
        encoding: "utf8",
        env: {
          ...process.env,
          GH_BIN: join(temp, "bin/gh"),
          GH_LOG: log,
          GH_STATE: join(temp, "state"),
          GH_SCENARIO: scenario,
          PATH: `${join(temp, "bin")}:${process.env.PATH}`,
        },
      },
    );
    return {
      name,
      ...result,
      log: existsSync(log) ? readFileSync(log, "utf8") : "",
      registryPath,
    };
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

function succeeds(name, args, scenario) {
  const result = run(name, args, scenario);
  assert.equal(result.status, 0, `${name}: ${result.stderr}`);
  return result;
}
function fails(name, args, scenario, includeRegistry) {
  const result = run(name, args, scenario, includeRegistry);
  assert.notEqual(result.status, 0, `${name} unexpectedly passed`);
  return result;
}
function count(text, pattern) {
  return (text.match(pattern) ?? []).length;
}

const publicCreated = succeeds("public source creation", [
  "--owner",
  "example-org",
  "--repository",
  "sample-app",
  "--apply",
]);
assert.match(publicCreated.log, /^repo create example-org\/sample-app --public/m);
assert.match(
  publicCreated.log,
  /api --method PATCH repos\/example-org\/sample-app --input -\t\{"has_wiki":false,"has_projects":false,"has_discussions":false,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"allow_auto_merge":false,"delete_branch_on_merge":true\}/,
);
assert.match(
  publicCreated.log,
  /api --method PUT repos\/example-org\/sample-app\/actions\/permissions -F enabled=false/,
);
assert.match(
  publicCreated.log,
  /api repos\/example-org\/sample-app\/actions\/permissions --jq \.enabled/,
);
assert.match(
  publicCreated.log,
  /repos\/example-org\/sample-app --input -\t\{"security_and_analysis":\{"secret_scanning":\{"status":"enabled"\},"secret_scanning_push_protection":\{"status":"enabled"\}\}\}/,
);
assert.match(publicCreated.log, /api --method PUT repos\/example-org\/sample-app\/private-vulnerability-reporting/);
assert.match(publicCreated.log, /api --method PUT repos\/example-org\/sample-app\/immutable-releases/);
assert.match(publicCreated.log, /api repos\/example-org\/sample-app --jq \[\.security_and_analysis\.secret_scanning\.status,\.security_and_analysis\.secret_scanning_push_protection\.status\] \| @json/);
assert.match(publicCreated.log, /api repos\/example-org\/sample-app\/private-vulnerability-reporting --jq \.enabled/);
assert.match(publicCreated.log, /api repos\/example-org\/sample-app\/immutable-releases --jq \.enabled/);
assert.match(
  publicCreated.log,
  /api --method PUT repos\/example-org\/sample-app\/branches\/release%2Fv1%2Bspecial%20chars\/protection --input -\t\{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":\{"dismiss_stale_reviews":true,"require_code_owner_reviews":false,"required_approving_review_count":0\},"restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false,"required_conversation_resolution":true\}/,
);
assert.match(
  publicCreated.log,
  /repos\/example-org\/sample-app\/branches\/release%2Fv1%2Bspecial%20chars\/protection/,
);
assert.equal(
  count(publicCreated.log, new RegExp(`branches/${encodedBranch}/protection`, "g")),
  2,
);
const privateCreated = succeeds("private distribution creation", [
  "--owner",
  "another-org",
  "--repository",
  "private-app",
  "--apply",
]);
assert.match(privateCreated.log, /^repo create another-org\/private-app --private/m);
assert.doesNotMatch(privateCreated.log, /secret_scanning|protection|immutable-releases/);
const customProfile = succeeds("custom profile preview", [
  "--owner",
  "custom-owner",
  "--repository",
  "custom.app",
]);
assert.match(customProfile.stdout, /Repository: custom-owner\/custom.app/);
assert.equal(customProfile.log, "");
const dotGithub = succeeds("dot github preview", [
  "--owner",
  "example-org",
  "--repository",
  ".github",
]);
assert.match(dotGithub.stdout, /Repository: example-org\/\.github/);
for (const repository of [".github-private", "_samples"]) {
  const validName = succeeds("valid repository name", [
    "--owner",
    "example-org",
    "--repository",
    repository,
  ]);
  assert.match(validName.stdout, new RegExp(`Repository: example-org/${repository}`));
}
const transient = succeeds(
  "post-create retry",
  ["--owner", "example-org", "--repository", "sample-app", "--apply"],
  "transient",
);
assert.equal(count(transient.log, /^repo create /gm), 1);
assert.equal(count(transient.log, /\[\.full_name/g), 4);
const resumed = succeeds("private resume", [
  "--owner",
  "another-org",
  "--repository",
  "private-app",
  "--apply",
  "--resume",
]);
assert.doesNotMatch(resumed.log, /^repo create /m);
assert.doesNotMatch(resumed.log, /secret_scanning|protection|immutable-releases/);
assert.match(resumed.log, /api --method PATCH repos\/another-org\/private-app --input -/);
assert.match(resumed.log, /api --method PUT repos\/another-org\/private-app\/actions\/permissions -F enabled=false/);
assert.equal(count(resumed.log, /\[\.full_name/g), 2);
const mismatch = fails(
  "identity mismatch",
  ["--owner", "example-org", "--repository", "sample-app", "--apply"],
  "wrong-target",
);
assert.equal(count(mismatch.log, /^repo create /gm), 1);
assert.doesNotMatch(mismatch.log, /--method PATCH|actions\/permissions/);
assert.equal(count(mismatch.stderr, /ERROR:/g), 1);
const visibilityMismatch = fails(
  "visibility mismatch",
  ["--owner", "example-org", "--repository", "sample-app", "--verify"],
  "wrong-visibility",
);
assert.doesNotMatch(visibilityMismatch.log, /--method/);
for (const [name, args, scenario] of [
  ["null branch", ["--owner", "example-org", "--repository", "sample-app", "--apply"], "null-branch"],
  ["empty branch", ["--owner", "example-org", "--repository", "sample-app", "--verify"], "empty-branch"],
]) {
  const invalidBranch = fails(name, args, scenario);
  assert.match(invalidBranch.stderr, /GitHub did not return a default branch/);
  assert.doesNotMatch(invalidBranch.log, /branches\/.*\/protection/);
}
for (const [name, args, scenario] of [
  ["null branch verification", ["--owner", "example-org", "--repository", "sample-app", "--verify"], "null-branch"],
  ["empty branch apply", ["--owner", "example-org", "--repository", "sample-app", "--apply"], "empty-branch"],
]) {
  const invalidBranch = fails(name, args, scenario);
  assert.match(invalidBranch.stderr, /GitHub did not return a default branch/);
  assert.doesNotMatch(invalidBranch.log, /branches\/.*\/protection/);
}
const verifyFailure = fails(
  "settings readback mismatch",
  ["--owner", "example-org", "--repository", "sample-app", "--verify"],
  "common-mismatch",
);
assert.match(verifyFailure.stderr, /Common settings readback mismatch/);
assert.equal(count(verifyFailure.stderr, /ERROR:/g), 1);
assert.doesNotMatch(verifyFailure.log, /--method/);
assert.equal(count(verifyFailure.log, /\[\.full_name/g), 1);
const recovery = fails(
  "recovery command",
  ["--owner", "example-org", "--repository", "sample-app", "--apply"],
  "transient-failure",
);
assert.match(recovery.stderr, /--owner example-org/);
assert.match(recovery.stderr, /--registry .*registry\\ inputs\/registry\\ file\.tsv/);
assert.match(recovery.stderr, /--apply --resume/);
assert.equal(count(recovery.log, /^repo create /gm), 1);
assert.equal(count(recovery.log, /\[\.full_name/g), 4);
assert.doesNotMatch(recovery.log, /--method PATCH|actions\/permissions/);
const missingOwner = fails("missing owner", ["--repository", "sample-app"], "", false);
assert.match(missingOwner.stderr, /--owner is required/);
const missingRegistry = fails(
  "missing registry",
  ["--owner", "example-org", "--repository", "sample-app"],
  "",
  false,
);
assert.match(missingRegistry.stderr, /--registry is required/);
const duplicateRegistry = fails(
  "duplicate registry",
  ["--registry", "first.tsv", "--registry", "second.tsv", "--owner", "example-org", "--repository", "sample-app"],
  "",
  false,
);
assert.match(duplicateRegistry.stderr, /--registry may be specified once/);
const emptyRegistry = fails(
  "empty registry",
  ["--registry", "", "--owner", "example-org", "--repository", "sample-app"],
  "",
  false,
);
assert.match(emptyRegistry.stderr, /--registry needs a path/);
const duplicateOwner = fails(
  "duplicate owner",
  ["--owner", "first", "--owner", "second", "--repository", "sample-app"],
  "",
  false,
);
assert.match(duplicateOwner.stderr, /--owner may be specified once/);
const emptyOwner = fails(
  "empty owner",
  ["--owner", "", "--repository", "sample-app"],
  "",
  false,
);
assert.match(emptyOwner.stderr, /--owner needs an owner name/);
for (const [name, args] of [
  ["invalid owner", ["--owner", "bad/owner", "--repository", "sample-app"]],
  ["invalid repository", ["--owner", "example-org", "--repository", "bad/name"]],
  ["dot owner", ["--owner", ".", "--repository", "sample-app"]],
  ["dot repository", ["--owner", "example-org", "--repository", ".."]],
]) {
  const invalid = fails(name, args);
  assert.equal(
    invalid.stderr,
    `ERROR: invalid ${name.includes("owner") ? "owner" : "repository name"} for this local check; allowed: ASCII letters, digits, dot, underscore, hyphen; not . or ..\n`,
  );
}
for (const [name, args, expectedError] of [
  [
    "unknown argument",
    ["--owner", "example-org", "--repository", "sample-app", "--unknown"],
    "unknown argument: --unknown",
  ],
  [
    "resume without apply",
    ["--owner", "example-org", "--repository", "sample-app", "--resume"],
    "--resume requires --apply",
  ],
  [
    "resume with verify",
    ["--owner", "example-org", "--repository", "sample-app", "--verify", "--resume"],
    "--resume requires --apply",
  ],
  [
    "apply then verify",
    ["--owner", "example-org", "--repository", "sample-app", "--apply", "--verify"],
    "choose only one of --apply or --verify",
  ],
  [
    "verify then apply",
    ["--owner", "example-org", "--repository", "sample-app", "--verify", "--apply"],
    "choose only one of --apply or --verify",
  ],
]) {
  const invalid = fails(name, args);
  assert.equal(invalid.status, 1, `${name}: ${invalid.stderr}`);
  assert.equal(invalid.stderr, `ERROR: ${expectedError}\n`);
  assert.equal(invalid.log, "");
}
const existingApply = fails("existing repository apply", [
  "--owner",
  "example-org",
  "--repository",
  "existing-app",
  "--apply",
]);
assert.match(existingApply.stderr, /only proposed repositories/);
console.log("Repository template validation passed.");
