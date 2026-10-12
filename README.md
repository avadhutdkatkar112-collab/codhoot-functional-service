# codhoot-functional-service

Execution server for CodHoot's **functional and logic** languages — Haskell,
OCaml, Common Lisp, Prolog, Scheme and Racket. All six install from Debian's
bookworm repositories onto one gcc base, which is what
`codhoot-runner-functional` does for the local docker path.

## Why this service exists

CodHoot's single-language services each hard-code one compiler and one entry
filename, so they cannot be reused for a language they were not built for. The
backend routes these languages here through the shared runtime image URL:

```
COMPILER_IMAGE_FUNCTIONAL_SERVICE_URL=https://codhoot-functional-service-<suffix>.onrender.com
```

One variable covers all six languages. The mapping is read at backend startup,
so set the variable and restart the backend service.

## Contract

`POST /compile`, signed with
`HMAC-SHA256(secret, timestamp + path + hex(sha256(body)))` keyed by
`CODHOOT_INTERNAL_SECRET`, headers `X-CodHoot-Timestamp` (unix seconds) and
`X-CodHoot-Signature` (hex digest). Unsigned, tampered or stale requests get
401.

```json
{ "language": "haskell", "source": "main :: IO ()\nmain = putStrLn \"hi\"\n" }
```

`GET /health` and `GET /health/live` are open — Render's health check and the
keepalive pinger must never need a signature.

| language   | entry file | compile                        | run                          |
|------------|------------|--------------------------------|------------------------------|
| commonlisp | `main.lisp` | —                              | `sbcl --script {src}`        |
| haskell    | `Main.hs`  | `ghc -O0 -o main {src}`        | `./main`                     |
| ocaml      | `main.ml`  | `ocamlopt -o main {src}`       | `./main`                     |
| prolog     | `main.pro` | see below                      | `swipl -q -g halt -f main.pro` |
| racket     | `main.rkt` | —                              | `racket {src}`               |
| scheme     | `main.scm` | —                              | `racket {src}`               |

Those command lines are the backend registry's own `CompileCommand` and
`RunCommand` for each language, so a job behaves identically to the local
`codhoot-runner-functional` docker path. Scheme runs on the Racket interpreter
because that is what the registry entry asks for.

### Prolog has a "compile" step that is not a compile

SWI-Prolog has no compile-a-file command. The registry's compile step consults
the program into a throwaway query so syntax errors surface before the run, and
the run step loads the file again. That two-step shape is carried here
verbatim; a Prolog error report is therefore produced by the compile step and
returned as `compile_time_ms` plus output, not by the run.

## Toolchains

GHC (Haskell), OCaml native compiler, SBCL, SWI-Prolog and Racket from Debian
bookworm, with a stable-name symlink for the versioned `ocamlopt`. Every
toolchain is smoke-tested during the image build — GHC, ocamlopt and swipl all
leave first-run caches under `HOME` that would otherwise be written as root.

## Deployment

Render blueprint: **New → Blueprint**, point it at this repo, apply. Set
`CODHOOT_INTERNAL_SECRET` to the same value the backend uses.

The service listens on `PORT` (Render sets it to 10000; the image default is
8081). `MAX_CONCURRENT_JOBS` defaults to 2.

Note: GHC is a large toolchain, so this image is the biggest of the shared
services. If a free-tier build reports an image-size or build-time limit, raise
the instance to 1 GB before debugging the Dockerfile — the install itself is
straight from Debian.

## Sandbox

Each job gets its own uid from a 32-entry pool, a private random 0700 working
directory, a minimal environment, rlimits applied by a trampoline re-exec, and
process-group kill on timeout. The service runs as root only to chown and
setuid; the boundary is the child. See `harden.go` / `harden_unix.go`.