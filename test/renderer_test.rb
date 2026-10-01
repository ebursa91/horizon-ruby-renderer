# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
$LOAD_PATH.unshift(File.join(ENV.fetch('LIQUID_RUBY_ROOT'), 'lib'))
require_relative '../lib/horizon_fixture/renderer'
require_relative '../lib/horizon_fixture/runtime'

class HorizonFixtureRendererTest < Minitest::Test
  def setup
    @fixture = JSON.parse(File.read(ENV.fetch('HORIZON_STORE', File.expand_path('../fixtures/store.json', __dir__))))
    @theme = ENV.fetch('HORIZON_THEME_ROOT')
  end

  def renderer
    HorizonFixture::Renderer.new(theme_root: @theme, fixture: @fixture)
  end

  def test_real_hero_renders_ordered_text_and_button_with_global_block_context
    host = renderer
    result = host.render(scope: 'hero')
    assert_includes result, '<section id="shopify-section-hero_jVaWmY" class="shopify-section hero-wrapper section-wrapper">'
    assert_includes result, 'Equip your everyday adventure'
    assert_includes result, 'Shop field essentials'
    assert_includes result, 'href="/collections/all"'
    assert_operator result.index('Equip your everyday adventure'), :<, result.index('Shop field essentials')
    assert_equal 1, result.scan('aria-label="Fixture placeholder"').size
    refute_includes result, 'Liquid error'
    refute_empty host.stylesheets
    assert_includes host.rendered_sources, 'snippets/button.liquid'
  end

  def test_real_product_list_uses_shared_store_products_and_prices
    result = renderer.render(scope: 'template')
    @fixture.fetch('globals').fetch('all_products').each_value do |product|
      assert_includes result, product.fetch('title')
      assert_includes result, product.fetch('url')
    end
    assert_includes result, '$18.00'
    assert_includes result, '$24.00'
    assert_includes result, '$32.00'
    assert_includes result, '--focal-point: 50.0% 50.0%;'
    assert_includes result, 'data-testid="product-list"'
    refute_includes result, '{{ closest.collection.title }}'
  end

  def test_repeated_render_does_not_leak_state_or_mutate_store
    host = renderer
    original = JSON.generate(@fixture)
    first = host.render(scope: 'template')
    first_css = host.stylesheets.dup
    first_sources = host.rendered_sources.dup
    assert_equal first, host.render(scope: 'template')
    assert_equal first_css, host.stylesheets
    assert_equal first_sources, host.rendered_sources
    assert_equal original, JSON.generate(@fixture)
    host.render(scope: 'hero')
    assert_equal first, host.render(scope: 'template')
  end

  def test_full_page_renders_layout_header_footer_and_nonempty_cart_deterministically
    host = renderer
    original = JSON.generate(@fixture)
    result = host.render(scope: 'page')
    assert_match(/\A<!doctype html>/, result)
    assert_match(/<title>\s*Harbor Supply<\/title>/, result)
    assert_includes result, %(href="#{@fixture.dig('globals', 'canonical_url')}")
    assert_includes result, 'id="header-component"'
    assert_includes result, 'id="MainContent"'
    assert_includes result, 'id="shopify-section-footer"'
    assert_includes result, '&copy; 2026'
    assert_includes result, @fixture.dig('globals', 'powered_by_link')
    assert_includes result, '<bdi>$131.00 USD</bdi>'
    assert_includes result, 'data-cart-line="1"'
    assert_includes result, 'data-cart-line="2"'
    assert_equal 1, result.scan('<style data-horizon-fixture>').size
    refute_includes result, HorizonFixture::Renderer::CSS_SENTINEL
    assert_includes result, "<style data-horizon-fixture>#{host.stylesheets.values.join}</style>"
    assert_operator result.index('<style data-horizon-fixture>'), :<, result.index('</head>')
    %w[layout/theme.liquid sections/header.liquid sections/footer.liquid snippets/cart-items-component.liquid].each do |source|
      assert_includes host.rendered_sources, source
    end
    css = host.stylesheets.dup
    assert_equal result, host.render(scope: 'page')
    assert_equal css, host.stylesheets
    assert_equal original, JSON.generate(@fixture)
  end

  def test_payment_terms_requires_explicit_disabled_platform_service
    @fixture.fetch('manifest').fetch('platform_capabilities')['payment_terms'] = true
    error = assert_raises(HorizonFixture::ContractError) { renderer.render(scope: 'page') }
    assert_includes error.message, 'payment_terms'
  end

  def test_nested_render_keeps_unknown_filter_errors
    with_micro_theme(block_source: "{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}", snippet: '{{ block.settings.text | unsupported_fixture_filter }}') do |host|
      assert_raises(Liquid::UndefinedFilter) { host.render(scope: 'hero') }
    end
  end

  def test_siblings_keep_global_block_section_and_local_assigns_isolated
    block = "{% assign leaked = block.settings.text %}{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}"
    with_micro_theme(block_source: block, snippet: '{{ section.id }}:{{ block.id }}:{{ block.settings.text }}:{{ leaked }};') do |host|
      expected = '<div id="shopify-section-test" class="shopify-section">test:second:B:;test:first:A:;</div>'
      assert_equal expected, host.render(scope: 'hero')
      assert_equal expected, host.render(scope: 'hero')
    end
  end

  def test_section_blocks_are_an_ordered_array_with_string_ids
    block = "{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}"
    with_micro_theme(block_source: block, snippet: "{{ section.blocks | find_index: 'id', block.id }};") do |host|
      assert_equal '<div id="shopify-section-test" class="shopify-section">0;1;</div>', host.render(scope: 'hero')
    end
    blocks = HorizonFixture::BlockCollection.new({ 'static' => { 'static' => true }, 'a' => {} }, ['a'])
    assert_equal %w[a static], blocks.map { |node| node.fetch('id') }
    assert_equal({ 'static' => true }, blocks.fetch('static'))
    assert_equal 'a', blocks.fetch(0).fetch('id')
    assert_raises(KeyError) { blocks.fetch('missing') }
  end

  def test_static_stylesheet_is_not_evaluated_and_is_collected_once
    block = "{% stylesheet %}.test { content: '{{ untouched }}'; }{% endstylesheet %}{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}"
    with_micro_theme(block_source: block, snippet: '{{ block.settings.text }}') do |host|
      assert_equal '<div id="shopify-section-test" class="shopify-section">BA</div>', host.render(scope: 'hero')
      assert_equal [".test { content: '{{ untouched }}'; }"], host.stylesheets.values
    end
  end

  def test_unknown_tag_is_not_ignored
    with_micro_theme(block_source: '{% unsupported_fixture_tag %}', snippet: '') do |host|
      assert_raises(Liquid::SyntaxError) { host.render(scope: 'hero') }
    end
  end

  def test_color_preserves_hex_rendering_and_alpha_properties
    color = HorizonFixture::Color.new('#12121266')
    assert_equal '#12121266', color.to_s
    assert_equal '18 18 18', color.rgb
    assert_in_delta 0.4, color.alpha
    assert_equal '18 18 18 / 0.4', color.rgba
    assert_equal '#fbe2f3', HorizonFixture::Color.new('#EA5AB9').shifted_lightness(30)
    assert_raises(HorizonFixture::ContractError) { HorizonFixture::Color.new('var(--arbitrary)') }
    assert_raises(HorizonFixture::ContractError) { HorizonFixture::Color.new('rgba(256, 0, 0, 1)') }
  end

  def test_local_settings_bindings_keep_theme_settings_visible
    host = renderer
    values = { 'local' => '{{ settings.theme_value }}', 'theme_value' => 'wrong' }
    materialized = host.send(:new_request).send(:materialize_settings, values, [], 'settings' => { 'theme_value' => 'theme' })
    assert_equal 'theme', materialized.fetch('local')
    initial = host.send(:new_request).send(:materialize_settings, values, [], {})
    assert_equal 'wrong', initial.fetch('local')
  end

  def test_source_rejects_snippet_path_traversal
    source = HorizonFixture::Source.new(@theme)
    assert_raises(HorizonFixture::ContractError) { source.read_template_file('../layout/theme') }
  end

  def test_source_caches_immutable_text_json_and_schemas
    source = HorizonFixture::Source.new(@theme)
    text = source.read('sections/hero.liquid')
    json = source.json('templates/index.json')
    schema = source.schema('sections/hero.liquid')
    assert_same text, source.read('sections/hero.liquid')
    assert_same json, source.json('templates/index.json')
    assert_same schema, source.schema('sections/hero.liquid')
    assert text.frozen?
    assert json.fetch('sections').frozen?
    assert schema.fetch('settings').first.frozen?
    assert_raises(FrozenError) { json.fetch('order') << 'changed' }
  end

  def test_request_globals_change_output_without_mutating_inputs_or_caching_response
    with_micro_theme(block_source: "{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}", snippet: '{{ marker }}:{{ nested.title }}:{{ block.settings.text }};') do |host|
      globals = { 'marker' => +'first', 'nested' => { 'title' => +'original' } }
      first = host.render_result(scope: 'hero', globals: globals)
      globals['marker'].replace('second')
      globals['nested']['title'].replace('updated')
      second = host.render_result(scope: 'hero', globals: globals)
      assert_includes first.html, 'first:original:B;first:original:A;'
      assert_includes second.html, 'second:updated:B;second:updated:A;'
      assert_equal 'second', globals['marker']
      assert_equal 'updated', globals.dig('nested', 'title')
      assert first.html.frozen?
      assert first.stylesheets.frozen?
      assert first.rendered_sources.frozen?
      refute_same first.request, second.request
    end
    caller_fixture = JSON.parse(JSON.generate(@fixture))
    host = HorizonFixture::Renderer.new(theme_root: @theme, fixture: caller_fixture)
    caller_fixture.fetch('pages').fetch('index')['title'] = 'Changed after initialization'
    assert_equal @fixture.dig('pages', 'index', 'title'), host.fixture.dig('pages', 'index', 'title')
    assert host.fixture.dig('globals', 'shop', 'name').frozen?
  end

  def test_cached_partial_errors_do_not_leak_into_next_request
    snippet = "{% if fail %}{{ marker | unknown_fixture_filter }}{% else %}{{ marker }}{% endif %}"
    with_micro_theme(block_source: "{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}", snippet: snippet) do |host|
      assert_includes host.render_result(scope: 'hero', globals: { 'marker' => 'good' }).html, 'goodgood'
      partials = host.send(:partials).dup
      assert_raises(Liquid::UndefinedFilter) { host.render_result(scope: 'hero', globals: { 'fail' => true }) }
      assert_empty host.stylesheets
      assert_empty host.rendered_sources
      result = host.render_result(scope: 'hero', globals: { 'marker' => 'fresh' })
      assert_includes result.html, 'freshfresh'
      assert_equal partials.keys, host.send(:partials).keys
      partials.each do |key, template|
        assert_same template.root, host.send(:partials).fetch(key).root
        assert_empty template.errors
      end
    end
  end

  def test_cooperatively_interleaved_fibers_keep_outputs_and_contexts_isolated
    block = "{% stylesheet %}.fixture { display: block; }{% endstylesheet %}{% render 'leaf' %}{% schema %}{\"tag\":null}{% endschema %}"
    with_micro_theme(block_source: block, snippet: '{{ marker }}:{{ block.settings.text }};') do |host|
      host.render_result(scope: 'hero') # Populate parsed ASTs before interleaving.
      create_request = host.method(:new_request)
      host.define_singleton_method(:new_request) do
        request = create_request.call
        record = request.method(:record_source)
        paused = false
        request.define_singleton_method(:record_source) do |path|
          record.call(path)
          if path == 'snippets/leaf.liquid' && !paused
            paused = true
            Fiber.yield(instance_variable_get(:@globals).fetch('marker'))
          end
        end
        request
      end
      alpha = Fiber.new { host.render_result(scope: 'hero', globals: { 'marker' => 'alpha' }) }
      beta = Fiber.new { host.render_result(scope: 'hero', globals: { 'marker' => 'beta' }) }
      assert_equal 'alpha', alpha.resume
      assert_equal 'beta', beta.resume
      second = beta.resume
      first = alpha.resume
      assert_includes first.html, 'alpha:B;alpha:A;'
      refute_includes first.html, 'beta'
      assert_includes second.html, 'beta:B;beta:A;'
      refute_includes second.html, 'alpha'
      assert_equal '.fixture { display: block; }', first.css
      assert_equal first.css, second.css
      refute_same first.stylesheets, second.stylesheets
      refute_same first.rendered_sources, second.rendered_sources
      assert_equal first.rendered_sources, second.rendered_sources
      first.request.partials.each do |key, template|
        other = second.request.partials.fetch(key)
        refute_same template, other
        assert_same template.root, other.root
      end
    end
  end

  def test_cli_rejects_internal_output_before_writing_success
    Dir.mktmpdir('horizon-protected-theme') do |directory|
      output = File.join(directory, 'out')
      FileUtils.mkdir_p(output)
      report = File.join(output, 'report.json')
      File.write(report, 'existing-file')
      command = [RbConfig.ruby, File.join(HorizonFixture::PROJECT_ROOT, 'bin/horizon-render'), '--liquid-root', @theme, '--theme-root', directory, '--fixture', File.join(HorizonFixture::PROJECT_ROOT, 'fixtures/store.json'), '--output-dir', output]
      stdout, stderr, status = Open3.capture3(*command)
      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'generated output must be outside source checkouts'
      assert_equal 'existing-file', File.read(report)
      refute File.exist?(File.join(output, 'index.html'))
    end
  end

  def test_generated_output_rejects_source_roots_and_symlinked_ancestors
    runtime = HorizonFixture::Runtime
    protected_path = File.join(HorizonFixture::PROJECT_ROOT, 'never-created-output')
    assert_raises(ArgumentError) { runtime.external_output_path!(protected_path) }
    refute File.exist?(protected_path)
    Dir.mktmpdir('horizon-output-policy') do |directory|
      File.symlink(HorizonFixture::PROJECT_ROOT, File.join(directory, 'project'))
      assert_raises(ArgumentError) { runtime.external_output_path!(File.join(directory, 'project', 'never-created-output')) }
      assert_raises(ArgumentError) { runtime.external_output_path!(File.join(@theme, 'never-created-output'), roots: [@theme]) }
      assert_equal File.join(directory, 'safe', 'page'), runtime.external_output_path!(File.join(directory, 'safe', 'page'))
    end
  end

  def test_benchmark_worker_preserves_per_sample_hashes_and_timing_contract
    Dir.mktmpdir('horizon-worker-test') do |output|
      command = [RbConfig.ruby, File.join(HorizonFixture::PROJECT_ROOT, 'benchmark/worker.rb'), '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', @theme, '--fixture', File.join(HorizonFixture::PROJECT_ROOT, 'fixtures/store.json'), '--output-dir', output, '--benchmark-mode', 'fiber', '--iterations', '2', '--warmup', '1']
      stdout, stderr, status = Open3.capture3(*command)
      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal report, JSON.parse(File.read(File.join(output, 'report.json')))
      assert_equal 'fiber', report.fetch('execution_mode')
      assert_equal false, report.fetch('response_cache')
      assert_equal true, report.fetch('correctness_verified')
      assert_equal 'page', report.fetch('scope')
      assert_equal 'index', report.fetch('page')
      assert_operator report.fetch('first_render_ms'), :>, 0
      assert_operator report.fetch('initialization_ms'), :>, 0
      assert_equal 2, report.fetch('samples').size
      assert_equal report.fetch('samples_ms'), report.fetch('samples').map { |sample| sample.fetch('elapsed_ms') }
      assert_equal report.fetch('samples_allocations'), report.fetch('samples').map { |sample| sample.fetch('allocations') }
      report.fetch('samples').each do |sample|
        assert_equal report.fetch('html'), sample.fetch('html')
        assert_equal report.fetch('css'), sample.fetch('css')
        assert_operator sample.fetch('cpu_ms'), :>, 0
        assert_operator sample.fetch('allocations'), :>, 0
      end
      assert_equal Digest::SHA256.file(File.join(output, 'index.html')).hexdigest, report.dig('html', 'sha256')
      assert_equal Digest::SHA256.file(File.join(output, 'styles.css')).hexdigest, report.dig('css', 'sha256')
      assert_equal 'd97c35b3ba08f026536cb4c469623acb9957af59fb9a9171db012958515fe990', report.dig('html', 'sha256')
      assert_equal '67a6538e0b763c32ced001728ebf68f375dec497d4fb91c0ee136658ff9f2034', report.dig('css', 'sha256')
      assert report.fetch('dependencies').fetch('bigdecimal').fetch('version')
    end
  end

  def test_worker_rejects_invalid_iteration_count_without_a_success_report
    Dir.mktmpdir('horizon-worker-invalid') do |output|
      marker = File.join(output, 'benchmark.json')
      File.write(marker, 'old-success')
      File.write(File.join(output, 'report.json'), 'old-success')
      command = [RbConfig.ruby, File.join(HorizonFixture::PROJECT_ROOT, 'benchmark/worker.rb'), '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', @theme, '--fixture', File.join(HorizonFixture::PROJECT_ROOT, 'fixtures/store.json'), '--output-dir', output, '--benchmark-json', marker, '--iterations', '0']
      stdout, stderr, status = Open3.capture3(*command)
      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'iterations and warmup must be positive'
      refute File.exist?(File.join(output, 'report.json'))
      refute File.exist?(marker)
    end
  end

  def test_output_artifact_symlinks_cannot_overwrite_source_files
    Dir.mktmpdir('horizon-artifact-target') do |target_directory|
      protected_file = File.join(target_directory, 'original.txt')
      File.write(protected_file, 'unchanged')
      Dir.mktmpdir('horizon-artifact-output') do |output|
        File.symlink(protected_file, File.join(output, 'index.html'))
        command = [RbConfig.ruby, File.join(HorizonFixture::PROJECT_ROOT, 'bin/horizon-render'), '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', @theme, '--fixture', File.join(HorizonFixture::PROJECT_ROOT, 'fixtures/store.json'), '--output-dir', output]
        stdout, stderr, status = Open3.capture3(*command)
        refute status.success?
        assert_empty stdout
        assert_includes stderr, 'output artifact must not be a symlink'
        assert_equal 'unchanged', File.read(protected_file)
        assert File.symlink?(File.join(output, 'index.html'))
        refute File.exist?(File.join(output, 'report.json'))
      end
    end
  end

  def test_success_marker_symlinks_are_rejected_without_deleting_their_target
    Dir.mktmpdir('horizon-marker-target') do |directory|
      target = File.join(directory, 'original.json')
      link = File.join(directory, 'report.json')
      File.write(target, 'unchanged')
      File.symlink(target, link)
      assert_raises(ArgumentError) { HorizonFixture::Runtime.clear_success_markers!([link]) }
      assert_equal 'unchanged', File.read(target)
      assert File.symlink?(link)
    end
  end

  def test_clis_preserve_fixture_input_when_an_output_artifact_collides
    %w[bin/horizon-render benchmark/worker.rb].each do |entry|
      %w[index.html styles.css report.json].each do |name|
        Dir.mktmpdir('horizon-input-collision') do |output|
          input = File.join(output, name)
          original = '{"original":"fixture bytes"}'
          File.write(input, original)
          command = [RbConfig.ruby, File.join(HorizonFixture::PROJECT_ROOT, entry), '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', @theme, '--fixture', input, '--output-dir', output]
          stdout, stderr, status = Open3.capture3(*command)
          refute status.success?, "#{entry} #{name}"
          assert_empty stdout
          assert_includes stderr, 'output artifact must not replace fixture input'
          assert_equal original, File.read(input)
        end
      end
    end
    Dir.mktmpdir('horizon-benchmark-input-collision') do |directory|
      input = File.join(directory, 'store.json')
      original = '{"original":"fixture bytes"}'
      File.write(input, original)
      command = [RbConfig.ruby, File.join(HorizonFixture::PROJECT_ROOT, 'benchmark/worker.rb'), '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', @theme, '--fixture', input, '--output-dir', File.join(directory, 'output'), '--benchmark-json', input]
      stdout, stderr, status = Open3.capture3(*command)
      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'output artifact must not replace fixture input'
      assert_equal original, File.read(input)
    end
  end

  private

  def with_micro_theme(block_source:, snippet:)
    Dir.mktmpdir('horizon-contract') do |directory|
      files = {
        'config/settings_schema.json' => '[]',
        'config/settings_data.json' => '{"current":{}}',
        'sections/sample.liquid' => "{% content_for 'blocks' %}{% schema %}{\"settings\":[]}{% endschema %}",
        'blocks/sample.liquid' => block_source,
        'snippets/leaf.liquid' => snippet,
        'templates/index.json' => JSON.generate('sections' => { 'test' => { 'type' => 'sample', 'blocks' => { 'first' => { 'type' => 'sample', 'settings' => { 'text' => 'A' } }, 'second' => { 'type' => 'sample', 'settings' => { 'text' => 'B' } } }, 'block_order' => %w[second first] } }, 'order' => ['test'])
      }
      files.each do |path, body|
        absolute = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, body)
      end
      fixture = { 'schema_version' => 1, 'synthetic' => true, 'globals' => {}, 'theme' => {}, 'pages' => { 'index' => { 'template' => 'templates/index.json', 'title' => 'Test', 'description' => 'Test', 'url' => 'https://test.example/' } } }
      yield HorizonFixture::Renderer.new(theme_root: directory, fixture: fixture)
    end
  end
end
