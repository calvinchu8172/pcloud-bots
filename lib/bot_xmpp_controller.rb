#!/usr/bin/env ruby

require_relative 'bot_db_access'
require_relative 'bot_route_access'
require_relative 'bot_redis_access'
require_relative 'bot_pair_protocol_template'
require_relative 'bot_mail_access'
require_relative 'bot_unit'
require_relative 'bot_xmpp_db_access'
require_relative 'bot_xmpp_health_check_template'

require 'blather/client/dsl'
require 'multi_xml'
require 'json'
require 'yaml'
require 'rubygems'
require 'eventmachine'
#require 'pry'


BOT_ACCOUNT_CONFIG_FILE = '../config/bot_account_config.yml'

KPAIR_START_REQUEST = 'pair_start_request'
KPAIR_COMPLETED_SUCCESS_RESPONSE = 'pair_completed_success_response'
KPAIR_COMPLETED_FAILURE_RESPONSE = 'pair_completed_failure_response'

KPERMISSION_ASK_REQUEST = 'permission_ask_request'
KPERMISSION_EXPIRE_TIME = 60

KDEVICE_INFO_ASK_REQUEST = 'device_info_query'

KDEVICE_INFO_EXPIRE_TIME = 30

KUNPAIR_ASK_REQUEST = 'unpair_ask_request'

KUPNP_ASK_REQUEST = 'upnp_ask_request'
KUPNP_SETTING_REQUEST = 'upnp_setting_request'
KUPNP_EXPIRE_TIME = 360

KPACKAGE_ASK_REQUEST = 'package_ask_request'
KPACKAGE_SETTING_REQUEST = 'package_setting_request'
KPACKAGE_EXPIRE_TIME = 360



KDDNS_SETTING_REQUEST = 'ddns_setting_request'
KDDNS_SETTING_SUCCESS_RESPONSE = 'ddns_setting_success_response'
KDDNS_SETTING_FAILURE_RESPONSE = 'ddns_setting_failure_response'

KSESSION_CANCEL_REQUEST = 'session_cancel_request'
KSESSION_CANCEL_SUCCESS_RESPONSE = 'session_cancel_success_response'
KSESSION_CANCEL_FAILURE_RESPONSE = 'session_cancel_failure_response'

KSESSION_TIMEOUT_REQUEST = 'session_timeout_request'
KSESSION_TIMEOUT_SUCCESS_RESPONSE = 'session_timeout_success_response'
KSESSION_TIMEOUT_FAILURE_RESPONSE = 'session_timeout_failure_response'

KLED_INDICATOR_REQUEST = 'led_indicator'
KLED_INDICATOR_BLINK_TIME = 30

KHEALTH_CHECK_SUCCESS_RESPONSE = 'health_check_success_response'

KSTATUS_START = 'start'
KSTATUS_WAITING = 'waiting'
KSTATUS_CANCEL = 'cancel'
KSTATUS_TIMEOUT = 'timeout'
KSTATUS_FAILURE = 'failure'
KSTATUS_DONE = 'done'
KSTATUS_OFFLINE = 'offline'
KSTATUS_FORM = 'form'
KSTATUS_SUBMIT = 'submit'
KSTATUS_UPDATED = 'updated'
KSTATUS_SUCCESS = 'success'

XMPP_API_VERSION = 'v1.0'

module XMPPController
  extend Blather::DSL

  #def self.new(account, password)
  def self.new(account , domain)
    @db_conn = nil
    #@bot_xmpp_password = password
    #setup @bot_xmpp_account, @bot_xmpp_password
    @account = account
    @db_conn = BotDBAccess.new
    @rd_conn = BotRedisAccess.new
    @xmpp_db = BotXmppDBAccess.new

    @route_conn = BotRouteAccess.new
    @mail_conn = BotMailAccessSMTP.new

    #@xmpp_server_domain = '@%s' % client.jid.domain
    @xmpp_server_domain = '@%s' % domain
    @xmpp_resource_id = '/device'
    @bot_xmpp_account = @account + @xmpp_server_domain + @xmpp_resource_id

  end

  def self.run
    EM.run {
      LOGGER.post(FLUENT_BOT_SYSINFO, {event: 'SYSTEM',
                                               direction: 'N/A',
                                               to: 'N/A',
                                               from: 'N/A',
                                               id: 'N/A',
                                               full_domain: 'N/A',
                                               message:"Start re-update DDNS record ...",
                                               data: 'N/A'})
      EM.add_periodic_timer(0.3) {
        batch_register_ddns
      }
      EM.add_periodic_timer(60) {
        msg = ALIVE_TESTER % [@bot_xmpp_account]
        write_to_stream msg
        LOGGER.post(FLUENT_BOT_SYSINFO, {event: 'SYSTEM',
                                               direction: 'N/A',
                                               to: 'N/A',
                                               from: @bot_xmpp_account,
                                               id: 'N/A',
                                               full_domain: 'N/A',
                                               message:"%s still running" % @bot_xmpp_account,
                                               data: 'N/A'})
      }
      @bot_xmpp_password = @xmpp_db.db_reset_password(@account)
      setup @bot_xmpp_account, @bot_xmpp_password

      @xmpp_db.close

      client.run
      }
  end


  def self.container(data)
    yield(data)
  end

  def self.alive
    return TRUE
  end

  def self.batch_register_ddns
    isLock = @rd_conn.rd_ddns_batch_lock_isSet
    return nil if isLock

    count = @rd_conn.rd_ddns_batch_session_count
    return nil if 0 == count

    begin
      @rd_conn.rd_ddns_batch_lock_set
      result = @rd_conn.rd_ddns_batch_session_access
      temp = Array.new
      i = 0
      while i < 100 do
        temp << result[i]
        i+=1
      end

      ddnss = temp.reverse

      zones_list = @route_conn.zones_list
      zones_list.each do |zone|
        zone_name = zone["name"]

        records = Array.new
        tempR = Array.new
        ddnss.each do |data|
          if valid_json? data then
            ddns = JSON.parse(data)

            session_id = ddns["index"]
            full_domain = ddns["full_domain"]
            domain_name = find_domainname(full_domain)
            action = ddns["action"]
            ip = ddns["ip"]

            isInclouded = tempR.include?(full_domain)

            if zone_name == domain_name && !isInclouded then
              records << {full_domain: full_domain, ip: ip, action: action, index: session_id}
              tempR << full_domain
            end
          end
        end

        if records.count > 0 then
          
          LOGGER.post(FLUENT_BOT_SYSINFO, {event: 'SYSTEM',
                                                   direction: 'N/A',
                                                   to: 'N/A',
                                                   from: 'N/A',
                                                   id: 'N/A',
                                                   full_domain: 'N/A',
                                                   message:"Batch register DDNS record ...",
                                                   data: 'N/A'})
          isSuccess = @route_conn.batch_create_records({domain_name: zone_name, records: records})

          #if update records failure, remove delete action and do again.
          if !isSuccess then
            i = 0
            while i < records.count do
              action = records[i][:action]
              records.delete_at(i) if 'delete' == action
              i+=1
            end
            sleep(0.3)

            isSuccess = @route_conn.batch_create_records({domain_name: zone_name, records: records})
          end

          ddnss.each do |data|
            if valid_json? data then
              ddns = JSON.parse(data)

              session_id = ddns["index"]
              device_id = ddns["device_id"]
              full_domain = ddns["full_domain"]
              action = ddns["action"]
              ip = ddns["ip"]

              user_email = @db_conn.db_retrive_user_email_by_device_id(device_id)

              
              LOGGER.post(isSuccess ? FLUENT_BOT_SYSINFO : FLUENT_BOT_SYSERROR,
                                    {event: 'DDNS',
                                     direction: 'N/A',
                                     to: 'N/A',
                                     from: 'N/A',
                                     id: session_id,
                                     full_domain: full_domain,
                                     message:"Batch register DDNS record %s" % [isSuccess ? 'success' : 'failure'] ,
                                     data: {ip: ip}})

              if isSuccess then
                ddns_session = @rd_conn.rd_ddns_session_access(session_id)
                @rd_conn.rd_ddns_session_update({index: session_id, status: KSTATUS_SUCCESS}) if !ddns_session.nil?

                isDeleted = @rd_conn.rd_ddns_batch_session_delete(data)
                
                LOGGER.post(isDeleted ? FLUENT_BOT_SYSINFO : FLUENT_BOT_SYSERROR,
                                    {event: 'DDNS',
                                     direction: 'N/A',
                                     to: 'N/A',
                                     from: 'N/A',
                                     id: session_id,
                                     full_domain: 'N/A',
                                     message:"Delete DDNS batch session %s" % [isDeleted ? 'success' : 'failure'] ,
                                     data: 'N/A'})
              else
                if 'update' == action then
                  ddns_session = @rd_conn.rd_ddns_session_access(session_id)
                  @rd_conn.rd_ddns_session_update({index: session_id, status: KSTATUS_FAILURE}) if !ddns_session.nil?

                  @rd_conn.rd_ddns_batch_session_delete(data)
                  retry_data = {index: session_id, device_id: device_id, full_domain: full_domain, ip: ip, action: 'update'}
                  @rd_conn.rd_ddns_batch_session_insert(JSON.generate(retry_data), session_id)
                else
                  @rd_conn.rd_ddns_batch_session_delete(data) if 'delete' == action
                end
              end
            end
          end
        end
        sleep(0.2)
      end
      @rd_conn.rd_ddns_batch_lock_delete
    rescue Exception => error
      @rd_conn.rd_ddns_batch_lock_delete
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

  def self.send_request(job, info)
    case job
# SENDER: SESSION CANCEL REQUEST
      when KSESSION_CANCEL_REQUEST
        device_xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
        title = info[:title]
        tag = info[:tag]
        msg = SESSION_CANCEL_REQUEST % [device_xmpp_account, @bot_xmpp_account, title, tag, XMPP_API_VERSION]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: title.upcase,
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: tag,
                                                  full_domain: 'N/A',
                                                  message:"Send %s SESSION CANCEL REQUEST message to device" % title.upcase ,
                                                  data: 'N/A'})
# SENDER: SESSION CANCEL SUCCESS RESPONSE
      when KSESSION_CANCEL_SUCCESS_RESPONSE
        to = info[:xmpp_account]
        title = info[:title]
        tag = info[:tag]
        msg = SESSION_CANCEL_SUCCESS_RESPONSE % [to, @bot_xmpp_account, title, tag, XMPP_API_VERSION]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: title.upcase,
                                                  direction: 'Bot->Device',
                                                  to: to,
                                                  from: @bot_xmpp_account,
                                                  id: tag,
                                                  full_domain: 'N/A',
                                                  message:"Send %s SESSION CANCEL SUCCESS message to device" % title.upcase ,
                                                  data: 'N/A'})

# SENDER: SESSION CANCEL FAILURE RESPONSE
      when KSESSION_CANCEL_FAILURE_RESPONSE
        to = info[:xmpp_account]
        title = info[:title]
        tag = info[:tag]
        error_code = info[:error_code]
        msg = SESSION_CANCEL_FAILURE_RESPONSE % [to, @bot_xmpp_account, title, error_code, tag]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: title.upcase,
                                                  direction: 'Bot->Device',
                                                  to: to,
                                                  from: @bot_xmpp_account,
                                                  id: tag,
                                                  full_domain: 'N/A',
                                                  message:"Send %s SESSION CANCEL FAILUSE message to device" % title.upcase ,
                                                  data: 'N/A'})

