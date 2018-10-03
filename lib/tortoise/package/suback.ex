defmodule Tortoise.Package.Suback do
  @moduledoc false

  @opcode 9

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type qos :: 0 | 1 | 2
  @type refusal_reason ::
          :unspecified_error
          | :implementation_specific_error
          | :not_authorized
          | :topic_filter_invalid
          | :packet_identifier_in_use
          | :quota_exceeded
          | :shared_subscriptions_not_supported
          | :subscription_identifiers_not_supported
          | :wildcard_subscriptions_not_supported

  @type ack_result :: {:ok, qos} | {:error, refusal_reason()}

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            acks: [ack_result],
            properties: [{any(), any()}]
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            identifier: nil,
            acks: [],
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, payload::binary>>) do
    with payload <- drop_length(payload),
         <<identifier::big-integer-size(16), rest::binary>> <- payload,
         {properties, acks} = Package.parse_variable_length(rest) do
      case return_codes_to_list(acks) do
        [] ->
          {:error, {:protocol_violation, :empty_subscription_ack}}

        sub_acks ->
          %__MODULE__{
            identifier: identifier,
            acks: sub_acks,
            properties: Package.Properties.decode(properties)
          }
      end
    end
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp return_codes_to_list(<<>>), do: []

  defp return_codes_to_list(<<code::8, rest::binary>>) do
    [
      case code do
        maximum_qos when code in 0x00..0x02 ->
          {:ok, maximum_qos}

        0x80 ->
          {:error, :unspecified_error}

        0x83 ->
          {:error, :implementation_specific_error}

        0x87 ->
          {:error, :not_authorized}

        0x8F ->
          {:error, :topic_filter_invalid}

        0x91 ->
          {:error, :packet_identifier_in_use}

        0x97 ->
          {:error, :quota_exceeded}

        0x9E ->
          {:error, :shared_subscriptions_not_supported}

        0xA1 ->
          {:error, :subscription_identifiers_not_supported}

        0xA2 ->
          {:error, :wildcard_subscriptions_not_supported}
      end
    ] ++ return_codes_to_list(rest)
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Suback{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          Enum.map(t.acks, &encode_ack/1)
        ])
      ]
    end

    defp encode_ack({:ok, qos}) when qos in 0x00..0x02, do: qos
    defp encode_ack({:error, :unspecified_error}), do: 0x80
    defp encode_ack({:error, :implementation_specific_error}), do: 0x83
    defp encode_ack({:error, :not_authorized}), do: 0x87
    defp encode_ack({:error, :topic_filter_invalid}), do: 0x8F
    defp encode_ack({:error, :packet_identifier_in_use}), do: 0x91
    defp encode_ack({:error, :quota_exceeded}), do: 0x97
    defp encode_ack({:error, :shared_subscriptions_not_supported}), do: 0x9E
    defp encode_ack({:error, :subscription_identifiers_not_supported}), do: 0xA1
    defp encode_ack({:error, :wildcard_subscriptions_not_supported}), do: 0xA2
  end
end
