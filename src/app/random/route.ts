import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function GET() {
  const supabase = await createClient();
  const { data: slug } = await supabase.rpc("random_published_article");
  redirect(slug ? `/article/${slug}` : "/?empty=1");
}
