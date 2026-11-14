<?php

declare(strict_types=1);

/**
 * Creates the first TastyIgniter super-admin and seeds restaurant basics.
 *
 * Usage:
 *   php create-admin.php /opt/tastyigniter admin@example.com 'Password1!' "Administrator" "My Restaurant"
 *
 * The script is idempotent: if an admin user already exists it exits 0.
 */

use Igniter\Local\Models\Location;
use Igniter\System\Models\Language;
use Igniter\System\Models\Settings;
use Igniter\User\Facades\AdminAuth;
use Igniter\User\Models\User;
use Igniter\User\Models\UserGroup;
use Igniter\User\Models\UserRole;

$appDir = $argv[1] ?? '/opt/tastyigniter';
$email = $argv[2] ?? '';
$password = $argv[3] ?? '';
$name = $argv[4] ?? 'Administrator';
$restaurant = $argv[5] ?? 'My Restaurant';

if (!is_file($appDir.'/vendor/autoload.php') || !is_file($appDir.'/bootstrap/app.php')) {
    fwrite(STDERR, "TastyIgniter application not found at {$appDir}\n");
    exit(1);
}
if ($email === '' || $password === '') {
    fwrite(STDERR, "Admin e-mail and password are required.\n");
    exit(1);
}

require $appDir.'/vendor/autoload.php';

/** @var \Illuminate\Foundation\Application $app */
$app = require $appDir.'/bootstrap/app.php';
$app->make(\Illuminate\Contracts\Console\Kernel::class)->bootstrap();

if (User::query()->exists()) {
    echo "Admin user already exists – skipping creation.\n";
    exit(0);
}

$role = UserRole::query()->first();
$group = UserGroup::query()->first();
$location = Location::query()->first();
$language = Language::query()->first();

if (!$role || !$group || !$location || !$language) {
    fwrite(STDERR, "TastyIgniter seed data is incomplete (role/group/location/language missing).\n");
    exit(1);
}

try {
    $user = AdminAuth::getProvider()->register([
        'email' => $email,
        'name' => $name,
        'language_id' => $language->language_id,
        'user_role_id' => $role->user_role_id,
        'username' => 'admin',
        'password' => $password,
        'super_user' => true,
        'status' => true,
        'groups' => [$group->user_group_id],
        'locations' => [$location->location_id],
    ], true);

    // User::register() does not assign language_id directly; persist it.
    $user->language_id = $language->language_id;
    $user->save();
} catch (Throwable $e) {
    fwrite(STDERR, "Could not create admin user: ".$e->getMessage()."\n");
    fwrite(STDERR, $e->getTraceAsString()."\n");
    exit(1);
}

try {
    $location->forceFill([
        'location_name' => $restaurant,
        'location_email' => $email,
    ])->save();

    Settings::set([
        'site_name' => $restaurant,
        'site_email' => $email,
        'sender_name' => $restaurant,
        'sender_email' => $email,
    ]);
    Settings::set('ti_setup', 'installed', 'prefs');
} catch (Throwable $e) {
    fwrite(STDERR, "Restaurant settings could not be updated: ".$e->getMessage()."\n");
    // The admin user is the critical part; do not fail the whole installation.
}

echo "Admin user {$email} created.\n";
