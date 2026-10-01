#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/horizon_fixture/runtime'

module HorizonFixture
  # A synchronous pipe transport for the shared HTTP benchmark frontend.
  # Each message renders a fresh request; only source and parsed ASTs are reused.
  class ServingWorker
    MAX_HEADER_BYTES = 4_096
    MAX_REQUEST_ID = (2**64) - 1
    FIXTURE_SHA256 = '867c41e0929881290af2b261af64146632bf0287524f5a6c55714af32e819f98'
    ORACLE = {
      'html' => { 'bytes' => 435_304, 'sha256' => 'd97c35b3ba08f026536cb4c469623acb9957af59fb9a9171db012958515fe990' }.freeze,
      'css' => { 'bytes' => 279_112, 'sha256' => '67a6538e0b763c32ced001728ebf68f375dec497d4fb91c0ee136658ff9f2034' }.freeze
    }.freeze

    def initialize(options, input: $stdin, output: $stdout, errors: $stderr)
      @options, @input, @output, @errors = options, input, output, errors
      @input.binmode
      @output.binmode
    end

    def run
      request_id = nil
      warmup = @options.fetch(:warmup)
      raise ArgumentError, 'warmup must be positive' unless warmup.positive?
      raise ArgumentError, 'mode must be direct or fiber' unless %w[direct fiber].include?(@options.fetch(:mode))
      source = Runtime.load_liquid!(@options.fetch(:liquid_root))
      Runtime.verify_checkout(@options.fetch(:theme_root), THEME_SHA, 'theme')
      fixture_bytes = File.binread(@options.fetch(:fixture))
      fixture = JSON.parse(fixture_bytes)
      unless fixture.is_a?(Hash) && fixture['synthetic'] == true && fixture['schema_version'] == 1
        raise ArgumentError, 'expected synthetic fixture schema version 1'
      end
      raise ArgumentError, 'fixture theme SHA does not match pin' unless fixture.dig('theme', 'sha') == THEME_SHA
      fixture_sha = Digest::SHA256.hexdigest(fixture_bytes)
      raise ArgumentError, 'fixture SHA256 does not match pinned store' unless fixture_sha == FIXTURE_SHA256
      @renderer = Renderer.new(theme_root: @options.fetch(:theme_root), fixture: fixture)
      warmup.times do
        unless Runtime.output_digest(render) == ORACLE
          raise ArgumentError, 'startup render does not match independent homepage oracle'
        end
      end
      write_header(Runtime.metadata.merge(ORACLE).merge(
        'action' => 'ready', 'schema_version' => 1, 'engine' => 'ruby',
        'liquid_sha' => LIQUID_SHA, 'liquid_source' => source, 'theme_sha' => THEME_SHA,
        'fixture_sha256' => fixture_sha, 'execution_mode' => @options.fetch(:mode),
        'warmup' => warmup, 'scope' => 'page', 'page' => 'index',
        'response_cache' => false, 'correctness_verified' => true,
        'html_bytes' => ORACLE.fetch('html').fetch('bytes'), 'css_bytes' => ORACLE.fetch('css').fetch('bytes')
      ))
      @output.flush
      loop do
        request_id = nil
        line = @input.gets("\n", MAX_HEADER_BYTES + 1)
        break if line.nil?
        unless line.bytesize <= MAX_HEADER_BYTES && line.end_with?("\n")
          raise ArgumentError, 'request header exceeds limit or lacks newline'
        end
        request = JSON.parse(line, max_nesting: 16)
        unless request.is_a?(Hash) && request.keys.sort == %w[action request_id] && request['action'] == 'render'
          raise ArgumentError, 'expected render action and request_id only'
        end
        request_id = request['request_id']
        unless request_id.is_a?(Integer) && request_id.between?(0, MAX_REQUEST_ID)
          request_id = nil
          raise ArgumentError, 'request_id must be an unsigned 64-bit integer'
        end
        result = render
        unless result.html.bytesize == ORACLE.fetch('html').fetch('bytes') && result.css.bytesize == ORACLE.fetch('css').fetch('bytes')
          raise ArgumentError, 'rendered response size changed'
        end
        write_header('request_id' => request_id, 'html_bytes' => result.html.bytesize, 'css_bytes' => result.css.bytesize, 'error' => nil)
        @output.write(result.html)
        @output.write(result.css)
        @output.flush
      end
      0
    rescue StandardError, LoadError => error
      # Even JSON escaping every byte as \uXXXX keeps the error header below its limit.
      message = "#{error.class}: #{error.message}".encode(Encoding::UTF_8, invalid: :replace, undef: :replace).byteslice(0, 512).scrub
      begin
        write_header('request_id' => request_id, 'html_bytes' => 0, 'css_bytes' => 0, 'error' => message)
        @output.flush
      rescue IOError, SystemCallError
        # A closed transport still fails the process rather than manufacturing output.
      end
      @errors.puts(message)
      1
    end

    private

    def render
      Runtime.execute(@options.fetch(:mode)) { @renderer.render_result(page: 'index', scope: 'page') }
    end

    def write_header(header)
      json = JSON.generate(header) + "\n"
      raise ArgumentError, 'response header exceeds limit' if json.bytesize > MAX_HEADER_BYTES
      @output.write(json)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { warmup: 50, mode: 'direct' }
  OptionParser.new do |parser|
    parser.banner = 'Usage: serve_worker.rb --liquid-root PATH --theme-root PATH --fixture PATH [--warmup N --mode direct|fiber]'
    parser.on('--liquid-root PATH') { |value| options[:liquid_root] = value }
    parser.on('--theme-root PATH') { |value| options[:theme_root] = value }
    parser.on('--fixture PATH') { |value| options[:fixture] = value }
    parser.on('--warmup N', Integer) { |value| options[:warmup] = value }
    parser.on('--mode MODE') { |value| options[:mode] = value }
  end.parse!
  %i[liquid_root theme_root fixture].each { |key| abort "missing --#{key.to_s.tr('_', '-')}" unless options[key] }
  exit HorizonFixture::ServingWorker.new(options).run
end
