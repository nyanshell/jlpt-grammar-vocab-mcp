# syntax=docker/dockerfile:1

# --- build stage ----------------------------------------------------------
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Stable release tarballs are kept forever on ziglang.org; the ARG remains
# overridable (--build-arg ZIG_URL=...) for mirrors or version bumps.
ARG ZIG_VERSION=0.16.0
ARG ZIG_URL=https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz
RUN curl -fL "$ZIG_URL" | tar -xJ -C /opt && mv /opt/zig-* /opt/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
# Fetches the pinned libduckdb release zip via build.zig.zon.
RUN /opt/zig/zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu

# The package manager extracts dependencies into ./zig-pkg (or the global
# cache on older builds); stage libduckdb.so for the runtime image.
RUN cp "$(find /src/zig-pkg /root/.cache/zig -name libduckdb.so 2>/dev/null | head -1)" /src/libduckdb.so

# --- runtime stage --------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/libduckdb.so /usr/local/lib/
COPY --from=build /src/zig-out/bin/jlpt-mcp-server /usr/local/bin/
RUN ldconfig \
    && useradd --system --uid 10001 --home-dir /data app \
    && mkdir -p /data && chown app /data

USER app
VOLUME /data
ENV PORT=8080 \
    DB_PATH=/data/jlpt.duckdb
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s CMD bash -c \
    'exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 && grep -q " 200 " <&3'

CMD ["jlpt-mcp-server"]
