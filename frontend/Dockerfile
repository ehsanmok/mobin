FROM nginx:alpine

# Copy frontend HTML to nginx default serve directory
COPY src/index.html /usr/share/nginx/html/index.html

# nginx config: serve all paths as index.html for SPA-style routing
RUN printf 'server {\n\
    listen 80;\n\
    root /usr/share/nginx/html;\n\
    index index.html;\n\
    # Return index.html for /paste/* paths (client-side routing)\n\
    location /paste/ {\n\
        try_files $uri /index.html;\n\
    }\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
    gzip on;\n\
    gzip_types text/html text/css application/javascript;\n\
}\n' > /etc/nginx/conf.d/default.conf

EXPOSE 80
