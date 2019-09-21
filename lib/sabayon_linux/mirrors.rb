require 'net/http'
require 'nokogiri'

module SabayonLinux
  class Mirrors
    def self.list
      data = Net::HTTP.get(URI('https://www.sabayon.org/mirrors/'))
      doc = Nokogiri::HTML.parse(data)

      (0..100).map do |num|
        suffix = "-#{num}" if num.positive?

        node = doc.at_css("#connection-speed#{suffix}")
        next unless node

        mirror = node.parent

        country = mirror.parent.parent
        if country.at_css('h2').nil?
          # Ctrl-C mirror placed wrongly in the HTML structure
          country = country.parent.parent
          name = mirror.at_css('h3').text
          speed = mirror.at_css("#connection-speed#{suffix}").next_element.text.delete(',').chomp('Mb/s').to_i

          top_mirror = mirror.parent.parent

          ftp_servers = find_hrefs(top_mirror, 'FTP', mirror)
          http_servers = find_hrefs(top_mirror, 'HTTP', mirror)
          rsync_servers = find_hrefs(top_mirror, 'Rsync', mirror)
        else
          name = mirror.at_css('h3').text
          speed = mirror.at_css("#connection-speed#{suffix}").next_element.text.delete(',').chomp('Mb/s').to_i
          ftp_servers = find_hrefs(mirror, 'FTP')
          http_servers = find_hrefs(mirror, 'HTTP')
          rsync_servers = find_hrefs(mirror, 'Rsync')
        end
        country_name = country.at_css('h2').text

        Mirror.new(
          country: country_name,
          name: name,
          speed: speed,

          ftp_servers: ftp_servers,
          http_servers: http_servers,
          rsync_servers: rsync_servers
        )
      end.compact
    end

    private

    def self.find_hrefs(node, type, skip_to = nil)
      list = node.element_children
      reading = skip_to ? false : true

      current_node = list.first
      while current_node
        return current_node.next_element.css('a')&.map { |a| a[:href] } if current_node.text == type && reading

        if skip_to
          reading = true if current_node == skip_to
          if !reading && current_node.name =~ /[ou]l|li/
            reading = true if current_node.element_children.include? skip_to
          end
        end

        current_node = current_node.next_element
      end
    end
  end
end
