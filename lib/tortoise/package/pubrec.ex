defmodule Tortoise.Package.Pubrec do
  @moduledoc false

  @opcode 5

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type reason :: :success | {:refused, refusal_reasons()}
  @type refusal_reasons ::
          :no_matching_subscribers
          | :unspecified_error
          | :implementation_specific_error
          | :not_authorized
          | :topic_Name_invalid
          | :packet_identifier_in_use
          | :quota_exceeded
          | :payload_format_invalid

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            reason: reason(),
            properties: [{:reason_string, String.t()}, {:user_property, String.t()}]
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0000},
            identifier: nil,
            reason: :success,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier, reason: :success, properties: []}
  end

  def decode(<<@opcode::4, 0::4, variable_header::binary>>) do
    <<identifier::big-integer-size(16), reason_code::8, properties::binary>> =
      Package.drop_length_prefix(variable_header)

    %__MODULE__{
      identifier: identifier,
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :success
      0x10 -> :no_matching_subscribers
      0x80 -> :unspecified_error
      0x83 -> :implementation_specific_error
      0x87 -> :not_authorized
      0x90 -> :topic_Name_invalid
      0x91 -> :packet_identifier_in_use
      0x97 -> :quota_exceeded
      0x99 -> :payload_format_invalid
    end
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(
          %Package.Pubrec{
            identifier: identifier,
            reason: :success,
            properties: []
          } = t
        )
        when identifier in 0x0001..0xFFFF do
      # The Reason Code and Property Length can be omitted if the
      # Reason Code is 0x00 (Success) and there are no Properties
      [Package.Meta.encode(t.__META__), <<2, identifier::big-integer-size(16)>>]
    end

    def encode(%Package.Pubrec{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16), to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(:success), do: 0x00

    defp to_reason_code({:refused, reason}) do
      case reason do
        :no_matching_subscribers -> 0x10
        :unspecified_error -> 0x80
        :implementation_specific_error -> 0x83
        :not_authorized -> 0x87
        :topic_Name_invalid -> 0x90
        :packet_identifier_in_use -> 0x91
        :quota_exceeded -> 0x97
        :payload_format_invalid -> 0x99
      end
    end
  end
end
