FROM ghcr.io/prefix-dev/pixi:0.66.0 AS base

WORKDIR /app

# Copy pixi manifest and lock file first for layer caching
COPY pixi.toml ./
RUN pixi install

# Copy test files
COPY . .

# Default: run headless load test
# Override CMD for integration tests:
#   docker run mobin-integtest pixi run test
ENV MOBIN_HOST=http://backend:8080

ENTRYPOINT ["pixi", "run"]
CMD ["load-test"]