# SENDER: SESSION TIMEOUT REQUEST
      when KSESSION_TIMEOUT_REQUEST
        device_xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
        title = info[:title]
        tag = info[:tag]
        msg = SESSION_TIMEOUT_REQUEST % [device_xmpp_account, @bot_xmpp_account, title, tag, XMPP_API_VERSION]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: title.upcase,
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: tag,
                                                  full_domain: 'N/A',
                                                  message:"Send %s SESSION TIMEOUT REQUEST message to device" % title.upcase ,
                                                  data: 'N/A'})

# SENDER: SESSION TIMEOUT SUCCESS RESPONSE
      when KSESSION_TIMEOUT_SUCCESS_RESPONSE
        device_xmpp_account = info[:xmpp_account]
        title = info[:title]
        tag = info[:tag]
        msg = SESSION_TIMEOUT_SUCCESS_RESPONSE % [device_xmpp_account, @bot_xmpp_account, title, tag]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: title.upcase,
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: tag,
                                                  full_domain: 'N/A',
                                                  message:"Send %s SESSION TIMEOUT SUCCESS RESPONSE message to device" % title.upcase,
                                                  data: 'N/A'})
# SENDER: SESSION TIMEOUT FAILURE RESPONSE
      when KSESSION_TIMEOUT_FAILURE_RESPONSE
        device_xmpp_account = info[:xmpp_account]
        title = info[:title]
        tag = info[:tag]
        error_code = info[:error_code]
        msg = SESSION_TIMEOUT_FAILURE_RESPONSE % [device_xmpp_account, @bot_xmpp_account, title, error_code, tag]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: title.upcase,
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: tag,
                                                  full_domain: 'N/A',
                                                  message:"Send %s SESSION TIMEOUT FAILURE RESPONSE message to device" % title.upcase,
                                                  data: 'N/A'})
# SENDER: PAIR START REQUEST
      when KPAIR_START_REQUEST
        device_xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
        device_id = info[:device_id]
        expire_time = info[:expire_time]

        cancel_msg = SESSION_CANCEL_REQUEST % [device_xmpp_account, @bot_xmpp_account, 'pair', device_id, XMPP_API_VERSION]
        write_to_stream cancel_msg

        msg = PAIR_START_REQUEST % [device_xmpp_account, @bot_xmpp_account, expire_time, device_id, XMPP_API_VERSION]
        write_to_stream msg

        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'PAIR',
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: device_id,
                                                  full_domain: 'N/A',
                                                  message:"Send PAIR START REQUEST message to device" ,
                                                  data: {expire_time: expire_time}})
        df = EM::DefaultDeferrable.new
        EM.add_timer(expire_time) {
          df.set_deferred_status :succeeded, device_id
        }
        df.callback do |x|
          device_id = x
          pairing = @rd_conn.rd_pairing_session_access(device_id)
          expire_at = !pairing.nil? ? pairing["expire_at"].to_i : Time.now.to_i
          status = !pairing.nil? ? pairing["status"] : nil                                          #check expire time for prevent pair start double send
          if (KSTATUS_START == status || KSTATUS_WAITING == status || KSTATUS_OFFLINE == status) && Time.now.to_i > (expire_at - 1) then
            data = {device_id: device_id, status: KSTATUS_TIMEOUT}
            @rd_conn.rd_pairing_session_update(data) if KSTATUS_START == status || KSTATUS_WAITING == status

            device = @rd_conn.rd_device_session_access(device_id)
            xmpp_account = device["xmpp_account"] if !device.nil?
            info = {xmpp_account: xmpp_account, title: 'pair', tag: device_id}
            send_request(KSESSION_TIMEOUT_REQUEST, info) if !device.nil?
          end
        end

# SENDER: PAIR COMPLETED SUCCESS RESPONSE
      when KPAIR_COMPLETED_SUCCESS_RESPONSE
        msg = PAIR_COMPLETED_SUCCESS_RESPONSE % [info[:xmpp_account], @bot_xmpp_account, info[:cloud_id], info[:session_id]]
        write_to_stream msg

# SENDER: PAIR COMPLETED FAILURE RESPONSE
      when KPAIR_COMPLETED_FAILURE_RESPONSE
        msg = PAIR_COMPLETED_FAILURE_RESPONSE % [info[:xmpp_account], @bot_xmpp_account, info[:error_code], info[:session_id]]
        write_to_stream msg

# SENDER: UNPAIR REQUEST
      when KUNPAIR_ASK_REQUEST

        EM.defer {
          xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
          session_id = info[:session_id]

          if !info[:full_domain].nil?
            index = @rd_conn.rd_ddns_session_index_get
            ddns_record = @db_conn.db_ddns_access({device_id: info[:session_id]})
            ip = ddns_record.ip_address

            batch_data = {index: index, device_id: info[:session_id], full_domain: info[:full_domain], ip: ip, action: 'delete'}
            isDeleted = @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), index)

            
            LOGGER.post(isDeleted ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWERROR,
                                  {event: 'UNPAIR',
                                   direction: 'N/A',
                                   to: 'N/A',
                                   from: 'N/A',
                                   id: 'N/A',
                                   full_domain: info[:full_domain],
                                   message:"Delete Route53 DDNS record %s as unpair" % [isDeleted ? 'success' : 'failure'] ,
                                   data: 'N/A'})

            isDeleted = FALSE
            ddns = @db_conn.db_ddns_access({full_domain: info[:full_domain]})
            isDeleted = @db_conn.db_ddns_delete(ddns.id) if !ddns.nil?
            
            LOGGER.post(isDeleted ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                  {event: 'UNPAIR',
                                   direction: 'N/A',
                                   to: 'N/A',
                                   from: 'N/A',
                                   id: !ddns.nil? ? ddns.id : 'N/A',
                                   full_domain: info[:full_domain],
                                   message:"Delete DB DDNS record as unpair %s" % [isDeleted ? 'success' : 'failure'] ,
                                   data: 'N/A'})
          end

          msg = UNPAIR_ASK_REQUEST % [xmpp_account, @bot_xmpp_account, session_id, XMPP_API_VERSION]
          write_to_stream msg
          
          LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'UNPAIR',
                                                    direction: 'Bot->Device',
                                                    to: xmpp_account,
                                                    from: @bot_xmpp_account,
                                                    id: session_id,
                                                    full_domain: 'N/A',
                                                    message:"Send UNPAIR ASK REQUEST message to device" ,
                                                    data: 'N/A'})

          df = EM::DefaultDeferrable.new
          periodic_timer = EM.add_periodic_timer(15) {
            unpair_session = @rd_conn.rd_unpair_session_access(session_id)
            if !unpair_session.nil? then
              write_to_stream msg
              
              LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'UNPAIR',
                                                        direction: 'Bot->Device',
                                                        to: xmpp_account,
                                                        from: @bot_xmpp_account,
                                                        id: session_id,
                                                        full_domain: 'N/A',
                                                        message:"Resend UNPAIR ASK REQUEST message to device" ,
                                                        data: 'N/A'})
            else
              df.set_deferred_status :succeeded, "[%s] Unpair success, and remove timer - %s" % [DateTime.now, info[:xmpp_account]]
            end
          }
          EM.add_timer(60 * 1){
            df.set_deferred_status :succeeded, "[%s] Unpair times is up - %s" % [DateTime.now, info[:xmpp_account]]
          }
          df.callback do |x|
            unpair_session = @rd_conn.rd_unpair_session_access(session_id)

            if !unpair_session.nil? then
              @rd_conn.rd_unpair_session_delete(session_id)
            end

            EM.cancel_timer(periodic_timer)
            
            LOGGER.post(FLUENT_BOT_FLOWERROR, {event: 'UNPAIR',
                                                      direction: 'N/A',
                                                      to: 'N/A',
                                                      from: 'N/A',
                                                      id: session_id,
                                                      full_domain: 'N/A',
                                                      message:"Unpair timeout, stop resend message to device" ,
                                                      data: 'N/A'})
          end
        }
        #unpairThread.abort_on_exception = FALSE

# SENDER: PERMISSION REQUEST
      when KPERMISSION_ASK_REQUEST

        device_xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
        device_id           = info[:device_id]
        session_id          = info[:session_id]

        expire_time         = KPERMISSION_EXPIRE_TIME
        expire_at           = (Time.now + expire_time).to_i

        permission_session  = info[:permission_session]

        # follow redis format
        share_point         = permission_session["share_point"]
        permission          = permission_session["permission"]
        cloud_id            = permission_session["cloud_id"]

        msg = PERMISSION_ASK_REQUEST % [device_xmpp_account, @bot_xmpp_account, share_point, permission, cloud_id, expire_time, session_id, XMPP_API_VERSION]
        write_to_stream msg

        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'PERMISSION',
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: device_id,
                                                  full_domain: 'N/A',
                                                  message:"Send User Permission START REQUEST message to device",
                                                  data: 'N/A'})

        df = EM::DefaultDeferrable.new
        EM.add_timer(expire_time * 1){
          df.set_deferred_status :succeeded, session_id
        }

        df.callback do |x|
          permission_session = @rd_conn.rd_permission_session_access( session_id )
          status = !permission_session.nil? ? permission_session["status"] : nil
          if (KSTATUS_SUBMIT == status) && Time.now.to_i > (expire_at - 1) then
            data = { index: session_id, status: KSTATUS_TIMEOUT }
            @rd_conn.rd_permission_session_update(data)

            device = @rd_conn.rd_device_session_access(device_id)
            info = {xmpp_account: device_xmpp_account, title: 'bot_set_share_permission', tag: permission_session["device_id"]}
            send_request(KSESSION_TIMEOUT_REQUEST, info) if !device.nil?
          end
        end

# SENDER: DEVICE INFOMATION REQUEST
      when KDEVICE_INFO_ASK_REQUEST
        device_xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
        session_id = info[:session_id]

        msg = DEVICE_INFO_ASK_REQUEST % [device_xmpp_account, @bot_xmpp_account, KDEVICE_INFO_EXPIRE_TIME, session_id, XMPP_API_VERSION]
        write_to_stream msg

       
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'DEVICE-INFOMATION',
                                                  direction: 'Bot->Device',
                                                  to: device_xmpp_account,
                                                  from: @bot_xmpp_account,
                                                  id: device_id,
                                                  full_domain: 'N/A',
                                                  message:"Send DEVICE INFOMATION START REQUEST message to device",
                                                  data: 'N/A'})
        df = EM::DefaultDeferrable.new
        EM.add_timer(KDEVICE_INFO_EXPIRE_TIME * 1){
          df.set_deferred_status :succeeded, session_id
        }
        df.callback do |x|
          index = x
          device_info = @rd_conn.rd_device_info_session_access(index)
          status = !device_info.nil? ? device_info["status"] : nil
          if KSTATUS_START == status then
            data = {session_id: index, status: KSTATUS_TIMEOUT}
            @rd_conn.rd_device_info_session_update(data)

            device = @rd_conn.rd_device_session_access(device_info["device_id"])
            xmpp_account = device["xmpp_account"] if !device.nil?
            info = {xmpp_account: xmpp_account, title: 'bot_get_device_information', tag: index}
            send_request(KSESSION_TIMEOUT_REQUEST, info)

           
            LOGGER.post(FLUENT_BOT_FLOWINFO,
                                  {event: 'DEVICE-INFOMATION',
                                   direction: 'N/A',
                                   to: xmpp_account + @xmpp_server_domain + @xmpp_resource_id,
                                   from: @bot_xmpp_account,
                                   id: index,
                                   full_domain: 'N/A',
                                   message:"Update status of device information session to 'TIMEOUT' as ask device information expired from device",
                                   data: 'N/A'})
          end
        end
