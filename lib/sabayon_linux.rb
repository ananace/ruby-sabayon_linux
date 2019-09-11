require "sabayon_linux/version"

module SabayonLinux
  class Error < StandardError; end

  autoload :Mirror, 'sabayon_linux/mirror'
  autoload :Mirrors, 'sabayon_linux/mirrors'
end
