export function slugify(value:string){return value.normalize("NFKD").replace(/[\u0300-\u036f]/g,"").toLowerCase().trim().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"").slice(0,110)||"page";}
export function makeSlug(title:string){return `${slugify(title)}-${crypto.randomUUID().slice(0,8)}`;}
export function formatDate(value?:string|null){if(!value)return "—";return new Intl.DateTimeFormat("en",{dateStyle:"medium",timeStyle:"short"}).format(new Date(value));}
export function formatDateShort(value?:string|null){if(!value)return "—";return new Intl.DateTimeFormat("en",{dateStyle:"medium"}).format(new Date(value));}
export function isModerationActive(action:{revoked_at:string|null;expires_at:string|null}){if(action.revoked_at)return false;if(!action.expires_at)return true;return new Date(action.expires_at).getTime()>Date.now();}
export function humanExpiry(value?:string|null){return value?formatDate(value):"permanent";}
export function formatBytes(value:number){if(!Number.isFinite(value)||value<=0)return "0 B";const u=["B","KiB","MiB","GiB"];const i=Math.min(Math.floor(Math.log(value)/Math.log(1024)),u.length-1);const n=value/1024**i;return `${n.toFixed(i===0?0:n>=10?1:2)} ${u[i]}`;}
export function stringSetting(value:unknown,fallback=""){return typeof value==="string"?value:fallback;}
export function booleanSetting(value:unknown,fallback=false){return typeof value==="boolean"?value:fallback;}
export function numberSetting(value:unknown,fallback:number){return typeof value==="number"&&Number.isFinite(value)?value:fallback;}
export function safeReturnPath(value:FormDataEntryValue|string|null|undefined,fallback="/dashboard"){const candidate=String(value||"").trim();if(!candidate.startsWith("/")||candidate.startsWith("//")||candidate.includes("\\")||/[\u0000-\u001f\u007f]/.test(candidate))return fallback;try{const base=new URL("https://zionxyos.invalid");const resolved=new URL(candidate,base);return resolved.origin===base.origin?`${resolved.pathname}${resolved.search}${resolved.hash}`:fallback;}catch{return fallback;}}
