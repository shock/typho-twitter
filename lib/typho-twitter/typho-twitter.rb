# Note the tests at the bottom.  You can test this class by running it standalone in the interpreter.

require 'rubygems'
require 'wdd-ruby-ext'
require "cgi"
require "net/http"
require "uri"
require "time"
require "typhoeus"
require "pp"
require 'json'
require 'base64'

# Class to abstract access to Twitter's Web Traffic API.
# Makes use of the Typhoeus gem to enable concurrent API calls.

class TyphoTwitter
  
  include WDD::Utilities
  
  def puts message
    Kernel.puts message
  end
  
  class HTTPException < RuntimeError
    attr :code
    attr :body
    
    def initialize( code, body )
      @code = code
      @body = body
      super( "#{code} - #{body}" )
    end
  end
  
  class TwitterException < RuntimeError
    attr :code
    attr :body
    
    def initialize( code, body )
      @code = code
      @body = body
      super( "#{code} - #{body}" )
    end
  end
    
  ##############################################################
  # TYPHOEUS STUFF
  #

    include Typhoeus
    remote_defaults :on_success => lambda { |response| puts "TWITTER - Success"; 
                                            json_result_object = JSON.parse( response.body );
                                            json_result_object },
                    :on_failure => lambda { |response| puts "TWITTER - ERROR #{response.code}"; 
                                            raise HTTPException.new( response.code, response.body ) },
                    :headers => @headers
                    
    # Typhoeus HTTP call declarations
    define_remote_method :typho_twitter, :base_uri   => "http://twitter.com"
    define_remote_method :typho_timeline, {
      :base_uri   => "http://twitter.com",
      :on_success => lambda { |response| #puts "TWITTER - Success"; 
        timeline_updates = JSON.parse( response.body );
        timeline_updates.collect{ |c| c.delete( "user" ); c  }
      }
    }

  #
  # TYPHOEUS STUFF
  ##############################################################
  
  attr :login
  attr :password
  attr :headers
  
  # Constants 
  TWITTER_THROTTLE_LIMIT = 20      # Theoretical Twitter throttle limit
  TWITTER_THROTTLE_TIMEOUT = 0    # Theoretical time period (seconds) for Twitter throttle limit
  NUM_FAILED_RETRIES = 100
  
  # +login+ - Twitter account login to use for authentication
  # +password+ - Password for Twitter login
  # +batch_size+ - Number of Twitter calls to batch together using Typhoeus
  # +batch_period+ - Minimum number of seconds to wait between Typhoeus batches (float supported)
  def initialize login, password, batch_size=TWITTER_THROTTLE_LIMIT, batch_period=TWITTER_THROTTLE_TIMEOUT
    @login, @password = login, password
    b64_encoded = Base64.b64encode("#{login}:#{password}")
    @headers = {"Authorization" => "Basic #{b64_encoded}"}
    @batch_size, @batch_period = batch_size, batch_period
  end

  # Does a batched group of Twitter calls.  Handles retries when possible on failures.
  # +data_array+ - An array of data inputs, one for each twitter call
  # +&block+ - A block that accepts a slice of +data_array+ and returns a batch (array) of Tyhpoeus proxy objects.
  def typho_twitter_batch data_array, &block
    json_results = {}
    typho_slice_size = @batch_size # total number of users we can lookup per Typhoeus batch
    retries = 0
    @time_gate = WDD::Utilities::TimeGate.new
    hydra = Typhoeus::Hydra.new(:max_concurrency => 40)
    hydra.disable_memoization
    
    failed_data_inputs = []
    data_array_slice = data_array
    data_array.each do |data_input|
      request = yield( data_input )
      # printvar :request, request
      request.on_complete do |response|
        puts "[#{response.code}] - #{request.url}"
        case response.code
        when 200:
          begin
            json_object = JSON.parse( response.body )
            json_results[data_input] = json_object
            retries = 0
          rescue JSON::ParserError
            puts json_result
            puts "TWITTER: #{$!.inspect}"
            retries += 1
            sleep_time = retries ** 2
            puts "Will retrying after sleeping for #{sleep_time} seconds"
            sleep sleep_time
            hydra.queue request
          end
        when 401:
          puts "**** Twitter Authorization Failed for #{data_input}."
          puts "Request URL: #{request.url}"
          json_results[data_input] = TwitterException.new(response.code, response.body)
        when 404:
          puts "Unknown data_input: #{data_input}"              
          puts "Request URL: #{request.url}"
          json_results[data_input] = TwitterException.new(response.code, response.body)
        when 502:
          puts "Twitter Over capacity for data_input: #{data_input}.  Will retry."
          puts "Request URL: #{request.url}"
          retries += 1
          sleep_time = retries ** 2
          puts "Will retrying after sleeping for #{sleep_time} seconds"
          sleep sleep_time
          hydra.queue request
        when 500:
          puts "Twitter server error for data_input: #{data_input}.  Will retry."
          puts "Request URL: #{request.url}"
          retries += 1
          sleep_time = retries ** 2
          puts "Will retrying after sleeping for #{sleep_time} seconds"
          sleep sleep_time
          hydra.queue request
        else
          puts "Unexpected HTTP result code: #{response.code}\n#{response.body}"
          puts "Request URL: #{request.url}"
          # retries += 1
          sleep_time = retries ** 2
          puts "Will retrying after sleeping for #{sleep_time} seconds"
          sleep sleep_time
          hydra.queue request
        end        
      end
      hydra.queue request
    end
    hydra.run
    data_array = failed_data_inputs
    retries -= 1
    # WDD::Utilities::printvar :json_results, json_results
    json_results
  end  
  

  # Retrieves the user data for a group of screen_names from Twitter.
  # +id_array+ = An array twitter user ids, one for each user to get data for.  Can be user_ids or screen_names.
  # Returns a Hash of objects from Twitter
  def get_users_show id_array
    typho_twitter_batch( id_array ) do |twitter_id|
      if twitter_id.is_a? Fixnum
        request = Typhoeus::Request.new("http://twitter.com/users/show.json?user_id=#{twitter_id}",
          :headers => @headers
        )
      else
        request = Typhoeus::Request.new("http://twitter.com/users/show.json?screen_name=#{twitter_id}",
          :headers => @headers
        )
      end
      request
    end
  end  

  # Retrieves the followers records for a group of twitter_ids from Twitter.
  # +twitter_id_array+ = An array twitter user ids, one for each user to get data for
  def get_statuses_followers twitter_id_array, limit=nil
    master_results = {}
    process_statuses_followers( twitter_id_array ) do |twitter_id, results|
      master_results[twitter_id] ||= []
      if results.is_a? TwitterException
        master_results[twitter_id] = results
        false
      else
        master_results[twitter_id] += results
        if limit && master_results[twitter_id].length >= limit
          master_results[twitter_id] = master_results[twitter_id].slice(0, limit)
          continue = false
        else
          continue = true
        end
        puts "#{twitter_id} - #{master_results[twitter_id].length} followers retrieved."
        continue
      end
    end
    master_results
  end  

  # Retrieves the followers records for a group of twitter_ids from Twitter and feeds them to the supplied
  # block one page at a time.  The block passed is expected to return a true or false value.  If it 
  # returns true, fetching of followers will continue for that twitter_id.  If it returns false, fetching
  # of followers will be aborted for that twitter_id only.  This allows a batch of fetches to be started for
  # multiple users.  Fetching of individual user's followers may be aborted while continuing the others.
  # +twitter_ids+ = An array twitter twitter_ids, one for each user to get data for.
  #
  # Returns nil.
  #
  # eg.
  #
  # process_statuses_followers( ['bdoughty', 'joshuabaer'] ) do |twitter_id, followers|
  #   puts "Twitter user #{twitter_id}"
  #   continue = true
  #   followers.each do |follower|
  #     continue = false if follower[:twitter_id] == 'needle'
  #   end
  #   continue 
  # end
  def process_statuses_followers twitter_id_array, &block

    raise "You must supply a block to this method." if !block_given?    
    # Track the proper Twitter API cursor for each twitter_id.  Twitter requests an initial cursor of -1 (to begin paging)
    cursor_tracker = {}
    twitter_id_array.each do |twitter_id|
      cursor_tracker[twitter_id] = -1
    end
    
    while( cursor_tracker.size > 0 )
      twitter_results = typho_twitter_batch( cursor_tracker.keys ) do |twitter_id|
        if twitter_id.is_a? Fixnum
          request = Typhoeus::Request.new("http://twitter.com/statuses/followers.json?cursor=#{cursor_tracker[twitter_id]}&user_id=#{twitter_id}",
            :headers => @headers
          )
        else
          request = Typhoeus::Request.new("http://twitter.com/statuses/followers.json?cursor=#{cursor_tracker[twitter_id]}&screen_name=#{twitter_id}",
            :headers => @headers
          )
        end
      end
      cursor_tracker = {}
      twitter_results.each do |twitter_id, results|
        next_cursor = 0
        if results.is_a?( Hash ) && results['users'] && results['users'].length > 0
          next_cursor = results["next_cursor"]
          continue = yield( twitter_id, results['users'] )
        else
          continue = yield( twitter_id, results ) # return the exception
        end
        if next_cursor != 0 && continue
          cursor_tracker[twitter_id] = next_cursor
        else
          cursor_tracker.delete( twitter_id ) # remove the twitter_id from processing
        end
      end
    end
        
    nil
  end  

  # Retrieves the followers ids for a group of twitter_ids from Twitter and feeds them to the supplied
  # block one page at a time.  The block passed is expected to return a true or false value.  If it 
  # returns true, fetching of follower ids will continue for that twitter_id.  If it returns false, fetching
  # of follower ids will be aborted for that twitter_id only.  This allows a batch of fetches to be started for
  # multiple users.  Fetching of individual user's followers ids may be aborted while continuing the others.
  # +twitter_ids+ = An array twitter twitter_ids, one for each user to get data for.
  #
  # Returns nil.
  #
  # eg.
  #
  # process_followers_ids( ['bdoughty', 'joshuabaer'] ) do |twitter_id, follower_ids|
  #   puts "Twitter user #{twitter_id}"
  #   continue = true
  #   follower_ids.each do |follower_id|
  #     continue = false if follower_id == SOME_TWITTER_USER_ID
  #   end
  #   continue 
  # end
  def process_followers_ids twitter_id_array, &block

    raise "You must supply a block to this method." if !block_given?    
    # Track the proper Twitter API cursor for each twitter_id.  Twitter requests an initial cursor of -1 (to begin paging)
    cursor_tracker = {}
    twitter_id_array.each do |twitter_id|
      cursor_tracker[twitter_id] = -1
    end
    
    while( cursor_tracker.size > 0 )
      twitter_results = typho_twitter_batch( cursor_tracker.keys ) do |twitter_id|
        if twitter_id.is_a? Fixnum
          request = Typhoeus::Request.new("http://twitter.com/followers/ids.json?cursor=#{cursor_tracker[twitter_id]}&user_id=#{twitter_id}",
            :headers => @headers
          )
        else
          request = Typhoeus::Request.new("http://twitter.com/followers/ids.json?cursor=#{cursor_tracker[twitter_id]}&screen_name=#{twitter_id}",
            :headers => @headers
          )
        end
      end
      cursor_tracker = {}
      twitter_results.each do |twitter_id, results|
        next_cursor = 0
        if results.is_a?( Hash ) && results['ids'] && results['ids'].length > 0
          next_cursor = results["next_cursor"]
          continue = yield( twitter_id, results['ids'] )
        else
          continue = yield( twitter_id, results ) # return the exception
        end
        if next_cursor != 0 && continue
          cursor_tracker[twitter_id] = next_cursor
        else
          cursor_tracker.delete( twitter_id ) # remove the twitter_id from processing
        end
      end
    end
        
    nil
  end  

  # Retrieves all timeline updates for a group of twitter_ids from Twitter.
  # This method calls process_statuses_user_timeline() with a block to aggregate the updates.
  # +twitter_id_array+ = An array twitter user ids, one for each user to get data for
  # Returns aggregated updates as a Hash with twitter_ids as keys, and arrays of updates as values.
  # If an unresolvable exception occurred fetching a particular twitter_id, then the resulting TwitterException
  # is returned for that screen name instead of an array of updates.
  def get_statuses_user_timeline twitter_id_array
    master_results = {}
    process_statuses_user_timeline( twitter_id_array ) do |twitter_id, results|
      master_results[twitter_id] ||= []
      if results.is_a? TwitterException
        master_results[twitter_id] = results
        false
      else
        master_results[twitter_id] += results
        true
      end
    end
    master_results
  end
  
  # Retrieves the timeline updates for a group of twitter_ids from Twitter and feeds them to the supplied
  # block one page at a time.  The block passed is expected to return a true or false value.  If it 
  # returns true, fetching of updates will continue for that twitter_id.  If it returns false, fetching
  # of updates will be aborted for that twitter_id only.  This allows a batch of fetches to be started for
  # multiple users.  Fetching of individual user's updates may be aborted while continuing the others.
  # +twitter_ids+ = An array twitter user ids, one for each user to get data for.
  #
  # Returns nil.
  #
  # eg.
  #
  # process_statuses_user_timeline( ['bdoughty', 'joshuabaer'] ) do |twitter_id, updates|
  #   puts "Twitter user #{twitter_id}"
  #   updates.each do |update|
  #     # do something with each status update
  #   end
  #   (twitter_id == 'bdoughty')  # block return value - aborts 'joshuabaer' after the first page, continues 'bdoughty'
  # end
  def process_statuses_user_timeline twitter_ids, &block
    page = 0
    count = 200
    while twitter_ids.length > 0
      page += 1 # Twitter starts with page 1
      puts "Getting page #{page} for timelines."
      twitter_results = typho_twitter_batch( twitter_ids ) do |twitter_id|
        if twitter_id.is_a? Fixnum
          request = Typhoeus::Request.new("http://twitter.com/statuses/user_timeline.json?user_id=#{twitter_id}&page=#{page}&count=#{count}",
            :headers => @headers
          )
        else
          request = Typhoeus::Request.new("http://twitter.com/statuses/user_timeline.json?screen_name=#{twitter_id}&page=#{page}&count=#{count}",
            :headers => @headers
          )
        end
      end

      twitter_ids = []
      twitter_results.each do |twitter_id, results|
        if results && !( results.respond_to?( :length ) && results.length == 0 )
          if block_given? 
            continue = yield( twitter_id, results )
          else
            raise "You must supply a block to this method."
          end
          # keep fetching for this twitter_id only if the block said to and there are more updates.
          twitter_ids << twitter_id if continue && !results.is_a?( TwitterException ) && results.length != 0
        end
      end
    end
    nil
  end  

end
