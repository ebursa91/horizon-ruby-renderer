# Genuine product and collection scenarios

The original homepage fixture and its recorded output remain byte-identical. `fixtures/scenarios.json` specifies an original deterministic matrix derived from its four fake products: 4 or 100 products, English/German/Polish, and two configurations. Both engines consume the same generated JSON. Generated fixtures and rendered theme output stay outside the repositories.

```sh
bundle exec ruby script/generate_scenarios.rb --output-dir /tmp/horizon-scenarios
bundle exec ruby script/validate_scenario.rb /tmp/horizon-scenarios/*.json
bundle exec bin/horizon-render --liquid-root "$LIQUID_ROOT" --theme-root "$HORIZON_ROOT" \
  --fixture /tmp/horizon-scenarios/harbor-100-pl-wide.json --page product --output-dir /tmp/horizon-product
```

Every fixture exposes `index`, `product`, and `collection`, pointing to the unchanged pinned `templates/index.json`, `templates/product.json`, and `templates/collection.json`. The 100-product fixtures also expose `collection_page_2` and `collection_last`, both using the same real collection template with a selected page number. Product resource IDs select the real second canvas-daypack variant; clones remap product, variant, image and option identities while retaining the four original local SVG URLs. No customer or merchant data is used.

Page metadata carries a type, resource handle, absolute canonical URL, and unsigned deterministic request ID, projected as a string in the explicitly synthetic `request.id` property. Page type and route populate the request; the selected product/collection is available globally and through `closest` across isolated blocks/snippets. Selected variant and option properties are derived per request. Page overrides apply after base section/block overrides, so genuine section ID `main` can carry distinct product and collection settings. Missing resources and invalid variant/page numbers fail.

Default configuration uses narrow page width, equal-width variant buttons, and collection windows of 24. Wide uses wide page width, variant dropdowns and full-width collection windows of 12. Both configurations disable infinite scroll to exercise the theme's selected page-size branch. Pagination slices the collection array inside the tag, keeps total counts, and exposes deterministic previous/next/parts metadata. Page 2 and last-page windows are checked against the original catalog order, including the short final window.

The fake cart contains notebook and selected daypack lines. Default quantities `[2,1]` produce 3 units and 13100 USD cents; wide quantities `[3,2]` produce 5 units and 24400 cents. SHA-derived scenario/page identifiers, cart tokens and line keys are deterministic. The validator checks canonical product/variant references, globally unique IDs, asset URLs, price ranges, cart arithmetic, locales, routes and page ranges. Regeneration tests compare bytes and ensure the original fixture is untouched.

Translations come directly from the external pinned `en.default.json`, `de.json`, and `pl.json`. No locale text is vendored. Integer cardinal counts use English/German one/other and Polish one/few/many; fractional counts use other, following [Unicode CLDR rules](https://unicode.org/cldr/charts/49/supplemental/language_plural_rules.html). Merchant product text is the original English synthetic data. Currency stays USD with the declared existing USD formatter; this does not emulate market currency conversion or localized money formatting.

Executed platform additions are explicitly bounded:

- Option values expose their names as strings and retain object properties. Identifier `handleize` accepts the executed ASCII identifier subset; unsupported identifiers fail. Product metadata adds the existing USD money formatter without its currency symbol.
- New scenarios declare recursively sorted object keys for the platform `json` filter, avoiding host object iteration differences. The original homepage contract is unchanged.
- `structured_data` emits declared synthetic Schema.org ProductGroup data with fake product/variant offers. It is a fixture contract, not a byte oracle of Shopify's hosted serialization. Shopify documents [ProductGroup output for products with variants](https://shopify.dev/docs/api/liquid/filters/structured_data).
- Raw `{% javascript %}` bodies are emitted inline once per source and request. Liquid remains raw, as required by [the tag contract](https://shopify.dev/docs/api/liquid/tags/javascript); Shopify's asset bundling is outside this fixture host.
- Payment terms and accelerated checkout return empty only when explicitly disabled in the fixture capabilities. An enabled or unspecified service fails; [payment_button](https://shopify.dev/docs/api/liquid/filters/payment_button) is a hosted checkout service and is not simulated.
- Collection view events expose a synthetic collection ID; product/cart event contracts remain deterministic. Recommendation RPCs, submissions, pickup availability and real checkout are outside the declared capabilities. The genuine initial product recommendation hydration shell remains rendered.

Every render still uses strict parsing, `render!`, unknown-filter errors, fresh request state, immutable upstream sources, and parsed template reuse without response caching. These scenarios extend engine compatibility coverage; they do not claim a full Shopify platform emulator.
