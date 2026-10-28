#!/bin/sh
# OHIF container entrypoint (replaces the image's /usr/src/entrypoint.sh).
# Renders the nginx config with the Orthanc credentials from the environment
# (docker/.env), so they live only in the server-side proxy, never in the
# browser-visible app-config.js. Then starts nginx.
set -e
if [ -z "$ORTHANC_PASSWORD" ]; then
    echo "ERROR: ORTHANC_PASSWORD is empty — set it in docker/.env" >&2
    exit 1
fi
AUTH=$(printf '%s:%s' "${ORTHANC_USERNAME:-admin}" "$ORTHANC_PASSWORD" | base64 | tr -d '\n')
sed "s|__ORTHANC_BASIC_AUTH__|${AUTH}|" /usr/src/moonai/default.conf.template \
    | envsubst '${PORT}:${PUBLIC_URL}' > /etc/nginx/conf.d/default.conf
# The image serves pre-compressed files (gzip_static); refresh the .gz of our
# mounted app-config.js so the stock config is never served instead.
CFG=/usr/share/nginx/html${PUBLIC_URL:-/}app-config.js
if [ -s "$CFG" ]; then
    rm -f "${CFG}.gz"
    gzip -c "$CFG" > "${CFG}.gz"
fi
exec "$@"
