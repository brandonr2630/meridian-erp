// update-erp-user Edge Function v4 — company-scoped authorisation, real error messages. Logic lives in handler.ts.
// Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY.
// Deploy with verify_jwt = false (CORS preflight carries no Authorization header); the handler verifies the caller's token itself.
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
