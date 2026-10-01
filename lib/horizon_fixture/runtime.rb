# frozen_string_literal: true

require 'open3'
require 'pathname'
require 'digest'
require 'tempfile'
require 'fileutils'

module HorizonFixture
  LIQUID_SHA = '4e39ae4cc3da73921923c0669e0fc84a66b2f696'
  THEME_SHA = '5acd1b6b66c02f61d3216e3adace5dd9e0404fc9'
  PROJECT_ROOT = File.realpath(File.join(__dir__, '../..'))

  module Runtime
    module_function

    def verify_checkout(root, expected_sha, label)
      sha, status = Open3.capture2('git', '-C', root, 'rev-parse', 'HEAD')
      raise ArgumentError, "#{label} SHA does not match pin" unless status.success? && sha.strip == expected_sha
      tracked, status = Open3.capture2('git', '-C', root, 'status', '--porcelain', '--untracked-files=no')
      raise ArgumentError, "#{label} checkout has tracked changes" unless status.success? && tracked.empty?
      sha.strip
    end

    def load_liquid!(root)
      raise LoadError, 'horizon-ruby-renderer requires Ruby >= 3.4' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.4')
      verify_checkout(root, LIQUID_SHA, 'Ruby Liquid')
      $LOAD_PATH.unshift(File.join(File.realpath(root), 'lib'))
      require_relative 'renderer'
      source = File.realpath(Liquid::Template.instance_method(:render).source_location.first)
      raise LoadError, 'Liquid loaded outside pinned checkout' unless source.start_with?("#{File.realpath(root)}/lib/")
      source
    end

    # Resolve the existing ancestor first so a symlink cannot redirect generated output.
    def external_output_path!(path, roots: [])
      expanded = File.expand_path(path)
      cursor, suffix = expanded, []
      until File.exist?(cursor) || File.symlink?(cursor)
        suffix.unshift(File.basename(cursor))
        parent = File.dirname(cursor)
        raise ArgumentError, "cannot resolve output path #{path}" if parent == cursor
        cursor = parent
      end
      resolved = File.join(File.realpath(cursor), *suffix)
      ([PROJECT_ROOT] + roots).each do |root|
        protected_root = File.realpath(root)
        if resolved == protected_root || resolved.start_with?("#{protected_root}/")
          raise ArgumentError, "generated output must be outside source checkouts: #{path}"
        end
      end
      resolved
    end

    def execute(mode)
      case mode
      when 'direct' then yield
      when 'fiber' then Fiber.new { yield }.resume
      else raise ArgumentError, "unsupported execution mode #{mode.inspect}"
      end
    end

    def artifact_path!(path, roots: [])
      raise ArgumentError, "output artifact must not be a symlink: #{path}" if File.symlink?(path)
      if File.exist?(path) && !File.file?(path)
        raise ArgumentError, "output artifact must be a regular file: #{path}"
      end
      external_output_path!(path, roots: roots)
    end

    def clear_success_markers!(paths, roots: [])
      paths.each { |path| artifact_path!(path, roots: roots) }
      paths.each { |path| File.unlink(path) if File.exist?(path) }
    end

    def reject_input_collisions!(input, output_paths, roots: [])
      source_path = File.exist?(input) ? File.realpath(input) : File.expand_path(input)
      output_paths.each do |path|
        if artifact_path!(path, roots: roots) == source_path
          raise ArgumentError, "output artifact must not replace fixture input: #{path}"
        end
      end
    end

    # Replace an artifact atomically; writing never follows an existing file symlink.
    def write_artifact!(path, content, roots: [])
      resolved = artifact_path!(path, roots: roots)
      FileUtils.mkdir_p(File.dirname(resolved))
      Tempfile.create(['.horizon-output-', '.tmp'], File.dirname(resolved)) do |temporary|
        temporary.write(content)
        temporary.close
        artifact_path!(resolved, roots: roots)
        File.rename(temporary.path, resolved)
      end
    end

    def metadata
      dependencies = %w[bigdecimal strscan prism json].each_with_object({}) do |name, result|
        spec = Gem.loaded_specs[name]
        feature = $LOADED_FEATURES.find { |path| File.basename(path).match?(/\A#{Regexp.escape(name)}\.(?:rb|so|bundle)\z/) }
        next unless spec || feature
        version = spec&.version&.to_s
        version ||= case name
        when 'bigdecimal' then BigDecimal::VERSION if defined?(BigDecimal::VERSION)
        when 'strscan' then StringScanner::Version if defined?(StringScanner::Version)
        when 'prism' then Prism::VERSION if defined?(Prism::VERSION)
        when 'json' then JSON::VERSION if defined?(JSON::VERSION)
        end
        result[name] = { 'version' => version, 'path' => spec&.full_gem_path || feature }
      end
      {
        'ruby_version' => RUBY_VERSION, 'ruby_description' => RUBY_DESCRIPTION,
        'yjit_enabled' => defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false,
        'dependencies' => dependencies
      }
    end

    def output_digest(result)
      {
        'html' => { 'bytes' => result.html.bytesize, 'sha256' => Digest::SHA256.hexdigest(result.html) },
        'css' => { 'bytes' => result.css.bytesize, 'sha256' => Digest::SHA256.hexdigest(result.css) }
      }
    end
  end
end
