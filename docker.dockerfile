# syntax=docker/dockerfile:1
FROM debian:trixie-slim AS build
# The folders land over /usr of the sandbox: a fixed mode keeps the umask of the checkout out of them.
COPY --chmod=0755 files/ /out/

FROM scratch
COPY --from=build /out /
