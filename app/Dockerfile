# Application de démonstration : nginx non-root qui écoute sur 8080 et expose
# /healthz pour les probes. À remplacer par les vrais microservices.
#
# Branche "stable" nginx (numéro pair) + minor Alpine explicite : un tag de
# branche nginx arrêtée (ex. 1.29) n'est plus reconstruit et accumule des CVE
# corrigées en amont — c'est ce qui faisait échouer le scan Trivy.
FROM nginxinc/nginx-unprivileged:1.30-alpine3.24

# Récupère les correctifs publiés entre deux rebuilds de l'image de base,
# pour ne pas bloquer la CI sur une CVE déjà corrigée dans les dépôts Alpine.
USER root
RUN apk upgrade --no-cache

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

USER 101
EXPOSE 8080
