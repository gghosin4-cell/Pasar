ARG PYTHON_VERSION=3.14
ARG DEBIAN_RELEASE=trixie

FROM ghcr.io/astral-sh/uv:python$PYTHON_VERSION-$DEBIAN_RELEASE-slim AS builder
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    python3-dev \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

ENV UV_PYTHON_DOWNLOADS=0

WORKDIR /build
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev
ADD . /build
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev


FROM python:$PYTHON_VERSION-slim-$DEBIAN_RELEASE

EXPOSE 8443

COPY --from=builder /build /code
WORKDIR /code

ENV PATH="/code/.venv/bin:$PATH"

# Apply the distribution's latest security updates and keep the runtime trust
# store explicit. Outbound notification clients use the trust store without
# replacing Python's process-wide SSLContext. The runtime does not install curl:
# the loopback health check uses the Python standard library instead.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY cli_wrapper.sh /usr/bin/pasarguard-cli
RUN chmod +x /usr/bin/pasarguard-cli

COPY tui_wrapper.sh /usr/bin/pasarguard-tui
RUN chmod +x /usr/bin/pasarguard-tui

# Copy healthcheck script
COPY healthcheck.sh /code/healthcheck.sh
RUN chmod +x /code/healthcheck.sh

RUN chmod +x /code/start.sh

ENTRYPOINT ["/code/start.sh"]
