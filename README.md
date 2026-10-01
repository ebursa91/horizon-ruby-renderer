# Horizon Ruby renderer

Render entirely synthetic stores with pinned Shopify Liquid and unmodified external Horizon sources. Store and saved configuration can come from a tenant-aware native gRPC data authority. This original fixture host includes bounded Shopify platform adapters, a CLI and a reusable Ruby library.

Ruby >= 3.4 is required. The default is Ruby 4.0.7; the reference extraction also runs on Ruby 3.4.10. The external pins are Liquid 5.14.0 (`4e39ae4cc3da73921923c0669e0fc84a66b2f696`) and Horizon 4.2.0 (`5acd1b6b66c02f61d3216e3adace5dd9e0404fc9`). No upstream Liquid or Horizon source is included.

## Run

Provide clean external checkouts at those commits and install dependencies using `bundle install`. The CLI verifies HEAD, tracked cleanliness and the actual loaded Liquid source.

Use the private mock data authority for native RPC rendering. The service supplies every store/cart/configuration snapshot; the client validates scope and exact context bytes before rendering, with no local file fallback. See [the data-service contract and native client API](docs/DATA_SERVICE.md).

```sh
HORIZON_DATA_TOKEN=mock-tenant-a-token bundle exec bin/horizon-render \
  --liquid-root /absolute/pinned-liquid --theme-root /absolute/pinned-horizon \
  --grpc-endpoint 127.0.0.1:50051 --tenant-id demo-a --storefront-id large \
  --locale pl --configuration wide --cart-id default --request-id request-0001 \
  --page collection --current-page 2 --output-dir /tmp/horizon-rpc-page
```

The explicit local fixture mode retains the independently recorded offline oracle and engine benchmark:

```sh
bundle exec ruby bin/horizon-render --liquid-root /absolute/pinned-liquid --theme-root /absolute/pinned-horizon --fixture fixtures/store.json --scope page --output-dir /tmp/horizon-ruby-page
LIQUID_RUBY_ROOT=/absolute/pinned-liquid HORIZON_THEME_ROOT=/absolute/pinned-horizon bundle exec ruby test/renderer_test.rb
python3 script/validate_fixture.py
```

Generated HTML and CSS must stay outside the repository. Synthetic product assets live in `fixtures/mock-assets`; theme assets remain in the external checkout. No Shopify account or merchant/customer data is used. Read [the fixture contract](docs/FIXTURE.md) and [genuine product/collection scenario coverage](docs/SCENARIOS.md) for provenance and limitations.

For a local preview after a successful render, link the external theme assets and copy the original synthetic product assets into the output directory, then serve it on localhost:

```sh
ln -s /absolute/pinned-horizon/assets /tmp/horizon-ruby-page/assets
cp -R fixtures/mock-assets/cdn /tmp/horizon-ruby-page/cdn
python3 -m http.server 8765 --bind 127.0.0.1 --directory /tmp/horizon-ruby-page
```

Open `http://127.0.0.1:8765/index.html`. Asset setup and the local server are outside the benchmark workload.

The expected homepage is 435304 HTML bytes, SHA256 `d97c35b3ba08f026536cb4c469623acb9957af59fb9a9171db012958515fe990`, and 279112 collected CSS bytes, SHA256 `67a6538e0b763c32ced001728ebf68f375dec497d4fb91c0ee136658ff9f2034`. Parser mode is strict, filters are strict, rendering uses `render!`, optional variables resolve to nil. Unsupported executed platform behavior fails.

## Library

Load the pinned Liquid checkout before requiring the library, then reuse one renderer:

```ruby
$LOAD_PATH.unshift('/absolute/pinned-liquid/lib')
require_relative 'lib/horizon_fixture'
fixture = JSON.parse(File.read('fixtures/store.json'))
renderer = HorizonFixture::Renderer.new(theme_root: '/absolute/pinned-horizon', fixture: fixture)
response = renderer.render_result(scope: 'page')
html, css = response.html, response.css
# Optional per-request synthetic globals override the persisted fixture.
response = renderer.render_result(scope: 'hero', globals: { 'request_marker' => 'second' })
```

