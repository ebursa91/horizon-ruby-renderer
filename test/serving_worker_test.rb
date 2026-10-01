# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'json'
require 'digest'
require 'timeout'
require 'tmpdir'
require 'stringio'
require_relative '../benchmark/serve_worker'

class HorizonServingWorkerTest < Minitest::Test
  def test_real_requests_preserve_ids_binary_framing_metadata_and_clean_eof
    %w[direct fiber].each do |mode|
      with_worker('--mode', mode) do |input, output, errors, process|
        ready = JSON.parse(output.readline)
        assert_equal 'ready', ready.fetch('action')
        assert_equal true, ready.fetch('correctness_verified')
        assert_equal false, ready.fetch('response_cache')
        assert_equal mode, ready.fetch('execution_mode')
        assert_equal HorizonFixture::LIQUID_SHA, ready.fetch('liquid_sha')
        assert_equal HorizonFixture::THEME_SHA, ready.fetch('theme_sha')
        assert_equal HorizonFixture::ServingWorker::FIXTURE_SHA256, ready.fetch('fixture_sha256')
        assert_equal RUBY_VERSION, ready.fetch('ruby_version')
        assert_includes [true, false], ready.fetch('yjit_enabled')
        assert_equal 1, ready.fetch('warmup')
        assert_equal HorizonFixture::ServingWorker::ORACLE.fetch('html'), ready.fetch('html')
        assert_equal HorizonFixture::ServingWorker::ORACLE.fetch('css'), ready.fetch('css')
        assert ready.fetch('dependencies').fetch('bigdecimal').fetch('version')
        [101, HorizonFixture::ServingWorker::MAX_REQUEST_ID].each do |id|
          input.puts(JSON.generate('action' => 'render', 'request_id' => id))
          input.flush
          response = JSON.parse(output.readline)
          assert_equal({ 'request_id' => id, 'html_bytes' => 435_304, 'css_bytes' => 279_112, 'error' => nil }, response)
          html = output.read(response.fetch('html_bytes'))
          css = output.read(response.fetch('css_bytes'))
          assert_equal 435_304, html.bytesize
          assert_equal 279_112, css.bytesize
          assert_equal HorizonFixture::ServingWorker::ORACLE.dig('html', 'sha256'), Digest::SHA256.hexdigest(html)
          assert_equal HorizonFixture::ServingWorker::ORACLE.dig('css', 'sha256'), Digest::SHA256.hexdigest(css)
        end
        input.close
        assert_empty output.read
        assert process.value.success?, errors.read
      end
    end
  end

  def test_invalid_action_returns_no_body_and_fails_the_process
    with_worker do |input, output, errors, process|
      assert_equal 'ready', JSON.parse(output.readline).fetch('action')
      input.puts(JSON.generate('action' => 'cached_response', 'request_id' => 17))
      input.flush
      failed = JSON.parse(output.readline)
      assert_equal 0, failed.fetch('html_bytes')
      assert_equal 0, failed.fetch('css_bytes')
      assert_includes failed.fetch('error'), 'expected render action'
      assert_empty output.read
      refute process.value.success?
      assert_includes errors.read, 'expected render action'
    end
  end

  def test_oversized_header_is_bounded_and_fails_without_body
    with_worker do |input, output, errors, process|
      assert_equal 'ready', JSON.parse(output.readline).fetch('action')
      input.write('x' * (HorizonFixture::ServingWorker::MAX_HEADER_BYTES + 1))
      input.flush
      failed = JSON.parse(output.readline)
      assert_includes failed.fetch('error'), 'request header exceeds limit'
      assert_equal 0, failed.fetch('html_bytes')
      assert_equal 0, failed.fetch('css_bytes')
      assert_empty output.read
      refute process.value.success?
      assert_includes errors.read, 'request header exceeds limit'
    end
  end

  def test_invalid_json_and_noninteger_ids_fail_without_faking_response_bytes
    invalid = [false, -1, 1.0, HorizonFixture::ServingWorker::MAX_REQUEST_ID + 1]
    lines = ["{invalid json}\n"] + invalid.map { |id| JSON.generate('action' => 'render', 'request_id' => id) + "\n" }
    lines.each do |line|
      with_worker do |input, output, errors, process|
        assert_equal 'ready', JSON.parse(output.readline).fetch('action')
        input.write(line)
        input.flush
        failed = JSON.parse(output.readline)
        assert_equal 0, failed.fetch('html_bytes')
        assert_equal 0, failed.fetch('css_bytes')
        refute_empty failed.fetch('error')
        assert_empty output.read
        refute process.value.success?
        refute_empty errors.read
      end
    end
  end

  def test_incomplete_header_at_eof_fails_instead_of_becoming_a_request
    with_worker do |input, output, errors, process|
      assert_equal 'ready', JSON.parse(output.readline).fetch('action')
      input.write(JSON.generate('action' => 'render', 'request_id' => 303))
      input.close
      failed = JSON.parse(output.readline)
      assert_includes failed.fetch('error'), 'lacks newline'
      assert_empty output.read
      refute process.value.success?
      refute_empty errors.read
    end
  end

  def test_non_synthetic_fixture_never_becomes_ready
    fixture = JSON.parse(File.read(fixture_path))
    fixture['synthetic'] = false
    Dir.mktmpdir('horizon-invalid-serving-store') do |directory|
      path = File.join(directory, 'store.json')
      File.write(path, JSON.generate(fixture))
      with_worker('--fixture', path) do |input, output, errors, process|
        input.close
        failed = JSON.parse(output.readline)
        refute failed.key?('action')
        assert_equal 0, failed.fetch('html_bytes')
        assert_includes failed.fetch('error'), 'expected synthetic fixture'
        assert_empty output.read
        refute process.value.success?
        assert_includes errors.read, 'expected synthetic fixture'
      end
    end
  end

  def test_changed_synthetic_fixture_hash_never_becomes_ready
    fixture = JSON.parse(File.read(fixture_path))
    fixture.fetch('globals').fetch('shop')['name'] = 'Changed fixture'
    Dir.mktmpdir('horizon-changed-serving-store') do |directory|
      path = File.join(directory, 'store.json')
      File.write(path, JSON.generate(fixture))
      with_worker('--fixture', path) do |input, output, errors, process|
        input.close
        failed = JSON.parse(output.readline)
        assert_includes failed.fetch('error'), 'fixture SHA256 does not match pinned store'
        assert_equal 0, failed.fetch('html_bytes')
        assert_empty output.read
        refute process.value.success?
        assert_includes errors.read, 'fixture SHA256 does not match pinned store'
      end
    end
  end

  def test_control_and_unicode_render_errors_keep_the_fatal_frame_bounded_and_parseable
    ["\u0000" * 700 + '☂' * 700, '☂' * 700 + "\u0000" * 700].each do |message|
      worker_class = Class.new(HorizonFixture::ServingWorker)
      worker_class.define_method(:render) { raise ArgumentError, message }
      output, errors = StringIO.new, StringIO.new
      options = { warmup: 1, mode: 'direct', liquid_root: ENV.fetch('LIQUID_RUBY_ROOT'), theme_root: ENV.fetch('HORIZON_THEME_ROOT'), fixture: fixture_path }
      status = worker_class.new(options, input: StringIO.new, output: output, errors: errors).run
      assert_equal 1, status
      frame = output.string
      assert_operator frame.bytesize, :<=, HorizonFixture::ServingWorker::MAX_HEADER_BYTES
      assert frame.end_with?("\n")
      failed = JSON.parse(frame)
      assert_equal 0, failed.fetch('html_bytes')
      assert_equal 0, failed.fetch('css_bytes')
      assert_includes failed.fetch('error'), 'ArgumentError'
      refute_empty errors.string
    end
  end

  private

  def fixture_path = File.expand_path('../fixtures/store.json', __dir__)

  def with_worker(*extra)
    command = [RbConfig.ruby, File.expand_path('../benchmark/serve_worker.rb', __dir__), '--liquid-root', ENV.fetch('LIQUID_RUBY_ROOT'), '--theme-root', ENV.fetch('HORIZON_THEME_ROOT'), '--fixture', fixture_path, '--warmup', '1', *extra]
    Open3.popen3(*command) do |input, output, errors, process|
      input.binmode
      output.binmode
      Timeout.timeout(30) { yield input, output, errors, process }
    ensure
      input.close unless input.closed?
      output.close unless output.closed?
      errors.close unless errors.closed?
      begin
        Process.kill('TERM', process.pid) if process.alive?
      rescue Errno::ESRCH
        # The child can exit between the wait-thread check and termination.
      end
    end
  end
end
