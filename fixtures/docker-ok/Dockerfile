# Multi-stage image with a build argument: exercises docker-build's target, build-args and smoke inputs.
FROM alpine:3.21 AS base
ARG GREETING=hello
RUN echo "$GREETING" > /greeting

FROM base AS production
CMD ["cat", "/greeting"]

FROM base AS debug
CMD ["sh"]
