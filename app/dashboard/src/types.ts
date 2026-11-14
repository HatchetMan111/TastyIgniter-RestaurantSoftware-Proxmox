export interface AppInfo {
  name: string
  version: string | null
  restaurant: string | null
  installed_at: string | null
  ctid: string | null
  admin_email: string | null
  port: number
}

export interface MemoryInfo {
  total: number
  used: number
  available: number
  percent: number
}

export interface DiskInfo {
  total: number
  used: number
  free: number
  percent: number
}

export interface HostInfo {
  hostname: string
  ip: string
  php: string
  web_server: string
  uptime: number
  load: number[]
  memory: MemoryInfo
  disk: DiskInfo
}

export interface DatabaseInfo {
  ok: boolean
  version: string | null
  orders: number | null
  orders_today: number | null
  customers: number | null
  admin_users: number | null
}

export interface ServicesInfo {
  web: boolean
  php_fpm: boolean
  nginx: boolean
  mariadb: boolean
}

export interface StatusPayload {
  ok: boolean
  timestamp: string
  app: AppInfo
  host: HostInfo
  database: DatabaseInfo
  services: ServicesInfo
}