# SENDER: PACKAGE GETTING REQUEST
      when KPACKAGE_ASK_REQUEST
        session_id = info[:session_id]
        msg = PACKAGE_ASK_REQUEST % [info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id, @bot_xmpp_account, 300, session_id, XMPP_API_VERSION]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'PACKAGE',
                                                  direction: 'Bot->Device',
                                                  to: info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id,
                                                  from: @bot_xmpp_account,
                                                  id: info[:session_id],
                                                  full_domain: 'N/A',
                                                  message:"Send package ASK REQUEST message to device" ,
                                                  data: 'N/A'})
        df = EM::DefaultDeferrable.new
        EM.add_timer(KPACKAGE_EXPIRE_TIME * 1) {
          df.set_deferred_status :succeeded, session_id
        }
        df.callback do |x|
          index = x
          package = @rd_conn.rd_package_session_access(index)
          status = !package.nil? ? package["status"] : nil

          if KSTATUS_START == status then
            data = {index: index, status: KSTATUS_TIMEOUT}
            @rd_conn.rd_package_session_update(data)

            device_id = package["device_id"]
            device = @rd_conn.rd_device_session_access(device_id)
            xmpp_account = device["xmpp_account"] if !device.nil?
            info = {xmpp_account: xmpp_account, title: 'get_package_service', tag: index}
            send_request(KSESSION_TIMEOUT_REQUEST, info)

            
            LOGGER.post(FLUENT_BOT_FLOWINFO,
                                  {event: 'PCAKAGE',
                                   direction: 'N/A',
                                   to: xmpp_account + @xmpp_server_domain + @xmpp_resource_id,
                                   from: @bot_xmpp_account,
                                   id: index,
                                   full_domain: 'N/A',
                                   message:"Update status of package session to 'TIMEOUT' as get service list expired frome device",
                                   data: 'N/A'})
          end
        end

# SENDER: PACKAGE SETTING REQUEST
      when KPACKAGE_SETTING_REQUEST
        session_id = info[:session_id]
        msg = PACKAGE_SETTING_REQUEST % [info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id, @bot_xmpp_account, 300,  info[:field_item], session_id]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'PACKAGE',
                                                  direction: 'Bot->Device',
                                                  to: info[:xmpp_account],
                                                  from: @bot_xmpp_account,
                                                  id: info[:session_id],
                                                  full_domain: 'N/A',
                                                  message:"Send PACKAGE SETTING RESPONSE message to device" ,
                                                  data: {field_item: info[:field_item]}})
        df = EM::DefaultDeferrable.new
        EM.add_timer(KPACKAGE_EXPIRE_TIME * 1) {
          df.set_deferred_status :succeeded, session_id
        }
        df.callback do |x|
          index = x
          package = @rd_conn.rd_package_session_access(index)
          status = !package.nil? ? package["status"] : nil

          if KSTATUS_SUBMIT == status then
            data = {index: index, status: KSTATUS_TIMEOUT}
            @rd_conn.rd_package_session_update(data)

            device_id = package["device_id"]
            device = @rd_conn.rd_device_session_access(device_id)
            xmpp_account = device["xmpp_account"] if !device.nil?
            info = {xmpp_account: xmpp_account, title: 'set_package_service', tag: index}
            send_request(KSESSION_TIMEOUT_REQUEST, info)

           
            LOGGER.post(FLUENT_BOT_FLOWINFO,
                                  {event: 'PACKAGE',
                                   direction: 'N/A',
                                   to: xmpp_account + @xmpp_server_domain + @xmpp_resource_id,
                                   from: @bot_xmpp_account,
                                   id: index,
                                   full_domain: 'N/A',
                                   message:"Update status of package session to 'TIMEOUT' as set service list expired from device",
                                   data: 'N/A'})
          end
        end


# SENDER: UPNP GETTING REQUEST
      when KUPNP_ASK_REQUEST
        session_id = info[:session_id]
        msg = UPNP_ASK_REQUEST % [info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id, @bot_xmpp_account, info[:language], 300, session_id, XMPP_API_VERSION]
        write_to_stream msg
       
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'UPNP',
                                                  direction: 'Bot->Device',
                                                  to: info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id,
                                                  from: @bot_xmpp_account,
                                                  id: info[:session_id],
                                                  full_domain: 'N/A',
                                                  message:"Send UPNP ASK REQUEST message to device" ,
                                                  data: {language: info[:language]}})
        df = EM::DefaultDeferrable.new
        EM.add_timer(KUPNP_EXPIRE_TIME * 1) {
          df.set_deferred_status :succeeded, session_id
        }
        df.callback do |x|
          index = x
          upnp = @rd_conn.rd_upnp_session_access(index)
          status = !upnp.nil? ? upnp["status"] : nil

          if KSTATUS_START == status then
            data = {index: index, status: KSTATUS_TIMEOUT}
            @rd_conn.rd_upnp_session_update(data)

            device_id = upnp["device_id"]
            device = @rd_conn.rd_device_session_access(device_id)
            xmpp_account = device["xmpp_account"] if !device.nil?
            info = {xmpp_account: xmpp_account, title: 'get_upnp_service', tag: index}
            send_request(KSESSION_TIMEOUT_REQUEST, info)

            LOGGER.post(FLUENT_BOT_FLOWINFO,
                                  {event: 'UPNP',
                                   direction: 'N/A',
                                   to: xmpp_account + @xmpp_server_domain + @xmpp_resource_id,
                                   from: @bot_xmpp_account,
                                   id: index,
                                   full_domain: 'N/A',
                                   message:"Update status of upnp session to 'TIMEOUT' as get service list expired frome device",
                                   data: 'N/A'})
          end
        end

# SENDER: UPNP SETTING REQUEST
      when KUPNP_SETTING_REQUEST
        session_id = info[:session_id]
        msg = UPNP_SETTING_REQUEST % [info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id, @bot_xmpp_account, info[:language], info[:field_item], 300, session_id]
        write_to_stream msg
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'UPNP',
                                                  direction: 'Bot->Device',
                                                  to: info[:xmpp_account],
                                                  from: @bot_xmpp_account,
                                                  id: info[:session_id],
                                                  full_domain: 'N/A',
                                                  message:"Send UPNP SETTING RESPONSE message to device" ,
                                                  data: {language: info[:language], field_item: info[:field_item]}})
        df = EM::DefaultDeferrable.new
        EM.add_timer(KUPNP_EXPIRE_TIME * 1) {
          df.set_deferred_status :succeeded, session_id
        }
        df.callback do |x|
          index = x
          upnp = @rd_conn.rd_upnp_session_access(index)
          status = !upnp.nil? ? upnp["status"] : nil

          if KSTATUS_SUBMIT == status then
            data = {index: index, status: KSTATUS_TIMEOUT}
            @rd_conn.rd_upnp_session_update(data)

            device_id = upnp["device_id"]
            device = @rd_conn.rd_device_session_access(device_id)
            xmpp_account = device["xmpp_account"] if !device.nil?
            info = {xmpp_account: xmpp_account, title: 'set_upnp_service', tag: index}
            send_request(KSESSION_TIMEOUT_REQUEST, info)

            LOGGER.post(FLUENT_BOT_FLOWINFO,
                                  {event: 'UPNP',
                                   direction: 'N/A',
                                   to: xmpp_account + @xmpp_server_domain + @xmpp_resource_id,
                                   from: @bot_xmpp_account,
                                   id: index,
                                   full_domain: 'N/A',
                                   message:"Update status of upnp session to 'TIMEOUT' as set service list expired from device",
                                   data: 'N/A'})
          end
        end

# SENDER: DDNS SETTING REQUEST
      when KDDNS_SETTING_REQUEST
        EM.defer {
          begin
          host_name = find_hostname(info[:full_domain])
          domain_name = find_domainname(info[:full_domain])

          @rd_conn.rd_ddns_session_update({index: info[:session_id], status: KSTATUS_WAITING})
          
          LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'DDNS',
                                                    direction: 'N/A',
                                                    to: info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id,
                                                    from: @bot_xmpp_account,
                                                    id: info[:session_id],
                                                    full_domain: info[:full_domain],
                                                    message:"Prepare send DDNS SETTING REQUEST to device" ,
                                                    data: 'N/A'})

          ddns_record = @db_conn.db_ddns_access({device_id: info[:device_id].to_i})

          #device = @rd_conn.rd_device_session_access(info[:device_id])
          #ip = info[:ip]

          batch_data = {index: info[:session_id], device_id: info[:device_id], full_domain: info[:full_domain], ip: info[:ip], action: 'update'}
          @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), info[:session_id])

          if !ddns_record.nil? then
            old_full_domain = ddns_record.full_domain.to_s

            data = {id: ddns_record.id, full_domain: info[:full_domain], ip_address: info[:ip]}
            isUpdated =  @db_conn.db_ddns_update(data)
            
            LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                  {event: 'DDNS',
                                   direction: 'N/A',
                                   to: 'N/A',
                                   from: 'N/A',
                                   id: ddns_record.id,
                                   full_domain: info[:full_domain],
                                   message:"Update DB DDNS setting %s" % [isUpdated ? 'success' : 'failure'] ,
                                   data: {ip: info[:ip]}})
            if old_full_domain != info[:full_domain]
              del_index = @rd_conn.rd_ddns_session_index_get
              ip = ddns_record.ip_address

              batch_data = {index: del_index, device_id: info[:device_id], full_domain: old_full_domain, ip: ip, action: 'delete'}
              isDeleted = @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), del_index)
              
              LOGGER.post(isDeleted ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWERROR,
                                    {event: 'DDNS',
                                     direction: 'N/A',
                                     to: 'N/A',
                                     from: 'N/A',
                                     id: 'N/A',
                                     full_domain: old_full_domain,
                                     message:"Delete previous DDNS setting in Route53 %s" % [isDeleted ? 'success' : 'failure'] ,
                                     data: 'N/A'})
            end
          else
            data = {device_id: info[:device_id], ip_address: info[:ip], full_domain: info[:full_domain]}
            new_ddns = @db_conn.db_ddns_insert(data)
            isInserted = !new_ddns.nil? ? TRUE : FALSE
            
            LOGGER.post(isInserted ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                  {event: 'DDNS',
                                   direction: 'N/A',
                                   to: 'N/A',
                                   from: 'N/A',
                                   id: 'N/A',
                                   full_domain: info[:full_domain],
                                   message:"Insert new DDNS setting into DB %s" % [isInserted ? 'success' : 'failure'] ,
                                   data: {device_id: info[:device_id], ip: info[:ip]}})
          end

          isSuccess = FALSE
          i = 0
          while !isSuccess && i < 100
            result = @rd_conn.rd_ddns_session_access(info[:session_id])
            isSuccess = KSTATUS_SUCCESS == result["status"] ? TRUE : FALSE
            i+=1
            sleep(0.1)
          end

          if isSuccess then
            msg = DDNS_SETTING_REQUEST % [info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id, @bot_xmpp_account, host_name, domain_name, info[:session_id], XMPP_API_VERSION]
            write_to_stream msg
            
            LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'DDNS',
                                                      direction: 'Bot->Device',
                                                      to: info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id,
                                                      from: @bot_xmpp_account,
                                                      id: info[:session_id],
                                                      full_domain: host_name + '.' + domain_name,
                                                      message:"Send DDNS SETTING REQUEST to device" ,
                                                      data: 'N/A'})
            @rd_conn.rd_ddns_resend_session_insert(info[:session_id])
            df = EM::DefaultDeferrable.new
            periodic_timer = EM.add_periodic_timer(15) {
              resend = @rd_conn.rd_ddns_resend_session_access(info[:session_id])
              if !resend.nil? then
                msg = DDNS_SETTING_REQUEST % [info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id, @bot_xmpp_account, host_name, domain_name, info[:session_id], XMPP_API_VERSION]
                write_to_stream msg
                
                LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'DDNS',
                                                          direction: 'Bot->Device',
                                                          to: info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id,
                                                          from: @bot_xmpp_account,
                                                          id: info[:session_id],
                                                          full_domain: host_name + '.' + domain_name,
                                                          message:"Resend DDNS SETTING REQUEST to device" ,
                                                          data: 'N/A'})
              else
                df.set_deferred_status :succeeded, info[:session_id]
              end
            }
            EM.add_timer(60 * 1){
              df.set_deferred_status :succeeded, info[:session_id]
            }
            df.callback do |x|
              index = x
              resend = @rd_conn.rd_ddns_resend_session_access(index)
              @rd_conn.rd_ddns_resend_session_delete(index) if !resend.nil?

              EM.cancel_timer(periodic_timer)
              
              LOGGER.post(FLUENT_BOT_FLOWERROR, {event: 'DDNS',
                                                        direction: 'N/A',
                                                        to: 'N/A',
                                                        from: 'N/A',
                                                        id: index,
                                                        full_domain: 'N/A',
                                                        message:"Timeout, stop resend DDNS SETTING REQUEST message to device" ,
                                                        data: 'N/A'})
            end
          end
          rescue Exception => error
            
            LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
          end
        }

