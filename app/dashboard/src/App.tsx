import { useCallback, useEffect, useState, type ReactNode } from 'react'
import type { StatusPayload } from './types'
import {
  ActivityIcon,
  AdminIcon,
  ArrowIcon,
  CartIcon,
  CheckIcon,
  ClockIcon,
  CopyIcon,
  CpuIcon,
  DiskIcon,
  ExternalIcon,
  LockIcon,
  RefreshIcon,
  ServerIcon,
  ShieldIcon,
  StoreIcon,
  UsersIcon,
} from './icons'

const REFRESH_MS = 10_000

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 MB'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  const value = bytes / 1024 ** index
  return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`
}

function formatUptime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return '—'
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) return `${days} T ${hours} Std`
  if (hours > 0) return `${hours} Std ${minutes} Min`
  return `${minutes} Min`
}

const dateFormatter = new Intl.DateTimeFormat('de-DE', {
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
})

function formatDate(iso: string | null): string {
  if (!iso) return '—'
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? '—' : dateFormatter.format(date)
}

function useStatus() {
  const [data, setData] = useState<StatusPayload | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null)

  const refresh = useCallback(async () => {
    try {
      const response = await fetch('/status/api/status', {
        cache: 'no-store',
        headers: { Accept: 'application/json' },
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const payload = (await response.json()) as StatusPayload
      setData(payload)
      setError(
        payload.ok
          ? null
          : !payload.database.ok
            ? 'Die Datenbank ist momentan nicht erreichbar.'
            : 'Ein oder mehrere Dienste sind momentan nicht erreichbar.',
      )
      setLastUpdated(new Date())
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Status-API nicht erreichbar')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
    const timer = window.setInterval(() => void refresh(), REFRESH_MS)
    return () => window.clearInterval(timer)
  }, [refresh])

  return { data, error, loading, lastUpdated, refresh }
}

function StatusPill({ online, loading }: { online: boolean; loading: boolean }) {
  return (
    <div className={`status-pill ${online ? 'is-online' : 'is-offline'}`}>
      <span className="status-dot" />
      <span>{loading ? 'Verbinde …' : online ? 'Online' : 'Offline'}</span>
    </div>
  )
}

function Metric({
  icon,
  label,
  value,
  hint,
  percent,
  tone = 'default',
}: {
  icon: ReactNode
  label: string
  value: ReactNode
  hint?: string
  percent?: number
  tone?: 'default' | 'warm' | 'cool'
}) {
  return (
    <article className={`metric card tone-${tone}`}>
      <div className="metric-head">
        <span className="metric-icon">{icon}</span>
        <span className="metric-label">{label}</span>
      </div>
      <div className="metric-value">{value}</div>
      {typeof percent === 'number' ? (
        <div className="progress" aria-hidden="true">
          <span style={{ width: `${Math.min(100, Math.max(0, percent))}%` }} />
        </div>
      ) : null}
      {hint ? <div className="metric-hint">{hint}</div> : null}
    </article>
  )
}

function ServiceRow({ label, ok, detail }: { label: string; ok: boolean; detail?: string }) {
  return (
    <div className="service-row">
      <span className={`service-state ${ok ? 'is-ok' : 'is-bad'}`}>
        {ok ? <CheckIcon width={14} height={14} /> : <span className="service-cross">×</span>}
      </span>
      <span className="service-label">{label}</span>
      <span className={`service-detail ${ok ? 'is-ok' : 'is-bad'}`}>{ok ? 'aktiv' : 'offline'}</span>
      {detail ? <span className="service-meta">{detail}</span> : null}
    </div>
  )
}

function DetailRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="detail-row">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function QuickCard({
  href,
  icon,
  title,
  description,
  external,
}: {
  href: string
  icon: ReactNode
  title: string
  description: string
  external?: boolean
}) {
  return (
    <a className="quick-card card" href={href} target={external ? '_blank' : undefined} rel={external ? 'noreferrer' : undefined}>
      <span className="quick-icon">{icon}</span>
      <span className="quick-copy">
        <strong>{title}</strong>
        <span>{description}</span>
      </span>
      <span className="quick-arrow">{external ? <ExternalIcon /> : <ArrowIcon />}</span>
    </a>
  )
}

function App() {
  const { data, error, loading, lastUpdated, refresh } = useStatus()
  const [copied, setCopied] = useState(false)
  const [refreshing, setRefreshing] = useState(false)

  const origin = window.location.origin
  const online = Boolean(data?.ok && data.services.web)
  const allServices = data
    ? data.services.web && data.services.php_fpm && data.services.nginx && data.services.mariadb
    : false

  const version = data?.app.version ?? '—'
  const ctid = data?.app.ctid ?? '—'
  const ip = data?.host.ip ?? '—'
  const adminEmail = data?.app.admin_email ?? '—'

  const handleRefresh = async () => {
    setRefreshing(true)
    await refresh()
    window.setTimeout(() => setRefreshing(false), 450)
  }

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(origin)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1800)
    } catch {
      setCopied(false)
    }
  }

  const memoryPercent = data?.host.memory.percent ?? 0
  const diskPercent = data?.host.disk.percent ?? 0
  const load = data?.host.load?.[0] ?? 0

  return (
    <div className="app-shell">
      <div className="ambient ambient-one" />
      <div className="ambient ambient-two" />

      <header className="topbar">
        <a className="brand" href="/status/" aria-label="TastyIgniter Control Center">
          <span className="brand-mark">TI</span>
          <span className="brand-copy">
            <span className="eyebrow">Local Restaurant Platform</span>
            <span className="brand-name">TastyIgniter</span>
          </span>
        </a>

        <div className="topbar-actions">
          <StatusPill online={online} loading={loading} />
          <button className="icon-button" type="button" onClick={handleRefresh} aria-label="Status aktualisieren" title="Status aktualisieren">
            <RefreshIcon className={refreshing ? 'spin' : ''} />
          </button>
        </div>
      </header>

      {error ? (
        <div className="offline-banner" role="alert">
          <ShieldIcon />
          <span>
            <strong>Status nicht vollständig verfügbar.</strong> {error}
          </span>
          <button type="button" onClick={handleRefresh}>
            Erneut versuchen
          </button>
        </div>
      ) : null}

      <main>
        <section className="hero card">
          <div className="hero-copy">
            <span className="kicker">
              <span className="kicker-dot" />
              Dein Server. Deine Daten. Kein Cloud-Zwang.
            </span>
            <h1>
              Restaurant-Betrieb.
              <span>Einfach lokal.</span>
            </h1>
            <p>
              TastyIgniter läuft vollständig in deinem Proxmox-Container – Storefront, Küche,
              Bestellungen und Verwaltung in einer Oberfläche. Dieses Dashboard zeigt dir den
              Zustand deiner Installation in Echtzeit.
            </p>
            <div className="hero-actions">
              <a className="button button-primary" href={`${origin}/`}>
                <StoreIcon />
                Storefront öffnen
                <ArrowIcon />
              </a>
              <a className="button button-ghost" href={`${origin}/admin`}>
                <AdminIcon />
                Admin-Panel
              </a>
            </div>
          </div>

          <aside className="hero-panel">
            <div className="hero-panel-head">
              <span>Installation</span>
              <span className={`mini-state ${allServices ? 'is-ok' : 'is-warn'}`}>
                {allServices ? 'Healthy' : 'Prüfen'}
              </span>
            </div>
            <DetailRow label="Container" value={`CT ${ctid}`} />
            <DetailRow label="Hostname" value={data?.host.hostname ?? '—'} />
            <DetailRow label="IP-Adresse" value={ip} />
            <DetailRow label="TastyIgniter" value={`v${version}`} />
            <DetailRow label="PHP" value={data?.host.php ?? '—'} />
            <div className="hero-url">
              <span>{origin}</span>
              <button type="button" onClick={handleCopy} aria-label="URL kopieren" title="URL kopieren">
                {copied ? <CheckIcon /> : <CopyIcon />}
              </button>
            </div>
            <div className={`signal ${allServices ? 'is-ok' : 'is-warn'}`}>
              <span className="signal-dot" />
              {allServices ? 'Alle Services laufen' : 'Ein oder mehrere Services prüfen'}
            </div>
          </aside>
        </section>

        <section className="quick-grid" aria-label="Schnellzugriff">
          <QuickCard
            href={`${origin}/`}
            icon={<StoreIcon />}
            title="Storefront"
            description="Speisekarte, Bestellung, Reservierung"
          />
          <QuickCard
            href={`${origin}/admin`}
            icon={<AdminIcon />}
            title="Admin-Panel"
            description="Bestellungen, Menü, Standorte"
          />
          <QuickCard
            href={`${origin}/status/api/status`}
            icon={<ActivityIcon />}
            title="Status-API"
            description="Rohdaten als JSON"
            external
          />
        </section>

        <div className="section-head">
          <div>
            <span className="section-kicker">Live-Metriken</span>
            <h2>Was gerade passiert</h2>
          </div>
          <span className="section-meta">
            <ClockIcon width={15} height={15} />
            {lastUpdated ? `Aktualisiert ${lastUpdated.toLocaleTimeString('de-DE')}` : 'Noch keine Daten'}
          </span>
        </div>

        <section className="metrics" aria-label="Kennzahlen">
          <Metric
            icon={<CartIcon />}
            label="Bestellungen"
            value={data?.database.orders ?? '—'}
            hint={data?.database.orders_today != null ? `${data.database.orders_today} heute` : 'Gesamt'}
            tone="warm"
          />
          <Metric
            icon={<UsersIcon />}
            label="Kunden"
            value={data?.database.customers ?? '—'}
            hint="Registrierte Kunden"
          />
          <Metric
            icon={<ShieldIcon />}
            label="Admin-Zugänge"
            value={data?.database.admin_users ?? '—'}
            hint={adminEmail}
          />
          <Metric
            icon={<CpuIcon />}
            label="Arbeitsspeicher"
            value={data ? `${memoryPercent.toFixed(0)} %` : '—'}
            percent={memoryPercent}
            hint={data ? `${formatBytes(data.host.memory.used)} von ${formatBytes(data.host.memory.total)}` : '—'}
            tone="cool"
          />
        </section>

        <div className="content-grid">
          <section className="panel card">
            <div className="panel-head">
              <div>
                <span className="section-kicker">Services</span>
                <h3>Systemd & Runtime</h3>
              </div>
              <span className={`panel-badge ${allServices ? 'is-ok' : 'is-warn'}`}>
                {allServices ? 'alle aktiv' : 'Aufmerksamkeit'}
              </span>
            </div>
            <div className="service-list">
              <ServiceRow label="Web-UI (nginx)" ok={Boolean(data?.services.nginx)} detail={`Port ${data?.app.port ?? 8080}`} />
              <ServiceRow label="PHP-FPM" ok={Boolean(data?.services.php_fpm)} detail={data?.host.php} />
              <ServiceRow label="MariaDB" ok={Boolean(data?.services.mariadb)} detail={data?.database.version ?? undefined} />
              <ServiceRow label="Storefront" ok={Boolean(data?.services.web)} detail={origin} />
            </div>
            <div className="panel-note">
              <LockIcon />
              <span>Alle Dienste laufen lokal. Keine externen Cloud-Dienste oder Telemetrie.</span>
            </div>
          </section>

          <section className="panel card">
            <div className="panel-head">
              <div>
                <span className="section-kicker">System</span>
                <h3>Ressourcen</h3>
              </div>
              <ServerIcon className="panel-icon" />
            </div>

            <div className="resource-row">
              <div className="resource-head">
                <span>
                  <CpuIcon width={16} height={16} /> Speicher
                </span>
                <strong>{data ? `${memoryPercent.toFixed(0)} %` : '—'}</strong>
              </div>
              <div className="progress">
                <span style={{ width: `${Math.min(100, memoryPercent)}%` }} />
              </div>
              <div className="resource-meta">
                {data ? `${formatBytes(data.host.memory.used)} / ${formatBytes(data.host.memory.total)}` : '—'}
              </div>
            </div>

            <div className="resource-row">
              <div className="resource-head">
                <span>
                  <DiskIcon width={16} height={16} /> Disk
                </span>
                <strong>{data ? `${diskPercent.toFixed(0)} %` : '—'}</strong>
              </div>
              <div className={`progress ${diskPercent > 85 ? 'is-danger' : diskPercent > 70 ? 'is-warn' : ''}`}>
                <span style={{ width: `${Math.min(100, diskPercent)}%` }} />
              </div>
              <div className="resource-meta">
                {data ? `${formatBytes(data.host.disk.used)} / ${formatBytes(data.host.disk.total)}` : '—'}
              </div>
            </div>

            <div className="detail-grid">
              <DetailRow label="Uptime" value={data ? formatUptime(data.host.uptime) : '—'} />
              <DetailRow label="Load (1 min)" value={load.toFixed(2)} />
              <DetailRow label="Webserver" value={data?.host.web_server ?? 'nginx'} />
              <DetailRow label="Installiert" value={formatDate(data?.app.installed_at ?? null)} />
            </div>
          </section>
        </div>

        <section className="panel card database-panel">
          <div className="panel-head">
            <div>
              <span className="section-kicker">Datenbank</span>
              <h3>MariaDB · {data?.database.version ?? 'nicht erreichbar'}</h3>
            </div>
            <span className={`panel-badge ${data?.database.ok ? 'is-ok' : 'is-bad'}`}>
              {data?.database.ok ? 'verbunden' : 'getrennt'}
            </span>
          </div>
          <div className="db-grid">
            <div>
              <span>Bestellungen gesamt</span>
              <strong>{data?.database.orders ?? '—'}</strong>
            </div>
            <div>
              <span>Bestellungen heute</span>
              <strong>{data?.database.orders_today ?? '—'}</strong>
            </div>
            <div>
              <span>Kunden</span>
              <strong>{data?.database.customers ?? '—'}</strong>
            </div>
            <div>
              <span>Admin-Benutzer</span>
              <strong>{data?.database.admin_users ?? '—'}</strong>
            </div>
            <div>
              <span>Restaurant</span>
              <strong>{data?.app.restaurant ?? '—'}</strong>
            </div>
            <div>
              <span>Admin-Login</span>
              <strong className="mono">{adminEmail}</strong>
            </div>
          </div>
        </section>

        <footer className="footer">
          <div>
            <span className="footer-mark">TI</span>
            <span>
              TastyIgniter v{version} · lokal auf CT {ctid}
            </span>
          </div>
          <div className="footer-links">
            <a href={`${origin}/`}>Storefront</a>
            <a href={`${origin}/admin`}>Admin</a>
            <a href={`${origin}/status/api/status`} target="_blank" rel="noreferrer">
              API <ExternalIcon width={13} height={13} />
            </a>
          </div>
        </footer>
      </main>
    </div>
  )
}

export default App
