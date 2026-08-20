#!/bin/bash
set -eu

mkdir -p /var/www/bretunetech/downloads
CONF=/etc/nginx/sites-available/bretunetech
BACKUP="${CONF}.bak-bretune-transfer-$(date +%Y%m%d-%H%M%S)"
cp "$CONF" "$BACKUP"

if ! grep -q 'location /downloads/' "$CONF"; then
  python3 <<'PY'
from pathlib import Path
p = Path('/etc/nginx/sites-available/bretunetech')
text = p.read_text()
block = """
    location /downloads/ {
        alias /var/www/bretunetech/downloads/;
        index index.html;
        autoindex off;
    }
"""
needle = "    client_max_body_size 20M;\n"
if needle not in text:
    raise SystemExit('Could not find insertion point in nginx config')
text = text.replace(needle, needle + block + "\n")
p.write_text(text)
print('Inserted /downloads/ location block')
PY
fi

nginx -t
systemctl reload nginx
echo NGINX_OK
