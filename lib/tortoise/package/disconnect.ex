defmodule Tortoise.Package.Disconnect do
  @moduledoc false

  @opcode 14

  # @allowed_properties [:reason_string, :server_reference, :session_expiry_interval, :user_property]

  alias Tortoise.Package

  @type reason ::
          :normal_disconnection
          | :disconnect_with_will_message
          | :unspecified_error
          | :malformed_packet
          | :protocol_error
          | :implementation_specific_error
          | :not_authorized
          | :server_busy
          | :server_shutting_down
          | :keep_alive_timeout
          | :session_taken_over
          | :topic_filter_invalid
          | :topic_name_invalid
          | :receive_maximum_exceeded
          | :topic_alias_invalid
          | :packet_too_large
          | :message_rate_too_high
          | :quota_exceeded
          | :administrative_action
          | :payload_format_invalid
          | :retain_not_supported
          | :qos_not_supported
          | :use_another_server
          | :server_moved
          | :shared_subscriptions_not_supported
          | :connection_rate_exceeded
          | :maximum_connect_time
          | :subscription_identifiers_not_supported
          | :wildcard_subscriptions_not_supported

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            reason: reason(),
            # todo, let this live in the properties module
            properties: [{atom(), any()}]
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            reason: :normal_disconnection,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, 0::8>>) do
    # If the Remaining Length is less than 1 the value of 0x00 (Normal
    # disconnection) is used
    %__MODULE__{reason: coerce_reason_code(0x00)}
  end

  def decode(<<@opcode::4, 0::4, variable_header::binary>>) do
    <<reason_code::8, properties::binary>> = drop_length_prefix(variable_header)

    %__MODULE__{
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :normal_disconnection
      0x04 -> :disconnect_with_will_message
      0x80 -> :unspecified_error
      0x81 -> :malformed_packet
      0x82 -> :protocol_error
      0x83 -> :implementation_specific_error
      0x87 -> :not_authorized
      0x89 -> :server_busy
      0x8B -> :server_shutting_down
      0x8D -> :keep_alive_timeout
      0x8E -> :session_taken_over
      0x8F -> :topic_filter_invalid
      0x90 -> :topic_name_invalid
      0x93 -> :receive_maximum_exceeded
      0x94 -> :topic_alias_invalid
      0x95 -> :packet_too_large
      0x96 -> :message_rate_too_high
      0x97 -> :quota_exceeded
      0x98 -> :administrative_action
      0x99 -> :payload_format_invalid
      0x9A -> :retain_not_supported
      0x9B -> :qos_not_supported
      0x9C -> :use_another_server
      0x9D -> :server_moved
      0x9E -> :shared_subscriptions_not_supported
      0x9F -> :connection_rate_exceeded
      0xA0 -> :maximum_connect_time
      0xA1 -> :subscription_identifiers_not_supported
      0xA2 -> :wildcard_subscriptions_not_supported
    end
  end

  defp drop_length_prefix(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Disconnect{reason: :normal_disconnection, properties: []} = t) do
      [Package.Meta.encode(t.__META__), 0]
    end

    def encode(%Package.Disconnect{} = t) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(reason) do
      case reason do
        :normal_disconnection -> 0x00
        :disconnect_with_will_message -> 0x04
        :unspecified_error -> 0x80
        :malformed_packet -> 0x81
        :protocol_error -> 0x82
        :implementation_specific_error -> 0x83
        :not_authorized -> 0x87
        :server_busy -> 0x89
        :server_shutting_down -> 0x8B
        :keep_alive_timeout -> 0x8D
        :session_taken_over -> 0x8E
        :topic_filter_invalid -> 0x8F
        :topic_name_invalid -> 0x90
        :receive_maximum_exceeded -> 0x93
        :topic_alias_invalid -> 0x94
        :packet_too_large -> 0x95
        :message_rate_too_high -> 0x96
        :quota_exceeded -> 0x97
        :administrative_action -> 0x98
        :payload_format_invalid -> 0x99
        :retain_not_supported -> 0x9A
        :qos_not_supported -> 0x9B
        :use_another_server -> 0x9C
        :server_moved -> 0x9D
        :shared_subscriptions_not_supported -> 0x9E
        :connection_rate_exceeded -> 0x9F
        :maximum_connect_time -> 0xA0
        :subscription_identifiers_not_supported -> 0xA1
        :wildcard_subscriptions_not_supported -> 0xA2
      end
    end
  end
end
