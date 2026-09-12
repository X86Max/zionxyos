import Link from "next/link";

export default function NotFound() {
  return <main className="site-width content-page narrow-page"><header className="classic-page-heading"><h1>Page not found</h1><p>The requested Zionxyos page does not exist or is no longer public.</p></header><div className="wiki-message"><p>Try searching for the topic, browse the category tree, or return to the main page.</p><p><Link href="/search">Search Zionxyos</Link> · <Link href="/categories">Categories</Link> · <Link href="/">Main page</Link></p></div></main>;
}
