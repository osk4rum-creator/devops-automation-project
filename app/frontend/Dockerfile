# Official nginx image variant that runs as non-root (UID 101) on port 8080.
# Pinned version, never :latest.
FROM nginxinc/nginx-unprivileged:1.30.6-alpine

# Apply OS security patches released after the base image was built
# (found by Trivy). Needs root only for this build step.
USER root
RUN apk upgrade --no-cache
USER 101

# NGINX_ENTRYPOINT_LOCAL_RESOLVERS: entrypoint exports the DNS server as
#   NGINX_LOCAL_RESOLVERS for the "resolver" line in the template.
# BACKEND_HOST: where /api/ is proxied. Kubernetes overrides it with the full
#   Service DNS name (backend.<namespace>.svc.cluster.local).
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    BACKEND_HOST=backend

COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080
