require 'tempfile'

# Necessary libraries
Spark.load_lib

# Main entry point for Spark functionality. A SparkContext represents the connection to a Spark
# cluster, and can be used to create RDDs, accumulators and broadcast variables on that cluster.
#
module Spark
  class Context

    include Spark::Helper::System
    include Spark::Helper::Parser

    attr_reader :jcontext, :temp_dir

    # Constructor for Ruby context. Configuration is automatically is taken
    # from Spark. Config will be automatically set to default if user start
    # context first.
    #
    def initialize
      Spark.config.valid!
      @jcontext = JavaSparkContext.new(Spark.config.spark_conf)

      # Does not work on 1.2
      # ui.attachTab(RubyTab.new(ui, to_java_hash(RbConfig::CONFIG)))

      spark_local_dir = JUtils.getLocalDir(sc.conf)
      @temp_dir = JUtils.createTempDir(spark_local_dir).getAbsolutePath

      set_call_site('Ruby') # description of stage
    end

    def stop
      @jcontext.stop
    end

    def sc
      @jcontext.sc
    end

    def ui
      sc.ui
    end

    # Default level of parallelism to use when not given by user (e.g. parallelize and makeRDD)
    #
    def default_parallelism
      sc.defaultParallelism
    end

    def get_serializer(serializer, *args)
      serializer   = Spark::Serializer.get(serializer)
      serializer ||= Spark::Serializer.get(config['spark.ruby.serializer'])
      serializer.new(config['spark.ruby.batch_size']).set(*args)
    end

    # Set a local property that affects jobs submitted from this thread, such as the
    # Spark fair scheduler pool.
    #
    def set_local_property(key, value)
      jcontext.setLocalProperty(key, value)
    end

    # Get a local property set in this thread, or null if it is missing
    #
    def get_local_property(key)
      jcontext.getLocalProperty(key)
    end

    # Support function for API backtraces.
    #
    def set_call_site(site)
      set_local_property('externalCallSite', site)
    end

    # Capture the current user callsite and return a formatted version for printing. If the user
    # has overridden the call site, this will return the user's version.
    #
    def get_call_site
      jcontext.getCallSite
    end

    # Return a copy of this SparkContext's configuration. The configuration *cannot*
    # be changed at runtime.
    #
    def config(key=nil)
      # if key
      #   Spark.config[key]
      # else
      #   Spark.config.get_all
      # end
      Spark.config
    end

    # Add a file to be downloaded with this Spark job on every node.
    # The path of file passed can be either a local file, a file in HDFS
    # (or other Hadoop-supported filesystems), or an HTTP, HTTPS or FTP URI.
    #
    # To access the file in Spark jobs, use `SparkFiles.get(file_name)` with the
    # filename to find its download location.
    #
    # `echo 10 > test.txt`
    #
    # $sc.add_file('test.txt')
    # $sc.parallelize(0..5).map(lambda{|x| x * SparkFiles.get_content('test.txt').to_i}).collect
    # => [0, 10, 20, 30, 40, 50]
    #
    def add_file(*files)
      files.each do |file|
        sc.addFile(file)
      end
    end

    # Broadcast a read-only variable to the cluster, returning a Spark::Broadcast
    # object for reading it in distributed functions. The variable will
    # be sent to each cluster only once.
    #
    # broadcast1 = $sc.broadcast('a', 1)
    # broadcast2 = $sc.broadcast('b', 2)
    #
    # rdd = $sc.parallelize(0..5, 4)
    # rdd = rdd.broadcast(broadcast1, broadcast2)
    # rdd = rdd.map_partitions_with_index(lambda{|part, index| [Broadcast[1] * index, Broadcast[2] * index] })
    # rdd.collect
    # => ["", "", "a", "b", "aa", "bb", "aaa", "bbb"]
    #
    def broadcast(value, id=nil)
      Spark::Broadcast.new(self, value, id)
    end

    # Distribute a local Ruby collection to form an RDD
    # Direct method can be slow so be careful, this method update data inplace
    #
    #   data: Range or Array
    #   num_slices: number of slice
    #   options: use
    #            serializer
    #            batch_size
    #
    # $sc.parallelize(["1", "2", "3"]).map(lambda{|x| x.to_i}).collect
    # => [1, 2, 3]
    #
    def parallelize(data, num_slices=nil, options={})
      num_slices ||= default_parallelism

      # use = jruby? ? (options[:use] || :direct) : :file
      use = :file
      serializer = get_serializer(options[:serializer], options[:batch_size])

      if data.is_a?(Array) && config['spark.ruby.parallelize_strategy'] == 'deep_copy'
        data = data.deep_copy
      else
        # For enumerator or range
        data = data.to_a
      end

      case use
      when :direct
        serializer.dump_to_java(data)
        jrdd = jcontext.parallelize(data, num_slices)
      when :file
        file = Tempfile.new('to_parallelize', temp_dir)
        serializer.dump(data, file)
        file.close # not unlink
        jrdd = RubyRDD.readRDDFromFile(jcontext, file.path, num_slices)
        file.unlink
      end

      Spark::RDD.new(jrdd, self, serializer)
    end

    # Read a text file from HDFS, a local file system (available on all nodes), or any
    # Hadoop-supported file system URI, and return it as an RDD of Strings.
    #
    # f = Tempfile.new("test")
    # f.puts("1")
    # f.puts("2")
    # f.close
    #
    # $sc.text_file(f.path).map(lambda{|x| x.to_i}).collect
    # => [1, 2]
    #
    def text_file(path, min_partitions=nil, options={})
      min_partitions ||= default_parallelism
      serializer = get_serializer(options[:serializer], options[:batch_size])

      Spark::RDD.new(@jcontext.textFile(path, min_partitions), self, serializer, get_serializer('UTF8'))
    end

    # Read a directory of text files from HDFS, a local file system (available on all nodes), or any
    # Hadoop-supported file system URI. Each file is read as a single record and returned in a
    # key-value pair, where the key is the path of each file, the value is the content of each file.
    #
    # dir = Dir.mktmpdir
    # f1 = Tempfile.new("test1", dir)
    # f2 = Tempfile.new("test2", dir)
    # f1.puts("1"); f1.puts("2");
    # f2.puts("3"); f2.puts("4");
    # f1.close
    # f2.close
    #
    # $sc.whole_text_files(dir).flat_map(lambda{|key, value| value.split}).collect
    # => ["1", "2", "3", "4"]
    #
    def whole_text_files(path, min_partitions=nil, options={})
      min_partitions ||= default_parallelism
      serializer = get_serializer(options[:serializer], options[:batch_size])
      deserializer = get_serializer('Pair', get_serializer('UTF8'), get_serializer('UTF8'))

      Spark::RDD.new(@jcontext.wholeTextFiles(path, min_partitions), self, serializer, deserializer)
    end

    # Executes the given partition function f on the specified set of partitions,
    # returning the result as an array of elements.
    #
    # If partitions is not specified, this will run over all partitions.
    #
    # rdd = $sc.parallelize(0..10, 5, batch_size: 1)
    # $sc.run_job(rdd, lambda{|x| x.to_s}, [0,2])
    # => ["[0, 1]", "[4, 5]"]
    #
    def run_job(rdd, f, partitions=nil, allow_local=false)
      run_job_with_command(rdd, partitions, allow_local, Spark::Command::MapPartitions, f)
    end

    # Execute the given command on specific set of partitions.
    #
    def run_job_with_command(rdd, partitions, allow_local, command, *args)
      if !partitions.nil? && !partitions.is_a?(Array)
        raise Spark::ContextError, 'Partitions must be nil or Array'
      end

      partitions_size = rdd.partitions_size

      # Execute all parts
      if partitions.nil?
        partitions = (0...partitions_size).to_a
      end

      # Can happend when you use coalesce
      partitions.delete_if {|part| part >= partitions_size}

      # Rjb represent Fixnum as Integer but Jruby as Long
      partitions = to_java_array_list(convert_to_java_int(partitions))

      mapped = rdd.new_rdd_from_command(command, *args)
      iterator = PythonRDD.runJob(rdd.context.sc, mapped.jrdd, partitions, allow_local)
      mapped.collect_from_iterator(iterator)
    end


    # Aliases
    alias_method :textFile, :text_file
    alias_method :wholeTextFiles, :whole_text_files
    alias_method :defaultParallelism, :default_parallelism
    alias_method :setLocalProperty, :set_local_property
    alias_method :getLocalProperty, :get_local_property
    alias_method :setCallSite, :set_call_site
    alias_method :getCallSite, :get_call_site
    alias_method :runJob, :run_job
    alias_method :runJobWithCommand, :run_job_with_command
    alias_method :addFile, :add_file

  end
end
