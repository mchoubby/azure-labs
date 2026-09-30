# Application de démonstration : nginx non-root qui écoute sur 8080 et expose
# /healthz pour les probes. À remplacer par les vrais microservices.
FROM nginxinc/nginx-unprivileged:1.29-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

USER 101
EXPOSE 8080
