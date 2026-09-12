import Link from "next/link";
import { updateProfileAction } from "@/actions/profile";
import { requireUser } from "@/lib/auth";
import { Flash } from "@/components/Flash";
export const metadata={title:"Profile settings"};
export default async function ProfilePage({searchParams}:{searchParams:Promise<{error?:string;success?:string}>}){const c=await requireUser();const p=await searchParams;return <><header className="classic-page-heading action-heading"><div><h1>Profile settings</h1><p>@{c.profile.username}</p></div><Link href={`/u/${c.profile.username}`} className="button">View public profile</Link></header><Flash error={p.error} success={p.success}/><form action={updateProfileAction} className="wiki-fieldset stack"><label><span>Display name</span><input name="display_name" maxLength={80} defaultValue={c.profile.display_name||""}/></label><label><span>Biography</span><textarea name="bio" rows={7} maxLength={1000} defaultValue={c.profile.bio||""}/></label><div><button className="button primary" type="submit">Save profile</button></div></form><p className="hint">Your username is used for stable contribution attribution and cannot be changed through this form.</p></>}
