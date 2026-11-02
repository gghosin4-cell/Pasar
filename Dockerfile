# PasarGuard container image.
#
# Two stages on a musl/Alpine base:
#   * the previous Debian slim runtime inherited glibc/acl/attr packages that
#     Debian ships without a fixed version, so the image scanner blocked the
#     rollout with no possible upgrade path;
#   * Alpine keeps the same Python runtime and wheels (every locked dependency
#     publishes a musllinux cp314 wheel) while removing those packages entirely.

ARG PYTHON_VERSION=3.14
ARG ALPINE_VERSION=3.22
ARG UV_VERSION=0.11.8

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv


FROM python:${PYTHON_VERSION}-alpine${ALPINE_VERSION} AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0

# Compiler toolchain lives only in the builder stage; the runtime image never
# contains it. Alpine dependencies are refreshed so cached layers pick up
# patched packages.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        build-base \
        libffi-dev \
        openssl-dev

COPY --from=uv /uv /uvx /bin/

# The virtualenv is created at its final runtime path so that interpreter and
# console-script shebangs stay valid once the layer is copied into the runtime
# stage.
WORKDIR /code
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev
ADD . /code
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev


FROM python:${PYTHON_VERSION}-alpine${ALPINE_VERSION}

EXPOSE 8443

COPY --from=builder /code /code
WORKDIR /code

ENV PATH="/code/.venv/bin:$PATH"

# Refresh the distribution's security updates and install only what the
# runtime scripts need: bash for start/healthcheck/wrapper scripts, the trust
# store for outbound TLS, and timezone data for local time rendering. The
# image intentionally ships no curl / HTTP client tooling.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        bash \
        ca-certificates \
        tzdata \
    && update-ca-certificates

COPY cli_wrapper.sh /usr/bin/pasarguard-cli
RUN chmod +x /usr/bin/pasarguard-cli

COPY tui_wrapper.sh /usr/bin/pasarguard-tui
RUN chmod +x /usr/bin/pasarguard-tui

# Copy healthcheck script
COPY healthcheck.sh /code/healthcheck.sh
RUN chmod +x /code/healthcheck.sh

RUN chmod +x /code/start.sh

ENTRYPOINT ["/code/start.sh"]
