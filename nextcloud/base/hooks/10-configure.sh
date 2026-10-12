#!/bin/sh
# Runs on every container start, after install/upgrade, via the image's
# /docker-entrypoint-hooks.d/before-starting hook folder. The entrypoint executes it
# through `su -p www-data`, so occ runs as the right user and the env is preserved.
# Must be named *.sh and be executable (see defaultMode in deployment.yaml).
# Shipped via configMapGenerator: editing this file changes the ConfigMap name hash,
# which rolls the Deployment so the hook actually re-runs.
set -eu

occ() { php -f /var/www/html/occ "$@"; }

if ! occ status | grep -q 'installed: true'; then
  echo '==> not installed yet, skipping configuration hook'
  exit 0
fi

# The entrypoint only sets trusted domains right after a fresh install; keep them
# in sync on every start so env changes (or an interrupted install) are applied.
i=1
for domain in ${NEXTCLOUD_TRUSTED_DOMAINS:-}; do
  occ config:system:set trusted_domains "$i" --value="$domain"
  i=$((i + 1))
done

occ config:system:set default_phone_region --value=NL
occ config:system:set maintenance_window_start --type=integer --value=1
occ config:app:set files default_quota --value='1 GB'

# No example files for new users.
occ config:system:set skeletondirectory --value=''
occ config:system:set templatedirectory --value=''

occ app:install richdocuments || occ app:enable richdocuments
occ config:app:set richdocuments wopi_allowlist --value='10.0.0.0/8'

i=0
until occ richdocuments:activate-config --wopi-url='http://collabora:9980' --callback-url='http://nextcloud'; do
  i=$((i + 1))
  if [ "$i" -ge 12 ]; then
    echo '==> Collabora unreachable, Nextcloud Office stays unavailable until the next discovery fetch'
    break
  fi
  sleep 5
done

# Team folders; scripts/team-folders.sh creates one per FILES-datas-<share> group pair.
occ app:install groupfolders || occ app:enable groupfolders
# Quota for team folders left on "Default" (all new ones); resolved on read, so changing
# it applies to every such folder. Per-folder overrides in the admin UI still win.
occ config:system:set groupfolders.quota.default --type=integer --value=2147483648 # 2 GiB

if [ -z "${OIDC_CLIENT_SECRET:-}" ] || [ "${OIDC_CLIENT_SECRET}" = 'REPLACE_ME' ]; then
  echo '==> OIDC_CLIENT_SECRET unset, skipping user_oidc configuration'
  exit 0
fi

occ app:install user_oidc || occ app:enable user_oidc

# Idempotent upsert; re-running also flushes the provider JWKS cache.
# --clientsecret-env keeps the secret out of the process list.
# Only the FILES-datas-<share>-RO/-RW permission groups are synced (they drive the team
# folders); with the login restriction, users without any of them cannot log in.
occ user_oidc:provider GEWIS \
  --clientid="$OIDC_CLIENT_ID" \
  --clientsecret-env='OIDC_CLIENT_SECRET' \
  --discoveryuri='https://auth.gewis.nl/realms/GEWISWG/.well-known/openid-configuration' \
  --scope='openid profile email' \
  --mapping-uid='preferred_username' \
  --mapping-email='email' \
  --mapping-display-name='name' \
  --mapping-groups='groups' \
  --group-provisioning=1 \
  --group-whitelist-regex='/^FILES-datas-.+-R[OW]$/' \
  --group-restrict-login-to-whitelist=1 \
  --unique-uid=0 \
  --check-bearer=0

# Single backend -> send users straight to Keycloak.
# Break-glass local login stays reachable at /login?direct=1.
occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends

occ db:add-missing-indices
