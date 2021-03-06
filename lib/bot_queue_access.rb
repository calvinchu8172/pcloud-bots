#!/usr/bin/env ruby

require 'aws-sdk-v1'
require 'json'
require 'yaml'
require_relative './bot_unit'

SQS_CONFIG_FILE = '../config/bot_queue_config.yml'

class BotQueueAccess

  def initialize
    @Queue = nil

    config_file = File.join(File.dirname(__FILE__), SQS_CONFIG_FILE)
    config = YAML.load(File.read(config_file))

    @Queue = self.sqs_connection(config)
  end

  def sqs_connection(config)
    sqs = AWS::SQS.new(:region => config['region'])
    return sqs.queues.named(config['sqs_queue_name'])
  end

  def sqs_listen
    @Queue.poll do |message|
      isValid = valid_json? message.body
      if isValid then
        msg = JSON.parse(message.body)
        if msg["job"] == "pairing" && block_given? then
          job = msg["job"]
          data = {device_id: msg["device_id"]}
          yield(job, data)

        elsif msg["job"] == "cancel" && block_given? then
          job = msg["job"]
          data = {title: msg["title"], tag: msg["tag"]}
          yield(job, data)

        elsif msg["job"] == "unpair" && block_given? then
          job = msg["job"]
          data = {device_id: msg["device_id"]}
          yield(job, data)

        elsif (msg["job"] == "upnp_query" || msg["job"] == "upnp_submit") && block_given? then
          job = msg["job"]
          data = {session_id: msg["session_id"]}
          yield(job, data)

        elsif msg["job"] == "ddns" && block_given? then
          job = msg["job"]
          data = msg
          yield(job, data)

        elsif msg["job"] == "create_permission" && block_given? then
          job = msg["job"]
          data = {session_id: msg["session_id"]}
          yield(job, data)

        elsif msg["job"] == "device_info" && block_given? then
          job = msg["job"]
          data = {session_id: msg["session_id"]}
          yield(job, data)

        elsif msg["job"] == "led_indicator" && block_given? then
          job = msg["job"]
          data = {session_id: msg["session_id"]}
          yield(job, data)

        elsif (msg["job"] == "package_query" || msg["job"] == "package_submit") && block_given? then
          job = msg["job"]
          data = {session_id: msg["session_id"]}
          yield(job, data)

        else
          puts 'Data type non JSON'
        end
      end
      message.delete
    end
  end

#===================== Unuse methods =====================
#=========================================================
  def sqs_receive
  end
end
