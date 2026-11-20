# syntax=docker/dockerfile:1
ARG LEASH_IMAGE=public.ecr.aws/s5i7k8t3/strongdm/leash:latest
ARG ARTEX_BASE_IMAGE=artex-base:local

FROM ${LEASH_IMAGE} AS leash

FROM ${ARTEX_BASE_IMAGE}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-15 \
        postgresql-client-15 \
        libcap2-bin \
    && rm -rf /var/lib/apt/lists/* /var/lib/postgresql/15/main

COPY --from=leash /usr/local/bin/leash-entry /usr/local/bin/leash-entry
COPY docker/artex-entrypoint.sh /app/artex-entrypoint.sh

RUN chmod 0755 /app/artex-entrypoint.sh /usr/local/bin/leash-entry \
    && mkdir -p /app/pgdata /app/data /app/keys \
    && chown -R postgres:postgres /app/pgdata \
    && chmod 0700 /app/keys

ENV ARTEX_JWT_KEY_DIR=/app/keys

VOLUME ["/app/data", "/app/keys", "/app/pgdata"]
EXPOSE 8787 8788

ENTRYPOINT ["/app/artex-entrypoint.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
