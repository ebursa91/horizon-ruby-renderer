# Authoritative mock store data over native gRPC

The renderer can fetch the complete store/configuration snapshot through the native Ruby gRPC SDK. The tenant-aware mock service is a separate private repository. The public client contains only the original versioned protocol and generated bindings; it does not contain the service registry or tenant snapshots.

```sh
export HORIZON_DATA_TOKEN=mock-tenant-a-token
bundle exec bin/horizon-render --liquid-root "$LIQUID_ROOT" --theme-root "$HORIZON_ROOT" \
  --grpc-endpoint 127.0.0.1:50051 --tenant-id demo-a --storefront-id large \
  --locale pl --configuration wide --cart-id default --request-id request-0001 \
  --page collection --current-page 2 --output-dir /tmp/horizon-rpc-page
```

`GetRenderContext` supplies authoritative UTF-8 fixture JSON, its exact SHA256 and snapshot revision, and echoed tenant/store/locale/configuration/page/cart/request scope. The client validates all echoed fields, the body service scope, fixture schema, theme pin, page type/template/number, and locale before rendering. The fetched fixture is passed to the renderer without local configuration overrides. Nonbaseline contexts declare `theme.configuration_source=service` and contain every saved setting; the host skips local `config/settings_data.json.current` entirely. External theme schema/default/type definitions remain template implementation. Request correlation stays in RPC metadata; deterministic synthetic page identifiers remain in the snapshot.

RPC mode requires `HORIZON_DATA_TOKEN` and rejects `--fixture`/`--store`. RPC failure, deadline, unavailable service, unauthorized tenant, hash mismatch or malformed context fails the render and removes an old success report. There is no file fallback. Explicit `--fixture` remains available for the recorded offline oracle and engine benchmarks, whose measurements are separate from data-service costs. The service's special `baseline` configuration accepts only demo-a/small/en/index/page1/default cart and the exact original fixture bytes; this allows a native transport check against the recorded homepage oracle.

Version 1 permits insecure transport only to literal loopback IPs. This is a local fake-data service contract. Requests are bounded to 8 KiB, contexts to 64 MiB, and deadlines to a finite positive maximum of ten seconds (default five). [gRPC recommends explicit client deadlines](https://grpc.io/docs/guides/deadlines/). Tokens are excluded from reports and error details. Production authentication, TLS, remote endpoints, and real merchant data require a separate service contract.

```ruby
require 'horizon_fixture/runtime'
HorizonFixture::Runtime.load_liquid!(liquid_root)
HorizonFixture::Runtime.verify_checkout(horizon_root, HorizonFixture::THEME_SHA, 'theme')
require 'horizon_fixture/data_client'

client = HorizonFixture::DataClient.new(
  endpoint: '127.0.0.1:50051', token: ENV.fetch('HORIZON_DATA_TOKEN'), deadline_seconds: 5
)
begin
  snapshot = client.fetch(tenant_id: 'demo-a', storefront_id: 'large', locale: 'de',
    configuration: 'wide', page: 'product', current_page: 1,
    cart_id: 'default', request_id: 'request-0001')
  renderer = HorizonFixture::Renderer.new(theme_root: horizon_root, fixture: snapshot.fixture)
  result = renderer.render_result(page: 'product')
ensure
  client.close
end
```

The report includes native SDK versions, authoritative context hash/bytes/revision/scope, and `fetch_ms`. That time covers the native RPC call, including its transport and protobuf work; context hashing/JSON validation and template rendering occur afterward. Cold CLI timing includes the full fetch, validation and rendering workload. The existing offline warm renderer benchmarks exclude this service by design.

Bindings are generated from the shared original protocol:

```sh
bundle exec grpc_tools_ruby_protoc -I proto \
  --ruby_out=lib/horizon_store_service --grpc_out=lib/horizon_store_service \
  proto/horizon/store/v1/store_context.proto
```

Tests use real native loopback gRPC for repeated requests, tenant rejection, deadline/unavailability, and genuine pinned-theme CLI rendering. Boundary tests reject mismatched scope/hash/schema/locale/page without inventing a successful response. The private service is also checked separately by both language clients against the same returned context bytes.

## Verified cross-renderer checkpoint

The [numeric native parity matrix](../benchmark/results/2026-10-01-grpc-parity.json) verifies 112 scopes and 236 fresh-process renders: two tenants, 4/100-product stores, en/de/pl, published/wide configurations, genuine index/product/collection, large collection pagination and representative empty carts. All contexts are stable across correlation identifiers, tenant catalog identities remain separate, and every HTML/CSS pair matches exactly. The separate offline matrix verifies 48 page cases and 192 renders with byte-identical regenerated fixtures.

The oracle fetches each context twice before invoking the native clients, warming the immutable service projection cache. Ruby `fetch_ms` starts after channel/stub construction; Rust `fetch_ms` includes connection/client construction and RPC. Both exclude context hashing, JSON/scope validation and rendering. Outer `cli_wall_ms` includes setup, process/dependency startup, fetch/validation/rendering, writes, exit polling, owned-group cleanup and post-exit verification. Fixed Ruby-before-Rust mixed-case execution supports no SDK ranking, render-only latency, inverse-latency RPS or service capacity claim. Prepared offline HTTP results are reported separately.
