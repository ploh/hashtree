#!/usr/bin/env ruby
#encoding: utf-8
# author: Peter Lohmann <peter@lohmann-online.info>

require "digest/sha2"


module HashTree
  # the size of the hash space
  HASH_SIZE = 10 ** 30

  def shash_array_length
    @@shash_array_length ||= (Math.log(HASH_SIZE) / Math.log(Tree::NonLeafNode::MAX_SIZE)).ceil
  end

  # the hashing method we use
  # called shash (for secure hash ;) to not interfere with ruby internal hash method (which should return a Fixnum instead of a String)
  def self.shash(content)
    Digest::SHA2.new(512).update(content).hexdigest.to_i(16) % HASH_SIZE
  end

  # shash in MAX_SIZE-ary representation
  def self.shash_array(shash)
    max_size = Tree::NonLeafNode::MAX_SIZE
    length = shash_array_length
    result = []
    partial_shash = shash
    (0...length).each do
      result.unshift(partial_shash % max_size)
      partial_shash = partial_shash.div(max_size)
    end
    result
  end


  class Tree
    # root is a pointer to the root node of the hashtree
    attr_reader :root
    private :root

    # abstract base class for leaf and non-leaf nodes
    class Node
      attr_reader :shash, :parent

      private :initialize
    end


    class NonLeafNode < Node
      # the maximum number of children a node may have
      MAX_SIZE = 5

      # the level of a (non-leaf) node is its depth in the tree (root is level 0)
      attr_reader :children, :level

      # the parameter defer_update is used during tree initialization to avoid unnecessary updates during tree construction
      def initialize(parent = nil, leaves = [], defer_update = false)
        @parent = parent
        @level = (parent ? parent.level + 1 : 0)
        @children = []
        leaves.each {|leaf| add_leaf(leaf)}
        update_shash unless defer_update
      end

      # to add a leaf node to this non-leaf node
      def add_leaf(leaf, defer_update = false)
        raise "node is not lowest level and can therefore not get a leaf: #{self}" unless lowest_level?
        children.insert(children.find_index {|child| child.shash > leaf.shash} || -1, leaf) #insertion_sort here
        leaf.parent = self
        divide_if_needed(defer_update)
      end

      # lowest level means: last level above leaf nodes
      # if a non-leaf node is not lowest level it must not have a leaf as a child
      def lowest_level?
        !children.any? {|child| child.kind_of?(NonLeafNode)}
      end

      def has_child?(child_shash)
        children.any? {|child| child.shash == child_shash}
      end

      # used in combination with defer_update to update the whole tree after initialization with blobs
      def update_subtree
        children.find_all {|child| child.kind_of?(NonLeafNode)}.each do |child|
          child.update_subtree
        end
        update_shash(false)
      end

      protected

      # the hash of a non-leaf node is the hash of the hashes of its children
      def update_shash(cascade = true)
        old = shash
        @shash = HashTree.shash(children.collect {|child| child.shash.to_s(36)}.join)
        parent.update_shash if parent && cascade && old != shash
      end

      # if a non-leaf node has to many leaf nodes as children it must be divided
      # the number of new non-leaf nodes is a constant and is always equal to MAX_SIZE because the tree we build will be a "lexicographical search tree" in this way
      def divide_if_needed(defer_update = false)
        if children.size > MAX_SIZE
          raise "node is not lowest level and can therefore not be divided: #{self}" unless lowest_level?
          @children = (0...MAX_SIZE).collect do |i|
            leaves = children.find_all {|leaf| leaf.shash_array[level] == i}
            NonLeafNode.new(self, leaves)
          end
          children.each {|child| child.divide_if_needed(defer_update)}
        end
        update_shash(false) unless defer_update
      end
    end

    # Blob = File (with filename and path) or other unique data object (usually: only the real file's *unique* representation by filename and hash of file content)
    # LeafNodes are the only nodes containing blobs
    class LeafNode < Node
      # note that there is no setter method for the blob because we want a leaf node to be immutable (if it has to change we interpret this as a deletion and a consecutive insertion)
      attr_reader :blob, :shash_array

      # the parent of a leaf node may change (in contrast to that of a non-leaf node)
      attr_writer :parent

      def initialize(blob = rand.to_s)
        @blob = blob
        @shash = HashTree.shash(blob.to_s)
        @shash_array = HashTree.shash_array(shash)
      end
    end


    # this class acts as handler for the communication between two trees when they want to find differences between themselves
    # it is equipped to count communication costs (i.e. the number of shashes communicated)
    class Communication
      attr_reader :cost

      def initialize(tree_root)
        @root = tree_root
        @current = @root
        @known = [@root]
        @cost = 1
      end

      def shash
        @current.shash
      end

      def shash_array
        @current.shash_array
      end

      def root?
        @current == @root
      end

      def leaf?
        @current.kind_of?(LeafNode)
      end

      def lowest_level?
        !leaf? && @current.lowest_level?
      end

      def inner_node?
        !leaf? && !lowest_level?
      end

      def number_of_children
        if leaf?
          nil
        else
          @current.children.size
        end
      end

      def move_down(number_of_child)
        raise "cannot move down from leaf: #{@current}" if leaf?
        raise "does not have a child with number #{number_of_child}: #{@current}" unless (0...number_of_children).include?(number_of_child)
        @current = @current.children[number_of_child]
        moved
        shash
      end

      def move_up
        @current = @current.parent unless root?
        moved
        shash
      end

      private

      # moving will only cost if the newly visited node was not visited before (because we assume in a productive implementation the client would have some sort of caching)
      def moved
        unless @known.include?(@current)
          @cost += 1
          @known << @current
        end
      end
    end


    # when a tree is initialized it can already get filled with content (this is faster then calling Tree#insert later because during initialization we optimize the generation of hashes)
    def initialize(contents = [])
      @root = NonLeafNode.new(nil, [], true)
      contents.each do |content|
        insert_privileged(content, true)
      end
      root.update_subtree
    end

    def insert(content)
      insert_privileged(content, false)
    end

    # this is used to find blobs in /tree/ that are not present in *self*
    # options may be :limit to limit the number of retrieved new shashes
    # and :verbose to print the communication cost after retrieving new content
    def find_new_content(tree, options)
      limit = case
      when !options[:limit] || options[:limit] <= 0
        Float::MAX * 2
      when options[:limit] > 0
        options[:limit]
      end
      verbose = (options[:verbose] ? true : false)
      communication = tree.create_communication
      result = get_new_content(communication, root, limit)
      $stdout.puts "Number of communications (i.e. retrieved hashes): #{communication.cost}" if verbose
      result
    end


    protected

    def create_communication
      Communication.new(root)
    end


    private

    def insert_privileged(content, defer_update = false)
      leaf = LeafNode.new(content)
      leaf_parent = search(leaf)
      leaf_parent.add_leaf(leaf, defer_update)
    end

    def get_new_content(communication, node, limit)
      result = []
      raise "can only get new content relative to non-leaf node but this is not one: #{node}" if !node.kind_of?(NonLeafNode)
      unless node.shash == communication.shash || result.size >= limit
        if communication.leaf?
          if node.lowest_level?
            result << communication.shash unless node.has_child?(communication.shash)
          else
            new_node = node.children[communication.shash_array[node.level]]
            result += get_new_content(communication, new_node, limit - result.size)
          end
        elsif communication.lowest_level? || communication.inner_node?
          (0...communication.number_of_children).each do |i|
            if result.size < limit
              new_node = if node.lowest_level? || communication.lowest_level?
                node
              else
                node.children[i]
              end
              communication.move_down(i)
              result += get_new_content(communication, new_node, limit - result.size)
              communication.move_up
            end
          end
        else
          raise "Cannot determine kind of communicated node: #{communication}"
        end
      end
      result
    end

    def search(leaf)
      current = root
      until current.lowest_level?
        current = current.children[leaf.shash_array[current.level]]
      end
      current
    end
  end