# SENDER: LED INDICATOR REQUEST
      when KLED_INDICATOR_REQUEST
        device_xmpp_account = info[:xmpp_account] + @xmpp_server_domain + @xmpp_resource_id
        msg = LED_INDICATOR_REQUEST % [device_xmpp_account, @bot_xmpp_account, KLED_INDICATOR_BLINK_TIME, info[:session_id], XMPP_API_VERSION]
        write_to_stream msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'LED_INDICATOR_REQUEST',
                                                  direction: 'Bot->Device',
                                                  to: info[:xmpp_account],
                                                  from: @bot_xmpp_account,
                                                  id: info[:session_id],
                                                  full_domain: 'N/A',
                                                  message:"Send LED INDICATOR REQUEST message to device" ,
                                                  data: 'N/A'})

# SENDER: DDNS SETTING SUCCESS RESPONSE
      when KDDNS_SETTING_SUCCESS_RESPONSE
        msg = DDNS_SETTING_SUCCESS_RESPONSE % [info[:xmpp_account], @bot_xmpp_account, info[:session_id]]
        write_to_stream msg

# SENDER: DDNS SETTING FAILURE RESPONSE
      when KDDNS_SETTING_FAILURE_RESPONSE
        msg = DDNS_SETTING_FAILURE_RESPONSE % [info[:xmpp_account], @bot_xmpp_account, info[:error_code], info[:session_id]]
        write_to_stream msg

# SENDER: HEALTH CHECK SUCCESS RESPONSE
      when KHEALTH_CHECK_SUCCESS_RESPONSE
        # puts "sender #{info}"
        bot_health_check_account = info[:bot_health_check_account]
        bot_xmpp_account = info[:bot_xmpp_account]
        health_check_send_time = info[:health_check_send_time]
        bot_receive_time = info[:bot_receive_time]
        bot_send_time = Time.now.to_i
        health_check_receive_time = info[:health_check_receive_time]
        thread = info[:thread]
        msg = HEALTH_CHECK_SUCCESS_RESPONSE % [bot_health_check_account, bot_xmpp_account, health_check_send_time, bot_receive_time, bot_send_time, health_check_receive_time, thread]
        write_to_stream msg
        # puts msg
        
        LOGGER.post(FLUENT_BOT_FLOWINFO, {event: 'HEALTH CHECK',
                                                  direction: 'Bot->Health_Check',
                                                  to: bot_health_check_account,
                                                  from: bot_xmpp_account,
                                                  health_check_send_time: health_check_send_time,
                                                  bot_receive_time: bot_receive_time,
                                                  bot_send_time: bot_send_time,
                                                  health_check_receive_time: health_check_receive_time,
                                                  id: thread,
                                                  full_domain: 'N/A',
                                                  message:"Send HEALTH_CHECK_SUCCESS_RESPONSE message back to %s" % bot_health_check_account,
                                                  data: 'N/A'})

    end
  end

  def self.result_syslog(msg)
    
    LOGGER.post(FLUENT_BOT_SYSINFO,
                          {event: 'SYSTEM',
                            direction: 'Device->Bot',
                            to: @bot_xmpp_account,
                            from: msg.from.to_s,
                            id: 'N/A',
                            full_domain: 'N/A',
                            message:"Receive RESULT message - %s from device" % msg.form.title ,
                            data: {xml: msg.to_s.gsub(/\n\s+/, "")}})
  end

  def self.submit_syslog(msg)
    
    LOGGER.post(FLUENT_BOT_SYSINFO,
                          {event: 'SYSTEM',
                           direction: 'Device->Bot',
                           to: @bot_xmpp_account,
                           from: msg.from.to_s,
                           id: 'N/A',
                           full_domain: 'N/A',
                           message:"Receive SUBMIT message - %s from device" % msg.form.title,
                           data: {xml: msg.to_s.gsub(/\n\s+/, "")}})
  end

  def self.cancel_syslog(msg)
    
    LOGGER.post(FLUENT_BOT_SYSINFO,
                          {event: 'SYSTEM',
                           direction: 'Device->Bot',
                           to: @bot_xmpp_account,
                           from: msg.from.to_s,
                           id: 'N/A',
                           full_domain: 'N/A',
                           message:"Receive CANCEL message - %s from device" % msg.form.title,
                           data: {xml: msg.to_s.gsub(/\n\s+/, "")}})
  end

  def self.form_syslog(msg)
    
    LOGGER.post(FLUENT_BOT_SYSINFO,
                          {event: 'SYSTEM',
                           direction: 'Device->Bot',
                           to: @bot_xmpp_account,
                           from: msg.from.to_s,
                           id: 'N/A',
                           full_domain: 'N/A',
                           message:"Receive FORM message - %s from device" % msg.form.title,
                           data: {xml: msg.to_s.gsub(/\n\s+/, "")}})
  end

  disconnected {
     
    LOGGER.post(FLUENT_BOT_SYSALERT, {event: 'SYSTEM',
                                              direction: 'N/A',
                                              to: 'N/A',
                                              from: @bot_xmpp_account,
                                              id: 'N/A',
                                              full_domain: 'N/A',
                                              message:"%s disconnected " % @bot_xmpp_account,
                                              data: 'N/A'})
    raise ( "%s disconnected" % @bot_xmpp_account)
  }

