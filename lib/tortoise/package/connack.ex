defmodule Tortoise.Package.Connack do
  @moduledoc false

  @opcode 2

  # @allowed_properties [:assigned_client_identifier, :authentication_data, :authentication_method, :maximum_packet_size, :maximum_qos, :reason_string, :receive_maximum, :response_information, :retain_available, :server_keep_alive, :server_reference, :session_expiry_interval, :shared_subscription_available, :subscription_identifier_available, :topic_alias_maximum, :user_property, :wildcard_subscription_available]

  alias Tortoise.Package

  @type reason :: :success | {:refused, refusal_reasons()}
  @type refusal_reasons ::
          :unspecified_error
          | :malformed_packet
          | :protocol_error
          | :implementation_specific_error
          | :unsupported_protocol_version
          | :client_identifier_not_valid
          | :bad_user_name_or_password
          | :not_authorized
          | :server_unavailable
          | :server_busy
          | :banned
          | :bad_authentication_method
          | :topic_name_invalid
          | :packet_too_large
          | :quota_exceeded
          | :payload_format_invalid
          | :retain_not_supported
          | :qos_not_supported
          | :use_another_server
          | :server_moved
          | :connection_rate_exceeded

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            session_present: boolean(),
            reason: reason(),
            properties: [{any(), any()}]
          }
  @enforce_keys [:reason]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            session_present: false,
            reason: :success,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, variable_header::binary>>) do
    <<0::7, session_present::1, reason_code::8, properties::binary>> =
      Package.drop_length_prefix(variable_header)

    %__MODULE__{
      session_present: session_present == 1,
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :success
      0x80 -> {:refused, :unspecified_error}
      0x81 -> {:refused, :malformed_packet}
      0x82 -> {:refused, :protocol_error}
      0x83 -> {:refused, :implementation_specific_error}
      0x84 -> {:refused, :unsupported_protocol_version}
      0x85 -> {:refused, :client_identifier_not_valid}
      0x86 -> {:refused, :bad_user_name_or_password}
      0x87 -> {:refused, :not_authorized}
      0x88 -> {:refused, :server_unavailable}
      0x89 -> {:refused, :server_busy}
      0x8A -> {:refused, :banned}
      0x8C -> {:refused, :bad_authentication_method}
      0x90 -> {:refused, :topic_name_invalid}
      0x95 -> {:refused, :packet_too_large}
      0x97 -> {:refused, :quota_exceeded}
      0x99 -> {:refused, :payload_format_invalid}
      0x9A -> {:refused, :retain_not_supported}
      0x9B -> {:refused, :qos_not_supported}
      0x9C -> {:refused, :use_another_server}
      0x9D -> {:refused, :server_moved}
      0x9F -> {:refused, :connection_rate_exceeded}
    end
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Connack{} = t) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<0::7, flag(t.session_present)::1, to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(:success), do: 0x00

    defp to_reason_code({:refused, reason}) do
      case reason do
        :unspecified_error -> 0x80
        :malformed_packet -> 0x81
        :protocol_error -> 0x82
        :implementation_specific_error -> 0x83
        :unsupported_protocol_version -> 0x84
        :client_identifier_not_valid -> 0x85
        :bad_user_name_or_password -> 0x86
        :not_authorized -> 0x87
        :server_unavailable -> 0x88
        :server_busy -> 0x89
        :banned -> 0x8A
        :bad_authentication_method -> 0x8C
        :topic_name_invalid -> 0x90
        :packet_too_large -> 0x95
        :quota_exceeded -> 0x97
        :payload_format_invalid -> 0x99
        :retain_not_supported -> 0x9A
        :qos_not_supported -> 0x9B
        :use_another_server -> 0x9C
        :server_moved -> 0x9D
        :connection_rate_exceeded -> 0x9F
      end
    end

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end
end