end


# demo code that does not get executed if this file is loaded as a library but only if it is the top-level script
if $PROGRAM_NAME == __FILE__
  include HashTree

  srand 1245131

  [250, 500, 1000, 2000].each do |collection_size|
    puts "Collection size: #{collection_size}"
    puts
    tree1 = Tree.new((1..collection_size).collect {|i| i.to_s})
    tree2 = Tree.new((1..collection_size+1).collect {|i| i <= (2.0/3.0*collection_size).floor ? i.to_s : rand.to_s})
    tree3 = Tree.new((1..collection_size+2).collect {|i| (i+1).to_s})
    tree4 = Tree.new((collection_size..1).collect {|i| i.to_s})

    begin
      puts "Finding a new blob in two very different collections..."
      tree1.find_new_content(tree2, limit: 1, verbose: true)
      puts
      puts "Finding all new blobs in two very different collections..."
      result = tree1.find_new_content(tree2, verbose: true)
      puts "Found #{result.size} new blobs"
      puts
    end

    begin
      puts "Finding a new blob in two almost identical collections..."
      tree1.find_new_content(tree3, limit: 1, verbose: true)
      puts
      puts "Finding all new blobs in two almost identical collections..."
      result = tree1.find_new_content(tree3, verbose: true)
      puts "Found #{result.size} new blobs"
      puts
    end

    begin
      puts "Finding all new blobs in two exactly identical collections..."
      result = tree1.find_new_content(tree4, verbose: true)
      puts "Found #{result.size} new blobs"
      puts
      puts
    end
  end
end
