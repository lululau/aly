# frozen_string_literal: true

require_relative "lib/aly/version"

Gem::Specification.new do |spec|
  spec.name          = "aly"
  spec.version       = Aly::VERSION
  spec.authors       = ["Liu Xiang"]
  spec.email         = ["liuxiang921@gmail.com"]

  spec.summary       = "A simple wrapper for aliyun cli"
  spec.description   = "A simple wrapper for aliyun cli"
  spec.homepage      = "https://github.com/lululau/aly"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.7.0")

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'thor', '~> 0.20.0'
  spec.add_dependency 'terminal-table', '~> 1.8.0'

  spec.add_development_dependency "pry-byebug", "~> 3.6.0"
end
