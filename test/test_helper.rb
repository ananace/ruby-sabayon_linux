require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sabayon_linux'
require 'sabayon_linux/mirror'
require 'sabayon_linux/mirrors'

require 'test/unit'
require 'mocha/setup'
