"use client";

import Link from "next/link";

export default function ErrorPage({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <main className="site-width content-page narrow-page"><header className="classic-page-heading"><h1>Something went wrong</h1><p>Zionxyos could not complete this request.</p></header><div className="wiki-message error"><p>The error was not expected. You can retry the request or return to the main page.</p><div className="actions compact"><button className="button primary" type="button" onClick={() => reset()}>Try again</button><Link className="button secondary" href="/">Main page</Link></div></div></main>;
}
