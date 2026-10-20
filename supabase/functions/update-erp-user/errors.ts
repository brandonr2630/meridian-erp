// Turns a Supabase Auth (GoTrue) admin API error body into something an admin can act on.
// GoTrue reports the human text in `msg` (older versions: `message`, OAuth style: `error_description`) and a machine code in
// `error_code`; create-erp-user used to read only `message`, so every failure showed the generic "Failed to create auth user".
export type AuthErrorInfo = { message: string; code: string | null; status: number };

export function describeAuthError(body: unknown, status: number, fallback = "Failed to create auth user"): AuthErrorInfo {
  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  const code = typeof b.error_code === "string" && b.error_code ? b.error_code : null;
  const raw = [b.msg, b.message, b.error_description, b.error].find((v) => typeof v === "string" && v.trim() !== "") as string | undefined;

  let message = raw?.trim() ?? fallback;
  if (code === "email_exists" || code === "user_already_exists") {
    message = "A user with this email address is already registered";
  } else if (code === "weak_password") {
    const reasons = (b.weak_password as { reasons?: unknown } | undefined)?.reasons;
    const list = Array.isArray(reasons) ? reasons.filter((r) => typeof r === "string") : [];
    message = (raw?.trim() ?? "Password does not meet the project's password requirements") + (list.length ? ` (${list.join(", ")})` : "");
  } else if (code === "validation_failed" || code === "email_address_invalid") {
    message = raw?.trim() ?? "The email address is not valid";
  }
  const safeStatus = Number.isInteger(status) && status >= 400 && status < 600 ? status : 500;
  return { message, code, status: safeStatus };
}
