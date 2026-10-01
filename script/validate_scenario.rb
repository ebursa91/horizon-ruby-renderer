# frozen_string_literal: true

require 'json'
require 'digest'

module HorizonScenarioValidation
  module_function

  def require_condition(condition, message)
    raise ArgumentError, message unless condition
  end

  def validate(fixture)
    require_condition(fixture['synthetic'] == true && fixture['schema_version'] == 1, 'scenario must be synthetic schema 1')
    manifest, globals = fixture.fetch('manifest'), fixture.fetch('globals')
    size, locale = manifest.fetch('product_count'), manifest.fetch('locale')
    require_condition([4, 100].include?(size), 'scenario size must be 4 or 100')
    require_condition(%w[en de pl].include?(locale), 'scenario locale must be en/de/pl')
    configuration = manifest.fetch('configuration')
    require_condition(%w[default wide].include?(configuration), 'scenario configuration must be default/wide')
    products = globals.fetch('all_products').values
    require_condition(products.length == size && globals.fetch('products').length == size, 'catalog product counts disagree')
    product_ids, variant_ids, image_ids, option_ids = [], [], [], []
    products.each do |product|
      product_ids << product.fetch('id')
      require_condition(globals.fetch('all_products').fetch(product.fetch('handle')) == product, 'catalog handle must identify canonical product')
      require_condition(product.fetch('url') == "/products/#{product.fetch('handle')}", 'product route must match handle')
      variants = product.fetch('variants')
      require_condition(variants.length == product.fetch('variants_count'), 'variant count disagrees')
      variants.each do |variant|
        variant_ids << variant.fetch('id')
        require_condition(variant.fetch('product').fetch('id') == product.fetch('id'), 'variant product reference mismatch')
        require_condition(variant.fetch('url') == "#{product.fetch('url')}?variant=#{variant.fetch('id')}", 'variant route/ID mismatch')
        require_condition(variant.fetch('price').is_a?(Integer) && variant.fetch('price') >= 0, 'variant prices must be nonnegative USD cents')
      end
      product.fetch('images').each do |image|
        image_ids << image.fetch('id')
        require_condition(image.fetch('product_id') == product.fetch('id'), 'image product reference mismatch')
        require_condition(image.fetch('src').match?(%r{\A/cdn/shop/products/[a-z-]+\.svg\z}), 'image must use original local synthetic SVG')
      end
      product.fetch('options_with_values').each do |option|
        option.fetch('values').each do |value|
          option_ids << value.fetch('id')
          require_condition(variants.any? { |variant| variant.fetch('id') == value.fetch('variant').fetch('id') }, 'option variant belongs to another product')
        end
      end
      prices = variants.map { |variant| variant.fetch('price') }
      require_condition(product.fetch('price_min') == prices.min && product.fetch('price_max') == prices.max, 'product price range mismatch')
    end
    { 'product' => product_ids, 'variant' => variant_ids, 'image' => image_ids, 'option' => option_ids }.each do |kind, identities|
      require_condition(identities.all? { |identity| identity.is_a?(Integer) && identity.positive? } && identities.uniq.length == identities.length, "#{kind} IDs must be positive and globally unique")
    end
    globals.fetch('collections').each_value do |collection|
      require_condition(collection.fetch('products_count') == collection.fetch('products').length && collection.fetch('all_products_count') == collection.fetch('products').length, 'collection counts disagree')
      collection.fetch('products').each do |product|
        require_condition(globals.fetch('all_products').fetch(product.fetch('handle')) == product, 'collection product must match canonical catalog snapshot')
      end
    end
    cart = globals.fetch('cart')
    require_condition(cart.fetch('item_count') == cart.fetch('items').sum { |line| line.fetch('quantity') }, 'cart quantity total mismatch')
    total = cart.fetch('items').sum do |line|
      product = globals.fetch('all_products').fetch(line.fetch('product').fetch('handle'))
      variant = product.fetch('variants').find { |item| item.fetch('id') == line.fetch('variant_id') }
      require_condition(variant && variant == line.fetch('variant'), 'cart variant must match canonical catalog')
      require_condition(product == line.fetch('product') && line.fetch('product_id') == product.fetch('id'), 'cart product snapshot mismatch')
      require_condition(line.fetch('quantity').is_a?(Integer) && line.fetch('quantity').positive?, 'cart quantities must be positive')
      expected = variant.fetch('price') * line.fetch('quantity')
      require_condition(%w[price original_price final_price].all? { |key| line.fetch(key) == variant.fetch('price') }, 'cart unit prices mismatch')
      require_condition(%w[line_price original_line_price final_line_price].all? { |key| line.fetch(key) == expected }, 'cart line prices mismatch')
      expected
    end
    require_condition(%w[total_price original_total_price items_subtotal_price].all? { |key| cart.fetch(key) == total }, 'cart total prices mismatch')
    require_condition(total == (configuration == 'wide' ? 24_400 : 13_100), 'cart total must match declared scenario configuration')
    expected_width = configuration == 'wide' ? 'wide' : 'narrow'
    require_condition(fixture.dig('theme', 'settings', 'page_width') == expected_width, 'page width must match scenario configuration')
    expected_variant_style = configuration == 'wide' ? 'dropdowns' : 'buttons'
    require_condition(fixture.dig('theme', 'page_overrides', 'product', 'block_overrides', 'variant_picker_R3rGDr', 'settings', 'variant_style') == expected_variant_style, 'variant picker style must match scenario configuration')
    require_condition(globals.dig('request', 'locale', 'iso_code') == locale && globals.dig('localization', 'language', 'iso_code') == locale, 'request/localization locales disagree')
    require_condition(globals.dig('shop', 'currency') == 'USD' && cart.dig('currency', 'iso_code') == 'USD', 'scenario currency must remain USD cents')
    request_ids = fixture.fetch('pages').values.map { |page| page.fetch('request_id') }
    require_condition(request_ids.uniq.length == request_ids.length && request_ids.all? { |id| id.is_a?(Integer) && (0..18_446_744_073_709_551_615).cover?(id) }, 'page request IDs must be unique unsigned 64-bit integers')
    fixture.fetch('pages').each do |page_key, page|
      type = page.fetch('type')
      require_condition(page.fetch('template') == "templates/#{type}.json", 'page must use genuine template for type')
      require_condition(page.fetch('canonical_url') == "#{globals.fetch('shop').fetch('url')}#{page.fetch('url')}", 'canonical URL must be absolute page URL')
      require_condition(locale == 'en' || page.fetch('url').start_with?("/#{locale}/"), 'page route must carry locale prefix')
      next if type == 'index'
      resource = page.fetch('resource')
      require_condition(resource.fetch('type') == type, 'page resource type mismatch')
      if type == 'product'
        product = globals.fetch('all_products').fetch(resource.fetch('handle'))
        require_condition(product.fetch('variants').any? { |variant| variant.fetch('id') == resource.fetch('variant_id') }, 'selected product variant does not exist')
      elsif type == 'collection'
        collection = globals.fetch('collections').fetch(resource.fetch('handle'))
        page_size = fixture.dig('theme', 'page_overrides', page_key, 'section_overrides', 'main', 'settings', 'products_per_page')
        pages = [(collection.fetch('products_count').to_f / page_size).ceil, 1].max
        require_condition((1..pages).cover?(page.fetch('current_page', 1)), 'collection page outside pagination range')
      else raise ArgumentError, "unsupported page type #{type}"
      end
    end
    require_condition(manifest.dig('platform_capabilities', 'payment_terms') == false && manifest.dig('platform_capabilities', 'payment_button') == false, 'payment services must be explicitly disabled')
    { 'scenario_id' => manifest.fetch('scenario_id'), 'products' => size, 'locale' => locale, 'pages' => fixture.fetch('pages').keys, 'cart_item_count' => cart.fetch('item_count'), 'cart_total_price' => total }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise ArgumentError, 'usage: validate_scenario.rb SCENARIO.json [...]' if ARGV.empty?
    reports = ARGV.map { |path| HorizonScenarioValidation.validate(JSON.parse(File.read(path))).merge('fixture_sha256' => Digest::SHA256.file(path).hexdigest) }
    puts JSON.pretty_generate(reports)
  rescue ArgumentError, KeyError => error
    warn error.message
    exit 1
  end
end