# HANDLER: Result:Pair:Start
  message :normal?, proc {|m| m.form.result? && 'pair' == m.form.title && 'start' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      expire_time = pairing["expire_at"] if !pairing.nil?
      isStartExpired = ((expire_time.to_i - Time.now.to_i) < 540)
      if !pairing.nil? && KSTATUS_START == pairing["status"] then
        data = {device_id: device_id, status: !isStartExpired ? KSTATUS_WAITING : KSTATUS_TIMEOUT}
        isSuccess = @rd_conn.rd_pairing_session_update(data)
        status = data[:status]
        
        LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Update the status of pairing session table to %s %s as receive PAIR START RESPONSE message from device" % [status, isSuccess ? 'success' : 'failure'] ,
                               data: 'N/A'})
      else
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'N/A',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Update the status of pairing session table to WAITING failure, session id not find or status wrong",
                               data: {error_code: 898}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Pair:Cancel
  message :normal?, proc {|m| m.form.result? && 'pair' == m.form.title && 'cancel' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      if !pairing.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Receive PAIR CALCEL RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Pair:Timeout
  message :normal?, proc {|m| m.form.result? && 'pair' == m.form.title && 'timeout' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      if !pairing.nil?
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Receive PAIR TIMEOUT RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Unpair
  message :normal?, proc {|m| m.form.result? && 'unpair' == m.form.title} do |msg|
    begin
      result_syslog(msg)

      device_id = msg.thread
      isSuccess = FALSE
      unpair_session = @rd_conn.rd_unpair_session_access(device_id)
      if !unpair_session.nil? then
        isSuccess = @rd_conn.rd_unpair_session_delete(device_id)
      else
        isSuccess = TRUE
      end

      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'UNPAIR',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: device_id,
                             full_domain: 'N/A',
                             message:"Delete record from unpair session table %s as receive UNPAIR SUCCESS RESPONSE message from device" % [isSuccess ? 'success' : 'failure'] ,
                             data: 'N/A'})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Get_upnp_service:Timeout
  message :normal?, proc {|m| m.form.result? && 'get_upnp_service' == m.form.title && 'timeout' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      session_id = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(session_id)
      if !upnp.nil?
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: session_id,
                               full_domain: 'N/A',
                               message:"Receive GET UPNP SERVICE LIST TIMEOUT RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Get_upnp_service:Cancel
  message :normal?, proc {|m| m.form.result? && 'get_upnp_service' == m.form.title && 'cancel' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      session_id = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(session_id)
      if !upnp.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: session_id,
                               full_domain: 'N/A',
                               message:"Receive GET UPNP SERVICE LIST CALCEL RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Set_upnp_service:!nil:Timeout
  message :normal?, proc {|m| m.form.result? && 'set_upnp_service' == m.form.title && nil != m.form.field('action') && 'timeout' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      index = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(index)
      if !upnp.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Receive UPNP SETTING TIMEOUT SUCCESS RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Set_upnp_service:!nil:Cancel
  message :normal?, proc {|m| m.form.result? && 'set_upnp_service' == m.form.title && nil != m.form.field('action') && 'cancel' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      session_id = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(session_id)
      if !upnp.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: session_id,
                               full_domain: 'N/A',
                               message:"Receive SET UPNP SERVICE LIST CALCEL RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Set_upnp_service:nil
  message :normal?, proc {|m| m.form.result? && 'set_upnp_service' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      result_syslog(msg)
      session_id = msg.thread
      data = {index: session_id, status: KSTATUS_UPDATED}
      isSuccess = @rd_conn.rd_upnp_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'UPNP',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status of unpnp session table to UPDATED %s as receive UPNP SETTING SUCCESS RESPONSE message from device" % [isSuccess ? 'success' : 'failure'] ,
                             data: 'N/A'})
    rescue Exception => error
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:permission
  message :normal?, proc {|m| m.form.result? && 'bot_set_share_permission' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      result_syslog(msg)

      session_id = msg.thread
      data       = {index: session_id, status: KSTATUS_DONE, error_code: ''}

      isSuccess  = @rd_conn.rd_permission_session_update(data)
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'PERMISSION',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             message:"Update the status of permission session table to UPDATED %s as receive PERMISSION RESPONSE message from device" % [isSuccess ? 'success' : 'failure'] ,
                             data: 'N/A'})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Get_device_information
  message :normal?, proc {|m| 'bot_get_device_information' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      result_syslog(msg)

      session_id = msg.thread

      if msg.form.field('ERROR_CODE').nil?
        # Device basic information
        info_key_list = ["fan-speed", "cpu-temperature-celsius", "cpu-temperature-fahrenheit",
                         "cpu-temperature-warning", "raid-status"]

        ## Store device info to hash
        device_info = Hash.new
        info_key_list.each do |key|
          key_field = msg.form.field("#{key}")
          if !key_field.nil?
            device_info_key = key.gsub("-", "_")
            device_info[device_info_key.to_sym] = key_field.value
          end
        end

        ## Define item list
        MultiXml.parser = :rexml
        xml = MultiXml.parse(msg.form.to_s)

        ## Store volume info in each item
        volume_list = Array.new
        xml["x"]["item"].each do |item|
          item_field =  ( item.class.to_s == 'Hash' ? item['field'] : item[1] )
          item_list = Array.new
          item_field.each do |field|
            new_field = Hash.new
            new_field[field["var"].to_sym] = field["value"]
            item_list << new_field
          end
          volume_list << item_list
        end

        device_info[:volume_list] = volume_list
        device_info = JSON.generate(device_info)

        data = {session_id: session_id, status: KSTATUS_DONE, device_info: device_info}
      else
        error_code = msg.form.field('ERROR_CODE').value
        data = {session_id: session_id, status: KSTATUS_FAILURE, error_code: error_code}
      end

      isSuccess         = @rd_conn.rd_device_info_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'DEVICE-INFOMATION',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             message:"Update the status of device information session table to UPDATED %s as receive DEVICE-INFOMATION RESPONSE message from device" % [isSuccess ? 'success' : 'failure'] ,
                             data: 'N/A'})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:Config_ddns
  message :normal?, proc {|m| m.form.result? && 'config_ddns' == m.form.title} do |msg|
    begin
      result_syslog(msg)

      index = msg.thread
      @rd_conn.rd_ddns_resend_session_delete(index)
      
      LOGGER.post(FLUENT_BOT_FLOWINFO,
                            {event: 'DDNS',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: index,
                             full_domain: 'N/A',
                             message:"Receive DDNS SETTING SUCCESS RESPONSE message from device success",
                             data: 'N/A'})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Pair:Completed
  message :normal?, proc {|m| m.form.submit? && 'pair' == m.form.title && 'completed' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      expire_time = pairing["expire_at"] if !pairing.nil?
      status = !pairing.nil? ? pairing["status"] : nil
      isExpired = !(expire_time.to_i > Time.now.to_i)
      if !pairing.nil? && KSTATUS_WAITING == status then
        if !isExpired
          data = {device_id: device_id, status: KSTATUS_DONE}
          isSuccess = @rd_conn.rd_pairing_session_update(data)
          
          LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                {event: 'PAIR',
                                 direction: 'Device->Bot',
                                 to: @bot_xmpp_account,
                                 from: msg.from.to_s,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Update the status of pairing session to COMPLETED %s as receive PAIR CONPLETED RESPONSE message from device" % [isSuccess ? 'success' : 'failure'] ,
                                 data: 'N/A'})

          pairing_insert = @db_conn.db_pairing_insert(pairing["user_id"].to_i, device_id.to_i)
          
          LOGGER.post(nil != pairing_insert ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                {event: 'PAIR',
                                 direction: 'N/A',
                                 to: 'N/A',
                                 from: 'N/A',
                                 id: pairing_insert.id,
                                 full_domain: 'N/A',
                                 message:"Insert paired data into pairing table %s as receive PAIR CONPLETED RESPONSE message from device" % [nil != pairing_insert ? 'success' : 'failure'] ,
                                 data: {user_id: pairing["user_id"], device_id: device_id}})

          cloud_id = pairing["cloud_id"]
          info = {xmpp_account: msg.from, session_id: device_id, cloud_id: cloud_id.nil? ? '' : cloud_id}
          send_request(KPAIR_COMPLETED_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'PAIR',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Send PAIR COMPLETED SUCCESS RESPONSE message to device after pairing successful",
                                 data: {cloud_id: info["cloud_id"]}})
        else
          data = {device_id: device_id, status: KSTATUS_TIMEOUT}
          isSuccess = @rd_conn.rd_pairing_session_update(data)

          info = {xmpp_account: msg.from, error_code: 899, session_id: device_id}
          send_request(KPAIR_COMPLETED_FAILURE_RESPONSE, info)
          
          LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                {event: 'PAIR',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Send PAIR COMPLETED FAILURE RESPONSE message to device as pairing timeout, and update the status of pairing session to TIMEOUT %s" % [isSuccess ? 'success' : 'failure'],
                                 data: {error_code: 899}})
        end
      else
        info = {xmpp_account: msg.from, error_code: 898, session_id: device_id}
        send_request(KPAIR_COMPLETED_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Send PAIR COMPLETED FAILURE RESPONSE message to device as session id not find or or status wrong",
                               data: {error_code: 898}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Pair:Cancel
  message :normal?, proc {|m| m.form.submit? && 'pair' == m.form.title && 'cancel' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      status = !pairing.nil? ? pairing["status"] : nil

      if !pairing.nil? && (KSTATUS_START == status || KSTATUS_WAITING == status) then
        data = {device_id: device_id, status: KSTATUS_CANCEL}
        isUpdated = @rd_conn.rd_pairing_session_update(data)
        
        LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Update the status of pairing session to 'CANCEL' %s as receive PAIR CANCEL RESPONSE message from device" % [isUpdated ? 'success' : 'failure'],
                               data: 'N/A'})

        if isUpdated
          info = {xmpp_account: msg.from, title: 'pair', tag: device_id}
          send_request(KSESSION_CANCEL_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'PAIR',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Send PAIR CANCEL SUCCESS RESPONSE message to device as update pairing session table success",
                                 data: 'N/A'})
        else
          info = {xmpp_account: msg.from, title: 'pair', error_code: 897, tag: device_id}
          send_request(KSESSION_CANCEL_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'PAIR',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Send PAIR CANCEL FAILURE RESPONSE message to device as update pairing session table failure",
                                 data: {error_code: 897}})
        end
      else
        info = {xmpp_account: msg.from, title: 'pair', error_code: 898, tag: device_id}
        send_request(KSESSION_CANCEL_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Send PAIR CANCEL FAILURE RESPONSE message to device as pairing session id not find or status wrong",
                               data: {error_code: 898}})
      end

    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Pair:Timeout
  message :normal?, proc {|m| m.form.submit? && 'pair' == m.form.title && 'timeout' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      status = !pairing.nil? ? pairing["status"] : nil

      if !pairing.nil? && (KSTATUS_START == status || KSTATUS_WAITING == status || KSTATUS_TIMEOUT == status) then
        data = {device_id: device_id, status: KSTATUS_TIMEOUT}
        isUpdated = @rd_conn.rd_pairing_session_update(data)
        
        LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Update the status of pairing session to 'TIMEOUT' %s as receive PAIR TIMEOUT RESPONSE message from device" % [isUpdated ? 'success' : 'failure'],
                               data: 'N/A'})

        if isUpdated
          info = {xmpp_account: msg.from, title: 'pair', tag: device_id}
          send_request(KSESSION_TIMEOUT_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'PAIR',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Send PAIR TIMEOUT SUCCESS RESPONSE message to device as update pairing session table success",
                                 data: 'N/A'})
        else
          info = {xmpp_account: msg.from, title: 'pair', error_code: 897, tag: device_id}
          send_request(KSESSION_TIMEOUT_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'PAIR',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: device_id,
                                 full_domain: 'N/A',
                                 message:"Send PAIR TIMEOUT FAILURE RESPONSE message to device as update pairing session table failure",
                                 data: {error_code: 897}})
        end
      else
        info = {xmpp_account: msg.from, title: 'pair', error_code: 898, tag: device_id}
        send_request(KSESSION_TIMEOUT_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Send PAIR TIMEOUT FAILURE RESPONSE message to device as pairing session id not find or status wrong",
                               data: {error_code: 898}})
      end
    rescue
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Get_upnp_service:Cancel
  message :normal?, proc {|m| m.form.submit? && 'get_upnp_service' == m.form.title && 'cancel' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      index = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(index)
      status = !upnp.nil? ? upnp["status"] : nil

      if !upnp.nil? && KSTATUS_START == status then
        data = {index: index, status: KSTATUS_CANCEL}
        isUpdated = @rd_conn.rd_upnp_session_update(data)
        
        LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Update the status of get upnp service list session to 'CANCEL' %s as receive GET UPNP SERVICE LIST CANCEL RESPONSE message from device" % [isUpdated ? 'success' : 'failure'],
                               data: 'N/A'})

        if isUpdated
          info = {xmpp_account: msg.from, title: 'get_upnp_service', tag: index}
          send_request(KSESSION_CANCEL_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send GET UPNP SERVICE LIST CANCEL SUCCESS RESPONSE message to device as update upnp session table success",
                                 data: 'N/A'})
        else
          info = {xmpp_account: msg.from, title: 'get_upnp_service', error_code: 797, tag: index}
          send_request(KSESSION_CANCEL_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send GET UPNP SERVICE LIST CANCEL FAILURE RESPONSE message to device as update upnp session table failure",
                                 data: {error_code: 797}})
        end
      else
        info = {xmpp_account: msg.from, title: 'get_upnp_service', error_code: 798, tag: index}
        send_request(KSESSION_CANCEL_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'UPNP',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: index,
                               full_domain: 'N/A',
                               message:"Send GET UPNP SERVICE LIST CANCEL FAILURE RESPONSE message to device as upnp session id not find or status wrong",
                               data: {error_code: 798}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Get_upnp_service:Timeout
  message :normal?, proc {|m| m.form.submit? && 'get_upnp_service' == m.form.title && 'timeout' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      index = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(index)
      status = !upnp.nil? ? upnp["status"] : nil

      if !upnp.nil? && KSTATUS_START == status then
        data = {index: index, status: KSTATUS_TIMEOUT}
        isUpdated = @rd_conn.rd_upnp_session_update(data)
        
        LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Update the status of set upnp service list session to 'TIMEOUT' %s as receive GET UPNP SERVICE LIST TIMEOUT RESPONSE message from device" % [isUpdated ? 'success' : 'failure'],
                               data: 'N/A'})

        if isUpdated
          info = {xmpp_account: msg.from, title: 'get_upnp_service', tag: index}
          send_request(KSESSION_TIMEOUT_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send GET UPNP SERVICE LIST TIMEOUT SUCCESS RESPONSE message to device as update upnp session table success",
                                 data: 'N/A'})
        else
          info = {xmpp_account: msg.from, title: 'get_upnp_service', error_code: 797, tag: index}
          send_request(KSESSION_TIMEOUT_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send GET UPNP SERVICE LIST TIMEOUT FAILURE RESPONSE message to device as update upnp session table failure",
                                 data: {error_code: 797}})
        end
      else
        info = {xmpp_account: msg.from, title: 'get_upnp_service', error_code: 798, tag: index}
        send_request(KSESSION_TIMEOUT_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'UPNP',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: index,
                               full_domain: 'N/A',
                               message:"Send GET UPNP SERVICE LIST TIMEOUT FAILURE RESPONSE message to device as upnp session id not find or status wrong",
                               data: {error_code: 798}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Set_upnp_service:Cancel
  message :normal?, proc {|m| m.form.submit? && 'set_upnp_service' == m.form.title && 'cancel' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      index = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(index)
      status = !upnp.nil? ? upnp["status"] : nil

      if !upnp.nil? && KSTATUS_SUBMIT == status then
        data = {index: index, status: KSTATUS_CANCEL}
        isUpdated = @rd_conn.rd_upnp_session_update(data)
        
        LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Update the status of set upnp service list session to 'CANCEL' %s as receive SET UPNP SERVICE LIST CANCEL RESPONSE message from device" % [isUpdated ? 'success' : 'failure'],
                               data: 'N/A'})
        if isUpdated
          info = {xmpp_account: msg.from, title: 'set_upnp_service', tag: index}
          send_request(KSESSION_CANCEL_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send SET UPNP SERVICE LIST CANCEL SUCCESS RESPONSE message to device as update upnp session table success",
                                 data: 'N/A'})
        else
          info = {xmpp_account: msg.from, title: 'set_upnp_service', error_code: 797, tag: index}
          send_request(KSESSION_CANCEL_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send SET UPNP SERVICE LIST CANCEL FAILURE RESPONSE message to device as update upnp session table failure",
                                 data: {error_code: 797}})
        end
      else
        info = {xmpp_account: msg.from, title: 'set_upnp_service', error_code: 798, tag: index}
        send_request(KSESSION_CANCEL_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'UPNP',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: index,
                               full_domain: 'N/A',
                               message:"Send SET UPNP SERVICE LIST CANCEL FAILURE RESPONSE message to device as upnp session id not find or status wrong",
                               data: {error_code: 798}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Set_upnp_service:Timeout
  message :normal?, proc {|m| m.form.submit? && 'set_upnp_service' == m.form.title && 'timeout' == m.form.field('action').value} do |msg|
    begin
      submit_syslog(msg)

      index = msg.thread
      upnp = @rd_conn.rd_upnp_session_access(index)
      status = !upnp.nil? ? upnp["status"] : nil

      if !upnp.nil? && KSTATUS_SUBMIT == status then
        data = {index: index, status: KSTATUS_TIMEOUT}
        isUpdated = @rd_conn.rd_upnp_session_update(data)
        
        LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Update the status of get upnp service list session to 'TIMEOUT' %s as receive SET UPNP SERVICE LIST TIMEOUT RESPONSE message from device" % [isUpdated ? 'success' : 'failure'],
                               data: 'N/A'})

        if isUpdated
          info = {xmpp_account: msg.from, title: 'set_upnp_service', tag: index}
          send_request(KSESSION_TIMEOUT_SUCCESS_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWINFO,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send SET UPNP SERVICE LIST TIMEOUT SUCCESS RESPONSE message to device as update upnp session table success",
                                 data: 'N/A'})
        else
          info = {xmpp_account: msg.from, title: 'set_upnp_service', error_code: 797, tag: index}
          send_request(KSESSION_TIMEOUT_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'UPNP',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: index,
                                 full_domain: 'N/A',
                                 message:"Send SET UPNP SERVICE LIST TIMEOUT FAILURE RESPONSE message to device as update upnp session table failure",
                                 data: {error_code: 797}})
        end
      else
        info = {xmpp_account: msg.from, title: 'set_upnp_service', error_code: 798, tag: index}
        send_request(KSESSION_TIMEOUT_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'UPNP',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: index,
                               full_domain: 'N/A',
                               message:"Send SET UPNP SERVICE LIST TIMEOUT FAILURE RESPONSE message to device as upnp session id not find or status wrong",
                               data: {error_code: 798}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Submit:Config_ddns
  message :normal?, proc {|m| m.form.submit? && 'config_ddns' == m.form.title} do |msg|
    begin
      submit_syslog(msg)

      session_id = msg.thread
      host_name = nil
      domain_name = nil
      msg.form.fields.each do |field|
        host_name = field.value.downcase if 'hostname_prefix' == field.var
        domain_name = field.value.downcase if 'hostname_suffix' == field.var
      end

      domain_name += '.' if '.' != domain_name[-1, 1]

      host_name_regex = /^[a-zA-Z][a-zA-Z0-9\-]*$/
      isValidHostName =  host_name.length.between?(3, 63) &&
                        !host_name_regex.match(host_name).nil? &&
                        !@route_conn.reserved_hostname.include?(host_name)

      isValidZoneName = !domain_name.empty? &&
                        !@route_conn.zones_list.include?(domain_name)

      if isValidHostName && isValidZoneName then
        device_ip = nil
        device_id = nil
        old_device_id = nil
        xmpp_account = msg.from.node
        device_id = @rd_conn.rd_xmpp_session_access(xmpp_account).to_i
        device = @rd_conn.rd_device_session_access(device_id)
        device_ip = device["ip"] if !device.nil?

        ddns_record = @db_conn.db_ddns_access({full_domain: host_name + '.' + domain_name})
        old_device_id = ddns_record.device_id if !ddns_record.nil?

        if !device_id.nil? && old_device_id.nil? && !device_ip.nil? then
          data = {host_name: host_name,
                  domain_name: domain_name,
                  device_ip: device_ip,
                  device_id: device_id,
                  session_id: msg.thread,
                  msg_from: msg.from.to_s,
                  xmpp_account: msg.from.node
                 }
          # Use container for provied variable over write
          container(data){
            |x|

            EM.defer {
              session_id = x[:session_id]
              ddns_record = @db_conn.db_ddns_access({device_id: x[:device_id]})

              index = @rd_conn.rd_ddns_session_index_get
              device = @rd_conn.rd_device_session_access(x[:device_id])
              ip = device["ip"]
              session_data = {index: index, device_id: x[:device_id], host_name: x[:host_name], domain_name: x[:domain_name], status: KSTATUS_START}
              @rd_conn.rd_ddns_session_insert(session_data)
              batch_data = {index: index, device_id: x[:device_id], full_domain: "%s.%s" % [x[:host_name], x[:domain_name]], ip: ip, action: 'update'}
              @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), index)

              if !ddns_record.nil? then
                old_full_domain = ddns_record.full_domain

                data = {id: ddns_record.id, full_domain: x[:host_name] + '.' + x[:domain_name], ip_address: x[:device_ip]}
                isUpdated =  @db_conn.db_ddns_update(data)
                
                LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                      {event: 'DDNS',
                                       direction: 'N/A',
                                       to: 'N/A',
                                       from: 'N/A',
                                       id: ddns_record.id,
                                       full_domain: x[:host_name] + '.' + x[:domain_name],
                                       message:"Update DDNS table %s as received DDNS SETTING REQUEST message from device" % [isUpdated ? 'success' : 'failure'],
                                       data: {ip: x[:device_ip]}})

                if old_full_domain != x[:host_name] + '.' + x[:domain_name] then
                  del_index = @rd_conn.rd_ddns_session_index_get
                  ip = ddns_record.ip_address

                  batch_data = {index: del_index, device_id: x[:device_id], full_domain: old_full_domain, ip: ip, action: 'delete'}
                  isDeleted = @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), del_index)

                  
                  LOGGER.post(isDeleted ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWERROR,
                                        {event: 'DDNS',
                                         direction: 'N/A',
                                         to: 'N/A',
                                         from: 'N/A',
                                         id: 'N/A',
                                         full_domain: old_full_domain,
                                         message:"Delete previous record from DDNS table %s as received DDNS SETTING REQUEST message from device" % [isDeleted ? 'success' : 'failure'],
                                         data: 'N/A'})
                end
              end

              isSuccess = FALSE
              i = 0
              while !isSuccess && i < 100
                result = @rd_conn.rd_ddns_session_access(index)
                isSuccess = KSTATUS_SUCCESS == result["status"] ? TRUE : FALSE
                i+=1
                sleep(0.1)
              end

              
              LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                    {event: 'DDNS',
                                     direction: 'N/A',
                                     to: 'N/A',
                                     from: 'N/A',
                                     id: 'N/A',
                                     full_domain: x[:host_name] + '.' + x[:domain_name],
                                     message:"Create Route53 DDNS record %s as received DDNS SETTING REQUEST message from device" % [isSuccess ? 'success' : 'failure'],
                                     data: {ip: x[:device_ip]}})

              if isSuccess then
                record = {device_id: x[:device_id], ip_address: x[:device_ip], full_domain: x[:host_name] + '.' + x[:domain_name]}
                @db_conn.db_ddns_insert(record) if ddns_record.nil?

                info = {xmpp_account: x[:msg_from], session_id: session_id}
                send_request(KDDNS_SETTING_SUCCESS_RESPONSE, info)
                
                LOGGER.post(FLUENT_BOT_FLOWINFO,
                                      {event: 'DDNS',
                                       direction: 'Bot->Device',
                                       to: x[:msg_from],
                                       from: @bot_xmpp_account,
                                       id: 'N/A',
                                       full_domain: x[:host_name] + '.' + x[:domain_name],
                                       message:"Send DDNS SETTING SUCCESS RESPONSE message to device as create Route53 DDNS record success",
                                       data: {ip: x[:device_ip], device_id: x[:device_id]}})
              else
                info = info = {xmpp_account: x[:msg_from], error_code: 997, session_id: session_id}
                send_request(KDDNS_SETTING_FAILURE_RESPONSE, info)
                
                LOGGER.post(FLUENT_BOT_FLOWERROR,
                                      {event: 'DDNS',
                                       direction: 'Bot->Device',
                                       to: x[:msg_from],
                                       from: @bot_xmpp_account,
                                       id: 'N/A',
                                       full_domain: x[:host_name] + '.' + x[:domain_name],
                                       message:"Send DDNS SETTING FAILURE RESPONSE message to device as create Route53 DDNS record failure",
                                       data: {error_code: 997}})
              end
            }
          }

        elsif !device_id.nil? && !old_device_id.nil? && !device_ip.nil? then
          if device_id == old_device_id then
            data = {host_name: host_name,
                    domain_name: domain_name,
                    device_ip: device_ip,
                    device_id: device_id,
                    session_id: msg.thread,
                    msg_from: msg.from.to_s,
                    xmpp_account: msg.from.node
                  }
            container(data){
              |x|
              EM.defer {
                session_id = x[:session_id]
                ddns_record = @db_conn.db_ddns_access({device_id: x[:device_id]})

                index = @rd_conn.rd_ddns_session_index_get
                device = @rd_conn.rd_device_session_access(x[:device_id])
                ip = device["ip"]
                session_data = {index: index, device_id: x[:device_id], host_name: x[:host_name], domain_name: x[:domain_name], status: KSTATUS_START}
                @rd_conn.rd_ddns_session_insert(session_data)
                batch_data = {index: index, device_id: x[:device_id], full_domain: "%s.%s" % [x[:host_name], x[:domain_name]], ip: ip, action: 'update'}
                @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), index)

                if !ddns_record.nil? then
                  old_full_domain = ddns_record.full_domain.to_s
                  host_name = find_hostname(old_full_domain)
                  domain_name = find_domainname(old_full_domain)

                  data = {id: ddns_record.id, full_domain: x[:host_name] + '.' + x[:domain_name], ip_address: x[:device_ip]}
                  isUpdated =  @db_conn.db_ddns_update(data)
                  
                  LOGGER.post(isUpdated ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                        {event: 'DDNS',
                                         direction: 'N/A',
                                         to: 'N/A',
                                         from: 'N/A',
                                         id: ddns_record.id,
                                         full_domain: x[:host_name] + '.' + x[:domain_name],
                                         message:"Update DDNS table %s as received DDNS SETTING REQUEST message from device" % [isUpdated ? 'success' : 'failure'],
                                         data: {ip: x[:device_ip]}})

                  if old_full_domain != x[:host_name] + '.' + x[:domain_name]then
                    del_index = @rd_conn.rd_ddns_session_index_get
                    ip = ddns_record.ip_address

                    batch_data = {index: del_index, device_id: x[:device_id], full_domain: old_full_domain, ip: ip, action: 'delete'}
                    isDeleted = @rd_conn.rd_ddns_batch_session_insert(JSON.generate(batch_data), del_index)
                    
                    LOGGER.post(isDeleted ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWERROR,
                                          {event: 'DDNS',
                                           direction: 'N/A',
                                           to: 'N/A',
                                           from: 'N/A',
                                           id: 'N/A',
                                           full_domain: old_full_domain,
                                           message:"Delete previous record from DDNS table %s as received DDNS SETTING REQUEST message from device" % [isDeleted ? 'success' : 'failure'],
                                           data: 'N/A'})
                  end
                end

                isSuccess = FALSE
                i = 0
                while !isSuccess && i < 100
                  result = @rd_conn.rd_ddns_session_access(index)
                  isSuccess = KSTATUS_SUCCESS == result["status"] ? TRUE : FALSE
                  i+=1
                  sleep(0.1)
                end

                
                LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                                      {event: 'DDNS',
                                       direction: 'N/A',
                                       to: 'N/A',
                                       from: 'N/A',
                                       id: 'N/A',
                                       full_domain: x[:host_name] + '.' + x[:domain_name],
                                       message:"Create Route53 DDNS record %s as received DDNS SETTING REQUEST message from device" % [isSuccess ? 'success' : 'failure'],
                                       data: {ip: x[:device_ip]}})

                if isSuccess then
                  info = info = {xmpp_account: x[:msg_from], session_id: session_id}
                  send_request(KDDNS_SETTING_SUCCESS_RESPONSE, info)
                  
                  LOGGER.post(FLUENT_BOT_FLOWINFO,
                                        {event: 'DDNS',
                                         direction: 'Bot->Device',
                                         to: x[:msg_from],
                                         from: @bot_xmpp_account,
                                         id: 'N/A',
                                         full_domain: x[:host_name] + '.' + x[:domain_name],
                                         message:"Send DDNS SETTING SUCCESS RESPONSE message to device as create Route53 DDNS record success",
                                         data: {ip: x[:device_ip], device_id: x[:device_id]}})
                else
                  info = info = {xmpp_account: x[:msg_from], error_code: 997, session_id: session_id}
                  send_request(KDDNS_SETTING_FAILURE_RESPONSE, info)
                  
                  LOGGER.post(FLUENT_BOT_FLOWERROR,
                                        {event: 'DDNS',
                                         direction: 'Bot->Device',
                                         to: x[:msg_from],
                                         from: @bot_xmpp_account,
                                         id: 'N/A',
                                         full_domain: x[:host_name] + '.' + x[:domain_name],
                                         message:"Send DDNS SETTING FAILURE RESPONSE message to device as create Route53 DDNS record failure",
                                         data: {error_code: 997}})
                end
              }
            }
          else
            info = info = {xmpp_account: msg.from, error_code: 995, session_id: msg.thread}
            send_request(KDDNS_SETTING_FAILURE_RESPONSE, info)
            
            LOGGER.post(FLUENT_BOT_FLOWERROR,
                                  {event: 'DDNS',
                                   direction: 'Bot->Device',
                                   to: msg.from.to_s,
                                   from: @bot_xmpp_account,
                                   id: 'N/A',
                                   full_domain: host_name + '.' + domain_name,
                                   message:"Send DDNS SETTING FAILURE RESPONSE message to device as DNS has been used to other device",
                                   data: {error_code: 995}})
          end
        else
          info = info = {xmpp_account: msg.from, error_code: 998, session_id: msg.thread}
          send_request(KDDNS_SETTING_FAILURE_RESPONSE, info)
          
          LOGGER.post(FLUENT_BOT_FLOWERROR,
                                {event: 'DDNS',
                                 direction: 'Bot->Device',
                                 to: msg.from.to_s,
                                 from: @bot_xmpp_account,
                                 id: 'N/A',
                                 full_domain: host_name + '.' + domain_name,
                                 message:"Send DDNS SETTING FAILURE RESPONSE message to device as device ip not find",
                                 data: {ip: device_ip, error_code: 998}})
        end
      else
        info = info = {xmpp_account: msg.from, error_code: 999, session_id: msg.thread}
        send_request(KDDNS_SETTING_FAILURE_RESPONSE, info)
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'DDNS',
                               direction: 'Bot->Device',
                               to: msg.from.to_s,
                               from: @bot_xmpp_account,
                               id: 'N/A',
                               full_domain: host_name + '.' + domain_name,
                               message:"Send DDNS SETTING FAILURE RESPONSE message to device as DNS format invalid",
                               data: {error_code: 999}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Pair:Start
  message :normal?, proc {|m| m.form.cancel? && 'pair' == m.form.title && 'start' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      status = !pairing.nil? ? pairing["status"] : nil
      if KSTATUS_START == status then
        data = {device_id: device_id, status: KSTATUS_FAILURE}
        error_code = msg.form.field('ERROR_CODE').value
        isSuccess = @rd_conn.rd_pairing_session_update(data)
        
        LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Update the status of pairing session to FAILURE %s as receive PAIR START FAILURE RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Pair:Timeout
  message :normal?, proc {|m| m.form.cancel? && 'pair' == m.form.title && 'timeout' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      error_code = msg.form.field('ERROR_CODE').value
      if !pairing.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Receive PAIR TIMEOUT FAILURE RESPONSE message from device success",
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Pair:Completed
  message :normal?, proc {|m| m.form.cancel? && 'pair' == m.form.title && 'completed' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      device_id = msg.thread
      data = {device_id: device_id, status: KSTATUS_FAILURE}
      error_code = msg.form.field('ERROR_CODE').value
      isSuccess = @rd_conn.rd_pairing_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                            {event: 'PAIR',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: device_id,
                             full_domain: 'N/A',
                             message:"Update the status of pairing session to FAILURE %s as receive START COMPLETED FAILURE RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                             data: {error_code: error_code}})
    rescue Exception => error
     
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Pair:Cancel
  message :normal?, proc {|m| m.form.cancel? && 'pair' == m.form.title && 'cancel' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      device_id = msg.thread
      pairing = @rd_conn.rd_pairing_session_access(device_id)
      if !pairing.nil? then
        error_code = msg.form.field('ERROR_CODE').value
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: device_id,
                               full_domain: 'N/A',
                               message:"Receive START COMPLETED FAILURE RESPONSE message from device success",
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Unpair
  message :normal?, proc {|m| m.form.cancel? && 'unpair' == m.form.title} do |msg|
    begin
      cancel_syslog(msg)

      device_id = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      isSuccess = FALSE
      unpair_session = @rd_conn.rd_unpair_session_access(device_id)
      if !unpair_session.nil? then
        isSuccess = @rd_conn.rd_unpair_session_delete(device_id)
      else
        isSuccess = TRUE
      end

      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                            {event: 'UNPAIR',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: device_id,
                             full_domain: 'N/A',
                             message:"Delete the record of unpair session %s as receive UNPAIR FAILURE RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                             data: {error_code: error_code}})

    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Get_upnp_service:nil
  message :normal?, proc {|m| m.form.cancel? && 'get_upnp_service' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      cancel_syslog(msg)

      session_id = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      data = {index: session_id, status: KSTATUS_FAILURE, error_code: error_code}
      isSuccess = @rd_conn.rd_upnp_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                            {event: 'UPNP',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status of upnp session to FAILURE %s as receive UPNP GET SETTING FAILURE RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                             data: {error_code: error_code}})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Get_upnp_service:!nil:Timeout
  message :normal?, proc {|m| m.form.cancel? && 'get_upnp_service' == m.form.title && nil != m.form.field('action') && 'timeout' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      index = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      upnp = @rd_conn.rd_upnp_session_access(index)
      if !upnp.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWERROR, {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Receive UPNP GET SETTING TIMEOUT FAILURE RESPONSE message from device success",
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Get_upnp_service:!nil:Cancel
  message :normal?, proc {|m| m.form.cancel? && 'get_upnp_service' == m.form.title && nil != m.form.field('action') && 'cancel' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      index = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      upnp = @rd_conn.rd_upnp_session_access(index)
      if !upnp.nil? then
        error_code = msg.form.field('ERROR_CODE').value
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Receive GET UPNP SERVICE LIST CANCEL FAILURE RESPONSE message from device success",
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Set_upnp_service:!nil:Cancel
  message :normal?, proc {|m| m.form.cancel? && 'set_upnp_service' == m.form.title && nil != m.form.field('action') && 'cancel' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      index = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      upnp = @rd_conn.rd_upnp_session_access(index)
      if !upnp.nil? then
        error_code = msg.form.field('ERROR_CODE').value
        
        LOGGER.post(FLUENT_BOT_FLOWERROR,
                              {event: 'PAIR',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Receive SET UPNP SERVICE LIST CANCEL FAILURE RESPONSE message from device success",
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Set_upnp_service:nil
  message :normal?, proc {|m| m.form.cancel? && 'set_upnp_service' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      cancel_syslog(msg)

      hasX = FALSE
      hasITEM = FALSE
      session_id = msg.thread
      error_code_record = Array.new

      upnp_session = @rd_conn.rd_upnp_session_access(session_id)
      if !upnp_session.nil? then
        service_list = JSON.parse(upnp_session["service_list"].to_s)

        MultiXml.parser = :rexml
        xml = MultiXml.parse(msg.form.to_s)
        hasX = xml.has_key?("x")
        hasITEM = xml["x"].has_key?("item") if hasX

        if !xml.nil? && hasX && hasITEM then

          if !xml["x"]["item"].instance_of?(Array) then
            items = Array.new
            items << xml["x"]["item"]
            xml["x"]["item"] = items
          end

          xml["x"]["item"].each do |item|
            servicename = nil
            error_code = nil

            item["field"].each do |field|
              var = field["var"]
              case var
                when 'servicename'
                  servicename = field["value"]
                when 'ERROR_CODE'
                  error_code = field["value"]
              end
            end

            service_list.each do |service|
              if service["service_name"] == servicename then
                service["error_code"] = error_code
              end
            end

            error_code_record << {service_name: servicename, error_code: error_code}
          end
        end

        service_list_json = JSON.generate(service_list)

        data = {index: session_id, status: KSTATUS_FORM, service_list: service_list_json}
        isSuccess = @rd_conn.rd_upnp_session_update(data)
        
        LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                              {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: session_id,
                               full_domain: 'N/A',
                               message:"Update the status of upnp session to FAILURE %s as receive UPNP SET SETTING FAILURE RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                               data: {error_code: JSON.generate(error_code_record)}})
      else
        
        LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                            {event: 'UPNP',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status of upnp session failure, session id not find",
                             data: {error_code: 798}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Set_upnp_service:!nil:Timeout
  message :normal?, proc {|m| m.form.cancel? && 'set_upnp_service' == m.form.title && nil != m.form.field('action') && 'timeout' == m.form.field('action').value} do |msg|
    begin
      cancel_syslog(msg)

      index = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      upnp = @rd_conn.rd_upnp_session_access(index)
      if !upnp.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWERROR, {event: 'UPNP',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Receive UPNP SET SETTING TIMEOUT FAILURE RESPONSE message from device success",
                               data: {error_code: error_code}})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:Config_ddns
  message :normal?, proc {|m| m.form.cancel? && 'config_ddns' == m.form.title} do |msg|
    begin
      cancel_syslog(msg)

      index = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      @rd_conn.rd_ddns_resend_session_delete(index)
      
      LOGGER.post(FLUENT_BOT_FLOWERROR,
                            {event: 'DDNS',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: index,
                             full_domain: 'N/A',
                             message:"Receive DDNS SETTING FAILURE RESPONSE message from device success",
                             data: {error_code: error_code}})
    rescue Exception => error
     
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Cancel:bot_led_indicator
  message :normal?, proc {|m| m.form.cancel? && 'bot_led_indicator' == m.form.title} do |msg|
    begin
      cancel_syslog(msg)

      session_id = msg.thread
      error_code = msg.form.field('ERROR_CODE').value

      
      LOGGER.post(FLUENT_BOT_FLOWERROR,
                            {event: 'LED_INDICATOR_RESPONSE',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Receive LED INDICATOR FAILURE RESPONSE message from device",
                             data: {error_code: error_code } })
      rescue Exception => error
        
        LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
      end
  end

# HANDLER: Cancel:permission
  message :normal?, proc {|m| m.form.cancel? && 'bot_set_share_permission' == m.form.title} do |msg|
    begin
      cancel_syslog(msg)

      session_id = msg.thread
      error_code = msg.form.field('ERROR_CODE').value || nil

      data       = {index: session_id, status: KSTATUS_FAILURE, error_code: error_code}
      @rd_conn.rd_permission_session_update(data)

      
      LOGGER.post(FLUENT_BOT_FLOWERROR,
                            {event: 'PERMISSION',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Receive PERMISSION FAILURE RESPONSE message from device",
                             data: {error_code: error_code } })
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Form:Get_upnp_service
  message :normal?, proc {|m| m.form.form? && 'get_upnp_service' == m.form.title} do |msg|
    begin
      form_syslog(msg)

      hasX = nil
      hasITEM = nil
      session_id = msg.thread
      service_list = Array.new

      MultiXml.parser = :rexml
      xml = MultiXml.parse(msg.form.to_s)
      hasX = xml.has_key?("x")
      hasITEM = xml["x"].has_key?("item") if hasX
      lan_ip = xml["x"]["field"]["value"] if xml["x"].has_key?("field") && 'lanip' == xml["x"]["field"]["var"]
      used_wan_port_list = Array.new

      if !xml.nil? && hasX && hasITEM then

        # Service item
        if !xml["x"]["item"].instance_of?(Array) then
          items = Array.new
          items << xml["x"]["item"]
          xml["x"]["item"] = items
        end

        # Handle item value
        xml["x"]["item"].each do |item|
          service_name = ''
          status = false
          enabled = false
          description = ''
          path = ''
          lan_port = ''
          wan_port = ''

          if !item['field'].instance_of?(Hash)
            item["field"].each do |field|
              var = field["var"]
              case var
                when 'service-name'
                  service_name = field["value"].nil? ? '' : field["value"]
                when 'status'
                  status = field["value"] == 'true' ? true : false
                when 'enabled'
                  enabled = field["value"] == 'true' ? true : false
                when 'description'
                  description = field["value"]
                when 'path'
                  path = field["value"].nil? ? '' : field["value"]
                when 'lan-port'
                  lan_port = field["value"].nil? ? '' : field["value"]
                when 'wan-port'
                  wan_port = field["value"].nil? ? '' : field["value"]
              end
            end

            service = {:service_name => service_name,
                       :status => status,
                       :enabled => enabled,
                       :description => description,
                       :path => path,
                       :lan_port => lan_port,
                       :wan_port => wan_port,
                       :error_code => ''
                      }
            service_list << service
          elsif item['field']['var'] == 'used-wan-port'
            used_wan_port =  item['field']['value']
            used_wan_port_list << used_wan_port
          end
        end

        service_list_json = JSON.generate(service_list)
        used_wan_port_list_json = !used_wan_port_list.empty? ? JSON.generate(used_wan_port_list) : ''
      else
        service_list_json = ''
      end

      data = {index: session_id, status: KSTATUS_FORM, service_list: service_list_json, used_wan_port_list: used_wan_port_list_json, lan_ip: lan_ip}
      isSuccess = @rd_conn.rd_upnp_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'UPNP',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status & service list of ddns session %s as receive DDNS SETTING RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                             data: {service_list: service_list_json}})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

# HANDLER: Result:bot_led_indicator
  message :normal?, proc {|m| m.form.form? && 'bot_led_indicator' == m.form.title } do |msg|
    begin
      result_syslog(msg)
      session_id = msg.thread
      
      LOGGER.post(FLUENT_BOT_FLOWERROR,
                            {event: 'LED_INDICATOR_RESPONSE',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Receive LED INDICATOR SUCCESS message from device",
                             data: 'N/A' })
      rescue Exception => error
        
        LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
      end
  end

 # HANDLER: Result:bot_get_package_list
  message :normal?, proc {|m| m.form.result? && 'bot_get_package_list' == m.form.title } do |msg|
    begin
      form_syslog(msg)
      hasX = nil
      hasITEM = nil
      session_id = msg.thread
      package_list = Array.new
      package_list_json = ''
      MultiXml.parser = :rexml
      xml = MultiXml.parse(msg.form.to_s)
      hasX = xml.has_key?("x")
      hasITEM = xml["x"].has_key?("item") if hasX

      if !xml.nil? && hasX && hasITEM then

        # Package item
        if !xml["x"]["item"].instance_of?(Array) then
          items = Array.new
          items << xml["x"]["item"]
          xml["x"]["item"] = items
        end

        # Handle item value
        xml["x"]["item"].each do |item|
          packagename = ''
          status = false
          enabled = false
          description = Array.new
          package_version = ''
          package = Hash.new

          requires = Array.new

          if !item['field'].instance_of?(Hash)
            item["field"].each do |field|
              var = field["var"]
              case var
                when 'package-name'
                  packagename = field["value"].nil? ? '' : field["value"]
                when 'version'
                  package_version = field["value"].nil? ? '' : field["value"]
                when 'status'
                  status = field["value"] == 'true' ? true : false
                when 'enabled'
                  enabled = field["value"] == 'true' ? true : false
                when 'description'
                  if field["value"].instance_of?(Array)
                    field["value"].each do |description_item|
                      description << description_item
                    end
                  else
                    description << field["value"]
                  end
                when 'requires'
                  if field["value"].instance_of?(Array)
                    field["value"].each do |required_item|
                      requires << required_item
                    end
                  else
                    requires << field["value"]
                  end
              end
            end
            continue if packagename == ''
            package = {:package_name => packagename,
                       :status => status,
                       :enabled => enabled,
                       :description => description,
                       :requires => requires,
                       :version => package_version,
                       :error_code => ''
                      }

            package_list << package
        end
        package_list_json = JSON.generate( package_list )
      end
      else

      end

      data = {index: session_id, status: KSTATUS_FORM, package_list: package_list_json}
      isSuccess = @rd_conn.rd_package_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'PACKAGE',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status & service list of package session %s as receive package SETTING RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                             data: {package_list: package_list_json}})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

  # HANDLER: Cancel:Get_package_service:nil
  message :normal?, proc {|m| m.form.cancel? && 'bot_get_package_list' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      cancel_syslog(msg)

      session_id = msg.thread
      error_code = msg.form.field('ERROR_CODE').value
      data = {index: session_id, status: KSTATUS_FAILURE, error_code: error_code}
      isSuccess = @rd_conn.rd_package_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWERROR : FLUENT_BOT_FLOWALERT,
                            {event: 'PACKAGE',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status of PACKAGE session to FAILURE %s as receive PACKAGE GET LIST FAILURE RESPONSE message from device" % [isSuccess ? 'success' : 'failure'],
                             data: {error_code: error_code}})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end


# HANDLER: Result:bot_set_package_list:!nil:Timeout
  message :normal?, proc {|m| m.form.result? && 'bot_set_package_list' == m.form.title && nil != m.form.field('action') && 'timeout' == m.form.field('action').value} do |msg|
    begin
      result_syslog(msg)

      index = msg.thread
      upnp = @rd_conn.rd_package_session_access(index)
      if !package.nil? then
        
        LOGGER.post(FLUENT_BOT_FLOWINFO,
                              {event: 'PACKAGE',
                               direction: 'Device->Bot',
                               to: @bot_xmpp_account,
                               from: msg.from.to_s,
                               id: index,
                               full_domain: 'N/A',
                               message:"Receive PACKAGE SETTING TIMEOUT SUCCESS RESPONSE message from device success",
                               data: 'N/A'})
      end
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end


# HANDLER: Result:bot_set_package_list:nil
  message :normal?, proc {|m| m.form.result? && 'bot_set_package_list' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      result_syslog(msg)
      session_id = msg.thread
      data = {index: session_id, status: KSTATUS_UPDATED}
      #info = {xmpp_account: msg.from.to_s,session_id: session_id}

      #send_request(KPACKAGE_ASK_REQUEST, info)
      isSuccess = @rd_conn.rd_package_session_update(data)
      
      LOGGER.post(isSuccess ? FLUENT_BOT_FLOWINFO : FLUENT_BOT_FLOWALERT,
                            {event: 'PACKAGE',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Update the status of package session table to UPDATED %s as receive PACKAGE SETTING SUCCESS RESPONSE message from device" % [isSuccess ? 'success' : 'failure'] ,
                             data: 'N/A'})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

  # HANDLER: Result:bot_set_package_list:Cancel
  message :normal?, proc {|m| m.form.cancel? && 'bot_set_package_list' == m.form.title && nil == m.form.field('action')} do |msg|
    begin
      result_syslog(msg)
      item_list = Hash.new
      ## Define item list
      MultiXml.parser = :rexml
      xml = MultiXml.parse(msg.form.to_s)
      xml["x"]["item"].each do |item|
        package_name = ''
        error_code = ''
        item_field =  ( item.class.to_s == 'Hash' ? item['field'] : item[1] )
        item_field.each do |field|
          package_name = field["value"]  if field["var"] == 'package-name'
          error_code = field["value"]  if field["var"] == 'ERROR_CODE'
        end
        item_list[package_name] = error_code
      end
      session_id = msg.thread
      package = @rd_conn.rd_package_session_access(session_id)
      package_list_json = package["package_list"].to_s if !package.nil?
      if valid_json? package_list_json then
        package_list = JSON.parse(package_list_json)
        package_list.each do |item|
          item_list.each do |failure_item_name , error_code|
            item['error_code']= error_code if item['package_name'] == failure_item_name
          end
        end
      end
      data = {index: session_id, status: KSTATUS_FORM, package_list: JSON.generate(package_list) }
      isSuccess = @rd_conn.rd_package_session_update(data)
      
      LOGGER.post(FLUENT_BOT_FLOWINFO,
                            {event: 'PACKAGE',
                             direction: 'Device->Bot',
                             to: @bot_xmpp_account,
                             from: msg.from.to_s,
                             id: session_id,
                             full_domain: 'N/A',
                             message:"Receive SET PACKAGE LIST FAILURE RESPONSE message from device ",
                             data: data})
    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end

  #HANDLER: bot_health_check_send
  message :normal?, proc {|m| m.form.form? && 'bot_health_check_send' == m.form.title } do |msg|
    begin
      # puts msg

      MultiXml.parser = :rexml
      xml = MultiXml.parse(msg.to_s)
      bot_xmpp_account = xml['message']['to']
      # puts bot_xmpp_account
      # bot_health_check_account = xml['message']['from'].split('/')[0]
      bot_health_check_account = xml['message']['from']
      # puts bot_health_check_account
      health_check_send_time = xml["message"]["x"]["item"]["field"][0]["value"]
      bot_receive_time = Time.now.to_i
      bot_send_time = xml["message"]["x"]["item"]["field"][2]["value"]
      health_check_receive_time = xml["message"]["x"]["item"]["field"][3]["value"]
      thread = xml['message']['thread']
      # response_msg_success = HEALTH_CHECK_SUCCESS_RESPONSE % [bot_health_check_account, bot_xmpp_account, session_id]
      # write_to_stream response_msg_success

      # puts "write back \n #{response_msg_success}"
      
      LOGGER.post(FLUENT_BOT_FLOWINFO,
                            {event: 'HEALTH_CHECK',
                             direction: 'Health_Check->Bot',
                             to: bot_xmpp_account,
                             from: bot_health_check_account,
                             health_check_send_time: health_check_send_time,
                             bot_receive_time: bot_receive_time,
                             bot_send_time: bot_send_time,
                             health_check_receive_time: health_check_receive_time,
                             id: thread,
                             full_domain: 'N/A',
                             message:"Receive HEALTH_CHECK_SEND_RESPONSE message from %s" % bot_health_check_account,
                             data: 'N/A'
                             })
      info = {
        bot_health_check_account: bot_health_check_account,
        bot_xmpp_account: bot_xmpp_account,
        health_check_send_time: health_check_send_time,
        bot_receive_time: bot_receive_time,
        bot_send_time: bot_send_time,
        health_check_receive_time: health_check_receive_time,
        thread: thread
      }
      # puts "handler #{info}"
      send_request(KHEALTH_CHECK_SUCCESS_RESPONSE, info)
      # puts "\n send request \n"

    rescue Exception => error
      
      LOGGER.post(FLUENT_BOT_SYSALERT, {message:error.message, inspect: error.inspect, backtrace: error.backtrace})
    end
  end


end
