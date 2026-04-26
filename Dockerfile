ARG OS_VERSION

FROM oraclelinux:${OS_VERSION:-10}-slim

ARG IMAGE_AUTHOR='lightvik@yandex.ru'

LABEL org.opencontainers.image.authors="${IMAGE_AUTHOR}"

RUN microdnf install -y xorriso isomd5sum && \
    microdnf clean all && \
    rm -rf /var/cache/yum /var/cache/dnf

COPY --chmod=755 --chown=root:root entrypoint.sh /entrypoint.sh

WORKDIR /workdir

ENTRYPOINT ["/entrypoint.sh"]
