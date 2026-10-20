// Mutation check for create-erp-user / update-erp-user: every deliberate breakage of the authorisation logic must make the
// suite fail. Run: node supabase/tests/authz/mutate.mjs   (prints "mutation check passed" only when all mutants are caught)
import { cpSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const FUNCS = join(here, "..", "..", "functions");
const A = "authz.ts";
// [name, [folders to mutate], file, from, to]
const both = ["create-erp-user", "update-erp-user"];
const M = [
  ["caller may administer every company", both, A, "a.isSuper || a.adminCompanies.has(companyId)", "true"],
  ["admin in any company counts as admin everywhere", both, A, "a.isSuper || a.adminCompanies.has(companyId)", "a.isSuper || a.adminCompanies.size > 0"],
  ["super-admin role never recognised", both, A, 'hasAtom(p, "admin:companies")', "false"],
  ["every caller treated as super admin", both, A, "if (isSuperRole(p)) isSuper = true;", "isSuper = true;"],
  ["inactive callers accepted", both, A, "&is_active=eq.true", ""],
  ["admin:settings counts as admin:users", both, A, 'if (hasAtom(p, "admin:users")) adminCompanies', 'if (hasAtom(p, "admin:users") || hasAtom(p, "admin:settings")) adminCompanies'],
  ["password minimum lowered to 8", both, A, "MIN_PASSWORD = 12", "MIN_PASSWORD = 8"],
  ["email never validated", both, A, "typeof v === \"string\" && v.length <= 254 && EMAIL.test(v)", "typeof v === \"string\""],
  ["create: token not required to be valid", ["create-erp-user"], "handler.ts", "if (!callerId) return reply(401", "if (false) return reply(401"],
  ["create: company-scope check removed", ["create-erp-user"], "handler.ts", "if (!canAdminister(access, company_id)) return reply(403", "if (false) return reply(403"],
  ["create: anyone may assign the super admin role", ["create-erp-user"], "handler.ts", "isSuperRole(role.permissions) && !access.isSuper", "false"],
  ["create: role of another company allowed", ["create-erp-user"], "handler.ts", "if (role.company_id && role.company_id !== company_id)", "if (false)"],
  ["create: unknown role allowed through", ["create-erp-user"], "handler.ts", "if (!role) return reply(400", "if (false) return reply(400"],
  ["create: unknown company allowed through", ["create-erp-user"], "handler.ts", "if (companies.length === 0) return reply(400", "if (false) return reply(400"],
  ["create: orphan login left behind on profile failure", ["create-erp-user"], "handler.ts", "await f(`${env.SUPABASE_URL}/auth/v1/admin/users/${authUserId}`, { method: \"DELETE\", headers: svc });", ""],
  ["create: password written to the audit row", ["create-erp-user"], "handler.ts", "{ target_erp_user_id: newUserId,", "{ pw: password, target_erp_user_id: newUserId,"],
  ["create: auth error reason dropped", ["create-erp-user"], "handler.ts", "return reply(info.status, { error: info.message, code: info.code });", "return reply(info.status, { error: \"Failed to create auth user\" });"],
  ["update: token not required to be valid", ["update-erp-user"], "handler.ts", "if (!callerId) return reply(401", "if (false) return reply(401"],
  ["update: super admin targets not protected", ["update-erp-user"], "handler.ts", "if (targetIsSuper || companies.length === 0)", "if (companies.length === 0)"],
  ["update: only ONE of the target's companies must be administered", ["update-erp-user"], "handler.ts", "companies.every(", "companies.some("],
  ["update: caller without admin rights reaches the lookup (existence oracle)", ["update-erp-user"], "handler.ts", "if (!access.isSuper && access.adminCompanies.size === 0) return reply(403", "if (false) return reply(403"],
  ["update: wrong error field (the old bug)", ["update-erp-user"], "handler.ts", "const info = describeAuthError(err, res.status, \"Failed to update auth user\");", "const info = { message: (err as { message?: string }).message ?? \"Failed to update auth user\", code: null, status: res.status };"],
  ["update: values written to the audit row", ["update-erp-user"], "handler.ts", "{ target_erp_user_id: target.id, fields: Object.keys(updates) }", "{ target_erp_user_id: target.id, fields: Object.keys(updates), updates }"],
  ["update: nonexistent user not reported", ["update-erp-user"], "handler.ts", "if (rows.length === 0) return reply(404", "if (false) return reply(404"],
  ["drift: authz.ts differs between the two functions", ["update-erp-user"], A, "export const MIN_PASSWORD = 12;", "export const MIN_PASSWORD = 12; // drift"],
];

let caught = 0; const missed = [];
for (const [name, folders, file, from, to] of M) {
  const dir = mkdtempSync(join(tmpdir(), "authz-mut-"));
  try {
    cpSync(FUNCS, dir, { recursive: true });
    for (const folder of folders) {
      const p = join(dir, folder, file);
      const src = readFileSync(p, "utf8").replaceAll("\r\n", "\n");
      if (!src.includes(from)) { console.error(`BAD MUTANT (pattern not found): ${name}`); process.exit(2); }
      writeFileSync(p, src.replace(from, to));
    }
    const r = spawnSync(process.execPath, ["--test", join(here, "create.test.mjs"), join(here, "update.test.mjs")], { env: { ...process.env, AUTHZ_FN_DIR: dir }, encoding: "utf8" });
    if (r.status !== 0) { caught++; console.log(`caught   ${name}`); } else { missed.push(name); console.log(`MISSED   ${name}`); }
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
if (missed.length) { console.error(`mutation check FAILED: ${caught}/${M.length} caught; missed: ${missed.join("; ")}`); process.exit(1); }
console.log(`mutation check passed: ${caught}/${M.length} mutants caught`);
