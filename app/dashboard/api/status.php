<?php

declare(strict_types=1);

/**
 * Status endpoint for the React dashboard.
 * Served by nginx at /status/api/status via PHP-FPM.
 *
 * This endpoint never exposes credentials; it only returns health and
 * aggregate counters.
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, max-age=0');
header('X-Content-Type-Options: nosniff');

$appDir = getenv('TI_APP_DIR') ?: '/opt/tastyigniter';
$metaFile = getenv('TI_META_FILE') ?: '/opt/tastyigniter-dashboard/install.json';

/**
 * Minimal .env parser (quoted values, comments, no interpolation).
 *
 * @return array<string, string>
 */
function readEnvFile(string $path): array
{
    $result = [];
    if (!is_readable($path)) {
        return $result;
    }
    $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }
        $pos = strpos($line, '=');
        if ($pos === false) {
            continue;
        }
        $key = trim(substr($line, 0, $pos));
        $value = trim(substr($line, $pos + 1));
        if (strlen($value) >= 2 && (
            ($value[0] === '"' && $value[strlen($value) - 1] === '"') ||
            ($value[0] === "'" && $value[strlen($value) - 1] === "'")
        )) {
            $value = substr($value, 1, -1);
        }
        $result[$key] = $value;
    }

    return $result;
}

function readComposerVersion(string $appDir, string $package): ?string
{
    $lockFile = $appDir.'/composer.lock';
    if (!is_readable($lockFile)) {
        return null;
    }
    $lock = json_decode((string)file_get_contents($lockFile), true);
    if (!is_array($lock)) {
        return null;
    }
    foreach (['packages', 'packages-dev'] as $section) {
        foreach (($lock[$section] ?? []) as $pkg) {
            if (($pkg['name'] ?? null) === $package) {
                return ltrim((string)($pkg['version'] ?? ''), 'v') ?: null;
            }
        }
    }

    return null;
}

function readMetadata(string $path): array
{
    if (!is_readable($path)) {
        return [];
    }
    $data = json_decode((string)file_get_contents($path), true);

    return is_array($data) ? $data : [];
}

function memoryInfo(): array
{
    $info = @file('/proc/meminfo', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    $values = [];
    foreach ($info as $line) {
        if (preg_match('/^(\w+):\s+(\d+)\s+kB$/', $line, $m)) {
            $values[$m[1]] = (int)$m[2] * 1024;
        }
    }
    $total = $values['MemTotal'] ?? 0;
    $available = $values['MemAvailable'] ?? ($values['MemFree'] ?? 0);
    $used = max(0, $total - $available);

    return [
        'total' => $total,
        'used' => $used,
        'available' => $available,
        'percent' => $total > 0 ? round($used / $total * 100, 1) : 0,
    ];
}

function uptimeSeconds(): int
{
    $raw = @file_get_contents('/proc/uptime');
    if ($raw === false) {
        return 0;
    }

    $systemUptime = (float)explode(' ', trim($raw))[0];

    // /proc/uptime is host uptime inside a Docker container. pid 1 is the
    // container/systemd init, so its age is the uptime users care about.
    $stat = @file_get_contents('/proc/1/stat');
    if ($stat === false) {
        return (int)floor($systemUptime);
    }

    $close = strrpos($stat, ')');
    if ($close === false) {
        return (int)floor($systemUptime);
    }

    $fields = preg_split('/\s+/', trim(substr($stat, $close + 1))) ?: [];
    $startTicks = isset($fields[19]) ? (float)$fields[19] : 0.0;
    $ticksPerSecond = 100.0;

    $seconds = $startTicks > 0 ? $systemUptime - ($startTicks / $ticksPerSecond) : $systemUptime;

    return max(0, (int)floor($seconds));
}

function phpFpmSocket(): ?string
{
    $sockets = glob('/run/php/php*-fpm.sock') ?: [];
    foreach ($sockets as $socket) {
        if (file_exists($socket)) {
            return $socket;
        }
    }

    return null;
}

function pdoConnection(array $env): ?PDO
{
    $host = $env['DB_HOST'] ?? '127.0.0.1';
    $port = $env['DB_PORT'] ?? '3306';
    $name = $env['DB_DATABASE'] ?? '';
    $user = $env['DB_USERNAME'] ?? '';
    $pass = $env['DB_PASSWORD'] ?? '';

    if ($name === '' || $user === '') {
        return null;
    }

    try {
        return new PDO(
            "mysql:host={$host};port={$port};dbname={$name};charset=utf8mb4",
            $user,
            $pass,
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_TIMEOUT => 3,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            ]
        );
    } catch (Throwable) {
        return null;
    }
}

