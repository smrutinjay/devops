server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # Static files served locally.
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Everything under /api/ is proxied to the App tier's private IP.
    # Note: we strip nothing here - the API listens on /health and /items
    # directly, so the frontend calls /api/items and we forward the
    # trailing path onward as /items.
    location /api/ {
        proxy_pass http://${app_private_ip}:${app_port}/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
