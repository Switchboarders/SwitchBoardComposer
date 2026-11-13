<?php
// Run by install.sh inside sb_php-fpm (as www-data), with a first line defining $cfg (base64 JSON, so no
// secret appears in a process list). Goes through SwitchBoard's own DatabaseManager, so secrets are
// encrypted with APP_ENCRYPTION_KEY exactly as when an admin saves the "SwitchBoard Chat" page.
//
// $cfg: action = "wire"   -> store SBChat address + admin token + MAS url/client on the admin account
//       action = "status" -> print what is configured (no secret), for verify.sh
//       admin_username, sbchat_url, sbchat_token, mas_url, mas_client_id, mas_secret
if (PHP_SAPI !== 'cli') { exit(1); }
$base = '/var/www/html/SwitchBoard/SwitchBoard/src/';
require_once $base.'commun/lesconstantes.php';
ini_set('display_errors', 'stderr');

function out(array $a): void { echo "SBWIRE ".json_encode($a)."\n"; }

ob_start();   // DatabaseManager echoes HTML messages: keep them out of the result line
$db = new DatabaseManager();
$admin = null;
foreach (($db->getuserslist() ?: []) as $u) {
	if (isset($u['username']) && strcasecmp($u['username'], $cfg['admin_username']) === 0) { $admin = $u; break; }
}
if ($admin === null) { ob_end_clean(); out(['ok' => false, 'error' => 'admin account not found']); exit(2); }
$id = intval($admin['iduser']);
// CLI has no web session: act as that admin, like the portal does after login
$_SESSION = ['authenticated' => true, 'iduser' => $id];

if ($cfg['action'] === 'wire') {
	$info = $db->getSbchatinfobyId($id) ?: [];
	$db->setsbchatinfobyuserid($id, [
		'sbchatapitoken'      => $cfg['sbchat_token'],
		'sbchatcalendarurl'   => $info['sbchatcalendarurl'] ?? '',
		'sbchatserveraddress' => rtrim($cfg['sbchat_url'], '/'),
		'masurl'              => rtrim($cfg['mas_url'], '/'),
		'masclientid'         => $cfg['mas_client_id'],
		'massecret'           => $cfg['mas_secret'],
	]);
	ob_end_clean();
	out(['ok' => true, 'iduser' => $id]);
	exit(0);
}

// mas_user: SwitchBoard's "Gérer les utilisateurs du serveur Matrix" path (MAS admin API with the
// admin's stored client): create the account if missing, then set its password.
if ($cfg['action'] === 'mas_user') {
	$info = $db->getSbchatinfobyId($id) ?: [];
	$client = new ClientSwitchBoardChat($info['sbchatserveraddress'] ?? '');
	$created = $client->get_mas_user_id($cfg['username']) ? 'existed' : ($client->add_mas_user($cfg['username']) ? 'created' : 'failed');
	$pw = $created !== 'failed' && $client->set_mas_user_password($cfg['username'], $cfg['password']);
	ob_end_clean();
	out(['ok' => $created !== 'failed' && $pw, 'account' => $created, 'password_set' => (bool)$pw]);
	exit(0);
}

// macro: SwitchBoard's macro editor path (SBChat update_macro, then list_macros) for a call center token
if ($cfg['action'] === 'macro') {
	$info = $db->getSbchatinfobyId($id) ?: [];
	$client = new ClientSwitchBoardChat($info['sbchatserveraddress'] ?? '');
	$existing = null;
	foreach (($client->list_macros($cfg['token']) ?: []) as $m) {
		if (($m['macro_name'] ?? '') === $cfg['name']) { $existing = $m; break; }
	}
	$client->update_macro($cfg['token'], [
		'id_macro' => (string)($existing['id_macro'] ?? -1),
		'macro_name' => $cfg['name'], 'macro_text' => $cfg['text'], 'macro_tags' => $cfg['tags'] ?? '',
	]);
	$found = false;
	foreach (($client->list_macros($cfg['token']) ?: []) as $m) {
		if (($m['macro_name'] ?? '') === $cfg['name'] && ($m['macro_text'] ?? '') === $cfg['text']) { $found = true; }
	}
	ob_end_clean();
	out(['ok' => $found]);
	exit(0);
}

// agreement_list / agreement_send / notify: SwitchBoard's agreement page and its message to respondents
if (in_array($cfg['action'], ['agreement_list', 'agreement_send', 'notify'], true)) {
	$info = $db->getSbchatinfobyId($id) ?: [];
	$client = new ClientSwitchBoardChat($info['sbchatserveraddress'] ?? '');
	if ($cfg['action'] === 'agreement_list') {
		$list = $client->list_agreement_signatures($cfg['token']);
		$people = [];
		foreach (($list['respondents'] ?? []) as $p) {
			$people[$p['respondent']] = ['signed_current' => (bool)($p['signed_current'] ?? false),
				'typed_name' => $p['latest']['typed_name'] ?? null];
		}
		$result = ['ok' => is_array($list), 'configured' => (bool)($list['configured'] ?? false),
			'version' => $list['version'] ?? null, 'sha256_len' => strlen((string)($list['sha256'] ?? '')), 'people' => $people];
	} elseif ($cfg['action'] === 'agreement_send') {
		[$ok, $sent] = $client->send_agreement($cfg['token']);
		$result = ['ok' => (bool)$ok, 'sent' => $sent];
	} else {
		$r = $client->send_message_to_respondents($cfg['token'], $cfg['respondents'], $cfg['message']);
		$result = ['ok' => is_array($r) && str_starts_with((string)($r['querystatus'] ?? ''), 'Success'), 'status' => $r['querystatus'] ?? null];
	}
	ob_end_clean();
	out($result);
	exit(0);
}

// status: is the wiring there, and does SwitchBoard reach SBChat and MAS with it?
$info = $db->getSbchatinfobyId($id) ?: [];
$client = new ClientSwitchBoardChat($info['sbchatserveraddress'] ?? '');
// list_macros: an array (possibly empty) when SBChat accepted the token, null otherwise
$macros = !empty($info['sbchatapitoken']) ? $client->list_macros($info['sbchatapitoken']) : null;
// list_mas_users prints the users as JSON inside <pre> (it returns nothing): capture and parse it
ob_start();
$client->list_mas_users();
$printed = ob_get_clean();
$users = json_decode(html_entity_decode(strip_tags((string)$printed)), true);
$server = $client->get_matrix_server_name();
ob_end_clean();
out([
	'ok' => true,
	'iduser' => $id,
	'sbchat_url' => $info['sbchatserveraddress'] ?? '',
	'mas_url' => $info['masurl'] ?? '',
	'has_token' => !empty($info['sbchatapitoken']),
	'sbchat_api' => is_array($macros),
	'mas_api' => is_array($users) && $users !== [],
	'matrix_server_name' => $server,
]);
