#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require_relative '../lib/horizon_fixture/runtime'

options = { page: 'index', scope: 'page', mode: 'direct', iterations: 25, warmup: 50 }
OptionParser.new do |parser|
  parser.banner = 'Usage: worker.rb --liquid-root PATH --theme-root PATH --fixture PATH --output-dir PATH [--iterations N --warmup N --benchmark-mode direct|fiber]'
  parser.on('--liquid-root PATH') { |value| options[:liquid_root] = value }
  parser.on('--theme-root PATH') { |value| options[:theme_root] = value }
  parser.on('--fixture PATH') { |value| options[:fixture] = value }
  parser.on('--output-dir PATH') { |value| options[:output_dir] = value }
  parser.on('--benchmark-json PATH') { |value| options[:benchmark_json] = value }
  parser.on('--page NAME') { |value| options[:page] = value }
  parser.on('--scope SCOPE') { |value| options[:scope] = value }
  parser.on('--benchmark-mode MODE') { |value| options[:mode] = value }
  parser.on('--iterations N', Integer) { |value| options[:iterations] = value }
  parser.on('--warmup N', Integer) { |value| options[:warmup] = value }
end.parse!
%i[liquid_root theme_root fixture output_dir].each { |key| abort "missing --#{key.to_s.tr('_', '-')}" unless options[key] }

begin
  roots = [options[:liquid_root], options[:theme_root]]
  options[:output_dir] = HorizonFixture::Runtime.external_output_path!(options[:output_dir], roots: roots)
  options[:benchmark_json] = HorizonFixture::Runtime.artifact_path!(options[:benchmark_json], roots: roots) if options[:benchmark_json]
  if options[:benchmark_json] && %w[index.html styles.css].any? { |name| options[:benchmark_json] == File.join(options[:output_dir], name) }
    raise ArgumentError, 'benchmark JSON must not replace HTML or CSS output'
  end
  artifact_paths = %w[index.html styles.css report.json].map { |name| File.join(options[:output_dir], name) }
  artifact_paths.each { |path| HorizonFixture::Runtime.artifact_path!(path, roots: roots) }
  HorizonFixture::Runtime.reject_input_collisions!(options[:fixture], artifact_paths + [options[:benchmark_json]].compact, roots: roots)
  markers = [File.join(options[:output_dir], 'report.json'), options[:benchmark_json]].compact.uniq
  HorizonFixture::Runtime.clear_success_markers!(markers, roots: roots)
  raise ArgumentError, 'iterations and warmup must be positive' unless options[:iterations].positive? && options[:warmup].positive?
  raise ArgumentError, 'benchmark mode must be direct or fiber' unless %w[direct fiber].include?(options[:mode])
  liquid_source = HorizonFixture::Runtime.load_liquid!(options[:liquid_root])
  HorizonFixture::Runtime.verify_checkout(options[:theme_root], HorizonFixture::THEME_SHA, 'theme')
  fixture = JSON.parse(File.read(options[:fixture]))
  raise ArgumentError, 'fixture theme SHA does not match pin' unless fixture.dig('theme', 'sha') == HorizonFixture::THEME_SHA
  clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  cpu_clock = -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) }
  started = clock.call
  renderer = HorizonFixture::Renderer.new(theme_root: options[:theme_root], fixture: fixture)
  initialization_ms = (clock.call - started) * 1_000
  render = -> { HorizonFixture::Runtime.execute(options[:mode]) { renderer.render_result(page: options[:page], scope: options[:scope]) } }
  started = clock.call
  result = render.call
  first_render_ms = (clock.call - started) * 1_000
  expected = HorizonFixture::Runtime.output_digest(result)
  verify = lambda do |rendered|
    digest = HorizonFixture::Runtime.output_digest(rendered)
    raise HorizonFixture::ContractError, 'request output changed during benchmark' unless digest == expected
    digest
  end
  # --warmup counts all excluded requests, including the AST-priming first render.
  (options[:warmup] - 1).times { verify.call(render.call) }
  samples = options[:iterations].times.map do
    allocation_start = GC.stat(:total_allocated_objects)
    cpu_started = cpu_clock.call
    started = clock.call
    result = render.call
    elapsed_ms = (clock.call - started) * 1_000
    cpu_ms = (cpu_clock.call - cpu_started) * 1_000
    allocations = GC.stat(:total_allocated_objects) - allocation_start
    # Hashes and report construction are intentionally outside the measured render.
    verify.call(result).merge('elapsed_ms' => elapsed_ms, 'cpu_ms' => cpu_ms, 'allocations' => allocations)
  end
  peak_rss = if File.file?('/proc/self/status')
    File.read('/proc/self/status')[/^VmHWM:\s+(\d+)\s+kB$/, 1]&.to_i
  end
  git_sha, git_status = Open3.capture2('git', '-C', HorizonFixture::PROJECT_ROOT, 'rev-parse', 'HEAD', err: File::NULL)
  git_dirty, dirty_status = Open3.capture2('git', '-C', HorizonFixture::PROJECT_ROOT, 'status', '--porcelain', err: File::NULL)
  report = result.manifest.merge(HorizonFixture::Runtime.metadata).merge(expected).merge(
    'schema_version' => 1, 'engine' => 'ruby', 'execution_mode' => options[:mode],
    'scope' => options[:scope], 'page' => options[:page], 'response_cache' => false,
    'initialization_ms' => initialization_ms, 'first_render_ms' => first_render_ms,
    'warmup' => options[:warmup], 'iterations' => options[:iterations],
    'samples' => samples, 'samples_ms' => samples.map { |sample| sample.fetch('elapsed_ms') },
    'samples_cpu_ms' => samples.map { |sample| sample.fetch('cpu_ms') },
    'samples_allocations' => samples.map { |sample| sample.fetch('allocations') },
    'peak_rss_kib' => peak_rss, 'correctness_verified' => true,
    'fixture_sha256' => Digest::SHA256.file(options[:fixture]).hexdigest,
    'liquid_sha' => HorizonFixture::LIQUID_SHA, 'liquid_source' => liquid_source,
    'source_sha' => git_status.success? ? git_sha.strip : nil,
    'source_dirty' => dirty_status.success? ? !git_dirty.empty? : nil,
    'gc_enabled' => true, 'clock' => 'CLOCK_MONOTONIC', 'cpu_clock' => 'CLOCK_PROCESS_CPUTIME_ID'
  )
  FileUtils.mkdir_p(options[:output_dir])
  HorizonFixture::Runtime.write_artifact!(File.join(options[:output_dir], 'index.html'), result.html, roots: roots)
  HorizonFixture::Runtime.write_artifact!(File.join(options[:output_dir], 'styles.css'), result.css, roots: roots)
  json = JSON.pretty_generate(report) + "\n"
  HorizonFixture::Runtime.write_artifact!(File.join(options[:output_dir], 'report.json'), json, roots: roots)
  if options[:benchmark_json]
    FileUtils.mkdir_p(File.dirname(options[:benchmark_json]))
    HorizonFixture::Runtime.write_artifact!(options[:benchmark_json], json, roots: roots)
  end
  puts JSON.generate(report)
rescue ArgumentError, LoadError, HorizonFixture::ContractError => error
  warn error.message
  exit 1
end
