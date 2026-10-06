require "uri"

module Adjutant
  # A host as hosts compare: lowercase, without a trailing dot, as DNS
  # compares names (RFC 4343). The net grant matches a host in this
  # form, and a risk-flow policy matches a Host origin or a URL
  # subject in it, so the two agree on which host a call reaches.
  #
  #   HostName.fold("https://API.Example.com.:443") # => "https://api.example.com:443"
  #   HostName.fold("Example.COM.")                 # => "example.com"
  module HostName
    # `origin` with its host folded: a URL's scheme and host, or the
    # whole string when it has no scheme.
    def self.fold(origin : String) : String
      origin.includes?("://") ? fold_url(origin) : fold_host(origin)
    end

    # `url` with its scheme and host folded, the rest as written. A
    # string that doesn't parse as a URL with a host is returned as
    # given.
    def self.fold_url(url : String) : String
      uri = URI.parse(url)
      host = uri.host
      return url if host.nil? || host.empty?
      uri.host = fold_host(host)
      uri.scheme = uri.scheme.try(&.downcase)
      uri.to_s
    rescue URI::Error
      url
    end

    def self.fold_host(host : String) : String
      host.downcase.rstrip('.')
    end
  end
end
