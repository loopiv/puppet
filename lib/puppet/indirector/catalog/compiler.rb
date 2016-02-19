require 'puppet/node'
require 'puppet/resource/catalog'
require 'puppet/indirector/code'
require 'puppet/util/profiler'
require 'puppet/util/checksums'
require 'yaml'

class Puppet::Resource::Catalog::Compiler < Puppet::Indirector::Code
  desc "Compiles catalogs on demand using Puppet's compiler."

  include Puppet::Util
  include Puppet::Util::Checksums

  attr_accessor :code

  def extract_facts_from_request(request)
    return unless text_facts = request.options[:facts]
    unless format = request.options[:facts_format]
      raise ArgumentError, "Facts but no fact format provided for #{request.key}"
    end

    Puppet::Util::Profiler.profile("Found facts", [:compiler, :find_facts]) do
      # If the facts were encoded as yaml, then the param reconstitution system
      # in Network::HTTP::Handler will automagically deserialize the value.
      if text_facts.is_a?(Puppet::Node::Facts)
        facts = text_facts
      else
        # We unescape here because the corresponding code in Puppet::Configurer::FactHandler escapes
        facts = Puppet::Node::Facts.convert_from(format, CGI.unescape(text_facts))
      end

      unless facts.name == request.key
        raise Puppet::Error, "Catalog for #{request.key.inspect} was requested with fact definition for the wrong node (#{facts.name.inspect})."
      end

      options = {
        :environment => request.environment,
        :transaction_uuid => request.options[:transaction_uuid],
      }

      Puppet::Node::Facts.indirection.save(facts, nil, options)
    end
  end

  # Compile a node's catalog.
  def find(request)
    extract_facts_from_request(request)

    node = node_from_request(request)
    node.trusted_data = Puppet.lookup(:trusted_information) { Puppet::Context::TrustedInformation.local(node) }.to_h

    if catalog = compile(node, request.options)
      return catalog
    else
      # This shouldn't actually happen; we should either return
      # a config or raise an exception.
      return nil
    end
  end

  # filter-out a catalog to remove exported resources
  def filter(catalog)
    return catalog.filter { |r| r.virtual? } if catalog.respond_to?(:filter)
    catalog
  end

  def initialize
    Puppet::Util::Profiler.profile("Setup server facts for compiling", [:compiler, :init_server_facts]) do
      set_server_facts
    end
  end

  # Is our compiler part of a network, or are we just local?
  def networked?
    Puppet.run_mode.master?
  end

  private

  # Add any extra data necessary to the node.
  def add_node_data(node)
    # Merge in our server-side facts, so they can be used during compilation.
    node.add_server_facts(@server_facts)
  end

  # Determine which checksum to use; if agent_checksum_type is not nil,
  # use the first entry in it that is also in known_checksum_types.
  # If no match is found, return nil.
  def common_checksum_type(agent_checksum_type)
    if agent_checksum_type
      agent_checksum_types = agent_checksum_type.split('.').map {|type| type.to_sym}
      checksum_type = agent_checksum_types.drop_while do |type|
        not known_checksum_types.include? type
      end.first
    end
    checksum_type
  end

  def get_content_uri(metadata, source, environment_path)
    # The static file content server doesn't know how to expand mountpoints, so
    # we need to do that ourselves from the actual system path of the source file.
    # This does that, while preserving any user-specified server or port.
    source_path = Pathname.new(metadata.full_path)
    path = source_path.relative_path_from(environment_path).to_s
    source_as_uri = URI.parse(CGI.escape(source))
    server = source_as_uri.host
    port = ":#{source_as_uri.port}" if source_as_uri.port
    return "puppet://#{server}#{port}/#{path}"
  end

  # Inline file metadata for static catalogs
  # Initially restricted to files sourced from codedir via puppet:/// uri.
  def inline_metadata(catalog, checksum_type)
    environment_path = Pathname.new File.join(Puppet[:environmentpath], catalog.environment, "")
    list_of_resources = catalog.resources.find_all { |res| res.type == "File" }

    # TODO: get property/parameter defaults if entries are nil in the resource
    # For now they're hard-coded to match the File type.

    file_metadata = {}
    list_of_resources.each do |resource|
      next if resource[:ensure] == 'absent'

      sources = [resource[:source]].flatten.compact
      next if sources.empty?
      next unless sources.all? {|source| source =~ /^puppet:/}

      # both need to handle multiple sources
      if resource[:recurse] == true || resource[:recurse] == 'true' || resource[:recurse] == 'remote'
        # Construct a hash mapping sources to arrays (list of files found recursively) of metadata
        options = {
          :environment        => catalog.environment_instance,
          :links              => resource[:links] ? resource[:links].to_sym : :manage,
          :checksum_type      => resource[:checksum] ? resource[:checksum].to_sym : checksum_type.to_sym,
          :source_permissions => resource[:source_permissions] ? resource[:source_permissions].to_sym : :ignore,
          :recurse            => true,
          :recurselimit       => resource[:recurselimit],
          :ignore             => resource[:ignore],
        }

        sources_in_environment = true

        source_to_metadatas = {}
        sources.each do |source|
          if list_of_data = Puppet::FileServing::Metadata.indirection.search(source, options)
            basedir_meta = list_of_data.find {|meta| meta.relative_path == '.'}
            devfail "FileServing::Metadata search should always return the root search path" if basedir_meta.nil?

            if ! basedir_meta.full_path.start_with? environment_path.to_s
              # If any source is not in the environment path, skip inlining this resource.
              sources_in_environment = false
              break
            end

            base_content_uri = get_content_uri(basedir_meta, source, environment_path)
            list_of_data.each do |metadata|
              if metadata.relative_path == '.'
                metadata.content_uri = base_content_uri
              else
                metadata.content_uri = "#{base_content_uri}/#{metadata.relative_path}"
              end
            end

            source_to_metadatas[source] = list_of_data
            # Optimize for returning less data if sourceselect is first
            if resource[:sourceselect] == 'first' || resource[:sourceselect].nil?
              break
            end
          end
        end

        if sources_in_environment && !source_to_metadatas.empty?
          catalog.recursive_metadata[resource.title] = source_to_metadatas
        end
      else
        options = {
          :environment        => catalog.environment_instance,
          :links              => resource[:links] ? resource[:links].to_sym : :manage,
          :checksum_type      => resource[:checksum] ? resource[:checksum].to_sym : checksum_type.to_sym,
          :source_permissions => resource[:source_permissions] ? resource[:source_permissions].to_sym : :ignore
        }

        metadata = nil
        sources.each do |source|
          if data = Puppet::FileServing::Metadata.indirection.find(source, options)
            metadata = data
            metadata.source = source
            break
          end
        end

        raise "Could not get metadata for #{resource[:source]}" unless metadata
        if metadata.full_path.start_with? environment_path.to_s
          metadata.content_uri = get_content_uri(metadata, metadata.source, environment_path)

          # If the file is in the environment directory, we can safely inline
          catalog.metadata[resource.title] = metadata
        end
      end
    end
  end

  # Compile the actual catalog.
  def compile(node, options)
    if node.environment && node.environment.static_catalogs? && options[:static_catalog] && options[:code_id]
      # Check for errors before compiling the catalog
      checksum_type = common_checksum_type(options[:checksum_type])
      raise Puppet::Error, "Unable to find a common checksum type between agent '#{options[:checksum_type]}' and master '#{known_checksum_types}'." unless checksum_type
    end

    str = "Compiled %s for #{node.name}" % [checksum_type ? 'static catalog' : 'catalog']
    str += " in environment #{node.environment}" if node.environment
    config = nil

    benchmark(:notice, str) do
      Puppet::Util::Profiler.profile(str, [:compiler, :compile, node.environment, node.name]) do
        begin
          config = Puppet::Parser::Compiler.compile(node, options[:code_id])
        rescue Puppet::Error => detail
          Puppet.err(detail.to_s) if networked?
          raise
        end
      end
    end

    if checksum_type && config.is_a?(model)
      str = "Inlined resource metadata into static catalog for #{node.name}"
      str += " in environment #{node.environment}" if node.environment
      benchmark(:notice, str) do
        Puppet::Util::Profiler.profile(str, [:compiler, :static_inline, node.environment, node.name]) do
          inline_metadata(config, checksum_type)
        end
      end
    end

    config
  end

  # Turn our host name into a node object.
  def find_node(name, environment, transaction_uuid, configured_environment)
    Puppet::Util::Profiler.profile("Found node information", [:compiler, :find_node]) do
      node = nil
      begin
        node = Puppet::Node.indirection.find(name, :environment => environment,
                                             :transaction_uuid => transaction_uuid,
                                             :configured_environment => configured_environment)
      rescue => detail
        message = "Failed when searching for node #{name}: #{detail}"
        Puppet.log_exception(detail, message)
        raise Puppet::Error, message, detail.backtrace
      end


      # Add any external data to the node.
      if node
        add_node_data(node)
      end
      node
    end
  end

  # Extract the node from the request, or use the request
  # to find the node.
  def node_from_request(request)
    if node = request.options[:use_node]
      if request.remote?
        raise Puppet::Error, "Invalid option use_node for a remote request"
      else
        return node
      end
    end

    # We rely on our authorization system to determine whether the connected
    # node is allowed to compile the catalog's node referenced by key.
    # By default the REST authorization system makes sure only the connected node
    # can compile his catalog.
    # This allows for instance monitoring systems or puppet-load to check several
    # node's catalog with only one certificate and a modification to auth.conf
    # If no key is provided we can only compile the currently connected node.
    name = request.key || request.node
    if node = find_node(name, request.environment, request.options[:transaction_uuid], request.options[:configured_environment])
      return node
    end

    raise ArgumentError, "Could not find node '#{name}'; cannot compile"
  end

  # Initialize our server fact hash; we add these to each client, and they
  # won't change while we're running, so it's safe to cache the values.
  def set_server_facts
    @server_facts = {}

    # Add our server version to the fact list
    @server_facts["serverversion"] = Puppet.version.to_s

    # And then add the server name and IP
    {"servername" => "fqdn",
      "serverip" => "ipaddress"
    }.each do |var, fact|
      if value = Facter.value(fact)
        @server_facts[var] = value
      else
        Puppet.warning "Could not retrieve fact #{fact}"
      end
    end

    if @server_facts["servername"].nil?
      host = Facter.value(:hostname)
      if domain = Facter.value(:domain)
        @server_facts["servername"] = [host, domain].join(".")
      else
        @server_facts["servername"] = host
      end
    end
  end
end
