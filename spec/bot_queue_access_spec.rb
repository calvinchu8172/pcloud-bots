require_relative '../lib/bot_queue_access'
require 'aws-sdk-v1'

describe BotQueueAccess do
  let(:sqs) {BotQueueAccess.new}

  config_file = File.join(File.dirname(__FILE__), SQS_CONFIG_FILE)
  config = YAML.load(File.read(config_file))

  it 'Config file check' do
    expect(config).to be_an_instance_of(Hash)

    expect(config).to have_key('region')
    expect(config).to have_key('sqs_queue_name')

    expect(config['region']).not_to eq('xxx')
    expect(config['sqs_queue_name']).not_to eq('xxx')
  end

  aws_sqs = AWS::SQS.new(:region => config['region'])
  queue = aws_sqs.queues.named(config['sqs_queue_name'])

  it 'Send Pair message to SQS' do
    pair_body = '{"job":"pairing", "session_id":1}'
    send_message = queue.send_message(pair_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Cancel message to SQS' do
    cancel_body = '{"job":"cancel", "title":"pair", "tag":1}'
    send_message = queue.send_message(cancel_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Unpair message to SQS' do
    unpair_body = '{"job":"unpair", "device_id":1}'
    send_message = queue.send_message(unpair_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Upnp query message to SQS' do
    upnp_query_body = '{"job":"upnp_query", "session_id":1}'
    send_message = queue.send_message(upnp_query_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Upnp submit message to SQS' do
    upnp_submit_body = '{"job":"upnp_submit", "session_id":1}'
    send_message = queue.send_message(upnp_submit_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Package query message to SQS' do
    upnp_query_body = '{"job":"Package_query", "session_id":1}'
    send_message = queue.send_message(upnp_query_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Package submit message to SQS' do
    package_submit_body = '{"job":"package_submit", "session_id":1}'
    send_message = queue.send_message(package_submit_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Device information message to SQS' do
    device_info_body = '{"job":"device_info", "session_id":1}'
    send_message = queue.send_message(device_info_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Led Indicator message to SQS' do
    led_indicator_submit_body = '{"job":"led_indicator", "session_id":1}'
    send_message = queue.send_message(led_indicator_submit_body)
    expect(send_message).to respond_to(:message_id)
  end

  it 'Send Create Permission message to SQS' do
    led_indicator_submit_body = '{"job":"create_permission", "session_id":1}'
    send_message = queue.send_message(led_indicator_submit_body)
    expect(send_message).to respond_to(:message_id)
  end
  it 'Send DDNS message to SQS' do
    ddns_body = '{"job":"ddns", "session_id":1}'
    send_message = queue.send_message(ddns_body)
    expect(send_message).to respond_to(:message_id)
  end

  receieve_message = ''

  it 'Receive message from SQS' do
    count = 0
    sqs.sqs_listen{
      |job, data|

      count += 1
      expect(job).to be_an_instance_of(String)
      expect(data).to be_an_instance_of(Hash)

      receieve_message += "    Received job:#{job} data:#{data}\n"

      break if 5 == count
    }
  end

  it '' do
    puts receieve_message
  end

  it 'Clear retain message' do
    queue.receive_message({:limit => 10, :wait_time_seconds => 20}){
      |message|
      message.delete
    }
  end
end
