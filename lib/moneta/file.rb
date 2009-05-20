begin
  require "xattr"
rescue LoadError
  puts "You need the xattr gem to use the File moneta store"
  exit
end
require "fileutils"

module Moneta
  class File

    # Abstract base class for path mappers. Custom mappers can plug in their
    # own mapping of keys to file names.
    class AbstractMapper

      # Initialize mapper with a root directory.
      def initialize(root)
        @root = root
        if ::File.file?(@root)
          raise StandardError, "The path you supplied #{@root} is a file"
        elsif !::File.exists?(@root)
          FileUtils.mkdir_p(@root)
        end
      end

      # Clear the root directory's contents.
      def clear
        FileUtils.rm_rf(@root)
        FileUtils.mkdir(@root)
      end

      attr_reader :root
    end

    # A simple mapper which maps keys directly to file names. Eg., the key
    # +foo+ will be mapped to +/root/foo+.
    class SimpleMapper < AbstractMapper
      def path_for(key)
        return ::File.join(@root, key)
      end
    end

    # A hashed mapper which can be configured to split the key across multiple
    # directory levels in order to optimize file-system access. The default
    # nesting level is 2. For example, given a nesting level of 2, the key +foo+
    # will be mapped to +/root/f6/39/foo+; given a nesting level of 3, it will
    # be mapped to +/root/f6/39/e3+.
    class HashDistributedMapper < AbstractMapper
      # Maximum number of nesting levels
      MAX_LEVELS = 4

      # Initialize mapper. Options:
      #
      # * +:path+ - root directory.
      # * +:levels+ - number of levels (defaults to 2).
      #
      def initialize(options)
        super(options[:path])
        @levels = options[:levels] || 2
        if @levels > 16 / SPLIT_PER_LEVEL
          raise ArgumentError, "Maximum number of levels is #{16 / SPLIT_PER_LEVEL}"
        end
        @padding = @levels * SPLIT_PER_LEVEL
        @splits = (0..(@levels - 1)).to_a.map { |n|
          [n * SPLIT_PER_LEVEL, SPLIT_PER_LEVEL] }
      end

      def path_for(key)
        hash = key.hash.to_s(16).reverse.ljust(@padding, "0")
        parents = ::File.join(@root, @splits.map { |split| hash[*split] })
        FileUtils.mkdir_p(parents)
        ::File.join(parents, key)
      end

      private
        SPLIT_PER_LEVEL = 2
    end

    class Expiration
      def initialize(mapper)
        @mapper = mapper
      end
      
      def [](key)
        attrs = xattr(key)
        ret = Marshal.load(attrs.get("moneta_expires"))
      rescue Errno::ENOENT, SystemCallError
      end
      
      def []=(key, value)
        attrs = xattr(key)
        attrs.set("moneta_expires", Marshal.dump(value))
      end
      
      def delete(key)
        attrs = xattr(key)
        attrs.remove("moneta_expires")
      end

      private
      def xattr(key)
        ::Xattr.new(@mapper.path_for(key))
      end
    end
    
    def initialize(options = {})
      @mapper = options[:mapper] || SimpleMapper.new(options[:path])
      @expiration = Expiration.new(@mapper)
    end
    
    module Implementation
      def key?(key)
        ::File.exist?(@mapper.path_for(key))
      end
      
      alias has_key? key?
      
      def [](key)
        path = @mapper.path_for(key)
        if ::File.exist?(path)
          Marshal.load(::File.read(path))
        end
      end
      
      def []=(key, value)
        ::File.open(@mapper.path_for(key), "w") do |file|
          contents = Marshal.dump(value)
          file.puts(contents)
        end
      end
            
      def delete(key)
        value = self[key]
        FileUtils.rm(@mapper.path_for(key))
        value
      rescue Errno::ENOENT
      end
            
      def clear
        @mapper.clear
      end
    end
    include Implementation
    include Defaults
    include Expires
    
  end
end
