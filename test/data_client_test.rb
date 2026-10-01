# frozen_string_literal: true

require 'json'
require 'digest'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative '../lib/horizon_fixture/data_client'

class HorizonDataClientTest < Minitest::Test
  FIELDS = { tenant_id: 'demo-a', storefront_id: 'small', locale: 'en', configuration: 'published', page: 'index', current_page: 1, cart_id: 'default', request_id: 'request-0001' }.freeze

  class Stub
    attr_reader :request, :arguments
    def initialize(&callback) = @callback = callback
    def get_render_context(request, **arguments)
      @request, @arguments = request, arguments
      @callback.call(request)
    end
  end

  class Service < Horizon::Store::V1::StoreContextService::Service
    def initialize(&callback) = @callback = callback
    def get_render_context(request, call)
      raise GRPC::Unauthenticated, 'unauthorized' unless call.metadata['authorization'] == 'Bearer mock-tenant-a-token'
      raise GRPC::PermissionDenied, 'tenant mismatch' unless request.tenant_id == 'demo-a'
      @callback.call(request)
    end
  end

  def fixture
    { 'synthetic' => true, 'schema_version' => 1, 'manifest' => { 'service_scope' => FIELDS.slice(:tenant_id, :storefront_id, :locale, :configuration, :page, :current_page, :cart_id).transform_keys(&:to_s) },
      'globals' => { 'request' => { 'locale' => { 'iso_code' => 'en' } }, 'localization' => { 'language' => { 'iso_code' => 'en' } } },
      'theme' => { 'sha' => HorizonFixture::THEME_SHA, 'configuration_source' => 'service', 'settings' => {} },
      'pages' => { 'index' => { 'type' => 'index', 'template' => 'templates/index.json', 'current_page' => 1 } } }
  end

  def response(document = fixture, **changes)
    bytes = JSON.generate(document)
    Horizon::Store::V1::GetRenderContextResponse.new(**FIELDS, context_json: bytes, context_sha256: Digest::SHA256.hexdigest(bytes), snapshot_revision: 'snapshot-0001', **changes)
  end

  def client(stub:, **options)
    HorizonFixture::DataClient.new(endpoint: '127.0.0.1:50051', token: 'mock-tenant-a-token', stub: stub, **options)
  end

  def test_valid_snapshot_preserves_authoritative_data_and_sets_bounded_deadline
    reply = response
    stub = Stub.new { reply }
    before = Time.now
    snapshot = client(stub: stub).fetch(**FIELDS)
    assert_equal fixture, snapshot.fixture
    assert_equal reply.context_sha256, snapshot.metadata.fetch('context_sha256')
    assert_equal false, snapshot.metadata.fetch('local_fixture_fallback')
    assert_equal true, snapshot.metadata.fetch('authoritative_rpc')
    assert_equal FIELDS.fetch(:request_id), stub.request.request_id
    assert_equal 'Bearer mock-tenant-a-token', stub.arguments.fetch(:metadata).fetch('authorization')
    assert_in_delta 5.0, stub.arguments.fetch(:deadline) - before, 0.1
    assert_operator snapshot.metadata.fetch('fetch_ms'), :>=, 0
    refute_includes JSON.generate(snapshot.metadata), 'mock-tenant-a-token'
  end

  def test_each_echoed_scope_field_must_match_request
    HorizonFixture::DataClient::SCOPE_FIELDS.each do |field|
      reply = response
      reply.public_send("#{field}=", field == :current_page ? 2 : 'wrong-scope')
      error = assert_raises(HorizonFixture::DataServiceError) { client(stub: Stub.new { reply }).fetch(**FIELDS) }
      assert_includes error.message, field.to_s
    end
  end

  def test_invalid_context_hash_scope_schema_locale_and_page_fail_closed
    replies = [response(context_sha256: '0' * 64), response(context_json: ''), response(snapshot_revision: '')]
    bad = fixture; bad.fetch('manifest').fetch('service_scope')['tenant_id'] = 'demo-b'; replies << response(bad)
    bad = fixture; bad.fetch('manifest').fetch('service_scope')['page'] = 'product'; replies << response(bad)
    bad = fixture; bad.fetch('manifest').fetch('service_scope')['current_page'] = 1.0; replies << response(bad)
    bad = fixture; bad['synthetic'] = false; replies << response(bad)
    bad = fixture; bad['schema_version'] = 1.0; replies << response(bad)
    bad = fixture; bad.fetch('theme')['sha'] = '0' * 40; replies << response(bad)
    bad = fixture; bad.fetch('theme').delete('configuration_source'); replies << response(bad)
    bad = fixture; bad.fetch('pages').clear; replies << response(bad)
    bad = fixture; bad.fetch('pages').fetch('index')['template'] = 'templates/product.json'; replies << response(bad)
    bad = fixture; bad.fetch('pages').fetch('index')['current_page'] = 2; replies << response(bad)
    bad = fixture; bad.fetch('globals').fetch('request').fetch('locale')['iso_code'] = 'pl'; replies << response(bad)
    bad = fixture; bad['manifest'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('manifest')['service_scope'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('theme')['settings'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('globals')['request'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('globals').fetch('request')['locale'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('globals')['localization'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('globals').fetch('localization')['language'] = 'invalid'; replies << response(bad)
    bad = fixture; bad.fetch('globals').fetch('localization').fetch('language')['iso_code'] = 'pl'; replies << response(bad)
    replies.each { |reply| assert_raises(HorizonFixture::DataServiceError) { client(stub: Stub.new { reply }).fetch(**FIELDS) } }
    invalid_utf8 = "\xFF".b
    replies = [response(context_json: invalid_utf8, context_sha256: Digest::SHA256.hexdigest(invalid_utf8)),
               response(context_json: '{', context_sha256: Digest::SHA256.hexdigest('{'))]
    replies.each { |reply| assert_raises(HorizonFixture::DataServiceError) { client(stub: Stub.new { reply }).fetch(**FIELDS) } }
  end

  def test_baseline_requires_exact_original_bytes_and_fixed_scope
    original = File.binread(File.expand_path('../fixtures/store.json', __dir__))
    fields = FIELDS.merge(configuration: 'baseline')
    reply = response(context_json: original, context_sha256: Digest::SHA256.hexdigest(original), configuration: 'baseline')
    snapshot = client(stub: Stub.new { reply }).fetch(**fields)
    assert_equal JSON.parse(original), snapshot.fixture
    mutated = JSON.parse(original); mutated.fetch('globals').fetch('shop')['name'] = 'wrong tenant'
    bytes = JSON.generate(mutated)
    reply = response(context_json: bytes, context_sha256: Digest::SHA256.hexdigest(bytes), configuration: 'baseline')
    assert_raises(HorizonFixture::DataServiceError) { client(stub: Stub.new { reply }).fetch(**fields) }
  end

  def test_input_bounds_and_close_prevent_calls
    stub = Stub.new { raise 'must not call RPC' }
    ['example.com:50051', '127.0.0.1:0', '127.0.0.1:65536', 'http://127.0.0.1:50051'].each do |endpoint|
      assert_raises(ArgumentError) { HorizonFixture::DataClient.new(endpoint: endpoint, token: 'token', stub: stub) }
    end
    [0, -1, 10.1, Float::NAN, Float::INFINITY].each { |seconds| assert_raises(ArgumentError) { client(stub: stub, deadline_seconds: seconds) } }
    [0, -1, 2**32, 1.5, false].each { |page| assert_raises(ArgumentError) { client(stub: stub).fetch(**FIELDS.merge(current_page: page)) } }
    ['', 'x' * 129, "line\nfeed"].each { |id| assert_raises(ArgumentError) { client(stub: stub).fetch(**FIELDS.merge(request_id: id)) } }
    closed = client(stub: stub); closed.close
    assert_raises(HorizonFixture::DataServiceError) { closed.fetch(**FIELDS) }
  end

  def test_native_rpc_round_trip_reuses_connection_and_rejects_tenant_mismatch
    with_server(->(request) { response(request_id: request.request_id) }) do |endpoint|
      live = HorizonFixture::DataClient.new(endpoint: endpoint, token: 'mock-tenant-a-token')
      assert_equal 'request-0001', live.fetch(**FIELDS).metadata.fetch('request_id')
      assert_equal 'request-0002', live.fetch(**FIELDS.merge(request_id: 'request-0002')).metadata.fetch('request_id')
      error = assert_raises(HorizonFixture::DataServiceError) { live.fetch(**FIELDS.merge(tenant_id: 'demo-b')) }
      assert_includes error.message, 'status 7'
      live.close
    end
  end

  def test_native_rpc_deadline_and_unavailability_never_return_fixtures
    with_server(->(_request) { sleep 0.15; response }) do |endpoint|
      live = HorizonFixture::DataClient.new(endpoint: endpoint, token: 'mock-tenant-a-token', deadline_seconds: 0.02)
      error = assert_raises(HorizonFixture::DataServiceError) { live.fetch(**FIELDS) }
      assert_includes error.message, 'status 4'
      live.close
    end
    live = HorizonFixture::DataClient.new(endpoint: '127.0.0.1:1', token: 'mock-tenant-a-token', deadline_seconds: 0.1)
    error = assert_raises(HorizonFixture::DataServiceError) { live.fetch(**FIELDS) }
    assert_match(/status (4|14)/, error.message)
    live.close
  end

  def test_cli_native_rpc_renders_original_oracle_and_clears_stale_success_on_failure
    original = File.binread(File.expand_path('../fixtures/store.json', __dir__))
    callback = lambda do |request|
      response(context_json: original, context_sha256: Digest::SHA256.hexdigest(original), configuration: request.configuration, request_id: request.request_id)
    end
    with_server(callback) do |endpoint|
      Dir.mktmpdir('horizon-rpc-cli-') do |output|
        command = [RbConfig.ruby, '-rbundler/setup', File.expand_path('../bin/horizon-render', __dir__),
          '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', ENV.fetch('HORIZON_THEME_ROOT'),
          '--grpc-endpoint', endpoint, '--tenant-id', 'demo-a', '--storefront-id', 'small', '--configuration', 'baseline',
          '--request-id', 'request-0001', '--output-dir', output]
        stdout, stderr, status = Open3.capture3({ 'HORIZON_DATA_TOKEN' => 'mock-tenant-a-token' }, *command)
        assert status.success?, stderr
        report = JSON.parse(stdout)
        assert_equal 'd97c35b3ba08f026536cb4c469623acb9957af59fb9a9171db012958515fe990', report.dig('html', 'sha256')
        assert_equal '67a6538e0b763c32ced001728ebf68f375dec497d4fb91c0ee136658ff9f2034', report.dig('css', 'sha256')
        assert_equal 'native grpc', report.dig('data_service', 'transport')
        assert_equal false, report.dig('data_service', 'local_fixture_fallback')
        refute_includes stdout, 'mock-tenant-a-token'
        _, stderr, status = Open3.capture3({ 'HORIZON_DATA_TOKEN' => 'wrong-token' }, *command)
        refute status.success?
        assert_includes stderr, 'status 16'
        refute File.exist?(File.join(output, 'report.json'))
        _, stderr, status = Open3.capture3({ 'HORIZON_DATA_TOKEN' => 'mock-tenant-a-token' }, *command, '--fixture', File.expand_path('../fixtures/store.json', __dir__))
        refute status.success?
        assert_includes stderr, 'cannot be combined'
      end
    end
  end

  private

  def with_server(callback)
    server = GRPC::RpcServer.new(pool_size: 2, poll_period: 0.1)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(Service.new(&callback))
    thread = Thread.new { server.run_till_terminated }
    raise 'native test server did not start' unless server.wait_till_running(3)
    yield "127.0.0.1:#{port}"
  ensure
    server.stop if server&.running_state == :running
    thread&.join(3)
  end
end
