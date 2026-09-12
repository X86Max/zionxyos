"use client";

import Link from "next/link";

export default function GlobalError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <html lang="en"><body><main style={{maxWidth:760,margin:"48px auto",padding:"0 20px",fontFamily:"Arial, Helvetica, sans-serif",lineHeight:1.5}}><h1>Zionxyos is temporarily unavailable</h1><p>The application could not render its main layout. This can happen during a temporary database, authentication, or deployment failure.</p><p><button type="button" onClick={() => reset()} style={{padding:"7px 12px",cursor:"pointer"}}>Try again</button> <Link href="/api/health">Health status</Link> · <Link href="/">Main page</Link></p></main></body></html>;
}
