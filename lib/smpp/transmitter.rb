# encoding: UTF-8
# The SMPP Transmitter maintains a unidirectional connection to an SMSC.
# Provide a config hash with connection options to get started.
# See the sample_gateway.rb for examples of config values.
# The transmitter accepts a delegate object that may implement
# the following (all optional) methods:
#
#   message_accepted(transmitter, mt_message_id, pdu)
#   message_rejected(transmitter, mt_message_id, pdu)
#   bound(transmitter)
#   unbound(transmitter)

class Smpp::Transmitter < Smpp::Base

  attr_reader :ack_ids

  # Send an MT SMS message. Delegate will receive message_accepted callback when SMSC
  # acknowledges, or the message_rejected callback upon error
  def send_mt(message_id, source_addr, destination_addr, short_message, options = {})
    logger.debug "Sending MT: #{short_message}"
    if @state == :bound_tx
      pdu = Pdu::SubmitSm.new(source_addr, destination_addr, short_message, options)
      write_pdu(pdu)

      # keep the message ID so we can associate the SMSC message ID with our message
      # when the response arrives.
      @ack_ids[pdu.sequence_number] = message_id
    else
      raise InvalidStateException, "Transmitter is unbound. Cannot send MT messages."
    end
  end

  # Send a concatenated message with a body of > 160 characters as multiple messages.
  def send_concat_mt(message_id, source_addr, destination_addr, message, options = {})
    logger.debug "Sending concatenated MT: #{message}"
    if @state == :bound_tx
      # Split the message into parts of 153 characters. (160 - 7 characters for UDH)
      parts = []
      while message.size > 0 do
        parts << message.slice!(0...Smpp::Transmitter.get_message_part_size(options))
      end
      0.upto(parts.size - 1) do |i|
        logger.debug "Message size: #{parts[i].size}"
        udh = sprintf("%c", 5) # UDH is 5 bytes.
        udh << sprintf("%c%c", 0, 3) # This is a concatenated message
        udh << sprintf("%c", message_id.to_s.last(2).to_i) # The ID for the entire concatenated message
        udh << sprintf("%c", parts.size) # How many parts this message consists of

        udh << sprintf("%c", i + 1) # This is part i+1

        options[:esm_class] = 64 # This message contains a UDH header.
        options[:udh] = udh

        pdu = Smpp::Pdu::SubmitSm.new(source_addr, destination_addr, parts[i], options)
        write_pdu(pdu)

        # This is definately a bit hacky - multiple PDUs are being associated with a single
        # message_id.
        @ack_ids[pdu.sequence_number] = message_id
      end
    else
      raise InvalidStateException, "Transmitter is unbound. Cannot send MT messages."
    end
  end

  def send_bind
    raise IOError, 'Transmitter already bound.' unless unbound?
    pdu = Pdu::BindTransmitter.new(
      @config[:system_id],
      @config[:password],
      @config[:system_type],
      @config[:source_ton],
      @config[:source_npi],
      @config[:source_address_range])
    write_pdu(pdu)
  end

  # Use data_coding to find out what message part size we can use
  # http://en.wikipedia.org/wiki/SMS#Message_size
  def self.get_message_part_size(options)
    return 153 if options[:data_coding].nil?
    return 153 if options[:data_coding] == 0
    return 153 if options[:data_coding] == 3
    return 134 if options[:data_coding] == 5
    return 134 if options[:data_coding] == 6
    return 134 if options[:data_coding] == 7
    return 67 if options[:data_coding] == 8
    return 153
  end
end
