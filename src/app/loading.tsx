export default function Loading() {
  return <main className="site-width content-page narrow-page" aria-live="polite" aria-busy="true">
    <header className="classic-page-heading"><h1>Loading</h1><p>Zionxyos is preparing this page.</p></header>
    <div className="wiki-message"><span className="loading-indicator" aria-hidden="true">…</span> Please wait.</div>
  </main>;
}
