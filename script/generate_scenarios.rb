# frozen_string_literal: true

require 'json'
require 'digest'
require 'optparse'
require 'fileutils'
require 'tempfile'

# Original synthetic scenarios derived from the original four product records.
# No theme, locale, or Liquid source is copied into these fixtures.
module HorizonScenarios
  BASE_SHA = '867c41e0929881290af2b261af64146632bf0287524f5a6c55714af32e819f98'
  LOCALES = {
    'en' => { 'name' => 'English', 'endonym_name' => 'English', 'iso_code' => 'en', 'direction' => 'ltr', 'root_url' => '/' },
    'de' => { 'name' => 'German', 'endonym_name' => 'Deutsch', 'iso_code' => 'de', 'direction' => 'ltr', 'root_url' => '/de' },
    'pl' => { 'name' => 'Polish', 'endonym_name' => 'Polski', 'iso_code' => 'pl', 'direction' => 'ltr', 'root_url' => '/pl' }
  }.freeze
  module_function

  def copy(value) = Marshal.load(Marshal.dump(value))

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def identifier(text) = Digest::SHA256.hexdigest(text)[0, 15].to_i(16)

  def cloned_product(source, index)
    handle = format('synthetic-item-%04d', index)
    title = "#{source.fetch('title')} #{format('%04d', index)}"
    identities = { source.fetch('id') => 10_000 + index }
    source.fetch('variants').each_with_index { |variant, ordinal| identities[variant.fetch('id')] = 100_000 + index * 10 + ordinal + 1 }
    source.fetch('images').each_with_index { |image, ordinal| identities[image.fetch('id')] = 200_000 + index * 10 + ordinal + 1 }
    source.fetch('options_with_values').each_with_index do |option, option_index|
      option.fetch('values').each_with_index { |value, value_index| identities[value.fetch('id')] = 400_000 + index * 100 + option_index * 10 + value_index + 1 }
    end
    rewrite = lambda do |value|
      case value
      when Hash
        value.to_h do |key, item|
          replacement = if key == 'src'
            item
          elsif %w[id product_id variant_id].include?(key) && identities.key?(item)
            identities.fetch(item)
          else
            rewrite.call(item)
          end
          [key, replacement]
        end
      when Array then value.map { |item| rewrite.call(item) }
      when String
        value.gsub(source.fetch('title'), title).gsub(source.fetch('handle'), handle).gsub(/(?<=variant=)\d+/) { |id| identities.fetch(id.to_i, id).to_s }
             .sub("HARBOR-#{source.fetch('id')}-", "SYNTHETIC-#{10_000 + index}-")
      else value
      end
    end
    product = rewrite.call(source)
    product['title'] = title
    product.fetch('variants').each { |variant| variant.fetch('product')['title'] = title }
    product['handle'] = handle
    product
  end

  def collection(base, products)
    value = copy(base)
    value['products'] = copy(products)
    value['products_count'] = value['all_products_count'] = products.length
    value['all_tags'] = value['tags'] = products.flat_map { |product| product.fetch('tags') }.uniq.sort
    value['all_types'] = products.map { |product| product.fetch('type') }.uniq.sort
    value['all_vendors'] = products.map { |product| product.fetch('vendor') }.uniq.sort
    value
  end

  def cart(base, products, chosen_product, scenario_id, configuration)
    quantities = configuration == 'wide' ? [3, 2] : [2, 1]
    selected_products = [products.first, chosen_product]
    value = copy(base)
    value['items'] = base.fetch('items').each_with_index.map do |old_line, index|
      line = copy(old_line)
      product = selected_products.fetch(index)
      variant = product.fetch('variants').fetch(index.zero? ? 0 : 1)
      price, quantity = variant.fetch('price'), quantities.fetch(index)
      line.merge!('id' => variant.fetch('id'), 'key' => "#{variant.fetch('id')}:#{Digest::SHA256.hexdigest("#{scenario_id}:line:#{index}")[0, 16]}",
                  'product_id' => product.fetch('id'), 'variant_id' => variant.fetch('id'), 'product' => copy(product), 'variant' => copy(variant),
                  'quantity' => quantity, 'title' => "#{product.fetch('title')} - #{variant.fetch('title')}",
                  'url' => variant.fetch('url'), 'sku' => variant.fetch('sku'), 'image' => copy(variant.fetch('image')),
                  'featured_image' => copy(variant.fetch('featured_image')), 'options_with_values' => copy(variant.fetch('options_with_values')),
                  'price' => price, 'original_price' => price, 'final_price' => price,
                  'line_price' => price * quantity, 'original_line_price' => price * quantity, 'final_line_price' => price * quantity)
      line
    end
    value['item_count'] = quantities.sum
    value['total_price'] = value['original_total_price'] = value['items_subtotal_price'] = value.fetch('items').sum { |line| line.fetch('final_line_price') }
    value['checkout_charge_amount'] = value.fetch('total_price')
    value['total_weight'] = value.fetch('items').sum { |line| line.fetch('variant').fetch('weight') * line.fetch('quantity') }
    value['token'] = "synthetic-#{Digest::SHA256.hexdigest(scenario_id)[0, 24]}"
    value
  end

  def build(base, size:, locale:, configuration:)
    raise ArgumentError, 'size must be 4 or 100' unless [4, 100].include?(size)
    raise ArgumentError, 'configuration must be default or wide' unless %w[default wide].include?(configuration)
    language = LOCALES.fetch(locale)
    scenario_id = "harbor-#{size}-#{locale}-#{configuration}"
    fixture = copy(base)
    products = copy(base.fetch('globals').fetch('all_products').values)
    originals = copy(products)
    (5..size).each { |index| products << cloned_product(originals.fetch((index - 1) % 4), index) }
    chosen_product = products.last
    globals = fixture.fetch('globals')
    globals.fetch('shop')['products_count'] = size
    globals['all_products'] = products.to_h { |product| [product.fetch('handle'), copy(product)] }
    globals['products'] = copy(products)
    globals['collections'] = base.fetch('globals').fetch('collections').to_h do |handle, old_collection|
      selected = handle == 'sale' ? products.select { |product| product['compare_at_price'] } : products
      [handle, collection(old_collection, selected)]
    end
    globals['cart'] = cart(base.fetch('globals').fetch('cart'), products, chosen_product, scenario_id, configuration)
    globals['localization']['language'] = copy(language)
    globals['localization']['available_languages'] = copy(LOCALES.values)
    globals['request']['locale'] = copy(language)
    prefix = locale == 'en' ? '' : "/#{locale}"
    globals['routes'].transform_values! { |route| route.is_a?(String) && route.start_with?('/') ? "#{prefix}#{route == '/' ? '/' : route}" : route }
    globals['request']['path'] = "#{prefix}/"
    globals['canonical_url'] = "#{globals.fetch('shop').fetch('url')}#{prefix}/"
    globals['recommendations'] = { 'performed' => false, 'products' => [], 'products_count' => 0, 'intent' => 'related' }
    fixture['pages'] = {
      'index' => copy(base.fetch('pages').fetch('index')).merge('type' => 'index', 'url' => "#{prefix}/", 'canonical_url' => globals.fetch('canonical_url'), 'request_id' => identifier("#{scenario_id}:index")),
      'product' => { 'type' => 'product', 'template' => 'templates/product.json', 'title' => chosen_product.fetch('title'), 'description' => "Synthetic #{chosen_product.fetch('title')} product fixture.",
                     'url' => "#{prefix}#{chosen_product.fetch('url')}", 'canonical_url' => "#{globals.fetch('shop').fetch('url')}#{prefix}#{chosen_product.fetch('url')}", 'request_id' => identifier("#{scenario_id}:product"),
                     'resource' => { 'type' => 'product', 'handle' => chosen_product.fetch('handle'), 'variant_id' => chosen_product.fetch('variants').fetch(1).fetch('id') } },
      'collection' => { 'type' => 'collection', 'template' => 'templates/collection.json', 'title' => 'All products', 'description' => "Synthetic collection with #{size} products.",
                        'url' => "#{prefix}/collections/all", 'canonical_url' => "#{globals.fetch('shop').fetch('url')}#{prefix}/collections/all", 'request_id' => identifier("#{scenario_id}:collection"),
                        'resource' => { 'type' => 'collection', 'handle' => 'all' } }
    }
    fixture.fetch('theme')['settings']['page_width'] = configuration == 'wide' ? 'wide' : 'narrow'
    fixture.fetch('theme')['page_overrides'] = {
      'product' => { 'block_overrides' => { 'variant_picker_R3rGDr' => { 'settings' => { 'variant_style' => configuration == 'wide' ? 'dropdowns' : 'buttons', 'show_swatches' => false } } } },
      'collection' => { 'section_overrides' => { 'main' => { 'settings' => { 'enable_infinite_scroll' => false, 'products_per_page' => configuration == 'wide' ? 12 : 24, 'product_grid_width' => configuration == 'wide' ? 'full-width' : 'centered' } } } }
    }
    if size == 100
      pages = (size.to_f / (configuration == 'wide' ? 12 : 24)).ceil
      { 'collection_page_2' => 2, 'collection_last' => pages }.each do |page_key, page_number|
        fixture.fetch('pages')[page_key] = copy(fixture.fetch('pages').fetch('collection')).merge('current_page' => page_number, 'request_id' => identifier("#{scenario_id}:#{page_key}"))
        fixture.fetch('theme').fetch('page_overrides')[page_key] = copy(fixture.fetch('theme').fetch('page_overrides').fetch('collection'))
      end
    end
    fixture.fetch('manifest').merge!('scenario_id' => scenario_id, 'request_id' => identifier(scenario_id), 'product_count' => size, 'locale' => locale, 'configuration' => configuration,
                                     'mock_contract' => { 'json_object_order' => 'sorted', 'javascript' => 'inline raw script once per source', 'structured_data' => 'synthetic Schema.org ProductGroup', 'pagination' => 'selected page with sliced products' })
    fixture.fetch('manifest').fetch('platform_capabilities')['payment_button'] = false
    canonical(fixture)
  end

  def main(argv)
    options = { base: File.expand_path('../fixtures/store.json', __dir__), spec: File.expand_path('../fixtures/scenarios.json', __dir__) }
    OptionParser.new do |parser|
      parser.on('--base PATH') { |value| options[:base] = value }
      parser.on('--spec PATH') { |value| options[:spec] = value }
      parser.on('--output-dir PATH') { |value| options[:output] = value }
    end.parse!(argv)
    raise ArgumentError, '--output-dir is required' unless options[:output]
    bytes = File.binread(options.fetch(:base))
    raise ArgumentError, 'original homepage fixture SHA changed' unless Digest::SHA256.hexdigest(bytes) == BASE_SHA
    base = JSON.parse(bytes)
    spec = JSON.parse(File.read(options.fetch(:spec)))
    raise ArgumentError, 'scenario specification must use original fixture pin and schema 1' unless spec['schema_version'] == 1 && spec['base_fixture_sha256'] == BASE_SHA
    FileUtils.mkdir_p(options.fetch(:output))
    spec.fetch('sizes').product(spec.fetch('locales'), spec.fetch('configurations')).each do |size, locale, configuration|
      fixture = build(base, size: size, locale: locale, configuration: configuration)
      path = File.join(options.fetch(:output), "#{fixture.fetch('manifest').fetch('scenario_id')}.json")
      raise ArgumentError, "generated fixture cannot replace its source: #{path}" if File.expand_path(path) == File.realpath(options.fetch(:base))
      raise ArgumentError, "generated fixture must not be a symlink: #{path}" if File.symlink?(path)
      raise ArgumentError, "generated fixture must be a regular file: #{path}" if File.exist?(path) && !File.file?(path)
      Tempfile.create(['.scenario-', '.json'], options.fetch(:output)) do |temporary|
        temporary.write("#{JSON.pretty_generate(fixture)}\n")
        temporary.close
        File.rename(temporary.path, path)
      end
    end
  end
end

HorizonScenarios.main(ARGV) if $PROGRAM_NAME == __FILE__
