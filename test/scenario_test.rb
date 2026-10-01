# frozen_string_literal: true

require 'json'
require 'digest'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
$LOAD_PATH.unshift(File.join(ENV.fetch('LIQUID_RUBY_ROOT'), 'lib'))
require_relative '../lib/horizon_fixture/renderer'
require_relative '../script/generate_scenarios'
require_relative '../script/validate_scenario'

class HorizonScenarioTest < Minitest::Test
  def setup
    @base_path = File.expand_path('../fixtures/store.json', __dir__)
    @base_bytes = File.binread(@base_path)
    @base = JSON.parse(@base_bytes)
    @theme = ENV.fetch('HORIZON_THEME_ROOT')
  end

  def scenario(size: 4, locale: 'en', configuration: 'default')
    HorizonScenarios.build(@base, size: size, locale: locale, configuration: configuration)
  end

  def host(fixture)
    HorizonFixture::Renderer.new(theme_root: @theme, fixture: fixture)
  end

  def test_generation_is_deterministic_and_leaves_original_bytes_unchanged
    source = JSON.generate(@base)
    spec = JSON.parse(File.read(File.expand_path('../fixtures/scenarios.json', __dir__)))
    spec.fetch('sizes').product(spec.fetch('locales'), spec.fetch('configurations')).each do |size, locale, configuration|
      fixture = scenario(size: size, locale: locale, configuration: configuration)
      report = HorizonScenarioValidation.validate(fixture)
      assert_equal size, report.fetch('products')
      assert_equal spec.dig('cart', configuration, 'total_price'), report.fetch('cart_total_price')
      assert_equal JSON.generate(fixture), JSON.generate(scenario(size: size, locale: locale, configuration: configuration))
    end
    assert_equal source, JSON.generate(@base)
    assert_equal @base_bytes, File.binread(@base_path)
    assert_equal HorizonScenarios::BASE_SHA, Digest::SHA256.hexdigest(@base_bytes)
  end

  def test_validator_rejects_broken_references_cart_and_page_range
    fixture = scenario(size: 100)
    bad = HorizonScenarios.copy(fixture)
    bad.fetch('globals').fetch('all_products').fetch('synthetic-item-0100').fetch('variants').first.fetch('product')['id'] = 1101
    assert_raises(ArgumentError) { HorizonScenarioValidation.validate(bad) }
    bad = HorizonScenarios.copy(fixture)
    bad.fetch('globals').fetch('cart')['total_price'] += 1
    assert_raises(ArgumentError) { HorizonScenarioValidation.validate(bad) }
    bad = HorizonScenarios.copy(fixture)
    bad.fetch('pages').fetch('collection_page_2')['current_page'] = 10
    assert_raises(ArgumentError) { HorizonScenarioValidation.validate(bad) }
  end

  def test_real_product_resource_variant_and_settings_survive_isolated_blocks
    fixture = scenario
    renderer = host(fixture)
    original = JSON.generate(fixture)
    result = renderer.render_result(page: 'product')
    assert_includes result.html, '<h1>Canvas daypack</h1>'
    assert_includes result.html, 'data-product-id="1104"'
    assert_includes result.html, 'value="2105"'
    assert_includes result.html, 'value="Sand"'
    assert_includes result.html, 'value="Large"'
    assert_includes result.html, '$95.00'
    assert_includes result.html, 'data-template-product-match="true"'
    assert_includes result.html, 'variant-option--buttons'
    assert_includes result.html, '"@type":"ProductGroup"'
    assert_includes result.rendered_sources, 'sections/product-information.liquid'
    assert_includes result.rendered_sources, 'snippets/variant-main-picker.liquid'
    assert_includes result.platform_filters, 'payment_button'
    assert_equal result.html, renderer.render_result(page: 'product').html
    renderer.render_result(page: 'collection')
    assert_equal result.html, renderer.render_result(page: 'product').html
    assert_equal original, JSON.generate(fixture)
    wide = host(scenario(configuration: 'wide')).render_result(page: 'product')
    assert_includes wide.html, 'variant-option--dropdowns'
    refute_equal result.html, wide.html
  end

  def test_genuine_collection_pages_slice_the_catalog_and_keep_total_counts
    fixture = scenario(size: 100)
    renderer = host(fixture)
    ids = fixture.fetch('globals').fetch('collections').fetch('all').fetch('products').map { |product| product.fetch('id').to_s }
    { 'collection' => [1, ids.first(24)], 'collection_page_2' => [2, ids.slice(24, 24)], 'collection_last' => [5, ids.last(4)] }.each do |page, (number, expected_ids)|
      result = renderer.render_result(page: page)
      assert_equal expected_ids, result.html.scan(/class="product-grid__item [^"]*"\s+data-page="#{number}"\s+data-product-id="(\d+)"/).flatten
      assert_includes result.html, 'data-last-page="5"'
      assert_includes result.rendered_sources, 'sections/main-collection.liquid'
      assert_includes result.html, '<script data-shopify>'
      assert_includes result.html, '&quot;collection_id&quot;:4101'
    end
    assert_equal 100, renderer.fixture.dig('globals', 'collections', 'all', 'products').length
    wide = host(scenario(size: 100, configuration: 'wide')).render_result(page: 'collection_page_2')
    assert_equal 12, wide.html.scan(/class="product-grid__item [^"]*"\s+data-page="2"/).length
    assert_includes wide.html, 'data-last-page="9"'
    assert_includes wide.html, 'collection-wrapper--full-width'
  end

  def test_actual_locale_files_and_currency_contract_are_used
    %w[en de pl].each do |locale|
      fixture = scenario(locale: locale, configuration: 'wide')
      result = host(fixture).render_result(page: 'product')
      assert_match(/<html[^>]+lang="#{locale}"/, result.html)
      translations = JSON.parse(File.read(File.join(@theme, 'locales', locale == 'en' ? 'en.default.json' : "#{locale}.json")), allow_comments: true)
      assert_includes result.html, translations.fetch('actions').fetch('add_to_cart')
      assert_includes result.html, '$244.00 USD'
      assert_equal locale, result.manifest.fetch('locale')
      assert_equal fixture.dig('pages', 'product', 'request_id'), result.manifest.fetch('request_id')
      assert_equal fixture.dig('pages', 'product', 'request_id').to_s, result.request.instance_variable_get(:@globals).dig('request', 'id')
    end
  end

  def test_payment_and_unknown_executed_filters_fail_closed
    fixture = scenario
    fixture.fetch('manifest').fetch('platform_capabilities')['payment_button'] = true
    assert_raises(HorizonFixture::ContractError) { host(fixture).render_result(page: 'product') }
    fixture = scenario
    fixture.fetch('pages').fetch('product').fetch('resource')['variant_id'] = 999_999
    assert_raises(HorizonFixture::ContractError) { host(fixture).render_result(page: 'product') }
  end

  def test_pagination_metadata_is_request_scoped_and_validates_pages
    with_micro_theme do |renderer|
      expected = '3,4|2/3/2/2/3|Previous:/collections/all?page=1|Next:/collections/all?page=3|1:true:/collections/all?page=1;2:false:;3:true:/collections/all?page=3;|6'
      assert_equal expected, renderer.render(page: 'collection', scope: 'template', globals: { 'current_page' => 2 })
      assert_equal expected, renderer.render(page: 'collection', scope: 'template', globals: { 'current_page' => 2 })
      [0, 4, 1.5, false].each do |page|
        assert_raises(HorizonFixture::ContractError) { renderer.render(page: 'collection', scope: 'template', globals: { 'current_page' => page }) }
      end
    end
  end

  def test_polish_plural_categories_include_fractional_other
    request = HorizonFixture::Request.new(host(scenario(locale: 'pl')))
    { 0 => 'many', 1 => 'one', 2 => 'few', 5 => 'many', 12 => 'many', 22 => 'few', 101 => 'many', 1.0 => 'other', 1.5 => 'other' }.each do |count, category|
      assert_equal category, request.send(:plural_category, 'pl', count)
    end
    assert_equal 'one', request.send(:plural_category, 'en', 1)
    assert_equal 'other', request.send(:plural_category, 'de', 2)
    assert_raises(HorizonFixture::ContractError) { request.send(:plural_category, 'pl', Float::NAN) }
  end

  def test_raw_javascript_deduplicates_without_evaluating_liquid
    with_micro_theme(source: "{% render 'raw' %}{% render 'raw' %}") do |renderer, root|
      File.write(File.join(root, 'snippets/raw.liquid'), "{% javascript %}window.fixture = '{{ not_liquid }}';{% endjavascript %}")
      expected = "<script data-shopify>window.fixture = '{{ not_liquid }}';</script>"
      assert_equal expected, renderer.render(page: 'collection', scope: 'template')
      assert_equal expected, renderer.render(page: 'collection', scope: 'template')
    end
  end

  private

  def with_micro_theme(source: nil)
    Dir.mktmpdir('horizon-page-contract-') do |root|
      %w[config templates sections snippets].each { |directory| FileUtils.mkdir_p(File.join(root, directory)) }
      File.write(File.join(root, 'config/settings_schema.json'), '[]')
      File.write(File.join(root, 'config/settings_data.json'), '{"current":{}}')
      File.write(File.join(root, 'templates/collection.json'), '{"order":["main"],"sections":{"main":{"type":"page","settings":{}}}}')
      body = source || "{% paginate collection.products by 2 %}{% for p in collection.products %}{{ p }}{% unless forloop.last %},{% endunless %}{% endfor %}|{{ paginate.current_page }}/{{ paginate.pages }}/{{ paginate.page_size }}/{{ paginate.current_offset }}/{{ paginate.parts.size }}|{{ paginate.previous.title }}:{{ paginate.previous.url }}|{{ paginate.next.title }}:{{ paginate.next.url }}|{% for p in paginate.parts %}{{ p.title }}:{{ p.is_link }}:{{ p.url }};{% endfor %}{% endpaginate %}|{{ collection.products.size }}"
      File.write(File.join(root, 'sections/page.liquid'), body + '{% schema %}{"tag":null}{% endschema %}')
      fixture = { 'synthetic' => true, 'schema_version' => 1, 'globals' => { 'collection' => { 'products' => (1..6).to_a }, 'request' => { 'path' => '/collections/all' } }, 'theme' => {},
                  'pages' => { 'collection' => { 'template' => 'templates/collection.json', 'title' => 'Test', 'description' => '', 'url' => '/collections/all' } } }
      yield HorizonFixture::Renderer.new(theme_root: root, fixture: fixture), root
    end
  end
end