The renderer owns an immutable fixture snapshot and caches immutable source text, parsed JSON/schema data and Liquid ASTs. Every render builds fresh globals, Drops, settings, contexts, diagnostics, stylesheets and mutable Liquid Template wrappers. It never caches a rendered response. `render_result` returns the HTML, assembled CSS and diagnostics belonging to that request. `render(scope: 'page')` still returns just the HTML; the renderer's diagnostic readers refer to its current Fiber or latest completed request.

Cooperative Fibers may share one renderer on one Ruby thread; request results stay isolated when rendering is suspended and resumed. Parallel thread rendering is not supported. Run a single request in a Fiber with `--mode fiber` or `HorizonFixture::Runtime.execute('fiber') { renderer.render_result(scope: 'page') }`. Fibers provide a hosting boundary and do not parallelize CPU-bound Liquid work. No scheduler or async dependency is needed for this synchronous workload.

## Measure

Enable YJIT explicitly on modern CRuby, rather than treating it as an implied default:

```sh
bundle exec ruby --yjit bin/horizon-render --liquid-root /absolute/pinned-liquid --theme-root /absolute/pinned-horizon --fixture fixtures/store.json --scope page --mode fiber --output-dir /tmp/horizon-ruby-yjit
bundle exec ruby --yjit benchmark/worker.rb --liquid-root /absolute/pinned-liquid --theme-root /absolute/pinned-horizon --fixture fixtures/store.json --scope page --benchmark-mode direct --warmup 50 --iterations 25 --output-dir /tmp/horizon-ruby-benchmark
```

The worker writes `report.json`, `index.html` and `styles.css` outside all source roots. `--benchmark-json /tmp/report.json` also writes the same JSON at a chosen external path. Constructor initialization and the first render, which includes lazy parsing, are reported separately. `--warmup N` counts all excluded requests, including that first render, and must be positive. Warm samples reuse prepared source/ASTs and measure fresh request rendering plus HTML and CSS assembly. SHA256, output writes, provenance checks and report construction occur outside those samples. Every warmup and measured result must match the first render; compare the reported digests with the independent pinned digests above before accepting a timing. GC remains enabled.

Reports include per-sample wall time, process CPU time and allocated objects, peak process RSS when Linux exposes it, actual Ruby/YJIT/dependency versions, source provenance, scope and `response_cache: false`. Compare plain Ruby, YJIT direct and YJIT Fiber in separate fresh processes with the same runtime, dependencies, fixture, scope and warmup. Host contention, JIT warmup, GC and execution order affect results; one synthetic page is not a general Ruby or Shopify benchmark. Cold CLI timing includes process startup and checkout validation.

An allocation profile of the original host found 88 JSON parses and 41 schema parses per warm homepage, plus context-local snippet parsing. Immutable source/JSON/schema and cross-request AST caches remove that repeated preparation; dynamic setting bindings and output still execute on every request. See [the measurement notes](docs/PERFORMANCE.md).

The [current results](benchmark/RESULTS.md) include exact native gRPC parity across 112 scopes and 236 renders, deterministic offline coverage and calibrated HTTP RPS. Sharing immutable Rust section/closest contexts improved the 100-product collection’s batch medians by 25.8–28.5× and reduced requested new-allocation traffic by 94.5%. The final four-client HTTP medians were 35.75 Rust and 33.60 YJIT RPS. See the [deep investigation](benchmark/DEEP_PERFORMANCE.md) for all batches, rejected candidates, boundaries and shared-host limits.

## Scope and license

The synthetic fixture host covers genuine homepage, product and collection templates, en/de/pl, two settings profiles and 4/100-product stores. It is not a Shopify server. Checkout, form submission, external services and full Drop semantics are unsupported. Payment terms return empty only for the fixture's explicit disabled capability. Liquid and Horizon remain independently licensed external dependencies; review Horizon's license before distributing its sources or generated content. This repository contains original host/fixture code and synthetic SVGs under the MIT license. Host extraction provenance: `ebursa91/liquid-rust` commit `ce6f371439aa556426c469c319f04afec77aad57`.

Next work profiles the optimized host, measures live RPC throughput and properly calibrated multi-worker scaling, and develops typed tenant-scoped providers; see [the active goal](ROADMAP.md). External theme sources and generated output remain local dependencies rather than repository artifacts.
