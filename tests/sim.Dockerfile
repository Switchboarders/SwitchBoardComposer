# respondent-sim (SwitchBoardChat tests/e2e/respondent-sim: one real Matrix device with end-to-end
# encryption) + Python, to run tests/roundtrip.py on the "web" network. Built with SwitchBoardChat's
# tests/e2e as context (its .dockerignore excludes tests/): docker build -f tests/sim.Dockerfile <sbchat>/tests/e2e
FROM rust:1.96.1-slim-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY respondent-sim/ ./
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    cargo build --release && cp target/release/respondent-sim /respondent-sim

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates python3 libssl3 libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /respondent-sim /usr/local/bin/respondent-sim
COPY lib.py /e2e/lib.py
