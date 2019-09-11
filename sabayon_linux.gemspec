require File.join(File.expand_path('lib', __dir__), 'sabayon_linux', 'version')

Gem::Specification.new do |spec|
  spec.name          = 'sabayon_linux'
  spec.version       = SabayonLinux::VERSION
  spec.authors       = ['Alexander Olofsson']
  spec.email         = ['ace@haxalot.com']

  spec.summary       = 'A Ruby gem for querying the Sabayon Linux infrastructure'
  spec.description   = spec.summary
  spec.homepage      = 'https://github.com/ananace/ruby-sabayon_linux'
  spec.license       = 'MIT'

  spec.files         = Dir["{bin,lib}/**"]
  spec.bindir        = 'bin'
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'mocha'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'simplecov'
  spec.add_development_dependency 'test-unit'

  spec.add_dependency 'logging', '~> 2'
  spec.add_dependency 'nokogiri'
end
