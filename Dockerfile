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

ENV PATH="/code/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8443

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

# The upstream python image ships a pip wheel inside ensurepip/_bundled that the
# scanner flags once a security release supersedes it. Replace both the bundled
# bootstrap wheel and the installed pip with the current patched release, so the
# image carries no stale pip artifact.
ARG PIP_VERSION=26.2.2
RUN set -eux; \
    py=/usr/local/bin/python3; \
    site="$("$py" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"; \
    if ! "$py" -m pip --version >/dev/null 2>&1; then "$py" -m ensurepip --upgrade; fi; \
    "$py" -m pip install --no-cache-dir --upgrade "pip==${PIP_VERSION}"; \
    "$py" -m pip download --no-cache-dir --no-deps --dest /tmp/pip-wheel "pip==${PIP_VERSION}"; \
    bundled="$("$py" -c 'import ensurepip, os; print(os.path.join(os.path.dirname(ensurepip.__file__), "_bundled"))')"; \
    rm -f "$bundled"/pip-*.whl; \
    cp /tmp/pip-wheel/pip-*.whl "$bundled"/; \
    rm -rf /tmp/pip-wheel; \
    "$py" -m pip --version; \
    ls "$bundled"; \
    ls -d "$site"/pip-*.dist-info

COPY cli_wrapper.sh /usr/bin/pasarguard-cli
RUN chmod +x /usr/bin/pasarguard-cli

COPY tui_wrapper.sh /usr/bin/pasarguard-tui
RUN chmod +x /usr/bin/pasarguard-tui

# Copy healthcheck script
COPY healthcheck.sh /code/healthcheck.sh
RUN chmod +x /code/healthcheck.sh

RUN chmod +x /code/start.sh

ENTRYPOINT ["/code/start.sh"]
