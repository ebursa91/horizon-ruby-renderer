# frozen_string_literal: true
raise LoadError, 'horizon-ruby-renderer requires Ruby >= 3.4' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.4')
require_relative 'horizon_fixture/renderer'
