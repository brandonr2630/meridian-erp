// create-erp-user Edge Function v9 — company-scoped authorisation. Logic lives in handler.ts (unit tested without Deno).
// Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY.
// Deploy with verify_jwt = false (the browser's CORS preflight carries no Authorization header); the handler verifies the
// caller's token with Supabase Auth itself.
import { handle } from "./handler.ts";

Deno.serve((req: Request) =>
  handle(
    req,
    {
      SUPABASE_URL: Deno.env.get("SUPABASE_URL")!,
      SERVICE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      ANON_KEY: Deno.env.get("SUPABASE_ANON_KEY")!,
    },
    fetch,
  )
);
