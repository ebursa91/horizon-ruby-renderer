# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'runtime'
$LOAD_PATH.unshift(File.expand_path('../horizon_store_service', __dir__))
require_relative '../horizon_store_service/horizon/store/v1/store_context_services_pb'

module HorizonFixture
  class DataServiceError < StandardError; end

  # One native gRPC call supplies the whole authoritative store/config snapshot.
  # The client has no local fixture fallback and never patches fetched data.
  class DataClient
    MAX_CONTEXT_BYTES = 64 * 1024 * 1024
    MAX_REQUEST_BYTES = 8 * 1024
    BASELINE_SHA256 = '867c41e0929881290af2b261af64146632bf0287524f5a6c55714af32e819f98'
    SCOPE_FIELDS = %i[tenant_id storefront_id locale configuration page current_page cart_id request_id].freeze
    Snapshot = Data.define(:fixture, :metadata)

    def initialize(endpoint:, token:, deadline_seconds: 5.0, stub: nil)
      unless endpoint.is_a?(String) && (match = endpoint.match(/\A(?:127\.0\.0\.1|\[::1\]):(\d+)\z/)) && (1..65_535).cover?(match[1].to_i)
        raise ArgumentError, 'mock data endpoint must be a loopback IP and valid port'
      end
      unless token.is_a?(String) && /\A[A-Za-z0-9._~-]{1,256}\z/.match?(token)
        raise ArgumentError, 'data-service bearer token must be a bounded ASCII token'
      end
      @deadline = Float(deadline_seconds)
      raise ArgumentError, 'data-service deadline must be finite, positive, and at most 10 seconds' unless @deadline.finite? && @deadline.positive? && @deadline <= 10
      @endpoint, @token = endpoint.dup.freeze, token.dup.freeze
      unless stub
        @channel = GRPC::Core::Channel.new(endpoint,
          { 'grpc.max_receive_message_length' => MAX_CONTEXT_BYTES + MAX_REQUEST_BYTES, 'grpc.max_send_message_length' => MAX_REQUEST_BYTES },
          :this_channel_is_insecure)
      end
      @stub = stub || Horizon::Store::V1::StoreContextService::Stub.new(endpoint, :this_channel_is_insecure, channel_override: @channel)
    end

    def close
      return if @closed
      @channel&.close
      @closed = true
    end

    def fetch(tenant_id:, storefront_id:, locale: 'en', configuration: 'published', page: 'index', current_page: 1, cart_id: 'default', request_id:)
      raise DataServiceError, 'data-service client is closed' if @closed
      fields = { tenant_id: tenant_id, storefront_id: storefront_id, locale: locale, configuration: configuration,
                 page: page, current_page: current_page, cart_id: cart_id, request_id: request_id }
      fields.each do |key, value|
        next if key == :current_page
        unless value.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(value)
          raise ArgumentError, "data-service #{key} must be a bounded ASCII identifier"
        end
      end
      unless current_page.is_a?(Integer) && (1..4_294_967_295).cover?(current_page)
        raise ArgumentError, 'data-service current_page must be a positive uint32'
      end
      request = Horizon::Store::V1::GetRenderContextRequest.new(**fields)
      raise ArgumentError, 'data-service request exceeds 8 KiB' if Horizon::Store::V1::GetRenderContextRequest.encode(request).bytesize > MAX_REQUEST_BYTES
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @stub.get_render_context(request, deadline: Time.now + @deadline, metadata: { 'authorization' => "Bearer #{@token}" })
      fetch_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      SCOPE_FIELDS.each do |key|
        raise DataServiceError, "data-service response #{key} scope mismatch" unless response.public_send(key) == fields.fetch(key)
      end
      bytes = response.context_json.dup.force_encoding(Encoding::UTF_8)
      raise DataServiceError, 'data-service context must be nonempty UTF-8 JSON below 64 MiB' unless bytes.bytesize.positive? && bytes.bytesize <= MAX_CONTEXT_BYTES && bytes.valid_encoding?
      sha = Digest::SHA256.hexdigest(bytes)
      unless /\A[0-9a-f]{64}\z/.match?(response.context_sha256) && sha == response.context_sha256
        raise DataServiceError, 'data-service context SHA256 mismatch'
      end
      unless /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/.match?(response.snapshot_revision)
        raise DataServiceError, 'data-service snapshot revision must be a bounded identifier'
      end
      fixture = JSON.parse(bytes, max_nesting: 256)
      unless fixture.is_a?(Hash) && fixture['synthetic'] == true && fixture['schema_version'].is_a?(Integer) && fixture['schema_version'] == 1 && fixture['globals'].is_a?(Hash) && fixture['theme'].is_a?(Hash) && fixture['pages'].is_a?(Hash)
        raise DataServiceError, 'data-service context must be synthetic fixture schema 1'
      end
      raise DataServiceError, 'data-service theme SHA does not match pin' unless fixture.dig('theme', 'sha') == THEME_SHA
      if configuration == 'baseline'
        unless sha == BASELINE_SHA256 && tenant_id == 'demo-a' && storefront_id == 'small' && locale == 'en' && page == 'index' && current_page == 1 && cart_id == 'default'
          raise DataServiceError, 'data-service baseline context does not match its immutable scope and pin'
        end
      else
        raise DataServiceError, 'data-service context must own saved theme configuration' unless fixture.dig('theme', 'configuration_source') == 'service'
        unless fixture['theme']['settings'].is_a?(Hash) && fixture['manifest'].is_a?(Hash)
          raise DataServiceError, 'data-service context configuration and manifest must be objects'
        end
        scope = fixture['manifest']['service_scope']
        unless scope.is_a?(Hash) && %i[tenant_id storefront_id locale configuration page current_page cart_id].all? { |key| scope[key.to_s].is_a?(key == :current_page ? Integer : String) && scope[key.to_s] == fields.fetch(key) }
          raise DataServiceError, 'data-service context tenant/store/config/cart scope mismatch'
        end
      end
      page_data = fixture.fetch('pages')[page]
      raise DataServiceError, 'data-service context does not contain requested page' unless page_data.is_a?(Hash)
      page_type = page_data.fetch('type', page)
      unless %w[index product collection].include?(page_type) && page_data['template'] == "templates/#{page_type}.json"
        raise DataServiceError, 'data-service page must use its genuine pinned template'
      end
      # An omitted page number is compatible only with the immutable baseline page 1.
      global_page = fixture.dig('globals', 'current_page')
      context_page = page_data.fetch('current_page', global_page.nil? ? 1 : global_page)
      raise DataServiceError, 'data-service context page number mismatch' unless context_page.is_a?(Integer) && context_page == current_page
      request_context = fixture['globals']['request']
      localization = fixture['globals']['localization']
      unless request_context.is_a?(Hash) && request_context['locale'].is_a?(Hash) && localization.is_a?(Hash) && localization['language'].is_a?(Hash)
        raise DataServiceError, 'data-service request locale and localization language must be objects'
      end
      unless request_context['locale']['iso_code'] == locale && localization['language']['iso_code'] == locale
        raise DataServiceError, 'data-service context locale mismatch'
      end
      metadata = fields.transform_keys(&:to_s).merge('transport' => 'native grpc', 'authoritative_rpc' => true, 'endpoint' => @endpoint,
        'snapshot_revision' => response.snapshot_revision, 'context_sha256' => sha, 'context_bytes' => bytes.bytesize,
        'fetch_ms' => fetch_ms, 'deadline_seconds' => @deadline, 'local_fixture_fallback' => false,
        'grpc_version' => GRPC::VERSION, 'google_protobuf_version' => Gem.loaded_specs.fetch('google-protobuf').version.to_s)
      Snapshot.new(fixture: fixture, metadata: metadata.freeze)
    rescue GRPC::BadStatus => error
      raise DataServiceError, "data-service RPC failed (status #{error.code})"
    rescue JSON::ParserError => error
      raise DataServiceError, "data-service context JSON is invalid: #{error.class}"
    end
  end
end
