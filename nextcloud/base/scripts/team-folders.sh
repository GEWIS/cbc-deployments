#!/bin/sh
# Ensures every file share defined by the Keycloak groups FILES-datas-<share>-RO and
# FILES-datas-<share>-RW has a team folder named <share>: the -RO group gets read and
# the -RW group read, write, share and delete. The admin group gets read and share on
# every team folder, as only admins may create shares (see hooks/10-configure.sh).
# user_oidc creates the FILES-datas groups on login; the team-folders sidecar in
# deployment.yaml runs this script every minute.
# Only missing folders and group assignments are added, so folders can be renamed or
# have their permissions changed in the admin UI.
set -eu

occ() { php -f /var/www/html/occ "$@"; }

# Skip quietly while Nextcloud is being installed, upgraded or in maintenance mode.
ready=$(php -r '
  $s = json_decode($argv[1], true);
  echo ($s["installed"] ?? false) && !($s["maintenance"] ?? true) && !($s["needsDbUpgrade"] ?? true) ? 1 : 0;
' "$(occ status --output=json)")
[ "$ready" = 1 ] || exit 0

groups=$(occ group:list 'FILES-datas-' --limit=10000 --output=json)
folders=$(occ groupfolders:list --output=json)

# One tab-separated line per missing group assignment: "<folder id or -> <share> <gid>
# <permissions>". A share's folder is the one already holding one of its groups, else
# an unassigned folder (the admin group aside) with the share's name, e.g. left over
# from an interrupted run. A name clash with a folder owned by other groups is
# reported, not taken over. Every folder, whether or not it belongs to a share, also
# gets the admin group.
todo=$(php -r '
  $shares = [];
  foreach (array_keys(json_decode($argv[1], true)) as $gid) {
    $gid = (string)$gid;
    if (preg_match("/^FILES-datas-(.+)-(RO|RW)\$/", $gid, $m)) {
      $shares[$m[1]][$gid] = $m[2] === "RW" ? "read write share delete" : "read";
    }
  }
  ksort($shares);
  $folders = json_decode($argv[2], true);
  $admin = ["admin" => "read share"];
  $done = [];
  foreach ($shares as $share => $wanted) {
    $folder = null;
    foreach ($folders as $f) {
      if (array_intersect_key($f["groups_list"], $wanted) !== []) {
        $folder = $f;
        break;
      }
    }
    if ($folder === null) {
      foreach ($folders as $f) {
        if ($f["mountPoint"] !== $share) {
          continue;
        }
        if (array_diff_key($f["groups_list"], $admin) !== []) {
          fwrite(STDERR, "==> team folder \"$share\" belongs to other groups, not assigning it to " . implode(", ", array_keys($wanted)) . "\n");
          continue 2;
        }
        $folder = $f;
      }
    }
    foreach ($wanted + $admin as $gid => $permissions) {
      if (!isset($folder["groups_list"][$gid])) {
        echo $folder["id"] ?? "-", "\t$share\t$gid\t$permissions\n";
      }
    }
    if ($folder !== null) {
      $done[$folder["id"]] = true;
    }
  }
  foreach ($folders as $f) {
    if (!isset($done[$f["id"]]) && !isset($f["groups_list"]["admin"])) {
      echo $f["id"], "\t", $f["mountPoint"], "\tadmin\t", $admin["admin"], "\n";
    }
  }
' "$groups" "$folders")

tab=$(printf '\t')
printf '%s\n' "$todo" | while IFS=$tab read -r id share gid permissions; do
  [ -n "$gid" ] || continue
  if [ "$id" = - ]; then
    # Lines are grouped by share: the RO and RW group of a new share get one folder.
    if [ "$share" != "${created_share:-}" ]; then
      created_id=$(occ groupfolders:create "$share")
      created_share=$share
    fi
    id=$created_id
  fi
  # shellcheck disable=SC2086 # $permissions is a space-separated list of arguments
  occ groupfolders:group "$id" "$gid" $permissions
  echo "==> team folder $id ($share): \"$gid\" gets $permissions"
done
