# Horizon Ruby renderer

Render one entirely synthetic store with pinned Shopify Liquid and unmodified external Horizon sources. This is an original fixture host with bounded Shopify platform adapters, a CLI and a reusable Ruby library.

Ruby >= 3.4 is required. The default is Ruby 4.0.7; the reference extraction also runs on Ruby 3.4.10. The external pins are Liquid 5.14.0 (`4e39ae4cc3da73921923c0669e0fc84a66b2f696`) and Horizon 4.2.0 (`5acd1b6b66c02f61d3216e3adace5dd9e0404fc9`). No upstream Liquid or Horizon source is included.

## Run

Provide clean external checkouts at those commits and install dependencies using `bundle install`. The CLI verifies HEAD, tracked cleanliness and the actual loaded Liquid source.

```sh
ruby bin/horizon-render --liquid-root /absolute/pinned-liquid --theme-root /absolute/pinned-horizon --fixture fixtures/store.json --scope page --output-dir /tmp/horizon-ruby-page
LIQUID_RUBY_ROOT=/absolute/pinned-liquid HORIZON_THEME_ROOT=/absolute/pinned-horizon ruby test/renderer_test.rb
python3 script/validate_fixture.py
```

Generated HTML and CSS must stay outside the repository. Synthetic product assets live in `fixtures/mock-assets`; theme assets remain in the external checkout. No Shopify account, credential, network API or merchant/customer data is used. Read [the fixture contract](docs/FIXTURE.md) for field provenance and limitations.

The expected homepage is 435304 HTML bytes, SHA256 `d97c35b3ba08f026536cb4c469623acb9957af59fb9a9171db012958515fe990`, and 279112 collected CSS bytes, SHA256 `67a6538e0b763c32ced001728ebf68f375dec497d4fb91c0ee136658ff9f2034`. Parser mode is strict, filters are strict, rendering uses `render!`, optional variables resolve to nil. Unsupported executed platform behavior fails.

## Library

Load the pinned Liquid checkout before requiring the library, then reuse one renderer for sequential requests:

```ruby
$LOAD_PATH.unshift('/absolute/pinned-liquid/lib')
require_relative 'lib/horizon_fixture'
fixture = JSON.parse(File.read('fixtures/store.json'))
renderer = HorizonFixture::Renderer.new(theme_root: '/absolute/pinned-horizon', fixture: fixture)
html = renderer.render(scope: 'page')
css = renderer.stylesheets.values.join
```

Rendering reuses parsed templates but resets request globals, diagnostics and stylesheet collection. Initialization and warm render measurements, YJIT and fiber evaluation will be documented separately. Fibers do not make CPU-bound Liquid work parallel.

## Scope and license

This fixture covers one homepage configuration and locale, not a Shopify server. Checkout, form submission, external services and full Drop semantics are unsupported. Payment terms return empty only for the fixture's explicit disabled capability. Liquid and Horizon remain independently licensed external dependencies; review Horizon's license before distributing its sources or generated content. This repository contains original host/fixture code and synthetic SVGs under the MIT license. Host extraction provenance: `ebursa91/liquid-rust` commit `ce6f371439aa556426c469c319f04afec77aad57`.
