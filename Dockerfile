FROM golang:1.22-bookworm@sha256:1f298b0c9fecdf504389a0329236f948cc04a566a2bb32337207cbaaa2f8177c AS builder
WORKDIR /build
# Copy every Go source file, not just main.go: the sandbox hardening lives in
# harden.go (portable) plus harden_unix.go / harden_other.go (per-platform).
COPY go.mod ./
COPY main.go harden.go harden_unix.go harden_other.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service .

# Haskell (GHC), OCaml, Common Lisp (SBCL), Prolog (SWI-Prolog), Scheme and
# Racket, all installed from Debian's repositories onto the gcc base, so they
# share one image the way the scripting interpreters share theirs. Scheme runs
# on the Racket interpreter, which is what the registry entry asks for.
FROM gcc:13.2-bookworm
LABEL org.opencontainers.image.title="codhoot-functional-service"
LABEL org.opencontainers.image.description="Hardened functional execution sandbox (haskell, ocaml, commonlisp, prolog, racket, scheme)"
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ghc \
        ocaml-nox \
        sbcl \
        swi-prolog-nox \
        racket; \
    rm -f /usr/bin/curl /usr/bin/wget /usr/local/bin/curl /usr/local/bin/wget; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ocamlopt is versioned in Debian's layout; expose a stable name so a registry
# entry never encodes a version suffix.
RUN set -eux; \
    ln -sf "$(command -v ocamlfind || command -v ocamlopt)" /usr/local/bin/ocamlopt; \
    ln -sf /usr/bin/racket /usr/local/bin/racket

# Smoke test each toolchain at build time: a compiler that is present but broken
# is worse than a failed build, and ghc, ocamlopt and swipl all leave first-run
# caches under HOME that would otherwise be written as root here.
RUN set -eux; \
    printf 'main :: IO ()\nmain = putStrLn "haskell ok"\n' > /tmp/Smoke.hs; \
    ghc -O0 -o /tmp/smoke-hs /tmp/Smoke.hs; \
    /tmp/smoke-hs; \
    printf 'let () = print_endline "ocaml ok";;\n' > /tmp/smoke.ml; \
    ocamlopt -o /tmp/smoke-ml /tmp/smoke.ml; \
    /tmp/smoke-ml; \
    sbcl --non-interactive --eval '(require :sbcl)' --eval '(format t "lisp ok~%")' --quit; \
    swipl -q -g halt -f /dev/null; \
    printf '(displayln "racket ok")\n' > /tmp/smoke.rkt; \
    racket /tmp/smoke.rkt; \
    rm -f /tmp/Smoke.hs /tmp/smoke.* /tmp/Smoke.hi /tmp/Smoke.o

WORKDIR /app
COPY --from=builder /out/service /app/service
RUN chmod 0755 /app/service && rm -f go.mod main.go harden.go harden_unix.go harden_other.go

# --- sandbox identity pool ---------------------------------------------------
# Each in-flight job is dropped to a DISTINCT uid by the service. That is what
# makes a job's 0700 working directory genuinely private: with one shared uid every
# job could read every other job's source and rewrite it before it ran.
# Runtimes that resolve getpwuid need real passwd entries, written directly here
# rather than with 32 useradd calls.
# shellcheck disable=SC2016
RUN set -eu; \
    i=0; \
    while [ "$i" -lt 32 ]; do \
      u=$((2000 + i)); \
      printf 'codhoot-s%d:x:%d:%d:codhoot sandbox:/nonexistent:/sbin/nologin\n' "$i" "$u" "$u" >> /tmp/pool; \
      i=$((i + 1)); \
    done; \
    cat /tmp/pool >> /etc/passwd; \
    rm -f /tmp/pool; \
    mkdir -p /tmp/codhoot-cache; \
    chmod 0755 /tmp/codhoot-cache

# The service itself runs as root on purpose: it must chown each job directory to
# that job's uid and setuid the compiler/runtime child. The security boundary is
# the child, not the service.
#
# There is deliberately no HEALTHCHECK here: it would require curl or wget in the
# image, and Render already health-checks /health over HTTP.
ENV PORT=8081
EXPOSE 8081
CMD ["/app/service"]