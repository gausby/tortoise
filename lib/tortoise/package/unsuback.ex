defmodule Tortoise.Package.Unsuback do
  @moduledoc false

  @opcode 11

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type refusal ::
          :no_subscription_existed
          | :unspecified_error
          | :implementation_specific_error
          | :not_authorized
          | :topic_filter_invalid
          | :packet_identifier_in_use

  @type result() :: :success | {:error, refusal()}

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            results: [],
            properties: [{:reason_string, any()}, {:user_property, any()}]
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0000},
            identifier: nil,
            results: [],
            properties: []

  @spec decode(binary()) :: t | {:error, term()}
  def decode(<<@opcode::4, 0::4, package::binary>>) do
    with payload <- drop_length(package),
         <<identifier::big-integer-size(16), rest::binary>> <- payload,
         {properties, unsubacks} = Package.parse_variable_length(rest) do
      case return_codes_to_list(unsubacks) do
        [] ->
          {:error, {:protocol_violation, :empty_unsubscription_ack}}

        results ->
          %__MODULE__{
            identifier: identifier,
            results: results,
            properties: Package.Properties.decode(properties)
          }
      end
    end
  end

  defp return_codes_to_list(<<>>), do: []

  defp return_codes_to_list(<<reason::8, rest::binary>>) do
    [
      case reason do
        0x00 -> :success
        0x11 -> {:error, :no_subscription_existed}
        0x80 -> {:error, :unspecified_error}
        0x83 -> {:error, :implementation_specific_error}
        0x87 -> {:error, :not_authorized}
        0x8F -> {:error, :topic_filter_invalid}
        0x91 -> {:error, :packet_identifier_in_use}
      end
    ] ++ return_codes_to_list(rest)
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Unsuback{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          Enum.map(t.results, &encode_result/1)
        ])
      ]
    end

    defp encode_result(:success), do: 0x00

    defp encode_result({:error, reason}) do
      case reason do
        :no_subscription_existed -> 0x11
        :unspecified_error -> 0x80
        :implementation_specific_error -> 0x83
        :not_authorized -> 0x87
        :topic_filter_invalid -> 0x8F
        :packet_identifier_in_use -> 0x91
      end
    end
  end
end
