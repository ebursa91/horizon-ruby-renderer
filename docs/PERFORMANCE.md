# Measurement boundaries

The warm worker measures `Renderer#render_result`: fresh request state, Liquid evaluation, HTML assembly and collected CSS assembly. Its constructor timer covers fixture copying and environment/cache setup; the separate first-render timer includes lazy AST parsing. `--warmup N` includes that first render and requires N >= 1. All N requests are excluded from measured samples. Output hashing, provenance, JSON construction and file writes occur outside the warm timer. Process CPU time and Ruby allocation deltas are measured around the same call, with ordinary enabled GC. Peak RSS is a process high-water mark, not memory retained by a single render.

Neither direct nor Fiber mode caches an output. A Fiber mode request runs in one new Fiber on the same thread, without a scheduler, external I/O or CPU parallelism. It evaluates an isolation/hosting strategy; it does not establish asynchronous throughput. Reusing source/JSON/schema and parsed ASTs models a prepared renderer. Mutable Liquid Template wrappers, contexts, resource/error state, settings and fixture globals belong to each request. Cooperative interleaving is tested; parallel thread execution is outside the API contract.

## Profile motivating the cache change

An instrumented plain Ruby 4.0.7 run of the original extracted host used the pinned full homepage after warmup and averaged five renders. The counters below are inclusive and overlap; their CPU/allocation columns must not be added together. Instrumentation and concurrent machine load make these diagnostic observations unsuitable as throughput results.

| Original work per warm page | Calls | Allocations | Process CPU ms |
| --- | ---: | ---: | ---: |
| Marshal fixture/node copying | 42 | 11050 | 22.59 |
| Source reads | 548 | 27438 | 50.21 |
| JSON parsing | 88 | 34966 | 37.68 |
| Schema parsing | 41 | 10370 | 11.16 |
| Settings materialization | 42 | 1510 | 3.04 |
| Theme settings | 1 | 2589 | 2.72 |

The original host reused its top-level templates, but stock Liquid's partial cache was context-local, so new requests reparsed snippets. This version retains immutable parsed partial ASTs across requests while cloning their mutable Template wrappers. It also retains pinned source text, raw JSON and schemas, replaces Marshal with a bounded JSON-tree copy, and copies/types fixture globals in one pass. Setting defaults, dynamic bindings and platform Drops remain request work.

## Reproducibility

Use the exact external commits and fixture bytes in the README. Keep generated results under `/tmp` or another external directory. A report records actual loaded dependency versions and paths because CRuby bundled bigdecimal/strscan versions can differ from Bundler's locked versions. Use the same dependency set across plain/YJIT/Fiber comparisons. Save raw worker JSON before summarizing medians or percentiles, validate every sample's hashes, and retain the independent pinned HTML/CSS oracle. Run measurement windows after compilation and tests finish, alternate execution order and report hardware/process affinity and host load.

The renderer's CLI performs Git provenance checks; a CLI without those checks has different startup work. End-to-end cold process timing therefore must be labeled separately from prepared warm rendering. Results apply to this configured synthetic homepage, not all Liquid templates, Shopify traffic or universal engine speed.

The [published seven-batch comparison](../benchmark/RESULTS.md) and its numeric-only JSON preserve every measured timing window and recorded implementation revision. The [long-term goal](../ROADMAP.md) keeps exact rendering parity as the optimization gate.