function scalar(PDO $pdo, string $sql): ?int
{
    try {
        $value = $pdo->query($sql)->fetchColumn();

        return $value === false ? null : (int)$value;
    } catch (Throwable) {
        return null;
    }
}

$env = readEnvFile($appDir.'/.env');
$meta = readMetadata($metaFile);
$pdo = pdoConnection($env);

$db = [
    'ok' => $pdo instanceof PDO,
    'version' => null,
    'orders' => null,
    'orders_today' => null,
    'customers' => null,
    'admin_users' => null,
];

if ($pdo instanceof PDO) {
    try {
        $db['version'] = (string)$pdo->query('SELECT VERSION()')->fetchColumn();
    } catch (Throwable) {
        $db['version'] = null;
    }
    $db['orders'] = scalar($pdo, 'SELECT COUNT(*) FROM orders');
    $db['orders_today'] = scalar($pdo, 'SELECT COUNT(*) FROM orders WHERE created_at >= CURDATE()');
    $db['customers'] = scalar($pdo, 'SELECT COUNT(*) FROM customers');
    $db['admin_users'] = scalar($pdo, 'SELECT COUNT(*) FROM admin_users');
}

$mem = memoryInfo();
$diskTotal = @disk_total_space($appDir) ?: 0;
$diskFree = @disk_free_space($appDir) ?: 0;
$diskUsed = max(0, $diskTotal - $diskFree);
$uptime = uptimeSeconds();
$load = function_exists('sys_getloadavg') ? (sys_getloadavg() ?: [0, 0, 0]) : [0, 0, 0];

$services = [
    'web' => true,
    'php_fpm' => phpFpmSocket() !== null,
    'nginx' => is_file('/run/nginx.pid') || is_dir('/run/nginx'),
    'mariadb' => $db['ok'],
];

$healthy = $db['ok'] && $services['php_fpm'] && $services['nginx'];

$payload = [
    'ok' => $healthy,
    'timestamp' => gmdate('c'),
    'app' => [
        'name' => 'TastyIgniter',
        'version' => readComposerVersion($appDir, 'tastyigniter/core') ?? ($meta['version'] ?? null),
        'restaurant' => $meta['restaurant'] ?? null,
        'installed_at' => $meta['installed_at'] ?? null,
        'ctid' => $meta['ctid'] ?? null,
        'admin_email' => $meta['admin_email'] ?? null,
        'port' => isset($meta['port']) ? (int)$meta['port'] : (int)($_SERVER['SERVER_PORT'] ?? 8080),
    ],
    'host' => [
        'hostname' => gethostname() ?: 'tastyigniter',
        'ip' => $_SERVER['SERVER_ADDR'] ?? (gethostbyname(gethostname() ?: 'localhost')),
        'php' => PHP_VERSION,
        'web_server' => $_SERVER['SERVER_SOFTWARE'] ?? 'nginx',
        'uptime' => $uptime,
        'load' => array_map(static fn($v): float => round((float)$v, 2), $load),
        'memory' => $mem,
        'disk' => [
            'total' => $diskTotal,
            'used' => $diskUsed,
            'free' => $diskFree,
            'percent' => $diskTotal > 0 ? round($diskUsed / $diskTotal * 100, 1) : 0,
        ],
    ],
    'database' => $db,
    'services' => $services,
];

http_response_code(200);
echo json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
