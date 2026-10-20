// Supabase Edge Function: erp-user-access (D0b). Logic lives in handler.ts so it can be unit tested without Deno.
// Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY. Optional: ALLOWED_ORIGINS (comma list).
// Deploy with verify_jwt = false (like the other ERP functions): the browser's CORS preflight carries no Authorization header,
// so platform-level JWT verification would reject it. The handler verifies the caller's token with Supabase Auth itself.
import { handle } from "./handler.ts";

Deno.serve((req: Request) =>
  handle(
    req,
    {
      SUPABASE_URL: Deno.env.get("SUPABASE_URL")!,
      SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      ANON_KEY: Deno.env.get("SUPABASE_ANON_KEY")!,
      ALLOWED_ORIGINS: (Deno.env.get("ALLOWED_ORIGINS") ?? "https://erp.terranresources.com").split(",").map((s) => s.trim()).filter(Boolean),
    },
    fetch,
  )
);
