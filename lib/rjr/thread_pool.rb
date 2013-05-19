# Thread Pool (second implementation)
#
# Copyright (C) 2010-2012 Mohammed Morsi <mo@morsi.org>
# Licensed under the Apache License, Version 2.0

require 'singleton'

module RJR

# Work item to be executed in a thread launched by {ThreadPool}.
#
# The end user just need to initialize this class with the handle
# to the job to be executed and the params to pass to it, before
# handing it off to the thread pool that will take care of the rest.
class ThreadPoolJob
  # Proc to be invoked to perform work
  attr_accessor :handler

  # Parameters to pass to handler proc
  attr_accessor :params

  # Time job started, if nil job hasn't started yet
  attr_accessor :time_started

  # Time job completed, if nil job hasn't completed yet
  attr_accessor :time_completed

  # Thread running the job
  attr_accessor :thread


  # ThreadPoolJob initializer
  # @param [Array] params arguments to pass to the job when it is invoked
  # @param [Callable] block handle to callable object corresponding to job to invoke
  def initialize(*params, &block)
    @params = params
    @handler = block
    @being_executed = false
    @timestamp = nil
  end

  def started?
    !@time_started.nil?
  end

  def completed?
    !@time_started.nil? && !@time_completed.nil?
  end

  # Return bool indicating if specified timeout expired
  def expired?(timeout)
    !@time_started.nil? && @time_completed.nil? && ((Time.now - @time_started) > timeout)
  end

  # Set job metadata and execute job with specified params
  def exec(lock)
    lock.synchronize {
      @thread = Thread.current
      @time_started = Time.now
    }

    @handler.call *@params

    # ensure we do not switch to another job
    # before atomic check expiration / terminate
    # expired threads happens below
    lock.synchronize {
      @time_completed = Time.now
      @thread = nil
    }
  end
end

# Utility to launches a specified number of threads on instantiation,
# assigning work to them in order as it arrives.
#
# Supports optional timeout which allows the developer to kill and restart
# threads if a job is taking too long to run.
#
# Second (and hopefully better) thread pool implementation.
class ThreadPool
  include Singleton

  class << self
    # @!group Config options

    # Number of threads to instantiate in local worker pool
    attr_accessor :num_threads

    # Timeout after which worker threads are killed
    attr_accessor :timeout

    # @!endgroup
  end

  private

  # Internal helper, launch worker thread
  def launch_worker
    @worker_threads << Thread.new {
      while work = @work_queue.pop
        begin
          #RJR::Logger.debug "launch thread pool job #{work}"
          @running_queue << work
          work.exec(@thread_lock)
          # TODO cleaner / more immediate way to pop item off running_queue
          #RJR::Logger.debug "finished thread pool job #{work}"
        rescue Exception => e
          # FIXME also send to rjr logger at a critical level
          puts "Thread raised Fatal Exception #{e}"
          puts "\n#{e.backtrace.join("\n")}"
        end
      end
    }
  end

  # Internal helper, performs checks on workers
  def check_workers
    if @terminate
      @worker_threads.each { |t| 
        t.kill
      }
      @worker_threads = []

    elsif @timeout
      readd = []
      while @running_queue.size > 0 && work = @running_queue.pop
        # check expiration / killing expired threads must be atomic
        # and mutually exclusive with the process of marking a job completed above
        @thread_lock.synchronize{
          if work.expired?(@timeout)
            work.thread.kill
            @worker_threads.delete(work.thread)
            launch_worker

          elsif !work.completed?
            readd << work
          end
        }
      end
      readd.each { |work| @running_queue << work }
    end
  end

  # Internal helper, launch management thread
  #
  # Should only be launched from within the pool_lock
  def launch_manager
    @manager_thread = Thread.new {
      until @terminate
        if @timeout
          sleep @timeout
          check_workers
        else
          Thread.yield
        end
      end

      check_workers
    }
  end

  # Create a new thread pool
  def initialize
    RJR::ThreadPool.num_threads ||=  20
    RJR::ThreadPool.timeout     ||=  10
    @num_threads    = RJR::ThreadPool.num_threads
    @timeout        = RJR::ThreadPool.timeout
    @worker_threads = []

    @work_queue     = Queue.new
    @running_queue  = Queue.new

    @thread_lock = Mutex.new
    @terminate = true

    ObjectSpace.define_finalizer(self, self.class.finalize(self))
  end

  # Ruby ObjectSpace finalizer to ensure that thread pool terminates all
  # threads when object is destroyed.
  def self.finalize(thread_pool)
    # TODO this isn't doing much as by the time this is invoked threads will
    # already be shutdown
    proc { thread_pool.stop ; thread_pool.join }
  end

  public

  # Start the thread pool
  def start
    return self unless @terminate
    @terminate = false
    0.upto(@num_threads) { |i| launch_worker }
    launch_manager
    self
  end

  # Add work to the pool
  # @param [ThreadPoolJob] work job to execute in first available thread
  def <<(work)
    # TODO option to increase worker threads if work queue gets saturated
    @work_queue.push work
  end

  # Terminate the thread pool, stopping all worker threads
  def stop
    @terminate = true
    @manager_thread.wakeup
  end

  # Block until all worker threads have finished executing
  def join
    @manager_thread.join
  end
end

end # module RJR
