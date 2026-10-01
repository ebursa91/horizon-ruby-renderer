# frozen_string_literal: true

require 'open3'
require 'pathname'

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
  end
end
