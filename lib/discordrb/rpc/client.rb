require 'json'
require 'securerandom'

require 'discordrb/websocket'
require 'discordrb/rpc/frame_cycle'
require 'discordrb/rpc/data'

module Discordrb::RPC
  # Client for Discord's RPC protocol.
  class Client
    attr_reader :ws

    def initialize(client_id, origin)
      @client_id = client_id
      @origin = origin

      # A hash of nonce to FrameCycle, so we can wait for responses in a more
      # sane way than `sleep 0.1 until`
      @cycles = {}
    end

    def run
      connect
    end

    def authorise(scopes)
      send_frame(:AUTHORIZE, client_id: @client_id.to_s, scopes: scopes)
    end

    def authenticate(token)
      send_frame(:AUTHENTICATE, access_token: token)
    end

    # Switches the client's view to a particular text channel.
    # @param id [Integer] the ID of the channel to switch to.
    # @return [RPCChannel] the channel that was switched to.
    def select_text_channel(id)
      response = send_frame(:SELECT_TEXT_CHANNEL, channel_id: id.to_s)
      RPCChannel.new(response['data'])
    end

    def select_voice_channel(id)
      send_frame(:SELECT_VOICE_CHANNEL, channel_id: id.to_s)
    end

    # Obtains a list of all the servers the controlled user is in, with basic
    # information such as name and icon URL.
    # @return [Array<RPCLightServer>] the servers the user is in.
    def servers
      response = send_frame(:GET_GUILDS, nil)
      response['data']['guilds'].map { |e| RPCLightServer.new(e) }
    end

    # Obtains more detailed information (i. e. the member list) of a particular
    # server the controlled user is in.
    # @return [RPCServer] the requested server.
    def server(id)
      response = send_frame(:GET_GUILD, guild_id: id.to_s)
      RPCServer.new(response['data'])
    end

    private

    def send_frame(command, payload, event = nil)
      nonce = SecureRandom.uuid
      send_frame_internal(command, payload, event, nonce)

      cycle = @cycles[nonce] = FrameCycle.new(nonce)
      response = cycle.wait_for_response

      @cycles.delete(nonce)

      # TODO: error classes
      raise "RPC error: #{response['data']}" if response['evt'] == 'ERROR'

      response
    end

    def send_frame_internal(command, payload, event, nonce)
      frame = {
        cmd: command,
        args: payload,
        evt: event,
        nonce: nonce
      }

      data = frame.to_json
      Discordrb::LOGGER.debug("RPCWS send: #{data}")
      @ws.send(data)
    end

    def connect
      url = "wss://discordapp.io:6463/?v=1&client_id=#{@client_id}"

      headers = {
        origin: @origin
      }

      @ws = Discordrb::WebSocket.new(
        url,
        method(:websocket_open),
        method(:websocket_message),
        proc { |e| Discordrb::LOGGER.error "RPCWS error: #{e}" },
        proc { |e| Discordrb::LOGGER.warn "RPCWS close: #{e}" },
        headers: headers
      )
    end

    def websocket_open
      Discordrb::LOGGER.debug 'RPCWS opened'
    end

    def websocket_message(msg)
      Discordrb::LOGGER.debug "RPCWS message: #{msg}"

      data = JSON.parse(msg)
      nonce = data['nonce']
      cycle = @cycles[nonce]

      if cycle
        # Notify that we're done with this particular cycle
        cycle.notify_response(data)
      end

      @last_data = data['data']

      Discordrb::LOGGER.debug "RPCWS: processed #{nonce}"
    end
  end
end
